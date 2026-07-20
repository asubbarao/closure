-- 02_url_crawl.sql
-- Spike: URL / source import via crawler → webbed parse → words shape.
--
-- Prerequisites:
--   · A local HTTP server serving spikes/web-ingest/fixtures/ on :8765
--     (see README). Crawler needs a real URL; file:// is not its model.
--
-- Run from repo root (server already up):
--   duckdb :memory: < spikes/web-ingest/02_url_crawl.sql
--
-- Notes:
--   · crawl() hangs / delays badly with default robots + link-follow; for a
--     single-document import use max_depth:=0, respect_robots:=false, delay:=0.
--   · CRAWL ... INTO syntax from upstream README is NOT available in the
--     signed community build exercised here (v1.5.3 osx_arm64) — table
--     function crawl() is the working surface.
--   · Do NOT LOAD webbed and crawler together if you need webbed.read_html:
--     both register read_html. This spike uses crawler's html.document body
--     + webbed's html_extract_text scalar (name collision only on read_html).

INSTALL crawler FROM community;
INSTALL webbed FROM community;
LOAD crawler;
LOAD webbed;

CREATE OR REPLACE MACRO qnorm(t) AS lower(trim(cast(t AS VARCHAR), '.,;:()"'''));
CREATE OR REPLACE MACRO LINE_H() AS 12.0;

SET crawler_respect_robots = false;
SET crawler_timeout_ms = 5000;
SET crawler_default_delay = 0;

-- ── fetch ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE TABLE crawled AS
SELECT
    url,
    status,
    content_type,
    html.document AS html_doc,
    error,
    response_time_ms
FROM crawl(
    ['http://127.0.0.1:8765/incident_report_24-000117.html'],
    max_depth := 0,
    respect_robots := false,
    timeout := 5,
    delay := 0,
    workers := 1,
    max_results := 1,
    user_agent := 'ClosureWebIngestSpike/1.0'
);

-- Fail loud if the fixture server is down
CREATE OR REPLACE TABLE _assert AS
SELECT
    CASE
        WHEN (SELECT count(*) FROM crawled WHERE status = 200 AND html_doc IS NOT NULL) = 1
        THEN 'ok'
        ELSE error('crawl failed — start fixture server: '
            || 'python3 -m http.server 8765 --directory spikes/web-ingest/fixtures')
    END AS status;

-- ── parse body → words (same geometry contract as 01_*) ─────────────────────
CREATE OR REPLACE TABLE extracted AS
SELECT
    url,
    status,
    content_type,
    array_to_string(html_extract_text(html_doc::HTML, '//text()'), ' ') AS body_text,
    html_extract_links(html_doc::HTML) AS links,
    response_time_ms
FROM crawled
WHERE status = 200;

CREATE OR REPLACE TABLE words AS
WITH body AS (
    SELECT
        1::INTEGER AS document_id,
        url AS source_url,
        regexp_replace(body_text, '[[:space:]]+', ' ') AS body_text
    FROM extracted
),
toks AS (
    SELECT
        b.document_id,
        b.source_url,
        t.word,
        t.ord::INTEGER AS seq
    FROM body b,
    UNNEST(regexp_extract_all(b.body_text, '[^[:space:]]+'))
        WITH ORDINALITY AS t(word, ord)
),
pos AS (
    SELECT
        document_id,
        source_url,
        seq,
        word,
        (
            SELECT coalesce(sum(length(t2.word) + 1), 0)
            FROM toks t2
            WHERE t2.document_id = toks.document_id
              AND t2.seq < toks.seq
        )::DOUBLE AS x0
    FROM toks
)
SELECT
    document_id,
    1::INTEGER AS page_no,
    seq,
    word,
    x0,
    0.0 AS y0,
    (x0 + length(word))::DOUBLE AS x1,
    LINE_H() AS y1,
    LINE_H() AS font_size,
    source_url
FROM pos
ORDER BY seq;

CREATE OR REPLACE VIEW v_grams AS
WITH base AS (
    SELECT document_id, page_no, seq, word, x0, y0, x1, y1,
           lead(word, 1) OVER w AS word1, lead(x1, 1) OVER w AS x1_1,
           lead(y0, 1) OVER w AS y0_1
    FROM words
    WINDOW w AS (PARTITION BY document_id, page_no ORDER BY seq)
)
SELECT document_id, page_no, seq, 1 AS n, qnorm(word) AS text_norm,
       word AS text_raw, x0, y0, x1, y1
FROM base
UNION ALL
SELECT document_id, page_no, seq, 2, qnorm(word) || ' ' || qnorm(word1),
       word || ' ' || word1, x0, y0, x1_1, y1
FROM base WHERE word1 IS NOT NULL AND abs(y0_1 - y0) < 2;

CREATE OR REPLACE TABLE pii_hits AS
SELECT g.n, g.seq, g.text_raw, g.x0, g.x1, e.kind, e.canonical_text
FROM (VALUES
    ('Magnolia Cronin', 'PERSON · SUBJECT'),
    ('271-72-1446', 'SSN'),
    ('08/16/1979', 'DATE OF BIRTH')
) AS e(canonical_text, kind)
JOIN v_grams g ON g.text_norm = qnorm(e.canonical_text)
ORDER BY e.kind, g.seq;

-- ── report ──────────────────────────────────────────────────────────────────
.mode markdown

SELECT '=== crawl fetch ===' AS section;
SELECT url, status, content_type, response_time_ms,
       length(html_doc) AS html_bytes,
       error
FROM crawled;

SELECT '=== word count from URL body ===' AS section;
SELECT count(*) AS n_words, min(x0) AS min_x0, max(x1) AS max_x1 FROM words;

SELECT '=== sample tokens ===' AS section;
SELECT seq, word, x0, x1 FROM words ORDER BY seq LIMIT 15;

SELECT '=== PII hits (name / SSN / DOB) ===' AS section;
SELECT kind, canonical_text, n, seq, text_raw, x0, x1 FROM pii_hits;

SELECT '=== links extracted (webbed html_extract_links on crawled body) ===' AS section;
SELECT unnest(links) AS link FROM extracted;

COPY (SELECT * FROM crawled)
TO 'spikes/web-ingest/out/crawl_meta.csv' (HEADER, DELIMITER ',');
COPY (SELECT * FROM words ORDER BY seq)
TO 'spikes/web-ingest/out/crawl_words.csv' (HEADER, DELIMITER ',');
COPY (SELECT * FROM pii_hits)
TO 'spikes/web-ingest/out/crawl_pii_hits.csv' (HEADER, DELIMITER ',');

SELECT 'wrote crawl_meta.csv, crawl_words.csv, crawl_pii_hits.csv' AS done;
