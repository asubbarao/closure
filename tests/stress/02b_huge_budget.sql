-- 02b_huge_budget.sql — open / page-scope / png on monster_huge under 512MB.
-- Expectation (from prior RSS measurements): pdf_info / any open of a ~700MB
-- file peaks near file size in *process* RSS — DuckDB's memory_limit does NOT
-- cap native Poppler open cost. Spill helps query operators only.
--
-- If monster_huge.pdf is absent, records status=skipped.
-- Invoke (after 01b or with prebuilt artifact):
--   duckdb154 -unsigned -c ".read tests/stress/00_setup.sql" \
--             -c ".read tests/stress/02b_huge_budget.sql"

SET memory_limit = '512MB';
SET temp_directory = '/tmp/closure_spill';
SET preserve_insertion_order = false;
SET threads = 4;

-- Presence check via glob-safe attempt: pdf_info returns 0 rows if missing? It errors.
-- Use read_blob existence pattern via length of file list from glob on directory.
CREATE OR REPLACE TABLE _huge_present AS
SELECT count(*) > 0 AS present
FROM glob('samples/stress/monster_huge.pdf');

-- ── pdf_info under 512MB ───────────────────────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail, error_msg)
SELECT
    'huge_pdf_info_512mb',
    CASE WHEN (SELECT present FROM _huge_present) THEN 'ok' ELSE 'skipped' END,
    CASE WHEN (SELECT present FROM _huge_present)
         THEN stress_now_ms() - (SELECT t0 FROM _stress_t0) ELSE 0 END,
    i.page_count,
    i.file_size,
    stress_mem_mb(),
    stress_spill_mb(),
    CASE WHEN (SELECT present FROM _huge_present)
         THEN format('size_mb={:.2f} — DuckDB pool mem_mb is NOT process RSS', i.file_size / 1024.0 / 1024.0)
         ELSE 'monster_huge.pdf absent' END,
    CASE WHEN (SELECT present FROM _huge_present) THEN NULL
         ELSE 'skip: run 01b_generate_huge.sql first' END
FROM (SELECT 1) _
LEFT JOIN (
    SELECT * FROM pdf_info('samples/stress/monster_huge.pdf')
    WHERE (SELECT present FROM _huge_present)
) i ON true;

-- ── one-page words under 512MB ─────────────────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail, error_msg)
SELECT
    'huge_read_words_page1_512mb',
    CASE WHEN (SELECT present FROM _huge_present) THEN 'ok' ELSE 'skipped' END,
    CASE WHEN (SELECT present FROM _huge_present)
         THEN stress_now_ms() - (SELECT t0 FROM _stress_t0) ELSE 0 END,
    CASE WHEN (SELECT present FROM _huge_present) THEN (
        SELECT count(*) FROM read_pdf_words(
            'samples/stress/monster_huge.pdf', first_page := 1, last_page := 1
        )
    ) ELSE NULL END,
    1,
    stress_mem_mb(),
    stress_spill_mb(),
    'first_page:=1 last_page:=1 under memory_limit=512MB',
    CASE WHEN (SELECT present FROM _huge_present) THEN NULL ELSE 'skipped' END;

-- ── mid-page png under 512MB ───────────────────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail, error_msg)
SELECT
    'huge_pdf_to_png_mid_512mb',
    CASE WHEN (SELECT present FROM _huge_present) THEN 'ok' ELSE 'skipped' END,
    CASE WHEN (SELECT present FROM _huge_present)
         THEN stress_now_ms() - (SELECT t0 FROM _stress_t0) ELSE 0 END,
    CASE WHEN (SELECT present FROM _huge_present) THEN (
        SELECT octet_length(pdf_to_png('samples/stress/monster_huge.pdf', 65000, 72))
    ) ELSE NULL END,
    65000,
    stress_mem_mb(),
    stress_spill_mb(),
    'pdf_to_png page 65000 dpi 72',
    CASE WHEN (SELECT present FROM _huge_present) THEN NULL ELSE 'skipped' END;

SELECT step, status, wall_ms, n, n2, round(mem_mb, 2) AS mem_mb, round(spill_mb, 2) AS spill_mb, detail, error_msg
FROM stress_metrics
WHERE step LIKE 'huge_%'
ORDER BY recorded_at;
