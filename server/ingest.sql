-- ingest.sql — LOAD: pin expensive extracts; durable ids; star the sources.
-- Depends on: sources.sql (v_src_*). Pattern: WITH raw AS (SELECT * FROM v_src_…)

-- cases: natural key = case_no from starred manifest files.
CREATE OR REPLACE TABLE cases AS
SELECT DISTINCT
    case_no AS id,
    case_no,
    'Case ' || case_no AS title
FROM v_src_manifest_files;

-- documents: star pdf_info × manifest; durable id survives reboot (ids.sql).
CREATE OR REPLACE TABLE documents AS
SELECT
    (substr(h, 1, 8) || '-' || substr(h, 9, 4) || '-' ||
        substr(h, 13, 4) || '-' || substr(h, 17, 4) || '-' ||
        substr(h, 21, 12))::UUID AS id,
    m.case_no AS case_id,
    p.filename,
    p.source_path,
    p.page_count::INTEGER AS page_count,
    p.width_pt::DOUBLE AS width_pt,
    p.height_pt::DOUBLE AS height_pt,
    p.file_size::BIGINT AS file_size
FROM v_src_pdf_info p
JOIN v_src_manifest_files m ON m.filename = p.filename
CROSS JOIN LATERAL (
    SELECT md5(m.case_no || chr(31) || p.filename) AS h
);

-- pages / words: star the extract rows; only attach durable document_id.
CREATE OR REPLACE TABLE pages AS
SELECT
    d.id AS document_id,
    p.page::INTEGER AS page_no,
    p.width::DOUBLE AS width_pt,
    p.height::DOUBLE AS height_pt
FROM read_pdf(getvariable('samples_dir') || '/*.pdf') p
JOIN documents d ON d.source_path = p.filename;

CREATE OR REPLACE TABLE words AS
SELECT
    d.id AS document_id,
    w.page::INTEGER AS page_no,
    w.word::VARCHAR AS word,
    w.x0::DOUBLE AS x0, w.y0::DOUBLE AS y0,
    w.x1::DOUBLE AS x1, w.y1::DOUBLE AS y1,
    w.font_size::DOUBLE AS font_size
FROM read_pdf_words(getvariable('samples_dir') || '/*.pdf') w
JOIN documents d ON d.source_path = w.filename;

-- watchlist: materialize the starred source (detect joins this table).
CREATE OR REPLACE TABLE watchlist AS
SELECT
  term::VARCHAR AS term,
  kind::VARCHAR AS kind,
  case_no::VARCHAR AS case_no
FROM v_src_watchlist;

-- entities shell: detect.sql fills via finetype / addrust / watchlist matching.
CREATE OR REPLACE TABLE entities AS
SELECT NULL::UUID    AS id,
       NULL::VARCHAR AS case_id,
       NULL::VARCHAR AS canonical_text,
       NULL::VARCHAR AS kind
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
manifest AS (SELECT * FROM v_src_manifest_files),
pdfs AS (SELECT * FROM v_src_pdf_info)
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
