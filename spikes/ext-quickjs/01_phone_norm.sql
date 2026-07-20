-- 01_phone_norm.sql
-- Fit: can quickjs fix the parenthesized-phone miss that web-ingest documented?
--
-- App contract (server/schema.sql / ingest.sql):
--   qnorm(t) = lower(trim(t, '.,;:()"'''))
--   match: v_grams.text_norm = qnorm(entity.canonical_text)
--
-- Failure mode (docs/web-extensions-usage.md):
--   catalog "(613) 235-3301" → qnorm → "613) 235-3301"  (trailing ")" residue after leading "(" trim)
--   tokens  "(613)" + "235-3301" → qnorm → "613" + "235-3301" → "613 235-3301"
--   equality fails → phone not suggested.
--
-- Run from repo root:
--   duckdb -unsigned -markdown :memory: < spikes/ext-quickjs/01_phone_norm.sql

INSTALL quickjs FROM community;
LOAD quickjs;

CREATE OR REPLACE MACRO qnorm(t) AS
  lower(trim(cast(t AS VARCHAR), '.,;:()"'''));

-- Pure-SQL digit strip (control): same power as JS for this task.
CREATE OR REPLACE MACRO sql_digits(t) AS
  regexp_replace(cast(t AS VARCHAR), '[^0-9]', '', 'g');

-- quickjs digit strip; quickjs_eval returns JSON so unwrap quotes.
CREATE OR REPLACE MACRO js_digits(t) AS
  trim(both '"' FROM cast(
    quickjs_eval('(s) => String(s).replace(/\D/g,"")', cast(t AS VARCHAR))
    AS VARCHAR
  ));

-- Structured phone validator (the actual JS win over a one-liner regexp).
CREATE OR REPLACE MACRO js_phone(t) AS
  quickjs_eval('(s) => {
    s = String(s);
    const d = s.replace(/\D/g,"");
    const okLen = d.length === 10 || (d.length === 11 && d[0] === "1");
    const ten = d.length === 11 ? d.slice(1) : d;
    const ok = okLen && ten.length === 10;
    return {
      ok: ok,
      digits: ten,
      e164: ok ? ("+1" + ten) : null,
      pretty: ok ? ("(" + ten.slice(0,3) + ") " + ten.slice(3,6) + "-" + ten.slice(6)) : null,
      reason: ok ? "ok" : "not 10/11 NANP digits"
    };
  }', cast(t AS VARCHAR));

-- ── 1) Catalog qnorm residual on real identities.json phones + web-ingest fixture ──
SELECT '=== 1. qnorm residue vs digit-strip (sample + fixture phones) ===' AS section;

WITH catalog AS (
  SELECT * FROM (VALUES
    ('fixture',  '(613) 235-3301'),
    ('case1',    '(586) 883-0028'),
    ('case1_w',  '(813) 412-5212'),
    ('plant',    '586.883.0028'),
    ('dashed',   '586-883-0028'),
    ('bad',      '12345')
  ) v(src, phone)
),
tok AS (
  SELECT phone, unnest(string_split(phone, ' ')) AS tok FROM catalog
)
SELECT
  c.src,
  c.phone AS catalog_raw,
  qnorm(c.phone) AS catalog_qnorm,
  string_agg(qnorm(t.tok), ' ' ORDER BY t.tok) AS tokens_qnorm,
  qnorm(c.phone) = string_agg(qnorm(t.tok), ' ' ORDER BY t.tok) AS match_qnorm,
  sql_digits(c.phone) AS sql_digits,
  js_digits(c.phone) AS js_digits,
  sql_digits(c.phone) = js_digits(c.phone) AS sql_eq_js,
  js_phone(c.phone) AS js_phone_struct
FROM catalog c
LEFT JOIN tok t ON t.phone = c.phone
GROUP BY c.src, c.phone
ORDER BY c.src;

-- ── 2) End-to-end n-gram style match on a narrative sentence (web-ingest failure) ──
SELECT '=== 2. n-gram match: qnorm miss vs digit-key hit ===' AS section;

WITH body AS (
  SELECT 'Subject provided SSN 271-72-1446 and phone (613) 235-3301. Witness Marques.' AS text
),
toks AS (
  SELECT t.word, t.ord::INTEGER AS seq
  FROM body b,
       UNNEST(regexp_extract_all(b.text, '[^[:space:]]+'))
         WITH ORDINALITY AS t(word, ord)
),
grams AS (
  SELECT seq, 1 AS n, word AS text_raw,
         qnorm(word) AS text_qnorm,
         sql_digits(word) AS text_sql_d,
         js_digits(word) AS text_js_d
  FROM toks
  UNION ALL
  SELECT t.seq, 2, t.word || ' ' || t2.word,
         qnorm(t.word) || ' ' || qnorm(t2.word),
         sql_digits(t.word || t2.word),
         js_digits(t.word || ' ' || t2.word)
  FROM toks t
  JOIN toks t2 ON t2.seq = t.seq + 1
),
catalog AS (
  SELECT * FROM (VALUES
    ('PHONE', '(613) 235-3301'),
    ('SSN',   '271-72-1446')
  ) v(kind, phrase)
)
SELECT
  c.kind,
  c.phrase,
  qnorm(c.phrase) AS cat_qnorm,
  bool_or(g.text_qnorm = qnorm(c.phrase)) AS hit_qnorm,
  bool_or(
    length(sql_digits(c.phrase)) >= 9
    AND g.text_sql_d = sql_digits(c.phrase)
  ) AS hit_sql_digits,
  bool_or(
    length(js_digits(c.phrase)) >= 9
    AND g.text_js_d = js_digits(c.phrase)
  ) AS hit_js_digits,
  max(CASE
        WHEN length(js_digits(c.phrase)) >= 9
         AND g.text_js_d = js_digits(c.phrase)
        THEN g.text_raw
      END) AS matched_raw
FROM catalog c
CROSS JOIN grams g
GROUP BY 1, 2, 3
ORDER BY kind;

COPY (
  WITH catalog AS (
    SELECT * FROM (VALUES
      ('fixture',  '(613) 235-3301'),
      ('case1',    '(586) 883-0028'),
      ('plant',    '586.883.0028')
    ) v(src, phone)
  )
  SELECT src, phone,
         qnorm(phone) AS catalog_qnorm,
         sql_digits(phone) AS sql_digits,
         js_digits(phone) AS js_digits,
         cast(js_phone(phone) AS VARCHAR) AS js_phone_struct
  FROM catalog
) TO 'spikes/ext-quickjs/out/01_phone.csv' (HEADER, DELIMITER ',');

SELECT 'wrote spikes/ext-quickjs/out/01_phone.csv' AS note;
