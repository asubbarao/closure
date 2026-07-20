-- 02_extract.sql — read_pdf_words + pdf_to_png under tight 512MB budget.
-- Preconditions: samples/stress/monster.pdf; stress_metrics from 00_setup.
-- Question under test: does the pipeline stream+spill or OOM?

SET memory_limit = '512MB';
SET temp_directory = '.tmp/spill';
SET preserve_insertion_order = false;
SET threads = 4;

-- ── pdf_info on primary monster ────────────────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'info_monster',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    i.page_count,
    i.file_size,
    stress_mem_mb(),
    stress_spill_mb(),
    format('size_mb={:.2f} encrypted={}', i.file_size / 1024.0 / 1024.0, i.is_encrypted)
FROM pdf_info('samples/stress/monster.pdf') i;

-- ── Full CTAS of words (ingest-shaped) ─────────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;

DROP TABLE IF EXISTS stress_words;
CREATE TABLE stress_words AS
SELECT
    page::INTEGER AS page_no,
    row_number() OVER (
        PARTITION BY page
        ORDER BY round(y0, 1), x0, word
    )::INTEGER AS seq,
    word::VARCHAR AS word,
    x0::DOUBLE AS x0,
    y0::DOUBLE AS y0,
    x1::DOUBLE AS x1,
    y1::DOUBLE AS y1,
    font_size::DOUBLE AS font_size
FROM read_pdf_words('samples/stress/monster.pdf');

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'extract_words_ctas',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    count(*),
    count(DISTINCT page_no),
    stress_mem_mb(),
    stress_spill_mb(),
    format(
        'memory_limit=512MB pages={}-{} base_table_mb={:.2f}',
        min(page_no),
        max(page_no),
        (SELECT coalesce(memory_usage_bytes, 0) / 1024.0 / 1024.0
         FROM duckdb_memory() WHERE tag = 'BASE_TABLE')
    )
FROM stress_words;

-- ── Streaming aggregate (no materialize) ───────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'extract_stream_count',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    count(*),
    count(DISTINCT page),
    stress_mem_mb(),
    stress_spill_mb(),
    'count(*) FROM read_pdf_words (no CTAS)'
FROM read_pdf_words('samples/stress/monster.pdf');

-- ── Page-scoped read (first_page/last_page) ────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'extract_page_range_mid',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    count(*),
    2500,
    stress_mem_mb(),
    stress_spill_mb(),
    'read_pdf_words(monster, first_page:=2500, last_page:=2500)'
FROM read_pdf_words('samples/stress/monster.pdf', first_page := 2500, last_page := 2500);

-- ── pdf_to_png one page under 512MB ────────────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
CREATE OR REPLACE TABLE _png AS
SELECT octet_length(pdf_to_png('samples/stress/monster.pdf', 2500, 72)) AS png_bytes;

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'extract_pdf_to_png_one_page',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    png_bytes,
    2500,
    stress_mem_mb(),
    stress_spill_mb(),
    'pdf_to_png(monster, page=2500, dpi=72)'
FROM _png;

SELECT step, status, wall_ms, n, n2, round(mem_mb, 2) AS mem_mb, round(spill_mb, 2) AS spill_mb, detail
FROM stress_metrics
WHERE step LIKE 'info_%' OR step LIKE 'extract%'
ORDER BY recorded_at;

SELECT tag,
       round(memory_usage_bytes / 1024.0 / 1024.0, 2) AS mem_mb,
       round(temporary_storage_bytes / 1024.0 / 1024.0, 2) AS spill_mb
FROM duckdb_memory()
WHERE memory_usage_bytes > 0 OR temporary_storage_bytes > 0
ORDER BY memory_usage_bytes DESC;
