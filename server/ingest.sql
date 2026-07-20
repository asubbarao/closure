-- ingest.sql — pure CTAS load from samples/ (no INSERT, no SET VARIABLE for setup).
--
-- FILE MANAGER GLOB ASSOCIATION:
--   1. Discover on-disk PDFs via pdf_info('samples/*.pdf') (pdf ext glob-read).
--   2. Read expected files + case_no from samples/manifest.json.
--   3. Associate PDF → case by (a) exact basename match to manifest, then
--      (b) filename pattern _YYYY-NNNN[A-Z]?.pdf → case_no YY-NNNN when
--      identities.json carries that case.
--   4. Fail loudly on any triad desync (manifest × identities × PDF basenames)
--      via ingest_orphan_diag() + boot-time asserts (kept here and in app.sql).
--
-- Reads: {samples_dir}/*.pdf, identities.json, manifest.json — samples_dir is
-- app_config-driven via cfg_samples_dir() (server/config.sql must load first;
-- table-function args are fold-only, so the macro rides where subqueries cannot).
-- Run from repo root. Does NOT load samples/messy/ or samples/stress/.

CREATE OR REPLACE MACRO qnorm(t) AS lower(trim(cast(t AS VARCHAR), '.,;:()"'''));

-- Tear down prior boot (CREATE OR REPLACE alone cannot break FK/view chains).
DROP VIEW IF EXISTS v_audit CASCADE;
DROP VIEW IF EXISTS v_suggestions CASCADE;
DROP VIEW IF EXISTS v_document_stats CASCADE;
DROP VIEW IF EXISTS v_entity_hits CASCADE;
DROP VIEW IF EXISTS v_grams CASCADE;
DROP VIEW IF EXISTS v_decision_log CASCADE;
DROP VIEW IF EXISTS v_manual_suggestions CASCADE;
DROP TABLE IF EXISTS decisions CASCADE;
DROP TABLE IF EXISTS audit_events CASCADE;
DROP TABLE IF EXISTS suggestions CASCADE;
DROP TABLE IF EXISTS entities CASCADE;
DROP TABLE IF EXISTS words CASCADE;
DROP TABLE IF EXISTS pages CASCADE;
DROP TABLE IF EXISTS documents CASCADE;
DROP TABLE IF EXISTS cases CASCADE;
DROP TABLE IF EXISTS app_templates CASCADE;
DROP TABLE IF EXISTS _seed_targets CASCADE;
DROP TABLE IF EXISTS _seed_hits CASCADE;
DROP TABLE IF EXISTS _seed_context CASCADE;
DROP SEQUENCE IF EXISTS seq_decision;
DROP SEQUENCE IF EXISTS seq_manual;

-- ── cases (from identities.json answer-key cast) ───────────────────────────
CREATE OR REPLACE TABLE cases AS
SELECT
    row_number() OVER (ORDER BY c.case_no)::INTEGER AS id,
    cast(c.case_no AS VARCHAR) AS case_no,
    'State v. ' || regexp_extract(cast(c.subject.name AS VARCHAR), '(\S+)$', 1)
        || ' — public records release' AS title
FROM (
    SELECT unnest(cases) AS c
    FROM read_json_auto(cfg_samples_dir() || '/identities.json')
);

-- ── documents: glob PDFs × manifest × cases ────────────────────────────────
-- Association rules (in order):
--   1. manifest.filename == pdf basename → use manifest.case_no
--   2. else parse stem: <docstem>_YYYY-NNNN[A-Z]? → case_no = YY-NNNN
--      when that case exists in identities
-- Rows without a resolvable case_id are dropped from documents; orphan diag
-- reports them so boot integrity fails loudly.
CREATE OR REPLACE TABLE documents AS
WITH
manifest AS (
    SELECT
        cast(f.filename AS VARCHAR) AS filename,
        cast(f.case_no AS VARCHAR) AS case_no,
        regexp_replace(cast(f.filename AS VARCHAR), '\.pdf$', '') AS stem
    FROM (
        SELECT unnest(files) AS f
        FROM read_json_auto(cfg_samples_dir() || '/manifest.json')
    )
),
pdf_glob AS (
    SELECT
        regexp_replace(file, '.*/', '') AS basename,
        regexp_replace(regexp_replace(file, '.*/', ''), '\.pdf$', '') AS stem,
        -- Filename pattern from generator: {stem}_YYYY-NNNN[A-Z]?.pdf
        -- → case_no "YY-NNNN" (identities use 2-digit year prefix).
        CASE
            WHEN regexp_matches(
                regexp_replace(file, '.*/', ''),
                '_\d{4}-\d+[A-Za-z]?\.pdf$'
            )
            THEN substr(
                    regexp_extract(
                        regexp_replace(file, '.*/', ''),
                        '_(\d{4})-(\d+)[A-Za-z]?\.pdf$',
                        1
                    ),
                    3, 2
                 )
                 || '-'
                 || regexp_extract(
                        regexp_replace(file, '.*/', ''),
                        '_(\d{4})-(\d+)[A-Za-z]?\.pdf$',
                        2
                    )
            ELSE NULL
        END AS case_no_from_name,
        page_count,
        width,
        height,
        file_size,
        file AS full_path
    FROM pdf_info(cfg_samples_dir() || '/*.pdf')
),
-- Glob discovers on-disk PDFs; manifest filename is the association key to case_no.
-- Filename pattern is validated in orphan diag (must agree with manifest.case_no).
associated AS (
    SELECT
        p.basename,
        p.stem,
        p.page_count,
        p.width,
        p.height,
        p.file_size,
        p.full_path,
        m.case_no
    FROM pdf_glob p
    INNER JOIN manifest m ON m.filename = p.basename
)
SELECT
    row_number() OVER (ORDER BY a.stem)::INTEGER AS id,
    ca.id AS case_id,
    a.stem AS filename,
    cfg_samples_dir() || '/' || a.basename AS source_path,
    a.page_count::INTEGER AS page_count,
    a.width::DOUBLE AS width_pt,
    a.height::DOUBLE AS height_pt,
    a.file_size::BIGINT AS file_size
