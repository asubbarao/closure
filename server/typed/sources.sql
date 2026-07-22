-- server/typed/sources.sql — domain-typed sources.
--
-- Pattern for append-only JSON logs (decisions):
--   1. server/decision.schema.json  → copied to exports/decisions/_schema.json
--      (empty-dir pin + human contract of the event shape)
--   2. read_json(..., columns := {…})  → real typing at the reader
--      (not try_cast laundry; not hope-auto-detects-TIMESTAMP across the glob)
--
-- Other sources: PDF extensions already bind typed columns; JSON catalogs
-- (manifest/watchlist) are already clean VARCHAR — no pin needed unless empty.

CREATE OR REPLACE VIEW v_src_pdf_info AS
SELECT
    file AS source_path,
    parse_filename(file, true) AS filename,
    try_cast(page_count AS INTEGER) AS page_count,
    try_cast(width AS DOUBLE) AS width_pt,
    try_cast(height AS DOUBLE) AS height_pt,
    try_cast(file_size AS BIGINT) AS file_size
FROM v_raw_pdf_info;

CREATE OR REPLACE VIEW v_src_pdf_pages AS
SELECT
    filename,
    parse_filename(filename, true) AS doc_filename,
    try_cast(page AS INTEGER) AS page_no,
    try_cast(width AS DOUBLE) AS width_pt,
    try_cast(height AS DOUBLE) AS height_pt
FROM v_raw_pdf_pages;

-- Pack bbox once — domain never re-packs loose x0..y1 from the PDF reader.
CREATE OR REPLACE VIEW v_src_pdf_words AS
SELECT
    filename,
    parse_filename(filename, true) AS doc_filename,
    try_cast(page AS INTEGER) AS page_no,
    word,
    struct_pack(
        x0 := try_cast(x0 AS DOUBLE),
        y0 := try_cast(y0 AS DOUBLE),
        x1 := try_cast(x1 AS DOUBLE),
        y1 := try_cast(y1 AS DOUBLE)
    ) AS bbox,
    try_cast(font_size AS DOUBLE) AS font_size
FROM v_raw_pdf_words;

CREATE OR REPLACE VIEW v_src_manifest AS
SELECT parse_filename(f.filename, true) AS filename, f.case_no AS case_no
FROM (SELECT unnest(files) AS f FROM v_raw_manifest)
WHERE f.filename IS NOT NULL;

CREATE OR REPLACE VIEW v_src_watchlist AS
SELECT term, kind, case_no
FROM v_raw_watchlist
WHERE nullif(trim(term), '') IS NOT NULL;

-- Decision event schema lives in two places that must stay aligned:
--   server/decision.schema.json  (pin + docs)
--   columns := below            (typed reader)
CREATE OR REPLACE VIEW v_src_decisions AS
SELECT *
FROM read_json(
    coalesce(nullif(getenv('CLOSURE_EXPORTS_DIR'), ''), 'exports') || '/decisions/*.json',
    columns := {
        'kind': 'VARCHAR',
        'suggestion_id': 'VARCHAR',
        'status': 'VARCHAR',
        'actor': 'VARCHAR',
        'reason': 'VARCHAR',
        'ts': 'TIMESTAMP',
        'document_id': 'VARCHAR',
        'case_id': 'VARCHAR',
        'text': 'VARCHAR',
        'batch_id': 'VARCHAR',
        'batch_label': 'VARCHAR',
        'undoes_batch_id': 'VARCHAR',
        'page_no': 'INTEGER',
        'bbox': 'STRUCT(x0 DOUBLE, y0 DOUBLE, x1 DOUBLE, y1 DOUBLE)',
        'context': 'VARCHAR',
        'confidence': 'INTEGER',
        'flag_tag': 'VARCHAR',
        'entity_id': 'VARCHAR',
        'source': 'VARCHAR',
        'scope': 'VARCHAR'
    },
    union_by_name := true,
    filename := true,
    ignore_errors := true
)
WHERE kind IN ('decision', 'added');

CREATE OR REPLACE VIEW v_manifest AS SELECT * FROM v_src_manifest;
