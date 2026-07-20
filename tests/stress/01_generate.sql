-- 01_generate.sql — primary multi-thousand-page PDF via COPY … (FORMAT pdf).
-- Target: ≥5,000 pages. Density: FONT_SIZE 10 letter ≈ 1 page / ~9.8 body rows
-- (measured: 49_000 rows → 5_000 pages, ~27 MB).
-- Artifact: samples/stress/monster.pdf

SET memory_limit = '2GB';
SET temp_directory = '/tmp/closure_spill';
SET preserve_insertion_order = false;
SET threads = 4;

-- Ensure parent dir exists (libharu needs it).
SELECT write_pdf('stress harness probe', 'samples/stress/_probe.pdf');

CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;

COPY (
    SELECT format(
        'LINE {} SSN 123-45-{:04d} DOB 19{:02d}-{:02d}-{:02d} NAME Subject{} ADDR {} Oak Ave STE {} phone 555-01-{:04d} officer Det. Smith badge {} {}',
        i,
        i % 10000,
        i % 50,
        1 + (i % 12),
        1 + (i % 28),
        i,
        100 + (i % 900),
        i % 50,
        i % 10000,
        i % 9000,
        repeat('chain of custody evidence narrative paragraph text ', 6)
    ) AS body
    FROM generate_series(1, 49000) t(i)
) TO 'samples/stress/monster.pdf' (
    FORMAT pdf,
    FONT_SIZE 10,
    PAGE_SIZE 'letter',
    TITLE 'Closure stress monster 5k',
    AUTHOR 'stress harness',
    FOOTER 'page {page}'
);

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'generate_monster',
    CASE WHEN i.page_count >= 5000 THEN 'ok' ELSE 'fail' END,
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    i.page_count,
    i.file_size,
    stress_mem_mb(),
    stress_spill_mb(),
    format(
        'path={} size_mb={:.2f}',
        i.file,
        i.file_size / 1024.0 / 1024.0
    )
FROM pdf_info('samples/stress/monster.pdf') i;

SELECT step, status, wall_ms, n AS page_count, n2 AS file_bytes, detail
FROM stress_metrics WHERE step = 'generate_monster';

SET memory_limit = '512MB';