FROM associated a
JOIN cases ca ON ca.case_no = a.case_no;

-- ── pages ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE pages AS
SELECT
    d.id AS document_id,
    p.page::INTEGER AS page_no,
    coalesce(p.width, d.width_pt)::DOUBLE AS width_pt,
    coalesce(p.height, d.height_pt)::DOUBLE AS height_pt
FROM read_pdf(cfg_samples_dir() || '/*.pdf') p
JOIN documents d
  ON d.filename = regexp_replace(regexp_replace(p.filename, '.*/', ''), '\.pdf$', '');

-- ── words ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE words AS
SELECT
    d.id AS document_id,
    w.page::INTEGER AS page_no,
    row_number() OVER (
        PARTITION BY d.id, w.page
        ORDER BY round(w.y0, 1), w.x0, w.word
    )::INTEGER AS seq,
    cast(w.word AS VARCHAR) AS word,
    w.x0::DOUBLE AS x0,
    w.y0::DOUBLE AS y0,
    w.x1::DOUBLE AS x1,
    w.y1::DOUBLE AS y1,
    w.font_size::DOUBLE AS font_size
FROM read_pdf_words(cfg_samples_dir() || '/*.pdf') w
JOIN documents d
  ON d.filename = regexp_replace(regexp_replace(w.filename, '.*/', ''), '\.pdf$', '');

-- ── entities (answer-key catalog from identities.json) ─────────────────────
CREATE OR REPLACE TABLE entities AS
WITH roster AS (
    SELECT
        ca.id AS case_id,
        c.case_no,
        c.subject,
        c.witnesses,
        c.officers,
        c.fp_street,
        c.fp_citation
    FROM (
        SELECT unnest(cases) AS c
        FROM read_json_auto(cfg_samples_dir() || '/identities.json')
    )
    JOIN cases ca ON ca.case_no = cast(c.case_no AS VARCHAR)
),
raw AS (
    SELECT case_id, cast(subject.name AS VARCHAR) AS text, 'PERSON · SUBJECT' AS kind FROM roster
    UNION ALL
    SELECT case_id, cast(subject.ssn AS VARCHAR), 'SSN' FROM roster
    UNION ALL
    SELECT case_id, cast(subject.dob AS VARCHAR), 'DATE OF BIRTH' FROM roster
    UNION ALL
    SELECT case_id, cast(subject.address AS VARCHAR), 'ADDRESS · SUBJECT' FROM roster
    UNION ALL
    SELECT case_id, cast(subject.phone AS VARCHAR), 'PHONE · SUBJECT' FROM roster
    UNION ALL
    SELECT case_id, cast(w.name AS VARCHAR), 'PERSON · WITNESS'
    FROM roster, unnest(witnesses) AS t(w)
    UNION ALL
    SELECT case_id, cast(w.phone AS VARCHAR), 'PHONE · WITNESS'
    FROM roster, unnest(witnesses) AS t(w)
    UNION ALL
    SELECT case_id, cast(o AS VARCHAR), 'OFFICER · NOT SUBJECT PII'
    FROM roster, unnest(officers) AS t(o)
    UNION ALL
    SELECT case_id, cast(fp_street AS VARCHAR), 'STREET NAME · NOT PII' FROM roster
    WHERE fp_street IS NOT NULL AND cast(fp_street AS VARCHAR) <> ''
    UNION ALL
    SELECT case_id, cast(fp_citation AS VARCHAR), 'CITATION · NOT PII' FROM roster
    WHERE fp_citation IS NOT NULL AND cast(fp_citation AS VARCHAR) <> ''
)
SELECT
    row_number() OVER (ORDER BY case_id, kind, text)::INTEGER AS id,
    case_id,
    text AS canonical_text,
    kind
