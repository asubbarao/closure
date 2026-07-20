-- 00_setup.sql — build corpus + dictionaries + tries into a scratch DB.
-- Invoked by run_bench.sh (do not run alone unless you pass a DB path).
--
-- Expects: duckdb -unsigned spikes/marisa/out/bench.db < this file
-- Run from repo root.

INSTALL pdf FROM community;
LOAD pdf;
INSTALL marisa FROM community;
LOAD marisa;
INSTALL fakeit FROM community;
LOAD fakeit;

SET memory_limit = '4GB';
SET threads = 4;

CREATE OR REPLACE TABLE _knobs AS
SELECT
    10::INTEGER AS word_repeats,    -- amplify samples words for scale
    200::INTEGER AS plant_phrases;

CREATE OR REPLACE MACRO qnorm(t) AS
    lower(trim(cast(t AS VARCHAR), '.,;:()"'''));

CREATE OR REPLACE TABLE _words_raw AS
SELECT
    regexp_replace(regexp_replace(w.filename, '.*/', ''), '\.pdf$', '') AS stem,
    w.page::INTEGER AS page_no,
    cast(w.word AS VARCHAR) AS word,
    w.x0::DOUBLE AS x0,
    w.y0::DOUBLE AS y0,
    w.x1::DOUBLE AS x1,
    w.y1::DOUBLE AS y1
FROM read_pdf_words('samples/*.pdf') w;

CREATE OR REPLACE TABLE words AS
SELECT
    (r.rep || '::' || w.stem) AS document_id,
    w.page_no,
    row_number() OVER (
        PARTITION BY r.rep, w.stem, w.page_no
        ORDER BY round(w.y0, 1), w.x0, w.word
    )::INTEGER AS seq,
    w.word,
    w.x0, w.y0, w.x1, w.y1
FROM _words_raw w
CROSS JOIN (
    SELECT unnest(generate_series(1, (SELECT word_repeats FROM _knobs))) AS rep
) r;

CREATE OR REPLACE TABLE grams AS
WITH base AS (
    SELECT
        document_id, page_no, seq, word, x0, y0, x1, y1,
        lead(word, 1) OVER win AS word1, lead(y0, 1) OVER win AS y0_1,
        lead(word, 2) OVER win AS word2, lead(y0, 2) OVER win AS y0_2,
        lead(word, 3) OVER win AS word3, lead(y0, 3) OVER win AS y0_3
    FROM words
    WINDOW win AS (PARTITION BY document_id, page_no ORDER BY seq)
)
SELECT document_id, page_no, seq, 1 AS n, qnorm(word) AS text_norm, word AS text_raw
FROM base
UNION ALL
SELECT document_id, page_no, seq, 2,
       qnorm(word) || ' ' || qnorm(word1), word || ' ' || word1
FROM base WHERE word1 IS NOT NULL AND abs(y0_1 - y0) < 2
UNION ALL
SELECT document_id, page_no, seq, 3,
       qnorm(word) || ' ' || qnorm(word1) || ' ' || qnorm(word2),
       word || ' ' || word1 || ' ' || word2
FROM base WHERE word2 IS NOT NULL AND abs(y0_1 - y0) < 2 AND abs(y0_2 - y0) < 2
UNION ALL
SELECT document_id, page_no, seq, 4,
       qnorm(word) || ' ' || qnorm(word1) || ' ' || qnorm(word2) || ' ' || qnorm(word3),
       word || ' ' || word1 || ' ' || word2 || ' ' || word3
FROM base WHERE word3 IS NOT NULL
  AND abs(y0_1 - y0) < 2 AND abs(y0_2 - y0) < 2 AND abs(y0_3 - y0) < 2;

