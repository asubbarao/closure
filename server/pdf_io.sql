-- pdf_io.sql — OCR enrich for empty (scanned) pages, scan-status, redact boxes.
--
-- After ingest (documents/pages/words exist). Prefer before detect so OCR words
-- feed suggestion CTAS. Does NOT rebuild documents/pages (ingest owns those).
--
-- Extensions: pdf (read_pdf_words auto_ocr), scalarfs (box lists for pdf_redact).
-- One geometry conversion for pdf_redact: top-left → bottom-left (y = height_pt - y1).

INSTALL scalarfs FROM community;
LOAD scalarfs;

-- ── OCR capability (one probe row) ──────────────────────────────────────────
CREATE OR REPLACE TABLE pdf_ocr_capability AS
WITH
fn AS (
    SELECT list_contains(parameters, 'auto_ocr') AS has_auto_ocr
    FROM duckdb_functions()
    WHERE function_name = 'read_pdf_words'
    LIMIT 1
),
probe AS (
    SELECT count(*) FILTER (WHERE coalesce(source, 'text') = 'ocr')::BIGINT AS ocr_words
    FROM read_pdf_words('spikes/scans/fixtures/image_only_scanned.pdf', auto_ocr := true)
)
SELECT
    coalesce((SELECT has_auto_ocr FROM fn), false) AS has_auto_ocr_param,
    coalesce((SELECT ocr_words FROM probe), 0) AS probe_ocr_word_count,
    (
        coalesce((SELECT has_auto_ocr FROM fn), false)
        AND coalesce((SELECT ocr_words FROM probe), 0) > 0
    ) AS ocr_available,
    CASE
        WHEN NOT coalesce((SELECT has_auto_ocr FROM fn), false)
            THEN 'pdf extension lacks auto_ocr — load local unsigned pdf build'
        WHEN coalesce((SELECT ocr_words FROM probe), 0) = 0
            THEN 'auto_ocr returned 0 OCR words — install tesseract eng model (brew install tesseract)'
        ELSE 'ocr ready'
    END AS ocr_status_note,
    now() AS probed_at;

-- ── Empty pages → OCR enrich (skip auto_ocr on full corpus when none) ───────
-- Foldable getvariable + query() so read_pdf_words(..., auto_ocr) never runs
-- when every page already has a text layer (samples today).
CREATE OR REPLACE TABLE _empty_pages AS
SELECT p.document_id, p.page_no
FROM pages p
WHERE NOT EXISTS (
    SELECT 1 FROM words w
    WHERE w.document_id = p.document_id AND w.page_no = p.page_no
);

SET VARIABLE pdf_io_empty_n = (SELECT count(*) FROM _empty_pages);
SET VARIABLE pdf_io_ocr_sql = (
    SELECT CASE
        WHEN getvariable('pdf_io_empty_n') = 0
          OR NOT coalesce((SELECT ocr_available FROM pdf_ocr_capability), false)
        THEN 'SELECT cast(NULL AS UUID) AS document_id, NULL::INTEGER AS page_no, '
             || 'cast(NULL AS VARCHAR) AS word, NULL::DOUBLE AS x0, NULL::DOUBLE AS y0, '
             || 'NULL::DOUBLE AS x1, NULL::DOUBLE AS y1, NULL::DOUBLE AS font_size WHERE false'
        ELSE 'SELECT d.id AS document_id, w.page::INTEGER AS page_no, '
             || 'cast(w.word AS VARCHAR) AS word, w.x0::DOUBLE AS x0, w.y0::DOUBLE AS y0, '
             || 'w.x1::DOUBLE AS x1, w.y1::DOUBLE AS y1, w.font_size::DOUBLE AS font_size '
             || 'FROM read_pdf_words('''
             || coalesce(cast(getvariable('samples_dir') AS VARCHAR), 'samples')
             || '/*.pdf'', auto_ocr := true) w '
             || 'JOIN documents d ON d.filename = parse_filename(w.filename, true) '
             || 'JOIN _empty_pages e ON e.document_id = d.id AND e.page_no = w.page '
             || 'WHERE coalesce(w.source, ''text'') = ''ocr'''
    END
);