FROM raw
WHERE text IS NOT NULL AND trim(text) <> '';

-- ── n-gram geometry helper (same-line consecutive words) ───────────────────
CREATE OR REPLACE VIEW v_grams AS
WITH base AS (
    SELECT document_id, page_no, seq, word, x0, y0, x1, y1,
           lead(word, 1) OVER w AS word1, lead(x1, 1) OVER w AS x1_1,
           lead(y0, 1) OVER w AS y0_1,   lead(y1, 1) OVER w AS y1_1,
           lead(word, 2) OVER w AS word2, lead(x1, 2) OVER w AS x1_2,
           lead(y0, 2) OVER w AS y0_2,   lead(y1, 2) OVER w AS y1_2,
           lead(word, 3) OVER w AS word3, lead(x1, 3) OVER w AS x1_3,
           lead(y0, 3) OVER w AS y0_3,   lead(y1, 3) OVER w AS y1_3
    FROM words
    WINDOW w AS (PARTITION BY document_id, page_no ORDER BY seq)
)
SELECT document_id, page_no, seq, 1 AS n, qnorm(word) AS text_norm,
       word AS text_raw, x0, y0, x1, y1
FROM base
UNION ALL
SELECT document_id, page_no, seq, 2, qnorm(word) || ' ' || qnorm(word1),
       word || ' ' || word1, x0, least(y0, y0_1), x1_1, greatest(y1, y1_1)
FROM base WHERE word1 IS NOT NULL AND abs(y0_1 - y0) < 2
UNION ALL
SELECT document_id, page_no, seq, 3,
       qnorm(word) || ' ' || qnorm(word1) || ' ' || qnorm(word2),
       word || ' ' || word1 || ' ' || word2,
       x0, least(y0, y0_1, y0_2), x1_2, greatest(y1, y1_1, y1_2)
FROM base WHERE word2 IS NOT NULL AND abs(y0_1 - y0) < 2 AND abs(y0_2 - y0) < 2
UNION ALL
SELECT document_id, page_no, seq, 4,
       qnorm(word) || ' ' || qnorm(word1) || ' ' || qnorm(word2) || ' ' || qnorm(word3),
       word || ' ' || word1 || ' ' || word2 || ' ' || word3,
       x0, least(y0, y0_1, y0_2, y0_3), x1_3, greatest(y1, y1_1, y1_2, y1_3)
FROM base WHERE word3 IS NOT NULL
       AND abs(y0_1 - y0) < 2 AND abs(y0_2 - y0) < 2 AND abs(y0_3 - y0) < 2;

-- ── audit snapshot (derived; not the mutable decisions log) ────────────────
CREATE OR REPLACE TABLE audit_events AS
SELECT
    row_number() OVER (ORDER BY c.id)::INTEGER AS id,
    now() AS ts,
    'system' AS actor,
    'ingested' AS action,
    NULL::INTEGER AS suggestion_id,
    c.id AS case_id,
    format(
        '{} documents · {} pages · {} words · {} entities',
        (SELECT count(*) FROM documents d WHERE d.case_id = c.id),
        (SELECT count(*) FROM pages p JOIN documents d ON d.id = p.document_id WHERE d.case_id = c.id),
        (SELECT count(*) FROM words w JOIN documents d ON d.id = w.document_id WHERE d.case_id = c.id),
        (SELECT count(*) FROM entities e WHERE e.case_id = c.id)
    ) AS target,
    NULL::VARCHAR AS reason
FROM cases c;

-- COPY TO target is a grammar literal (no expressions); the boot artifact
-- always lands under the repo-relative exports/ default.
COPY (
    SELECT case_id, filename, source_path,
           cfg_exports_dir() || '/' || filename || '_redacted.pdf' AS out_path
    FROM documents
    ORDER BY case_id, filename
) TO 'exports/export_map.csv' (HEADER true, DELIMITER ',');

