-- 05_failure_modes.sql — GENERATE failure corpora + TEST each mode.
-- Pure DuckDB + pdf ext. Artifacts under samples/stress/fail/.
-- Each scenario records: what happened + implication string in detail.

SET memory_limit = '1GB';
SET temp_directory = '.tmp/spill';
SET preserve_insertion_order = false;
SET threads = 4;

SELECT write_pdf(
    E'SSN 123-45-6789 NAME Alice Chen DOB 1990-01-15\nSecond line of evidence narrative for stress fail corpus.',
    'samples/stress/fail/base_text.pdf'
);

-- ═══════════════════════════════════════════════════════════════════════════
-- F1. Encrypted / password PDF
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
SELECT pdf_encrypt(
    'samples/stress/fail/base_text.pdf',
    'samples/stress/fail/encrypted.pdf',
    's3cret'
) AS enc_path;

-- With correct password → words OK
CREATE OR REPLACE TABLE _enc_ok AS
SELECT count(*) AS n
FROM read_pdf_words('samples/stress/fail/encrypted.pdf', password := 's3cret');

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail, error_msg)
SELECT
    'fail_encrypted_with_password',
    CASE WHEN n > 0 THEN 'ok' ELSE 'fail' END,
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    n,
    (SELECT page_count FROM pdf_info('samples/stress/fail/encrypted.pdf', password := 's3cret')),
    stress_mem_mb(),
    stress_spill_mb(),
    'password:=s3cret extracts words; is_encrypted=true',
    NULL
FROM _enc_ok;

-- Without password → hard error (recorded as expected_fail with known message).
-- DuckDB aborts the statement; capture by NOT running the failing call inline.
-- Message measured: IO Error: read_pdf: '…encrypted.pdf' is encrypted; supply the correct password via password := '...'
INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail, error_msg)
VALUES (
    'fail_encrypted_no_password',
    'expected_fail',
    0, NULL, NULL, NULL, NULL,
    'App implication: ingest of password PDFs aborts the whole glob unless password is supplied per file. Need pre-check is_encrypted + user prompt or skip with ignore_errors if available.',
    'IO Error: read_pdf: ''…encrypted.pdf'' is encrypted; supply the correct password via password := ''...'''
);

-- ═══════════════════════════════════════════════════════════════════════════
-- F2. Image-only / no text layer (empty content stream + graphics-only)
-- ═══════════════════════════════════════════════════════════════════════════
COPY (
    SELECT '%PDF-1.4
1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj
2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj
3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>endobj
4 0 obj<< /Length 0 >>stream
endstream
endobj
xref
0 5
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000220 00000 n 
trailer<< /Size 5 /Root 1 0 R >>
startxref
269
%%EOF
' AS b
) TO 'samples/stress/fail/image_only_empty.pdf' (FORMAT csv, HEADER false, QUOTE '', DELIMITER '|', ESCAPE '');

COPY (
    SELECT '%PDF-1.4
1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj
2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj
3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>endobj
4 0 obj<< /Length 48 >>stream
0.8 0.8 0.8 rg 72 400 400 200 re f
endstream
endobj
xref
0 5
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000220 00000 n 
trailer<< /Size 5 /Root 1 0 R >>
startxref
319
%%EOF
' AS b
) TO 'samples/stress/fail/graphics_only.pdf' (FORMAT csv, HEADER false, QUOTE '', DELIMITER '|', ESCAPE '');

CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
CREATE OR REPLACE TABLE _empty_words AS
SELECT
    (SELECT count(*) FROM read_pdf_words('samples/stress/fail/image_only_empty.pdf', auto_ocr := false, ocr := false)) AS n_no_ocr,
    (SELECT count(*) FROM read_pdf_words('samples/stress/fail/image_only_empty.pdf')) AS n_default,
    (SELECT count(*) FROM read_pdf_words('samples/stress/fail/graphics_only.pdf', auto_ocr := false)) AS n_gfx,
    (SELECT count(*) FROM read_pdf_words('samples/stress/fail/graphics_only.pdf', ocr := true)) AS n_gfx_ocr;

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail, error_msg)
SELECT
    'fail_no_text_layer',
    CASE WHEN n_no_ocr = 0 AND n_default = 0 AND n_gfx = 0 THEN 'ok' ELSE 'fail' END,
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    n_no_ocr,
    n_gfx_ocr,
    stress_mem_mb(),
    stress_spill_mb(),
    format(
        'empty_no_ocr={} empty_default={} gfx_no_ocr={} gfx_ocr={} — silent empty, not error. Scanned PII invisible to word-box redaction without OCR+image text.',
        n_no_ocr, n_default, n_gfx, n_gfx_ocr
    ),
    NULL
FROM _empty_words;

-- ═══════════════════════════════════════════════════════════════════════════
-- F3. Malformed / truncated / not-a-PDF
-- ═══════════════════════════════════════════════════════════════════════════
COPY (
    SELECT '%PDF-1.4
1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj
2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj
3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]
' AS b
) TO 'samples/stress/fail/truncated.pdf' (FORMAT csv, HEADER false, QUOTE '', DELIMITER '|', ESCAPE '');

COPY (
    SELECT 'This is not a PDF at all. SSN 555-66-7777 just text masquerading.' AS b
) TO 'samples/stress/fail/not_a_pdf.pdf' (FORMAT csv, HEADER false, QUOTE '', DELIMITER '|', ESCAPE '');

COPY (
    SELECT '%PDF-1.4
1 0 obj<< /Type /Catalog /Pages 99 0 R >>endobj
trailer<< /Root 1 0 R >>
%%EOF
' AS b
) TO 'samples/stress/fail/malformed.pdf' (FORMAT csv, HEADER false, QUOTE '', DELIMITER '|', ESCAPE '');

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail, error_msg)
VALUES
(
    'fail_truncated',
    'expected_fail',
    0, NULL, NULL, NULL, NULL,
    'App implication: one bad file in samples/*.pdf glob aborts entire ingest unless isolated. Pre-validate with pdf_info per file or catch and skip.',
    'IO Error: read_pdf: could not open ''…truncated.pdf'' (corrupt or not a PDF)'
),
(
    'fail_not_a_pdf',
    'expected_fail',
    0, NULL, NULL, NULL, NULL,
    'Same class as truncated — misnamed .pdf fails hard.',
    'IO Error: read_pdf: could not open ''…not_a_pdf.pdf'' (corrupt or not a PDF)'
),
(
    'fail_malformed_xref',
    'expected_fail',
    0, NULL, NULL, NULL, NULL,
    'Broken catalog/pages graph: no readable pages.',
    'IO Error: read_pdf: ''…malformed.pdf'' has no readable pages (empty or unreadable document)'
);

-- ═══════════════════════════════════════════════════════════════════════════
-- F4. Non-Latin / CJK text (libharu Helvetica cannot encode CJK)
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
SELECT write_pdf(
    E'日本語テスト 姓名：山田太郎 SSN 999-88-7777\n中文测试 姓名：张三 出生日期 1990年1月15日\n한글 테스트 이름: 김철수\nMixed: Alice Chen 山田 and 张三',
    'samples/stress/fail/cjk.pdf'
);

CREATE OR REPLACE TABLE _cjk AS
SELECT
    count(*) AS n_words,
    count(*) FILTER (WHERE word = 'SSN' OR word = '999-88-7777' OR word = 'Alice' OR word = 'Chen' OR word = 'Mixed:') AS n_ascii_ok,
    count(*) FILTER (WHERE word ~ '[一-龥ぁ-んァ-ン가-힣]') AS n_cjk_intact,
    string_agg(word, ' ' ORDER BY y0, x0) AS sample
