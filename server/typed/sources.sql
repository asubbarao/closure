-- server/typed/sources.sql — one layer on top of raw: extra typed columns only.
-- Live logs stay VIEWs (new JSON files must show up without reboot).
-- Static corpus is CTAS'd in domain/facts.sql from these views.

-- Page geometry, PDF points, origin top-left. Declared once so every layer says
-- ::bbox instead of respelling the four fields.
CREATE OR REPLACE TYPE bbox AS STRUCT(x0 DOUBLE, y0 DOUBLE, x1 DOUBLE, y1 DOUBLE);

-- PDF: reader already typed; only normalize names + cast bbox once.
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

-- Decisions: read_json_auto guesses per-file, so pin the columns the domain
-- sorts and joins on — same names, replaced in place, plus the epoch default
-- for a missing ts. Downstream then just says ts / page_no / bbox.
-- (Cannot CTAS — log is append-only and must re-read the glob each query.)
CREATE OR REPLACE VIEW v_src_decisions AS
SELECT
    * EXCLUDE (ts, page_no, confidence, bbox),
    coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01') AS ts,
    try_cast(page_no AS INTEGER) AS page_no,
    try_cast(confidence AS INTEGER) AS confidence,
    try_cast(bbox AS bbox) AS bbox
FROM v_raw_decisions
WHERE kind IN ('decision', 'added');

CREATE OR REPLACE VIEW v_manifest AS SELECT * FROM v_src_manifest;
