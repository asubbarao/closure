-- 01_html_xml_words.sql
-- Spike: multi-format document ingest via webbed → same shape as app `words`
-- (document_id, page_no, seq, word, x0, y0, x1, y1, font_size).
--
-- Run from repo root:
--   duckdb :memory: < spikes/web-ingest/01_html_xml_words.sql
--
-- Position model (honest):
--   PDF path: x0/y0/x1/y1 are page-point boxes from read_pdf_words (top-left origin).
--   HTML/XML path: no layout boxes. We emit SYNTHETIC geometry:
--     · page_no  = 1 (single logical "page" per document; multi-page HTML not modeled)
--     · y0/y1    = line_index * LINE_H  (line = whitespace-split of block text by \n,
--                   or a single line if the extract is flat)
--     · x0/x1    = UTF-8 char offsets within that line (start inclusive, end exclusive)
--     · font_size = constant LINE_H (placeholder; not a real font metric)
--   Same-line n-grams (abs(y0_a - y0_b) < 2) still work: tokens on the same line
--   share y0. Redaction *boxes* on an HTML render would need a different export
--   path (CSS selectors / char ranges), not pdf_redact.

INSTALL webbed FROM community;
LOAD webbed;

CREATE OR REPLACE MACRO qnorm(t) AS lower(trim(cast(t AS VARCHAR), '.,;:()"'''));

CREATE OR REPLACE MACRO LINE_H() AS 12.0;

-- ── fixtures ────────────────────────────────────────────────────────────────
-- read_text is a table function (filename, content, size, last_modified).
CREATE OR REPLACE TABLE fixtures AS
SELECT 'html' AS fmt,
       regexp_replace(filename, '.*/', '') AS filename,
       content AS raw
FROM read_text('spikes/web-ingest/fixtures/incident_report_24-000117.html')
UNION ALL
SELECT 'xml',
       regexp_replace(filename, '.*/', ''),
       content
FROM read_text('spikes/web-ingest/fixtures/incident_report_24-000117.xml');

-- ── text plane ──────────────────────────────────────────────────────────────
-- HTML: //text() nodes joined with space (html_extract_text without xpath
--       concatenates with NO spaces — do not use the 1-arg form for tokens).
-- XML:  same idea via xml_extract_text(..., '//text()') then join.
CREATE OR REPLACE TABLE extracted AS
SELECT
    fmt,
    filename,
    CASE fmt
        WHEN 'html' THEN array_to_string(
            html_extract_text(raw::HTML, '//text()'),
            ' '
        )
        WHEN 'xml' THEN array_to_string(
            list_transform(
                xml_extract_text(raw, '//text()'),
                lambda x: cast(x AS VARCHAR)
            ),
            ' '
        )
    END AS body_text,
    -- structural side-channel (HTML only): duck_blocks for element-level review
    CASE fmt
        WHEN 'html' THEN html_to_duck_blocks(raw)
        ELSE NULL
    END AS duck_blocks,
    CASE fmt
        WHEN 'xml' THEN xml_to_json(raw)
        ELSE NULL
    END AS xml_json
FROM fixtures;