CREATE OR REPLACE TABLE words AS
SELECT document_id, page_no, word, x0, y0, x1, y1, font_size, 'text'::VARCHAR AS source
FROM words
UNION ALL BY NAME
SELECT document_id, page_no, word, x0, y0, x1, y1, font_size, 'ocr'::VARCHAR AS source
FROM query(getvariable('pdf_io_ocr_sql'));

DROP TABLE IF EXISTS _empty_pages;

-- ── Single scan-status view (library badge + /scan routes) ──────────────────
CREATE OR REPLACE VIEW document_scan_status AS
WITH page_words AS (
    SELECT document_id, page_no,
           count(*) FILTER (WHERE coalesce(source, 'text') = 'text')::BIGINT AS native_words,
           count(*) FILTER (WHERE source = 'ocr')::BIGINT AS ocr_words,
           count(*)::BIGINT AS total_words
    FROM words
    GROUP BY document_id, page_no
),
agg AS (
    SELECT
        d.id AS document_id,
        d.case_id,
        d.filename,
        d.source_path,
        d.page_count,
        count(*) FILTER (WHERE coalesce(pw.native_words, 0) > 0)::BIGINT AS text_layer_pages,
        count(*) FILTER (
            WHERE coalesce(pw.native_words, 0) = 0 AND coalesce(pw.ocr_words, 0) > 0
        )::BIGINT AS ocr_pages,
        count(*) FILTER (
            WHERE coalesce(pw.native_words, 0) = 0 AND coalesce(pw.ocr_words, 0) = 0
        )::BIGINT AS scanned_gap_pages,
        coalesce(sum(pw.native_words), 0)::BIGINT AS native_word_count,
        coalesce(sum(pw.ocr_words), 0)::BIGINT AS ocr_word_count,
        coalesce(sum(pw.total_words), 0)::BIGINT AS total_word_count
    FROM documents d
    LEFT JOIN pages p ON p.document_id = d.id
    LEFT JOIN page_words pw
      ON pw.document_id = p.document_id AND pw.page_no = p.page_no
    GROUP BY d.id, d.case_id, d.filename, d.source_path, d.page_count
)
SELECT
    a.document_id,
    a.case_id,
    a.filename,
    a.source_path,
    a.page_count,
    a.text_layer_pages,
    a.ocr_pages,
    a.scanned_gap_pages,
    a.native_word_count,
    a.ocr_word_count,
    a.total_word_count,
    0::BIGINT AS image_count,
    (SELECT ocr_available FROM pdf_ocr_capability) AS ocr_available,
    (SELECT ocr_status_note FROM pdf_ocr_capability) AS ocr_status_note,
    (a.native_word_count = 0 AND a.page_count > 0) AS is_scanned,
    (a.native_word_count = 0 AND a.ocr_word_count > 0) AS ocr_ingested,
    (a.native_word_count = 0 AND a.ocr_word_count = 0 AND a.page_count > 0) AS scan_gap,
    CASE
        WHEN a.native_word_count > 0 AND a.ocr_word_count = 0 THEN NULL
        WHEN a.native_word_count = 0 AND a.ocr_word_count > 0 THEN 'scanned · OCR'
        WHEN a.native_word_count = 0 AND a.ocr_word_count = 0 THEN 'scanned — no text layer'
        WHEN a.ocr_word_count > 0 THEN 'mixed · OCR'
        ELSE NULL
    END AS scan_badge,
    CASE
        WHEN a.native_word_count = 0 AND a.ocr_word_count > 0 THEN 'b-blue'
        WHEN a.native_word_count = 0 AND a.ocr_word_count = 0 THEN 'b-rej'
        WHEN a.ocr_word_count > 0 THEN 'b-pend'
        ELSE 'b-gray'
    END AS scan_badge_class,
    CASE
        WHEN a.native_word_count = 0 AND a.ocr_word_count > 0
            THEN 'Image-only pages OCR''d into words (source=ocr). Review boxes before export.'
        WHEN a.native_word_count = 0 AND a.ocr_word_count = 0
             AND NOT (SELECT ocr_available FROM pdf_ocr_capability)
            THEN 'Scanned / image-only PDF and OCR is not available on this host. '
                 || (SELECT ocr_status_note FROM pdf_ocr_capability)
                 || '. No suggestions can be generated from a missing text layer.'
        WHEN a.native_word_count = 0 AND a.ocr_word_count = 0
            THEN 'No text layer and OCR returned no words (blank or unreadable raster). '
                 || 'Do not treat zero suggestions as a clean document.'
        ELSE NULL
    END AS scan_detail
