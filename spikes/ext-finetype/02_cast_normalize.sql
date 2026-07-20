-- 02_cast_normalize.sql
-- Does finetype_cast canonicalize phones so the web-ingest token-match succeeds?
-- That failure: qnorm('(613) 235-3301') → '613) 235-3301' while tokenized n-grams
-- become '613 235-3301' (paren residue). See docs/web-extensions-usage.md.
--
-- Run from repo root:
--   duckdb -unsigned -markdown < spikes/ext-finetype/02_cast_normalize.sql

INSTALL finetype FROM community;
LOAD finetype;

CREATE OR REPLACE MACRO qnorm(t) AS lower(trim(cast(t AS VARCHAR), '.,;:()"'''));

SELECT '=== finetype_cast on PII shapes ===' AS section;

SELECT
  v,
  finetype_cast(v) AS casted,
  finetype(v) AS type,
  qnorm(v) AS qnormed,
  regexp_replace(v, '[^0-9]+', '', 'g') AS digits_only
FROM (VALUES
  ('(613) 235-3301'),
  ('(684) 468-1078'),
  ('613-235-3301'),
  ('613.235.3301'),
  ('6132353301'),
  ('+1 (613) 235-3301'),
  ('271-72-1446'),
  ('298-78-3399'),
  ('08/16/1979'),
  ('01/08/1974'),
  ('1979-08-16'),
  ('Estelle Bergstrom')
) t(v);

SELECT '=== phone match strategies (web-ingest failure) ===' AS section;

SELECT
  strategy,
  catalog_key,
  other_key,
  catalog_key = other_key AS matches
FROM (
  SELECT
    'qnorm catalog vs tokenized 2-gram' AS strategy,
    qnorm('(613) 235-3301') AS catalog_key,
    qnorm('(613)') || ' ' || qnorm('235-3301') AS other_key
  UNION ALL
  SELECT
    'finetype_cast full string is identity?',
    '(613) 235-3301',
    finetype_cast('(613) 235-3301')
  UNION ALL
  SELECT
    'finetype_cast split pieces concat == cast full',
    finetype_cast('(613)') || finetype_cast('235-3301'),
    finetype_cast('(613) 235-3301')
  UNION ALL
  SELECT
    'digits_only (SQL regexp) catalog vs self',
    regexp_replace('(613) 235-3301', '[^0-9]+', '', 'g'),
    regexp_replace('(613) 235-3301', '[^0-9]+', '', 'g')
  UNION ALL
  SELECT
    'digits_only pieces concat',
    regexp_replace('(613)', '[^0-9]+', '', 'g')
      || regexp_replace('235-3301', '[^0-9]+', '', 'g'),
    regexp_replace('(613) 235-3301', '[^0-9]+', '', 'g')
  UNION ALL
  SELECT
    'DOB cast to ISO (useful side effect)',
    finetype_cast('08/16/1979'),
    '1979-08-16'
);

SELECT '=== verdict helpers ===' AS section;

SELECT
  finetype_cast('(613) 235-3301') = '(613) 235-3301' AS cast_leaves_paren_phone_unchanged,
  finetype_cast('08/16/1979') = '1979-08-16' AS cast_normalizes_mdy_dob,
  finetype_cast('271-72-1446') = '271-72-1446' AS cast_leaves_ssn_unchanged,
  -- the actual Closure match failure is NOT fixed by cast:
  qnorm('(613) 235-3301')
    <> (qnorm('(613)') || ' ' || qnorm('235-3301')) AS qnorm_still_mismatches_tokens,
  regexp_replace('(613)', '[^0-9]+', '', 'g')
    || regexp_replace('235-3301', '[^0-9]+', '', 'g')
    = regexp_replace('(613) 235-3301', '[^0-9]+', '', 'g') AS sql_digits_fix_match;
