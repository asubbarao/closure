-- 03_page_vs_all.sql — prove render path is O(one page), not O(document).
-- Mirrors routes.sql review route: page-scoped words → list(struct_pack(...)).
-- Preconditions: stress_words from 02_extract.sql.

SET memory_limit = '512MB';
SET temp_directory = '.tmp/spill';
SET preserve_insertion_order = false;

CREATE OR REPLACE TABLE _pg AS
SELECT greatest(1, (SELECT cast(max(page_no) / 2 AS INTEGER) FROM stress_words)) AS page_no;

-- ── A. Page-scoped filter ──────────────────────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
CREATE OR REPLACE TABLE _page_words AS
SELECT * FROM stress_words WHERE page_no = (SELECT page_no FROM _pg);

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'page_words_filter',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    count(*),
    (SELECT page_no FROM _pg),
    stress_mem_mb(),
    stress_spill_mb(),
    'WHERE page_no = mid-doc'
FROM _page_words;

-- ── B. Page-scoped tera-shaped list(struct) ────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
CREATE OR REPLACE TABLE _page_list AS
SELECT list(struct_pack(
    word := word,
    seq := seq,
    bbox := bbox
) ORDER BY seq) AS words
FROM stress_words
WHERE page_no = (SELECT page_no FROM _pg);

INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'page_list_tera_shape',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    len(words),
    (SELECT page_no FROM _pg),
    stress_mem_mb(),
    stress_spill_mb(),
    'list(struct_pack) ONE page — review-route shape'
FROM _page_list;

-- ── C. Full-table cheap aggregate ──────────────────────────────────────────
CREATE OR REPLACE TABLE _stress_t0 AS SELECT stress_now_ms() AS t0;
INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail)
SELECT
    'all_words_count',
    'ok',
    stress_now_ms() - (SELECT t0 FROM _stress_t0),
    count(*),
    count(DISTINCT page_no),
    stress_mem_mb(),
    stress_spill_mb(),
    'count(*) over full words table'
FROM stress_words;

-- ── D. Anti-pattern deferred (isolated OOM in break_b1_all_list.sql) ───────
INSERT INTO stress_metrics (step, status, wall_ms, n, n2, mem_mb, spill_mb, detail, error_msg)
VALUES (
    'all_words_list_pack',
    'expected_fail_isolated',
    NULL, NULL, NULL, NULL, NULL,
    'see break_b1_all_list.sql — list(struct) ALL pages under 512MB',
    'Out of Memory @256MB: failed to allocate 64.0 MiB (208.9 MiB/244.1 MiB used) — measured 2026-07-19; @512MB often succeeds on 5k corpus'
);

SELECT step, status, wall_ms, n, n2 AS page_or_pages, round(mem_mb, 2) AS mem_mb, detail
FROM stress_metrics
WHERE step IN (
    'page_words_filter',
    'page_list_tera_shape',
    'all_words_count',
    'all_words_list_pack'
)
ORDER BY recorded_at;