-- ── tokenize → words-shaped table ───────────────────────────────────────────
-- One logical line for the whole body (flat extract). Char offsets become x*.
CREATE OR REPLACE TABLE words AS
WITH body AS (
    SELECT
        row_number() OVER (ORDER BY fmt, filename)::INTEGER AS document_id,
        fmt,
        filename,
        regexp_replace(body_text, '[[:space:]]+', ' ') AS body_text
    FROM extracted
    WHERE body_text IS NOT NULL AND length(trim(body_text)) > 0
),
toks AS (
    SELECT
        b.document_id,
        b.fmt,
        b.filename,
        b.body_text,
        t.word,
        t.ord::INTEGER AS seq
    FROM body b,
    UNNEST(regexp_extract_all(b.body_text, '[^[:space:]]+'))
        WITH ORDINALITY AS t(word, ord)
),
pos AS (
    SELECT
        document_id,
        fmt,
        filename,
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
    fmt,
    filename
FROM pos
ORDER BY document_id, seq;

-- ── same n-gram helper shape as server/schema.sql (y-threshold same-line) ───
CREATE OR REPLACE VIEW v_grams AS
WITH base AS (
    SELECT document_id, page_no, seq, word, x0, y0, x1, y1,
           lead(word, 1) OVER w AS word1, lead(x1, 1) OVER w AS x1_1,
           lead(y0, 1) OVER w AS y0_1,   lead(y1, 1) OVER w AS y1_1,
           lead(word, 2) OVER w AS word2, lead(x1, 2) OVER w AS x1_2,
           lead(y0, 2) OVER w AS y0_2,   lead(y1, 2) OVER w AS y1_2,
           lead(word, 3) OVER w AS word3, lead(x1, 3) OVER w AS x1_3,
           lead(y0, 3) OVER w AS y0_3,   lead(y1, 3) OVER w AS y1_3
    FROM words
    WINDOW w AS (PARTITION BY document_id, page_no ORDER BY seq)
)
SELECT document_id, page_no, seq, 1 AS n, qnorm(word) AS text_norm,
       word AS text_raw, x0, y0, x1, y1
FROM base
UNION ALL
SELECT document_id, page_no, seq, 2, qnorm(word) || ' ' || qnorm(word1),
       word || ' ' || word1, x0, least(y0, y0_1), x1_1, greatest(y1, y1_1)
FROM base WHERE word1 IS NOT NULL AND abs(y0_1 - y0) < 2
UNION ALL
SELECT document_id, page_no, seq, 3,
       qnorm(word) || ' ' || qnorm(word1) || ' ' || qnorm(word2),
       word || ' ' || word1 || ' ' || word2,
       x0, least(y0, y0_1, y0_2), x1_2, greatest(y1, y1_1, y1_2)
FROM base WHERE word2 IS NOT NULL AND abs(y0_1 - y0) < 2 AND abs(y0_2 - y0) < 2
UNION ALL
SELECT document_id, page_no, seq, 4,
       qnorm(word) || ' ' || qnorm(word1) || ' ' || qnorm(word2) || ' ' || qnorm(word3),
       word || ' ' || word1 || ' ' || word2 || ' ' || word3,
       x0, least(y0, y0_1, y0_2, y0_3), x1_3, greatest(y1, y1_1, y1_2, y1_3)
FROM base WHERE word3 IS NOT NULL
       AND abs(y0_1 - y0) < 2 AND abs(y0_2 - y0) < 2 AND abs(y0_3 - y0) < 2;

-- PII targets from samples/identities.json case 24-000117 (not loading the
-- whole catalog — keep the spike standalone).
CREATE OR REPLACE TABLE pii_targets AS
SELECT * FROM (VALUES
    ('Magnolia Cronin', 'PERSON · SUBJECT'),
    ('271-72-1446',     'SSN'),
    ('08/16/1979',      'DATE OF BIRTH'),
    ('776 Maple St, Portland, OR 97205', 'ADDRESS · SUBJECT'),
    ('(613) 235-3301',  'PHONE · SUBJECT'),
    ('Marques Cruickshank', 'PERSON · WITNESS'),
    ('Cronin Street',   'STREET NAME · NOT PII'),
    ('Cronin v. Ohio, 494 U.S. 541 (1990)', 'CITATION · NOT PII')
) AS t(canonical_text, kind);

CREATE OR REPLACE TABLE pii_hits AS
SELECT
    w.fmt,
    w.filename,
    e.kind,
    e.canonical_text,
    g.n AS n_tokens,
    g.seq AS start_seq,
    g.text_raw,
    g.x0, g.y0, g.x1, g.y1
FROM pii_targets e
JOIN v_grams g ON g.text_norm = qnorm(e.canonical_text)
JOIN (SELECT DISTINCT document_id, fmt, filename FROM words) w
  ON w.document_id = g.document_id
ORDER BY w.fmt, e.kind, g.seq;

-- ── report ──────────────────────────────────────────────────────────────────
.mode markdown

SELECT '=== word counts by format ===' AS section;
SELECT fmt, filename, count(*) AS n_words,
       min(x0) AS min_x0, max(x1) AS max_x1
FROM words GROUP BY 1, 2 ORDER BY 1;

SELECT '=== first 20 HTML tokens (char-offset geometry) ===' AS section;
SELECT seq, word, x0, y0, x1, y1
FROM words WHERE fmt = 'html' ORDER BY seq LIMIT 20;

SELECT '=== first 20 XML tokens ===' AS section;
SELECT seq, word, x0, y0, x1, y1
FROM words WHERE fmt = 'xml' ORDER BY seq LIMIT 20;

SELECT '=== PII / plant hits via same n-gram matcher as the app ===' AS section;
SELECT fmt, kind, canonical_text, n_tokens, start_seq, text_raw,
       x0, x1, y0
FROM pii_hits
ORDER BY fmt, kind, start_seq;

SELECT '=== HTML duck_blocks (structure side-channel, not word geometry) ===' AS section;
SELECT b.element_order, b.kind, b.element_type,
       left(coalesce(b.content, ''), 80) AS content_preview
FROM extracted e,
     UNNEST(e.duck_blocks) AS u(b)
WHERE e.fmt = 'html'
ORDER BY b.element_order
LIMIT 25;

SELECT '=== XML as JSON (xml_to_json; no html_to_json in webbed) ===' AS section;
SELECT left(xml_json, 300) AS xml_json_head FROM extracted WHERE fmt = 'xml';

-- Persist for the README / docs
COPY (SELECT * FROM words ORDER BY document_id, seq)
TO 'spikes/web-ingest/out/words.csv' (HEADER, DELIMITER ',');
COPY (SELECT * FROM pii_hits ORDER BY fmt, kind, start_seq)
TO 'spikes/web-ingest/out/pii_hits.csv' (HEADER, DELIMITER ',');

SELECT 'wrote spikes/web-ingest/out/words.csv and pii_hits.csv' AS done;
