-- 01c_generate_folder.sql — 100+ page doc + folder of many PDFs for glob ingest.
-- Artifacts:
--   samples/stress/mid100.pdf          — ≥100 pages
--   samples/stress/glob/g_001.pdf …    — N small multi-page files
--   samples/stress/glob/ (N files)

SET memory_limit = '2GB';
SET temp_directory = '/tmp/closure_spill';
SET preserve_insertion_order = false;
SET threads = 4;

SELECT write_pdf('folder probe', 'samples/stress/_probe.pdf');

-- ── 100+ page mid-size document ────────────────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;

COPY (
    SELECT format(
        'MID100 line {} case 2024-{:04d} SSN 321-54-{:04d} NAME MidSubject{} {}',
        i,
        i % 9000,
        i % 10000,
        i,
        repeat('paragraph body for mid-scale ingest timing ', 8)
    ) AS body
    FROM generate_series(1, 1200) t(i)
) TO 'samples/stress/mid100.pdf' (
    FORMAT pdf,
    FONT_SIZE 11,
    PAGE_SIZE 'letter',
    TITLE 'Closure mid100',
    FOOTER 'page {page}'
);

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'generate_mid100',
    CASE WHEN i.page_count >= 100 THEN 'ok' ELSE 'fail' END,
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    i.page_count,
    i.file_size,
    stress_mem_mb(),
    stress_spill_mb(),
    format('size_mb={:.2f}', i.file_size / 1024.0 / 1024.0)
FROM pdf_info('samples/stress/mid100.pdf') i;

-- ── Folder of many small PDFs (glob corpus) ────────────────────────────────
-- 40 files × ~5 pages each ≈ 200 pages total across the folder.
-- Generated via write_pdf in a set-based loop using recursive CTE + side effect
-- is awkward; use generate_series + write_pdf scalar per row via list comprehension
-- pattern: SELECT write_pdf(...) FROM generate_series.

CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;

-- Write 40 files into glob/, plus scale subfolders (5 / 20 / 40) for timed globs.
-- read_pdf_words accepts a VARCHAR path or glob, not VARCHAR[].
CREATE OR REPLACE TABLE _glob_written AS
SELECT
    i AS file_idx,
    write_pdf(
        format(
            E'GLOB FILE {:03d}\nSSN 111-22-{:04d} NAME GlobPerson{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}',
            i,
            i % 10000,
            i,
            repeat(format('L1-{} narrative chain custody evidence. ', i), 20),
            repeat(format('L2-{} officer report badge detail. ', i), 20),
            repeat(format('L3-{} alpha bravo charlie delta. ', i), 20),
            repeat(format('L4-{} echo foxtrot golf hotel. ', i), 20),
            repeat(format('L5-{} india juliet kilo lima. ', i), 20),
            repeat(format('L6-{} mike november oscar papa. ', i), 20),
            repeat(format('L7-{} quebec romeo sierra tango. ', i), 20),
            repeat(format('L8-{} uniform victor whiskey xray. ', i), 20),
            repeat(format('L9-{} yankee zulu end of page body. ', i), 20),
            repeat(format('L10-{} trailing filler paragraph. ', i), 20)
        ),
        format('samples/stress/glob/g_{:03d}.pdf', i)
    ) AS path_main,
    CASE WHEN i <= 5 THEN write_pdf(
        format(E'SCALE5 FILE {:03d}\nSSN 111-22-{:04d} NAME GlobPerson{}\n{}',
               i, i % 10000, i, repeat('scale5 body narrative. ', 40)),
        format('samples/stress/glob5/g_{:03d}.pdf', i)
    ) END AS path_5,
    CASE WHEN i <= 20 THEN write_pdf(
        format(E'SCALE20 FILE {:03d}\nSSN 111-22-{:04d} NAME GlobPerson{}\n{}',
               i, i % 10000, i, repeat('scale20 body narrative. ', 40)),
        format('samples/stress/glob20/g_{:03d}.pdf', i)
    ) END AS path_20
FROM generate_series(1, 40) t(i);

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'generate_glob_folder',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    (SELECT count(*) FROM _glob_written),
    (SELECT sum(file_size) FROM pdf_info('samples/stress/glob/*.pdf')),
    stress_mem_mb(),
    stress_spill_mb(),
    format(
        'files={} total_pages={} total_mb={:.2f}',
        (SELECT count(*) FROM _glob_written),
        (SELECT sum(page_count) FROM pdf_info('samples/stress/glob/*.pdf')),
        (SELECT sum(file_size) FROM pdf_info('samples/stress/glob/*.pdf')) / 1024.0 / 1024.0
    );

SELECT step, status, wall_ms, n, n2, detail
FROM stress_metrics
WHERE step IN ('generate_mid100', 'generate_glob_folder')
ORDER BY recorded_at;

SET memory_limit = '512MB';
