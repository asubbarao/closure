-- 01_ocr_probe.sql — community pdf OCR vs image-only fixture.
INSTALL pdf FROM community;
LOAD pdf;

SELECT 'params' AS phase, parameters
FROM duckdb_functions()
WHERE function_name = 'read_pdf_words'
LIMIT 1;

SELECT 'native_fixture' AS phase, count(*) AS n
FROM read_pdf_words('spikes/scans/fixtures/image_only_scanned.pdf', auto_ocr := false);

SELECT 'ocr_fixture' AS phase,
       count(*) AS n,
       count(*) FILTER (WHERE coalesce(source, 'text') = 'ocr') AS ocr_n,
       round(avg(confidence), 1) AS avg_conf
FROM read_pdf_words('spikes/scans/fixtures/image_only_scanned.pdf', auto_ocr := true);

SELECT 'pii_tokens' AS phase, word, source, round(confidence, 1) AS conf
FROM read_pdf_words('spikes/scans/fixtures/image_only_scanned.pdf', auto_ocr := true)
WHERE position('300-71' IN word) > 0
   OR position('Hilbert' IN word) > 0
   OR position('Feeney' IN word) > 0
LIMIT 12;

SELECT 'messy_blank_native' AS phase, count(*) AS n
FROM read_pdf_words('samples/messy/image_only_scanned.pdf', auto_ocr := false);

SELECT 'messy_blank_ocr' AS phase, count(*) AS n
FROM read_pdf_words('samples/messy/image_only_scanned.pdf', auto_ocr := true);

SELECT 'images_fixture' AS phase, count(*) AS n, max(width) AS w, max(height) AS h
FROM pdf_images('spikes/scans/fixtures/image_only_scanned.pdf');
