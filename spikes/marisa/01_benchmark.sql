-- 01_benchmark.sql — optional single-file sketch of the marisa spike.
--
-- Prefer the accurate driver:
--   bash spikes/marisa/run_bench.sh
--
-- This file documents the SQL shapes side-by-side for inspection / ad-hoc
-- probing. Timing via nested clock_timestamp() is less reliable than the
-- shell driver (.timer on in one process).
--
-- Run from repo root (if used):
--   duckdb -unsigned :memory: < spikes/marisa/01_benchmark.sql

INSTALL pdf FROM community;
LOAD pdf;
INSTALL marisa FROM community;
LOAD marisa;
INSTALL fakeit FROM community;
LOAD fakeit;

SET memory_limit = '4GB';
SET threads = 4;

CREATE OR REPLACE MACRO qnorm(t) AS
    lower(trim(cast(t AS VARCHAR), '.,;:()"'''));

-- Thin demo: 1× samples, 10k dict, print both plans + counts.
CREATE OR REPLACE TABLE words AS
SELECT
    regexp_replace(regexp_replace(w.filename, '.*/', ''), '\.pdf$', '') AS document_id,
    w.page::INTEGER AS page_no,
    row_number() OVER (
        PARTITION BY w.filename, w.page
        ORDER BY round(w.y0, 1), w.x0, w.word
    )::INTEGER AS seq,
    cast(w.word AS VARCHAR) AS word,
    w.x0::DOUBLE AS x0, w.y0::DOUBLE AS y0, w.x1::DOUBLE AS x1, w.y1::DOUBLE AS y1
FROM read_pdf_words('samples/*.pdf') w;

CREATE OR REPLACE TABLE grams AS
WITH base AS (
    SELECT document_id, page_no, seq, word, x0, y0, x1, y1,
           lead(word, 1) OVER win AS word1, lead(y0, 1) OVER win AS y0_1,
           lead(word, 2) OVER win AS word2, lead(y0, 2) OVER win AS y0_2,
           lead(word, 3) OVER win AS word3, lead(y0, 3) OVER win AS y0_3
    FROM words
    WINDOW win AS (PARTITION BY document_id, page_no ORDER BY seq)
)
SELECT document_id, page_no, seq, 1 AS n, qnorm(word) AS text_norm FROM base
UNION ALL
SELECT document_id, page_no, seq, 2, qnorm(word)||' '||qnorm(word1)
FROM base WHERE word1 IS NOT NULL AND abs(y0_1 - y0) < 2
UNION ALL
SELECT document_id, page_no, seq, 3,
       qnorm(word)||' '||qnorm(word1)||' '||qnorm(word2)
FROM base WHERE word2 IS NOT NULL AND abs(y0_1 - y0) < 2 AND abs(y0_2 - y0) < 2
UNION ALL
SELECT document_id, page_no, seq, 4,
       qnorm(word)||' '||qnorm(word1)||' '||qnorm(word2)||' '||qnorm(word3)
FROM base WHERE word3 IS NOT NULL
  AND abs(y0_1 - y0) < 2 AND abs(y0_2 - y0) < 2 AND abs(y0_3 - y0) < 2;

CREATE OR REPLACE TABLE _plant AS
SELECT text_norm FROM (
    SELECT text_norm FROM grams
    WHERE n BETWEEN 1 AND 3 AND length(text_norm) >= 3
      AND regexp_matches(text_norm, '[a-z]')
    GROUP BY text_norm
    ORDER BY abs(hash(text_norm))
    LIMIT 200
);

CREATE OR REPLACE TABLE dict_10k AS
WITH filler AS (
    SELECT DISTINCT lower(trim(fakeit_name_first()||' '||fakeit_name_last())) AS text_norm
    FROM generate_series(1, 20000)
    WHERE text_norm IS NOT NULL AND text_norm <> ''
    ORDER BY text_norm
    LIMIT 9800
)
SELECT text_norm, row_number() OVER (ORDER BY text_norm)::INTEGER AS dict_id
FROM (
    SELECT text_norm FROM _plant
    UNION
    SELECT text_norm FROM filler
) u;

CREATE OR REPLACE TABLE trie_10k AS
SELECT marisa_trie(text_norm) AS trie FROM dict_10k;

SELECT 'corpus' AS section, count(*) AS n_words FROM words
UNION ALL SELECT 'grams', count(*) FROM grams
UNION ALL SELECT 'dict', count(*) FROM dict_10k
UNION ALL SELECT 'trie_bytes', octet_length(trie) FROM trie_10k;

.timer on

SELECT 'hash_join' AS method, count(*) AS hits
FROM grams g JOIN dict_10k d ON g.text_norm = d.text_norm;

SELECT 'marisa_lookup' AS method, count(*) AS hits
FROM grams g, trie_10k t
WHERE marisa_lookup(t.trie, g.text_norm);

EXPLAIN
SELECT count(*) FROM grams g JOIN dict_10k d ON g.text_norm = d.text_norm;

EXPLAIN
SELECT count(*) FROM grams g, trie_10k t WHERE marisa_lookup(t.trie, g.text_norm);

SELECT 'See docs/marisa-verdict.md — prefer run_bench.sh for full 10k/100k numbers' AS note;
