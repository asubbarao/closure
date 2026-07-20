-- 01b_generate_huge.sql — OPTIONAL ~0.7–1 GB / 100k+ pages.
-- Produces samples/stress/monster_huge.pdf
-- Measured constants (DuckDB 1.5.4 + pdf ext, 2026-07-19):
--   700_000 dense rows → 130_419 pages, 709.4 MB
-- Disk-heavy; skip in CI. Run after primary suite:
--   duckdb154 -unsigned -c ".read tests/stress/00_setup.sql" \
--             -c ".read tests/stress/01b_generate_huge.sql"

SET memory_limit = '4GB';
SET temp_directory = '/tmp/closure_spill';
SET preserve_insertion_order = false;
SET threads = 4;

SELECT write_pdf('huge probe', 'samples/stress/_probe.pdf');

CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;

-- Unique-ish body (md5) to limit zlib wins; FONT_SIZE 10 letter ≈ ~5.4 rows/page.
COPY (
    SELECT format(
        'L{} h={} SSN {:03d}-{:02d}-{:04d} DOB 19{:02d}-{:02d}-{:02d} NAME Subj{}-{} ADDR {} {} St #{} ph 555-{:04d} {}',
        i,
        md5(i::VARCHAR),
        (i * 7) % 1000,
        (i * 3) % 100,
        (i * 11) % 10000,
        i % 50,
        1 + (i % 12),
        1 + (i % 28),
        i,
        md5((i * 13)::VARCHAR)[1:8],
        100 + (i % 900),
        CASE i % 5
            WHEN 0 THEN 'Oak'
            WHEN 1 THEN 'Maple'
            WHEN 2 THEN 'Pine'
            WHEN 3 THEN 'Cedar'
            ELSE 'Elm'
        END,
        i % 200,
        i % 10000,
        repeat(md5((i * 99)::VARCHAR) || ' evidence narrative chain custody ', 10)
    ) AS body
    FROM generate_series(1, 700000) t(i)
) TO 'samples/stress/monster_huge.pdf' (
    FORMAT pdf,
    FONT_SIZE 10,
    PAGE_SIZE 'letter',
    TITLE 'Closure stress monster huge',
    AUTHOR 'stress harness',
    FOOTER 'page {page}'
);

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'generate_monster_huge',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    i.page_count,
    i.file_size,
    stress_mem_mb(),
    stress_spill_mb(),
    format('path={} size_mb={:.2f}', i.file, i.file_size / 1024.0 / 1024.0)
FROM pdf_info('samples/stress/monster_huge.pdf') i;

SELECT step, status, wall_ms, n AS page_count, n2 AS file_bytes, detail
FROM stress_metrics WHERE step = 'generate_monster_huge';

SET memory_limit = '512MB';
