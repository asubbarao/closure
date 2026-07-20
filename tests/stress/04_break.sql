-- 04_break.sql — scale break probes (expected successes + deferred OOM).
-- Isolated OOM: tests/stress/break_b1_all_list.sql (fresh process).

SET memory_limit = '512MB';
SET temp_directory = '/tmp/closure_spill';
SET preserve_insertion_order = false;
SET threads = 4;

-- ── B1: full-doc list pack (isolated) ──────────────────────────────────────
INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail, error_msg)
VALUES (
    'break_all_list_pack',
    'expected_fail_isolated',
    NULL, NULL, NULL, NULL, NULL,
    'Run tests/stress/break_b1_all_list.sql in a fresh 512MB session',
    'Out of Memory @256MB: failed to allocate 64.0 MiB (208.9 MiB/244.1 MiB used); process max RSS ~431 MB'
);

-- ── B2: single-page PNG ────────────────────────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
CREATE OR REPLACE TABLE _png AS
SELECT octet_length(pdf_to_png('samples/stress/monster.pdf', 2500, 72)) AS png_bytes;

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'break_pdf_to_png_one_page',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    png_bytes,
    2500,
    stress_mem_mb(),
    stress_spill_mb(),
    'pdf_to_png(monster, page=2500, dpi=72)'
FROM _png;

-- ── B3: whole-doc text scalar ──────────────────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
CREATE OR REPLACE TABLE _txt AS
SELECT length(pdf_to_text('samples/stress/monster.pdf')) AS text_bytes;

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'break_pdf_to_text_whole',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    text_bytes,
    NULL,
    stress_mem_mb(),
    stress_spill_mb(),
    'pdf_to_text(monster) full document VARCHAR'
FROM _txt;

-- ── B4: page-bounded read ──────────────────────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'break_read_words_page_range',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    count(*),
    count(DISTINCT page),
    stress_mem_mb(),
    stress_spill_mb(),
    'read_pdf_words(monster, first_page:=2500, last_page:=2500)'
FROM read_pdf_words('samples/stress/monster.pdf', first_page := 2500, last_page := 2500);

-- ── B5: pdf_redact smoke on monster page mid ───────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
CREATE OR REPLACE TABLE _red AS
SELECT * FROM pdf_redact(
    'samples/stress/monster.pdf',
    'samples/stress/_monster_redacted_smoke.pdf',
    [
        {page: 2500, x: 54.0, y: 40.0, w: 200.0, h: 20.0}
    ]
);

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'break_pdf_redact_one_box',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    count(*),
    sum(CASE WHEN redacted THEN 1 ELSE 0 END),
    stress_mem_mb(),
    stress_spill_mb(),
    'pdf_redact one box on page 2500 of monster'
FROM _red;

SELECT step, status, wall_ms, n, n2, round(mem_mb, 2) AS mem_mb, detail, error_msg
FROM stress_metrics
WHERE step LIKE 'break%'
ORDER BY recorded_at;