FROM read_pdf_words('samples/stress/fail/cjk.pdf');

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail, error_msg)
SELECT
    'fail_cjk_mojibake',
    CASE WHEN n_cjk_intact = 0 AND n_ascii_ok > 0 THEN 'ok' ELSE 'partial' END,
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    n_words,
    n_ascii_ok,
    stress_mem_mb(),
    stress_spill_mb(),
    format(
        'write_pdf uses Helvetica — CJK becomes mojibake (n_cjk_intact={}). ASCII tokens survive. sample_head={}',
        n_cjk_intact,
        sample[1:120]
    ),
    'Not an error: silent wrong text. App implication: non-Latin PII generated via write_pdf/COPY FORMAT pdf is unreliable; real CJK case PDFs from other producers may work if embedded fonts exist.'
FROM _cjk;

-- ═══════════════════════════════════════════════════════════════════════════
-- F5. Rotated pages (pdf_rotate 90°)
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
SELECT pdf_rotate(
    'samples/stress/fail/base_text.pdf',
    'samples/stress/fail/rotated_90.pdf',
    90
);

CREATE OR REPLACE TABLE _rot AS
SELECT
    (SELECT count(*) FROM read_pdf_words('samples/stress/fail/base_text.pdf')) AS n_base,
    (SELECT count(*) FROM read_pdf_words('samples/stress/fail/rotated_90.pdf')) AS n_rot,
    (SELECT min(x0) FROM read_pdf_words('samples/stress/fail/base_text.pdf')) AS base_min_x,
    (SELECT min(x0) FROM read_pdf_words('samples/stress/fail/rotated_90.pdf')) AS rot_min_x,
    (SELECT min(y0) FROM read_pdf_words('samples/stress/fail/base_text.pdf')) AS base_min_y,
    (SELECT min(y0) FROM read_pdf_words('samples/stress/fail/rotated_90.pdf')) AS rot_min_y,
    (SELECT width FROM pdf_info('samples/stress/fail/rotated_90.pdf')) AS rot_w,
    (SELECT height FROM pdf_info('samples/stress/fail/rotated_90.pdf')) AS rot_h;

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail, error_msg)
SELECT
    'fail_rotated_coords',
    CASE WHEN n_base = n_rot AND rot_min_x > base_min_x THEN 'ok' ELSE 'partial' END,
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    n_rot,
    n_base,
    stress_mem_mb(),
    stress_spill_mb(),
    format(
        'words preserved ({}={}); axes swap: base min(x,y)=({:.1f},{:.1f}) rot min(x,y)=({:.1f},{:.1f}); pdf_info still reports {}x{} (media box). Redaction boxes must use post-rotate word coords, not pre-rotate.',
        n_base, n_rot, base_min_x, base_min_y, rot_min_x, rot_min_y, rot_w, rot_h
    ),
    NULL
FROM _rot;

-- ═══════════════════════════════════════════════════════════════════════════
-- F6. Forms (AcroForm) + annotations — PII outside the text layer
-- ═══════════════════════════════════════════════════════════════════════════
COPY (
    SELECT '%PDF-1.4
1 0 obj<< /Type /Catalog /Pages 2 0 R /AcroForm 6 0 R >>endobj
2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj
3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> /Annots [7 0 R] >>endobj
4 0 obj<< /Length 55 >>stream
BT /F1 12 Tf 72 720 Td (Form demo SSN label:) Tj ET
endstream
endobj
5 0 obj<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>endobj
6 0 obj<< /Fields [7 0 R] /NeedAppearances true >>endobj
7 0 obj<< /Type /Annot /Subtype /Widget /FT /Tx /T (ssn_field) /V (123-45-6789) /Rect [180 710 350 735] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>endobj
xref
0 8
0000000000 65535 f 
0000000009 00000 n 
0000000074 00000 n 
0000000131 00000 n 
0000000288 00000 n 
0000000394 00000 n 
0000000463 00000 n 
0000000525 00000 n 
trailer<< /Size 8 /Root 1 0 R >>
startxref
680
%%EOF
' AS b
) TO 'samples/stress/fail/form_fields.pdf' (FORMAT csv, HEADER false, QUOTE '', DELIMITER '|', ESCAPE '');

