-- 01_single_vs_column.sql
-- KEY QUESTION: does finetype COLUMN MODE fix single-value phone/SSN ISBN misfires?
-- Run from repo root:
--   duckdb -unsigned -markdown < spikes/ext-finetype/01_single_vs_column.sql
--
-- Primary surface for column accuracy is ft_profile('table') / finetype(list(v)).
-- Scalar finetype(v) is documented as weaker without column neighbours.

INSTALL finetype FROM community;
LOAD finetype;

-- ── tables under test ───────────────────────────────────────────────────────
CREATE OR REPLACE TABLE phones_paren AS
SELECT * FROM (VALUES
  -- identities.json subject + witness phones (paren US form)
  ('(684) 468-1078'),('(301) 204-0543'),('(355) 563-8372'),('(452) 576-8514'),
  ('(771) 808-2217'),('(616) 721-5823'),('(682) 733-5223'),('(406) 720-3750'),
  ('(345) 426-1402'),('(304) 806-6845'),('(555) 855-1614'),('(288) 376-8504'),
  -- web-ingest fixture phone (Magnolia Cronin sample path)
  ('(613) 235-3301')
) t(v);

CREATE OR REPLACE TABLE phones_dash AS
SELECT * FROM (VALUES
  ('684-468-1078'),('301-204-0543'),('355-563-8372'),('452-576-8514'),
  ('771-808-2217'),('616-721-5823'),('682-733-5223'),('406-720-3750')
) t(v);

CREATE OR REPLACE TABLE phones_uk AS
SELECT * FROM (VALUES
  ('+44 20 7946 0958'),('0117 496 0123'),('020 7946 0958'),('+44 117 496 0123')
) t(v);

CREATE OR REPLACE TABLE ssns_pure AS
SELECT * FROM (VALUES
  ('298-78-3399'),('491-69-6779'),('211-73-0681'),('234-04-2281'),
  ('271-72-1446'),('123-45-6789'),('987-65-4321')
) t(v);

CREATE OR REPLACE TABLE ssns_tiny AS
SELECT * FROM (VALUES ('298-78-3399'),('491-69-6779')) t(v);

CREATE OR REPLACE TABLE dobs_pure AS
SELECT * FROM (VALUES
  ('01/08/1974'),('11/03/1984'),('10/11/1986'),('02/28/1983'),
  ('08/16/1979'),('12/25/1990'),('03/15/2001')
) t(v);

CREATE OR REPLACE TABLE names_ctx AS
SELECT * FROM (VALUES
  ('Estelle Bergstrom'),('Sherwood Runolfsson'),('Darrel Waters'),('Yolanda Torp'),
  ('Magnolia Cronin'),('Yasmine Nienow'),
  -- context traps: officer / citation / street — still name-shaped tokens
  ('Det. Nienow'),('Nienow v. Ohio'),('Ofc. Smith'),('Cronin Street')
) t(v);

CREATE OR REPLACE TABLE addrs_pure AS
SELECT * FROM (VALUES
  ('4199 Maple St, Portland, OR 97205'),
  ('3947 Oakwood Dr, Salem, OR 97301'),
  ('5717 Industrial Blvd, Eugene, OR 97401'),
  ('9622 River Rd, Bend, OR 97701')
) t(v);

CREATE OR REPLACE TABLE decoys AS
SELECT * FROM (VALUES
  ('978-0-306-40615-7'),  -- real ISBN
  ('not a phone'),
  ('42'),
  ('State v. Waters'),
  ('ABC-12-3456')
) t(v);

-- ── A. single-value isolation (the known misfires) ──────────────────────────
SELECT '=== A. single-value isolation ===' AS section;

SELECT v, finetype(v) AS type, finetype_detail(v) AS detail
FROM (VALUES
  ('(613) 235-3301'),
  ('271-72-1446'),
  ('08/16/1979'),
  ('298-78-3399'),
  ('(684) 468-1078'),
  ('Estelle Bergstrom'),
  ('4199 Maple St, Portland, OR 97205'),
  ('user@example.com'),
  ('192.168.1.1')
) t(v);

-- ── B. column mode via ft_profile (authoritative) ───────────────────────────
SELECT '=== B. ft_profile column mode ===' AS section;

SELECT 'phones_paren' AS tbl, * FROM ft_profile('phones_paren')
UNION ALL BY NAME SELECT 'phones_dash',  * FROM ft_profile('phones_dash')
UNION ALL BY NAME SELECT 'phones_uk',    * FROM ft_profile('phones_uk')
UNION ALL BY NAME SELECT 'ssns_pure',    * FROM ft_profile('ssns_pure')
UNION ALL BY NAME SELECT 'ssns_tiny',    * FROM ft_profile('ssns_tiny')
UNION ALL BY NAME SELECT 'dobs_pure',    * FROM ft_profile('dobs_pure')
UNION ALL BY NAME SELECT 'names_ctx',    * FROM ft_profile('names_ctx')
UNION ALL BY NAME SELECT 'addrs_pure',   * FROM ft_profile('addrs_pure')
UNION ALL BY NAME SELECT 'decoys',       * FROM ft_profile('decoys');

-- ── C. list-form finetype_detail (same distribution idea) ───────────────────
SELECT '=== C. finetype_detail(list) ===' AS section;

SELECT 'phones_paren' AS col, finetype_detail(list(v)) AS detail FROM phones_paren
UNION ALL SELECT 'ssns_pure',  finetype_detail(list(v)) FROM ssns_pure
UNION ALL SELECT 'ssns_tiny',  finetype_detail(list(v)) FROM ssns_tiny
UNION ALL SELECT 'dobs_pure',  finetype_detail(list(v)) FROM dobs_pure
UNION ALL SELECT 'names_ctx',  finetype_detail(list(v)) FROM names_ctx;

