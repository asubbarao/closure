-- break_b1_all_list.sql — ISOLATED OOM probe (tera-context bomb).
-- Fresh session, 256MB cap (matches quackapi serve default), materialize words
-- then list(struct) ALL rows.
--
-- Measured 2026-07-19 on 5k-page / 3.097M-word monster.pdf (DuckDB 1.5.4):
--   memory_limit=256MB → Out of Memory Error: failed to allocate data of size
--     64.0 MiB (208.9 MiB/244.1 MiB used); process max RSS ~431 MB
--   memory_limit=512MB → often SUCCEEDS for this corpus (borderline; do not rely)
--
-- Invoke:
--   duckdb154 -unsigned -c ".read tests/stress/break_b1_all_list.sql" \
--       2>samples/stress/break_b1.err || true
-- Requires samples/stress/monster.pdf (from 01_generate.sql).

INSTALL pdf FROM community;
LOAD pdf;
SET memory_limit = '256MB';
SET temp_directory = '/tmp/closure_spill';
SET preserve_insertion_order = false;
SET threads = 4;

CREATE OR REPLACE TABLE stress_words AS
SELECT
    page::INTEGER AS page_no,
    word::VARCHAR AS word,
    x0::DOUBLE AS x0, y0::DOUBLE AS y0, x1::DOUBLE AS x1, y1::DOUBLE AS y1
FROM read_pdf_words('samples/stress/monster.pdf');

SELECT count(*) AS words, count(DISTINCT page_no) AS pages FROM stress_words;

-- THE BOMB — do not put this in a tera_render context map.
SELECT len(list(struct_pack(
    word := word,
    page_no := page_no,
    x0 := x0, y0 := y0, x1 := x1, y1 := y1
))) AS all_words_list_len
FROM stress_words;