FROM agg a;

-- ── Scan routes (VARCHAR ids — case_no / uuid, not INTEGER) ─────────────────
CREATE OR REPLACE ROUTE api_doc_scan GET '/api/documents/:id/scan' AS
SELECT
    document_id, case_id, filename, source_path, page_count,
    text_layer_pages, ocr_pages, scanned_gap_pages,
    native_word_count, ocr_word_count, total_word_count, image_count,
    ocr_available, ocr_status_note,
    is_scanned, ocr_ingested, scan_gap,
    scan_badge, scan_badge_class, scan_detail
FROM document_scan_status
WHERE cast(document_id AS VARCHAR) = $id;

CREATE OR REPLACE ROUTE api_case_scan GET '/api/cases/:id/scan' AS
SELECT
    document_id, case_id, filename, page_count,
    native_word_count, ocr_word_count, total_word_count,
    is_scanned, ocr_ingested, scan_gap,
    scan_badge, scan_badge_class, scan_detail, ocr_available
FROM document_scan_status
WHERE case_id = $id
ORDER BY filename;

-- ── ONE box conversion: top-left words → pdf_redact bottom-left ─────────────
-- y = height_pt - y1. Hand the list via scalarfs (no temp files, no SQL builders):
--   COPY (
--     SELECT list(redact_box(s.page_no, s.x0, s.y0, s.x1, s.y1, p.height_pt)
--                 ORDER BY s.page_no, s.id)
--     FROM v_suggestions s
--     JOIN pages p ON cast(p.document_id AS VARCHAR) = s.document_id
--                  AND p.page_no = s.page_no
--     WHERE s.document_id = $id AND s.status = 'accepted'
--   ) TO 'variable:boxes' (FORMAT variable);
--   SELECT * FROM pdf_redact(src, out_path, getvariable('boxes'));
CREATE OR REPLACE MACRO redact_box(page_no, x0, y0, x1, y1, height_pt) AS
    struct_pack(
        page := page_no,
        x := x0,
        y := height_pt - y1,
        w := x1 - x0,
        h := y1 - y0
    );

-- quackapi: query() only accepts foldable SQL strings (export/store routes).
CREATE OR REPLACE MACRO run_sql(q) AS TABLE
SELECT * FROM query(q);

SELECT 'pdf_io OCR enrich' AS phase,
       (SELECT ocr_available FROM pdf_ocr_capability) AS ocr_available,
       (SELECT ocr_status_note FROM pdf_ocr_capability) AS ocr_status_note,
       (SELECT count(*) FROM documents) AS documents,
       (SELECT count(*) FROM words) AS words,
       (SELECT count(*) FROM words WHERE source = 'ocr') AS ocr_words,
       (SELECT count(*) FROM document_scan_status WHERE is_scanned) AS scanned_docs,
       (SELECT count(*) FROM document_scan_status WHERE ocr_ingested) AS ocr_ingested_docs,
       (SELECT count(*) FROM document_scan_status WHERE scan_gap) AS scan_gap_docs;
