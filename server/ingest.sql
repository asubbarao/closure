-- ingest.sql — LOAD step: pin expensive corpus extracts; issue ids once.
-- Depends on: SET samples_dir / exports_dir (app.sql); sources.sql (v_src_pdf_info).
-- No qnorm, v_grams, regex joins, cfg_* macros, row_number, or identities unpivot.

-- cases: distinct case_no from the manifest (natural key = case_no).
-- Manifest is nested (files[] of structs) — unnest is the clean read of what exists;
-- generator should eventually emit a flat case list.
CREATE OR REPLACE TABLE cases AS
SELECT DISTINCT
    cast(f.case_no AS VARCHAR) AS id,
    cast(f.case_no AS VARCHAR) AS case_no,
    'Case ' || cast(f.case_no AS VARCHAR) AS title
FROM (
    SELECT unnest(files) AS f
    FROM read_json_auto(getvariable('samples_dir') || '/manifest.json')
);

-- documents: v_src_pdf_info × manifest. uuid() issued once at load (ruling C).
-- Join via parse_filename (built-in basename) — no regex.
CREATE OR REPLACE TABLE documents AS
SELECT
    uuid()                     AS id,
    cast(m.case_no AS VARCHAR) AS case_id,
    p.filename,
    p.source_path,
    p.page_count::INTEGER      AS page_count,
    p.width_pt::DOUBLE         AS width_pt,
    p.height_pt::DOUBLE        AS height_pt,
    p.file_size::BIGINT        AS file_size
FROM v_src_pdf_info p
JOIN (
    SELECT
        parse_filename(cast(f.filename AS VARCHAR), true) AS filename,
        cast(f.case_no AS VARCHAR) AS case_no
    FROM (
        SELECT unnest(files) AS f
        FROM read_json_auto(getvariable('samples_dir') || '/manifest.json')
    )
) m ON m.filename = p.filename;

-- pages / words: expensive extracts — pin to tables.
CREATE OR REPLACE TABLE pages AS
SELECT
    d.id            AS document_id,
    p.page::INTEGER AS page_no,
    p.width::DOUBLE AS width_pt,
    p.height::DOUBLE AS height_pt
FROM read_pdf(getvariable('samples_dir') || '/*.pdf') p
JOIN documents d ON d.filename = parse_filename(p.filename, true);

-- No fabricated seq (no row_number). Order by (page_no, y0, x0) or use ngrams().
CREATE OR REPLACE TABLE words AS
SELECT
    d.id                    AS document_id,
    w.page::INTEGER         AS page_no,
    cast(w.word AS VARCHAR) AS word,
    w.x0::DOUBLE AS x0, w.y0::DOUBLE AS y0,
    w.x1::DOUBLE AS x1, w.y1::DOUBLE AS y1,
    w.font_size::DOUBLE     AS font_size
FROM read_pdf_words(getvariable('samples_dir') || '/*.pdf') w
JOIN documents d ON d.filename = parse_filename(w.filename, true);

-- watchlist: flat operator-known parties (a case's known names/orgs), read
-- straight from the generator's flat artifact — the reshaping lives at the
-- source, NOT in the app (ruling B). detect.sql consumes it via rapidfuzz. A
-- real deployment swaps samples/watchlist.json for a case-management feed of the
-- same term/kind/case_no shape; the app is unchanged.
CREATE OR REPLACE TABLE watchlist AS
SELECT cast(term AS VARCHAR)    AS term,
       cast(kind AS VARCHAR)    AS kind,
       cast(case_no AS VARCHAR) AS case_no
FROM read_json_auto(getvariable('samples_dir') || '/watchlist.json')
WHERE coalesce(trim(term), '') <> '';

-- entities shell: detect.sql fills via finetype / addrust / watchlist matching.
CREATE OR REPLACE TABLE entities AS
SELECT cast(NULL AS UUID)    AS id,
       cast(NULL AS VARCHAR) AS case_id,
       cast(NULL AS VARCHAR) AS canonical_text,
       cast(NULL AS VARCHAR) AS kind
WHERE false;

COPY (
    SELECT case_id, filename, source_path,
           getvariable('exports_dir') || '/' || filename || '_redacted.pdf' AS out_path
    FROM documents
    ORDER BY case_id, filename
) TO 'exports/export_map.csv' (HEADER true, DELIMITER ',');

-- Manifest × samples/*.pdf desync rows (integrity gate, not a stats dump).
-- Consumers: ingest assert + app.sql boot orphan diagnostics / integrity.
CREATE OR REPLACE VIEW v_ingest_orphans AS
WITH
manifest AS (
    SELECT
        parse_filename(cast(f.filename AS VARCHAR), true) AS filename,
        cast(f.case_no AS VARCHAR) AS case_no
    FROM (
        SELECT unnest(files) AS f
        FROM read_json_auto(getvariable('samples_dir') || '/manifest.json')
    )
),
pdfs AS (SELECT filename FROM v_src_pdf_info)
SELECT 'manifest_no_pdf' AS kind, m.filename AS name, m.case_no AS detail
FROM manifest m
WHERE NOT EXISTS (SELECT 1 FROM pdfs p WHERE p.filename = m.filename)
UNION ALL
SELECT 'pdf_not_in_manifest', p.filename, p.filename
FROM pdfs p
WHERE NOT EXISTS (SELECT 1 FROM manifest m WHERE m.filename = p.filename);

SELECT CASE
    WHEN (SELECT count(*) FROM v_ingest_orphans) > 0
    THEN error(
        'ingest desync (manifest × samples/*.pdf): ' ||
        coalesce(
            (SELECT string_agg(kind || ':' || name, ', ' ORDER BY kind, name)
             FROM v_ingest_orphans),
            '(unknown)'
        )
    )
    WHEN (SELECT count(*) FROM documents) = 0
    THEN error('ingest produced 0 documents')
    WHEN (SELECT count(*) FROM cases) = 0
    THEN error('ingest produced 0 cases')
    WHEN (SELECT count(*) FROM words) = 0
    THEN error('ingest produced 0 words')
    WHEN (SELECT count(*) FROM pages) = 0
    THEN error('ingest produced 0 pages')
    ELSE 'ingest integrity ok'
END AS ingest_integrity;

SELECT 'ingest complete' AS status,
       (SELECT count(*) FROM cases)     AS cases,
       (SELECT count(*) FROM documents) AS documents,
       (SELECT count(*) FROM pages)     AS pages,
       (SELECT count(*) FROM words)     AS words,
       (SELECT count(*) FROM watchlist) AS watchlist,
       (SELECT count(*) FROM entities)  AS entities;
