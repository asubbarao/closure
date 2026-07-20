-- 02_ingest_scan.sql — ingest + pdf_io OCR enrich (no HTTP).
INSTALL pdf FROM community;
LOAD pdf;
INSTALL tera FROM community;
LOAD tera;
LOAD '../quackapi/build/release/extension/quackapi/quackapi.duckdb_extension';

.read server/ingest.sql
.read server/pdf_io.sql

SELECT 'capability' AS phase, ocr_available, ocr_status_note, probe_ocr_word_count
FROM pdf_ocr_capability;

SELECT 'scan_status' AS phase,
       filename, native_word_count, ocr_word_count,
       is_scanned, ocr_ingested, scan_gap, scan_badge
FROM document_scan_status
WHERE is_scanned OR ocr_ingested OR scan_gap
ORDER BY filename;

SELECT 'words_by_source' AS phase, source, count(*) AS n
FROM words
GROUP BY source
ORDER BY source;

-- Seed so suggestions appear for OCR'd case-1 PII.
.read server/seed.sql

SELECT 'suggestions_on_scan' AS phase,
       d.filename,
       count(s.id) AS suggestions,
       count(s.id) FILTER (WHERE s.confidence >= 90) AS high_band
FROM documents d
JOIN suggestions s ON s.document_id = d.id
WHERE d.filename = 'image_only_scanned'
GROUP BY d.filename;

SELECT 'sample_sugg' AS phase, s.text, s.confidence, s.flag_tag, s.page_no
FROM suggestions s
JOIN documents d ON d.id = s.document_id
WHERE d.filename = 'image_only_scanned'
ORDER BY s.confidence DESC
LIMIT 15;