-- Plant real document n-grams so hit counts are non-zero and comparable.
-- Use abs(hash) ordering (stable) + length filter; require a letter via regexp_matches.
CREATE OR REPLACE TABLE _plant AS
SELECT text_norm
FROM (
    SELECT text_norm
    FROM grams
    WHERE n BETWEEN 1 AND 3
      AND length(text_norm) >= 3
      AND regexp_matches(text_norm, '[a-z]')
    GROUP BY text_norm
    ORDER BY abs(hash(text_norm))
    LIMIT 200
);

CREATE OR REPLACE TABLE _fake_pool AS
SELECT DISTINCT text_norm FROM (
    SELECT lower(trim(fakeit_name_first() || ' ' || fakeit_name_last())) AS text_norm
    FROM generate_series(1, 160000)
    UNION ALL
    SELECT lower(trim(fakeit_name_last())) AS text_norm
    FROM generate_series(1, 50000)
    UNION ALL
    SELECT lower(trim(fakeit_address_street_name() || ' ' || fakeit_address_street_suffix())) AS text_norm
    FROM generate_series(1, 50000)
) s
WHERE text_norm IS NOT NULL AND text_norm <> '';

-- Plants first (guaranteed hits), then fill with distinct fakeit noise.
CREATE OR REPLACE TABLE dict_10k AS
WITH n_plant AS (SELECT count(*)::INTEGER AS n FROM _plant),
filler AS (
    SELECT f.text_norm
    FROM _fake_pool f
    WHERE NOT EXISTS (SELECT 1 FROM _plant p WHERE p.text_norm = f.text_norm)
    ORDER BY f.text_norm
    LIMIT (SELECT 10000 - n FROM n_plant)
),
u AS (
    SELECT text_norm FROM _plant
    UNION
    SELECT text_norm FROM filler
)
SELECT text_norm, row_number() OVER (ORDER BY text_norm)::INTEGER AS dict_id
FROM u;

CREATE OR REPLACE TABLE dict_100k AS
WITH n_plant AS (SELECT count(*)::INTEGER AS n FROM _plant),
filler AS (
    SELECT f.text_norm
    FROM _fake_pool f
    WHERE NOT EXISTS (SELECT 1 FROM _plant p WHERE p.text_norm = f.text_norm)
    ORDER BY f.text_norm
    LIMIT (SELECT 100000 - n FROM n_plant)
),
u AS (
    SELECT text_norm FROM _plant
    UNION
    SELECT text_norm FROM filler
)
SELECT text_norm, row_number() OVER (ORDER BY text_norm)::INTEGER AS dict_id
FROM u;

-- Pre-build tries (build cost measured separately in the driver).
CREATE OR REPLACE TABLE trie_10k AS
SELECT marisa_trie(text_norm) AS trie FROM dict_10k;

CREATE OR REPLACE TABLE trie_100k AS
SELECT marisa_trie(text_norm) AS trie FROM dict_100k;

CREATE OR REPLACE TABLE corpus_stats AS
SELECT
    (SELECT count(*) FROM words) AS n_words,
    (SELECT count(*) FROM grams) AS n_grams,
    (SELECT count(DISTINCT text_norm) FROM grams) AS n_grams_uniq,
    (SELECT count(*) FROM dict_10k) AS n_dict_10k,
    (SELECT count(*) FROM dict_100k) AS n_dict_100k,
    (SELECT word_repeats FROM _knobs) AS word_repeats,
    (SELECT plant_phrases FROM _knobs) AS plant_phrases,
    (SELECT octet_length(trie) FROM trie_10k) AS trie_10k_bytes,
    (SELECT octet_length(trie) FROM trie_100k) AS trie_100k_bytes,
    (SELECT sum(length(text_norm)) FROM dict_10k) AS dict_10k_text_bytes,
    (SELECT sum(length(text_norm)) FROM dict_100k) AS dict_100k_text_bytes,
    (SELECT sum(length(text_norm)) FROM grams) AS grams_text_bytes,
    version() AS duckdb_version,
    current_setting('threads') AS threads,
    current_setting('memory_limit') AS memory_limit;

SELECT * FROM corpus_stats;
CHECKPOINT;
SELECT 'setup complete' AS status;