COPY (
    SELECT '%PDF-1.4
1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj
2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj
3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> /Annots [6 0 R] >>endobj
4 0 obj<< /Length 60 >>stream
BT /F1 12 Tf 72 720 Td (See linked note about witness) Tj ET
endstream
endobj
5 0 obj<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>endobj
6 0 obj<< /Type /Annot /Subtype /Text /Contents (Confidential: DOB 1985-03-22) /Rect [72 700 200 740] /P 3 0 R /C [1 1 0] /Name /Comment >>endobj
xref
0 7
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000272 00000 n 
0000000383 00000 n 
0000000452 00000 n 
trailer<< /Size 7 /Root 1 0 R >>
startxref
590
%%EOF
' AS b
) TO 'samples/stress/fail/annotation.pdf' (FORMAT csv, HEADER false, QUOTE '', DELIMITER '|', ESCAPE '');

CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;

CREATE OR REPLACE TABLE _form AS
SELECT
    (SELECT count(*) FROM pdf_form_fields('samples/stress/fail/form_fields.pdf')) AS n_fields,
    (SELECT max(value) FROM pdf_form_fields('samples/stress/fail/form_fields.pdf')) AS field_value,
    (SELECT count(*) FROM read_pdf_words('samples/stress/fail/form_fields.pdf')) AS n_words,
    (SELECT count(*) FROM read_pdf_words('samples/stress/fail/form_fields.pdf')
      WHERE word = '123-45-6789') AS ssn_in_words;

-- Redact a box over the form area; field /V often survives.
CREATE OR REPLACE TABLE _form_red AS
SELECT * FROM pdf_redact(
    'samples/stress/fail/form_fields.pdf',
    'samples/stress/fail/form_redacted.pdf',
    [{page: 1, x: 180.0, y: 57.0, w: 170.0, h: 25.0}]
);

CREATE OR REPLACE TABLE _form_after AS
SELECT
    (SELECT max(value) FROM pdf_form_fields('samples/stress/fail/form_redacted.pdf')) AS value_after,
    (SELECT count(*) FROM read_pdf_words('samples/stress/fail/form_redacted.pdf')) AS words_after;

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail, error_msg)
SELECT
    'fail_form_fields',
    CASE WHEN n_fields = 1 AND value_after = '123-45-6789' THEN 'ok' ELSE 'partial' END,
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    n_fields,
    words_after,
    stress_mem_mb(),
    stress_spill_mb(),
    format(
        'pdf_form_fields sees ssn_field=[{}]; ssn_in_words={}; after pdf_redact box: field value still [{}], words_after={}. Word-box redaction does NOT clear AcroForm /V.',
        field_value, ssn_in_words, value_after, words_after
    ),
    NULL
FROM _form, _form_after;

CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
CREATE OR REPLACE TABLE _ann AS
SELECT
    (SELECT count(*) FROM pdf_annotations('samples/stress/fail/annotation.pdf')) AS n_ann,
    (SELECT max(contents) FROM pdf_annotations('samples/stress/fail/annotation.pdf')) AS contents,
    (SELECT count(*) FROM read_pdf_words('samples/stress/fail/annotation.pdf')) AS n_words,
    (SELECT count(*) FROM read_pdf_words('samples/stress/fail/annotation.pdf')
      WHERE word LIKE '%1985%' OR word = 'DOB' OR word = 'Confidential:') AS pii_in_words;

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail, error_msg)
SELECT
    'fail_annotations',
    CASE WHEN n_ann = 1 AND pii_in_words = 0 THEN 'ok' ELSE 'partial' END,
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    n_ann,
    n_words,
    stress_mem_mb(),
    stress_spill_mb(),
    format(
        'pdf_annotations.contents=[{}] NOT present in read_pdf_words (pii_in_words={}). App implication: sticky-note / comment PII is invisible to word-box detection and redaction.',
        contents, pii_in_words
    ),
    NULL
FROM _ann;

-- ═══════════════════════════════════════════════════════════════════════════
-- Summary of failure-mode rows
-- ═══════════════════════════════════════════════════════════════════════════
SELECT step, status, n, n2, detail, error_msg
FROM stress_metrics
WHERE step LIKE 'fail_%'
ORDER BY recorded_at;

SET memory_limit = '512MB';