-- Orphan diagnostics for sample triad desync (manifest × identities × PDF basenames).
-- Used by app.sql boot integrity to fail loudly instead of serving an empty app.
CREATE OR REPLACE MACRO ingest_orphan_diag() AS TABLE
WITH
manifest AS (
    SELECT
        cast(f.filename AS VARCHAR) AS filename,
        cast(f.case_no AS VARCHAR) AS case_no,
        regexp_replace(cast(f.filename AS VARCHAR), '\.pdf$', '') AS stem
    FROM (
        SELECT unnest(files) AS f
        FROM read_json_auto(cfg_samples_dir() || '/manifest.json')
    )
),
pdfs AS (
    SELECT
        regexp_replace(file, '.*/', '') AS basename,
        regexp_replace(regexp_replace(file, '.*/', ''), '\.pdf$', '') AS stem,
        CASE
            WHEN regexp_matches(
                regexp_replace(file, '.*/', ''),
                '_\d{4}-\d+[A-Za-z]?\.pdf$'
            )
            THEN substr(
                    regexp_extract(
                        regexp_replace(file, '.*/', ''),
                        '_(\d{4})-(\d+)[A-Za-z]?\.pdf$',
                        1
                    ),
                    3, 2
                 )
                 || '-'
                 || regexp_extract(
                        regexp_replace(file, '.*/', ''),
                        '_(\d{4})-(\d+)[A-Za-z]?\.pdf$',
                        2
                    )
            ELSE NULL
        END AS case_no_from_name
    FROM pdf_info(cfg_samples_dir() || '/*.pdf')
),
id_cases AS (
    SELECT cast(c.case_no AS VARCHAR) AS case_no
    FROM (
        SELECT unnest(cases) AS c
        FROM read_json_auto(cfg_samples_dir() || '/identities.json')
    )
)
SELECT 'manifest_no_pdf' AS kind, m.filename AS name, m.case_no AS detail
FROM manifest m
WHERE NOT EXISTS (SELECT 1 FROM pdfs p WHERE p.basename = m.filename)
UNION ALL
SELECT 'manifest_no_identity_case', m.filename, m.case_no
FROM manifest m
WHERE NOT EXISTS (SELECT 1 FROM id_cases i WHERE i.case_no = m.case_no)
UNION ALL
SELECT 'pdf_not_in_manifest', p.basename, p.stem
FROM pdfs p
WHERE NOT EXISTS (SELECT 1 FROM manifest m WHERE m.filename = p.basename)
UNION ALL
SELECT 'identity_case_no_manifest_docs', i.case_no, i.case_no
FROM id_cases i
WHERE NOT EXISTS (SELECT 1 FROM manifest m WHERE m.case_no = i.case_no)
UNION ALL
SELECT 'pdf_case_unresolved', p.basename, coalesce(p.case_no_from_name, '(no pattern)')
FROM pdfs p
WHERE NOT EXISTS (SELECT 1 FROM manifest m WHERE m.filename = p.basename)
  AND (
      p.case_no_from_name IS NULL
      OR NOT EXISTS (SELECT 1 FROM id_cases i WHERE i.case_no = p.case_no_from_name)
  )
UNION ALL
SELECT 'manifest_case_mismatch_filename', m.filename,
       m.case_no || ' vs name ' || coalesce(p.case_no_from_name, '?')
FROM manifest m
JOIN pdfs p ON p.basename = m.filename
WHERE p.case_no_from_name IS NOT NULL
  AND m.case_no <> p.case_no_from_name;

-- Fail loudly here (not only in app.sql) so partial boots and offline .read fail too.
SELECT CASE
    WHEN (SELECT count(*) FROM ingest_orphan_diag()) > 0
    THEN error(
        'ingest triad desync (manifest × identities × samples/*.pdf): ' ||
        coalesce(
            (SELECT string_agg(kind || ':' || name, ', ' ORDER BY kind, name)
             FROM ingest_orphan_diag()),
            '(unknown)'
        )
    )
    WHEN (SELECT count(*) FROM documents) = 0
    THEN error('ingest produced 0 documents — empty samples/*.pdf or case association failed')
    WHEN (SELECT count(*) FROM cases) = 0
    THEN error('ingest produced 0 cases — samples/identities.json missing or empty')
    WHEN (SELECT count(*) FROM words) = 0
    THEN error('ingest produced 0 words — PDFs have no text layer or glob failed')
    WHEN (SELECT count(*) FROM pages) = 0
    THEN error('ingest produced 0 pages — read_pdf glob failed')
    ELSE 'ingest integrity ok'
END AS ingest_integrity;

SELECT 'ingest complete' AS status,
       (SELECT count(*) FROM cases)     AS cases,
       (SELECT count(*) FROM documents) AS documents,
       (SELECT count(*) FROM pages)     AS pages,
       (SELECT count(*) FROM words)     AS words,
       (SELECT count(*) FROM entities)  AS entities;