-- ── D. domain / header hints (cheat codes — not free detection) ─────────────
SELECT '=== D. domain hints (not free detection) ===' AS section;

SELECT finetype(list(v), 'phone') AS phones_hinted,
       finetype_detail(list(v), 'phone') AS detail
FROM phones_paren;

SELECT finetype(list(v), 'ssn') AS ssns_hinted,
       finetype_detail(list(v), 'ssn') AS detail
FROM ssns_tiny;  -- tiny col fails free profile; hint rescues

-- ── E. context failure: names that are NOT subject PII ──────────────────────
SELECT '=== E. names are formats, not context ===' AS section;

SELECT v,
       finetype(v) AS single_type,
       json_extract(finetype_detail(v), '$.confidence') AS conf
FROM names_ctx
ORDER BY v;

-- ── F. accuracy scorecard (column mode) ─────────────────────────────────────
SELECT '=== F. column-mode accuracy scorecard ===' AS section;

SELECT * FROM (
  SELECT 'PHONE US paren' AS scenario,
         'identity.person.phone_number' AS want,
         (SELECT type FROM ft_profile('phones_paren')) AS got,
         (SELECT confidence FROM ft_profile('phones_paren')) AS conf,
         (SELECT type FROM ft_profile('phones_paren'))
           = 'identity.person.phone_number' AS ok
  UNION ALL
  SELECT 'PHONE US dash', 'identity.person.phone_number',
         (SELECT type FROM ft_profile('phones_dash')),
         (SELECT confidence FROM ft_profile('phones_dash')),
         (SELECT type FROM ft_profile('phones_dash'))
           = 'identity.person.phone_number'
  UNION ALL
  SELECT 'PHONE UK-ish', 'identity.person.phone_number',
         (SELECT type FROM ft_profile('phones_uk')),
         (SELECT confidence FROM ft_profile('phones_uk')),
         (SELECT type FROM ft_profile('phones_uk'))
           = 'identity.person.phone_number'
  UNION ALL
  SELECT 'SSN pure n=7', 'identity.government.ssn',
         (SELECT type FROM ft_profile('ssns_pure')),
         (SELECT confidence FROM ft_profile('ssns_pure')),
         (SELECT type FROM ft_profile('ssns_pure'))
           = 'identity.government.ssn'
  UNION ALL
  SELECT 'SSN tiny n=2', 'identity.government.ssn',
         (SELECT type FROM ft_profile('ssns_tiny')),
         (SELECT confidence FROM ft_profile('ssns_tiny')),
         (SELECT type FROM ft_profile('ssns_tiny'))
           = 'identity.government.ssn'
  UNION ALL
  SELECT 'DOB mdy slash', 'datetime.date.mdy_slash',
         (SELECT type FROM ft_profile('dobs_pure')),
         (SELECT confidence FROM ft_profile('dobs_pure')),
         (SELECT type FROM ft_profile('dobs_pure'))
           = 'datetime.date.mdy_slash'
  UNION ALL
  SELECT 'ADDRESS full', 'geography.address.full_address',
         (SELECT type FROM ft_profile('addrs_pure')),
         (SELECT confidence FROM ft_profile('addrs_pure')),
         (SELECT type FROM ft_profile('addrs_pure'))
           = 'geography.address.full_address'
  UNION ALL
  SELECT 'PERSON names (format only)', 'identity.person.full_name',
         (SELECT type FROM ft_profile('names_ctx')),
         (SELECT confidence FROM ft_profile('names_ctx')),
         (SELECT type FROM ft_profile('names_ctx'))
           = 'identity.person.full_name'
);

-- ── G. app regex vs finetype ────────────────────────────────────────────────
-- IMPORTANT: scalar finetype(v) over a pure phone/ssn TABLE still rides column
-- distribution (samples > 1 in detail). True single-value = literal only.
SELECT '=== G. app regexp accuracy (always 100% on these shapes) ===' AS section;

WITH vals AS (
  SELECT 'PHONE' AS expected, v FROM phones_paren
  UNION ALL SELECT 'SSN', v FROM ssns_pure
  UNION ALL SELECT 'DOB', v FROM dobs_pure
)
SELECT expected,
       count(*) AS n,
       count(*) FILTER (
         WHERE CASE expected
           WHEN 'PHONE' THEN regexp_matches(v, '^\([0-9]{3}\)\s*[0-9]{3}-[0-9]{4}$')
                        OR regexp_matches(v, '^[0-9]{3}[.-][0-9]{3}[.-][0-9]{4}$')
           WHEN 'SSN'   THEN regexp_matches(v, '^[0-9]{3}[-.][0-9]{2}[-.][0-9]{4}$')
           WHEN 'DOB'   THEN regexp_matches(v, '^[0-9]{2}/[0-9]{2}/[0-9]{4}$')
         END
       ) AS regex_hits
FROM vals
GROUP BY expected
ORDER BY expected;

SELECT '=== G2. isolated literals (true single-value; no column) ===' AS section;
SELECT 'isolated_literal' AS mode,
       finetype('(613) 235-3301') AS phone,
       finetype('271-72-1446') AS ssn,
       finetype('08/16/1979') AS dob;

SELECT '=== G3. ft_profile vs finetype(list) agreement ===' AS section;
SELECT 'ssns_pure' AS col,
       (SELECT type FROM ft_profile('ssns_pure')) AS profile_type,
       finetype(list(v)) AS list_type
FROM ssns_pure
UNION ALL
SELECT 'phones_paren',
       (SELECT type FROM ft_profile('phones_paren')),
       finetype(list(v))
FROM phones_paren;
