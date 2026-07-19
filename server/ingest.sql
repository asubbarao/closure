-- ingest.sql — load a case folder into the database from real files only.
--
-- Input (SET VARIABLE data_dir, defaulted by run.sh to samples):
--   <data_dir>/*.pdf
--   <data_dir>/identities.json  — case roster / PII answer key
--   <data_dir>/manifest.json    — which PDF belongs to which case
--
-- Idempotent: clears prior rows then re-reads the directory.
-- No VALUES clauses. No hand-typed PII.
-- suggestions stays EMPTY this pass (seeding is a later step).

SET VARIABLE data_dir = coalesce(getvariable('data_dir'), 'samples');

DELETE FROM audit_events;
DELETE FROM suggestions;
DELETE FROM words;
DELETE FROM pages;
DELETE FROM entities;
DELETE FROM documents;
DELETE FROM cases;

-- ── cases ──────────────────────────────────────────────────────────────────
INSERT INTO cases (id, case_no, title)
SELECT
    row_number() OVER (ORDER BY c.case_no)::INTEGER,
    c.case_no,
    'State v. ' || regexp_extract(c.subject.name, '(\S+)$', 1)
        || ' — public records release'
FROM (
    SELECT unnest(cases) AS c
    FROM read_json_auto(getvariable('data_dir') || '/identities.json')
);

-- ── documents ──────────────────────────────────────────────────────────────
CREATE OR REPLACE TEMP TABLE _manifest AS
SELECT
    f.filename AS filename,
    f.case_no  AS case_no,
    regexp_replace(f.filename, '\.pdf$', '') AS stem
FROM (
    SELECT unnest(files) AS f
    FROM read_json_auto(getvariable('data_dir') || '/manifest.json')
);

CREATE OR REPLACE TEMP TABLE _pdf_info AS
SELECT
    regexp_replace(file, '.*/', '') AS basename,
    page_count, width, height, file_size, file AS full_path
FROM pdf_info(getvariable('data_dir') || '/*.pdf');

INSERT INTO documents (case_id, filename, source_path, page_count, width_pt, height_pt, file_size)
SELECT
    ca.id,
    m.stem,
    getvariable('data_dir') || '/' || m.filename,
    i.page_count,
    i.width,
    i.height,
    i.file_size
FROM _manifest m
JOIN cases ca ON ca.case_no = m.case_no
JOIN _pdf_info i ON i.basename = m.filename;

-- ── pages ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE TEMP TABLE _pdf_pages AS
SELECT
    regexp_replace(regexp_replace(filename, '.*/', ''), '\.pdf$', '') AS stem,
    page, width, height
FROM read_pdf(getvariable('data_dir') || '/*.pdf');

INSERT INTO pages (document_id, page_no, width_pt, height_pt)
SELECT d.id, p.page, coalesce(p.width, d.width_pt), coalesce(p.height, d.height_pt)
FROM _pdf_pages p
JOIN documents d ON d.filename = p.stem;

-- ── words ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE TEMP TABLE _pdf_words AS
SELECT
    regexp_replace(regexp_replace(filename, '.*/', ''), '\.pdf$', '') AS stem,
    page, word, x0, y0, x1, y1, font_size
FROM read_pdf_words(getvariable('data_dir') || '/*.pdf');

INSERT INTO words (document_id, page_no, seq, word, x0, y0, x1, y1, font_size)
SELECT
    d.id,
    w.page,
    row_number() OVER (
        PARTITION BY d.id, w.page
        ORDER BY round(w.y0, 1), w.x0, w.word
    )::INTEGER,
    w.word, w.x0, w.y0, w.x1, w.y1, w.font_size
FROM _pdf_words w
JOIN documents d ON d.filename = w.stem;

-- ── entities (real answer-key values from identities.json) ─────────────────
CREATE OR REPLACE TEMP TABLE _roster AS
SELECT
    ca.id AS case_id,
    c.case_no, c.subject, c.witnesses, c.officers, c.fp_street, c.fp_citation
FROM (
    SELECT unnest(cases) AS c
    FROM read_json_auto(getvariable('data_dir') || '/identities.json')
)
JOIN cases ca ON ca.case_no = c.case_no;

INSERT INTO entities (case_id, canonical_text, kind)
SELECT case_id, text, kind FROM (
    SELECT case_id, subject.name  AS text, 'PERSON · SUBJECT'      AS kind FROM _roster
    UNION ALL
    SELECT case_id, subject.ssn,             'SSN'                         FROM _roster
    UNION ALL
    SELECT case_id, subject.dob,             'DATE OF BIRTH'               FROM _roster
    UNION ALL
    SELECT case_id, subject.address,         'ADDRESS · SUBJECT'           FROM _roster
    UNION ALL
    SELECT case_id, subject.phone,           'PHONE · SUBJECT'             FROM _roster
    UNION ALL
    SELECT case_id, w.name,                  'PERSON · WITNESS'
    FROM _roster, unnest(witnesses) AS t(w)
    UNION ALL
    SELECT case_id, w.phone,                 'PHONE · WITNESS'
    FROM _roster, unnest(witnesses) AS t(w)
    UNION ALL
    SELECT case_id, o,                       'OFFICER · NOT SUBJECT PII'
    FROM _roster, unnest(officers) AS t(o)
    UNION ALL
    SELECT case_id, fp_street,               'STREET NAME · NOT PII'       FROM _roster
    WHERE fp_street IS NOT NULL AND cast(fp_street AS VARCHAR) <> ''
    UNION ALL
    SELECT case_id, fp_citation,             'CITATION · NOT PII'          FROM _roster
    WHERE fp_citation IS NOT NULL AND cast(fp_citation AS VARCHAR) <> ''
) x
WHERE text IS NOT NULL AND trim(cast(text AS VARCHAR)) <> '';

-- ── audit ──────────────────────────────────────────────────────────────────
INSERT INTO audit_events (actor, action, case_id, target)
SELECT
    'system',
    'ingested',
    c.id,
    format(
        '{} documents · {} pages · {} words · {} entities',
        (SELECT count(*) FROM documents d WHERE d.case_id = c.id),
        (SELECT count(*) FROM pages p JOIN documents d ON d.id = p.document_id WHERE d.case_id = c.id),
        (SELECT count(*) FROM words w JOIN documents d ON d.id = w.document_id WHERE d.case_id = c.id),
        (SELECT count(*) FROM entities e WHERE e.case_id = c.id)
    )
FROM cases c;

-- export map for the shell-side export helper (paths only — no fabricated data)
COPY (
    SELECT case_id, filename, source_path,
           'exports/' || filename || '_redacted.pdf' AS out_path
    FROM documents
    ORDER BY case_id, filename
) TO 'exports/export_map.csv' (HEADER true, DELIMITER ',');

SELECT 'ingest complete' AS status,
       (SELECT count(*) FROM cases)       AS cases,
       (SELECT count(*) FROM documents)   AS documents,
       (SELECT count(*) FROM pages)       AS pages,
       (SELECT count(*) FROM words)       AS words,
       (SELECT count(*) FROM entities)    AS entities,
       (SELECT count(*) FROM suggestions) AS suggestions;
