-- 06_glob_scale.sql — measure ingest time + memory as file count scales.
-- Preconditions: samples/stress/glob{,5,20}/ from 01c; mid100.pdf.
-- Mirrors server/ingest.sql: glob read_pdf_words + CTAS.
-- Note: read_pdf_words takes VARCHAR path/glob (not VARCHAR[]).

SET memory_limit = '1GB';
SET temp_directory = '.tmp/spill';
SET preserve_insertion_order = false;
SET threads = 4;

-- ── Scale 1: single mid100 (100+ pages, one file) ──────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
DROP TABLE IF EXISTS _ingest_mid;
CREATE TABLE _ingest_mid AS
SELECT filename, page, word, x0, y0, x1, y1
FROM read_pdf_words('samples/stress/mid100.pdf');

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'glob_ingest_1_file_mid100',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    count(*),
    count(DISTINCT page),
    stress_mem_mb(),
    stress_spill_mb(),
    format(
        'files=1 pages={} size_mb={:.2f}',
        count(DISTINCT page),
        (SELECT file_size / 1024.0 / 1024.0 FROM pdf_info('samples/stress/mid100.pdf'))
    )
FROM _ingest_mid;

-- ── Scale 5 ────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
DROP TABLE IF EXISTS _ingest_5;
CREATE TABLE _ingest_5 AS
SELECT filename, page, word, x0, y0, x1, y1
FROM read_pdf_words('samples/stress/glob5/*.pdf');

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'glob_ingest_5_files',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    count(*),
    count(DISTINCT filename),
    stress_mem_mb(),
    stress_spill_mb(),
    format('files={} pages={}', count(DISTINCT filename),
           count(DISTINCT filename || ':' || page::VARCHAR))
FROM _ingest_5;

-- ── Scale 20 ───────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
DROP TABLE IF EXISTS _ingest_20;
CREATE TABLE _ingest_20 AS
SELECT filename, page, word, x0, y0, x1, y1
FROM read_pdf_words('samples/stress/glob20/*.pdf');

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'glob_ingest_20_files',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    count(*),
    count(DISTINCT filename),
    stress_mem_mb(),
    stress_spill_mb(),
    format('files={}', count(DISTINCT filename))
FROM _ingest_20;

-- ── Scale 40: full folder glob ─────────────────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
DROP TABLE IF EXISTS _ingest_40;
CREATE TABLE _ingest_40 AS
SELECT filename, page, word, x0, y0, x1, y1
FROM read_pdf_words('samples/stress/glob/*.pdf');

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'glob_ingest_40_files',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    count(*),
    count(DISTINCT filename),
    stress_mem_mb(),
    stress_spill_mb(),
    format(
        'files={} pages_sum={} — near-linear in file count for small files',
        count(DISTINCT filename),
        (SELECT sum(page_count) FROM pdf_info('samples/stress/glob/*.pdf'))
    )
FROM _ingest_40;

-- ── pdf_info on stress root (many artifacts; includes monsters if present) ─
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'glob_info_stress_root',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    count(*),
    sum(page_count),
    stress_mem_mb(),
    stress_spill_mb(),
    format(
        'pdf_info samples/stress/*.pdf → files={} total_pages={} total_mb={:.1f}',
        count(*),
        sum(page_count),
        sum(file_size) / 1024.0 / 1024.0
    )
FROM pdf_info('samples/stress/*.pdf');

SELECT step, status, wall_ms, n AS words_or_files, n2, round(mem_mb, 2) AS mem_mb, detail
FROM stress_metrics
WHERE step LIKE 'glob_%'
ORDER BY recorded_at;

SET memory_limit = '512MB';
