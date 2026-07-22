-- server/typed/sources.sql — domain-typed sources on top of raw.
-- Only the PDF/JSON readers need this layer; the decisions table is typed by
-- its DDL (server/store.sql), so it has nothing to fix up.

-- PDF: reader already typed; normalize names + pack bbox once.
CREATE OR REPLACE VIEW v_src_pdf_info AS
SELECT
    file AS source_path,
    parse_filename(file, true) AS filename,
    page_count,
    width AS width_pt,
    height AS height_pt,
    file_size
FROM v_raw_pdf_info;

CREATE OR REPLACE VIEW v_src_pdf_pages AS
SELECT
    filename,
    parse_filename(filename, true) AS doc_filename,
    page AS page_no,
    width AS width_pt,
    height AS height_pt
FROM v_raw_pdf_pages;

CREATE OR REPLACE VIEW v_src_pdf_words AS
SELECT
    filename,
    parse_filename(filename, true) AS doc_filename,
    page AS page_no,
    word,
    (x0, y0, x1, y1)::bbox AS bbox,
    font_size
FROM v_raw_pdf_words;

CREATE OR REPLACE VIEW v_src_manifest AS
SELECT parse_filename(f.filename, true) AS filename, f.case_no AS case_no
FROM (SELECT unnest(files) AS f FROM v_raw_manifest)
WHERE f.filename IS NOT NULL;

CREATE OR REPLACE VIEW v_src_watchlist AS
SELECT term, kind, case_no
FROM v_raw_watchlist
WHERE nullif(trim(term), '') IS NOT NULL;

CREATE OR REPLACE VIEW v_src_decisions AS
SELECT * FROM decisions;

CREATE OR REPLACE VIEW v_manifest AS SELECT * FROM v_src_manifest;
