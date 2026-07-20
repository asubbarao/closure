-- 02_ssn_dob.sql
-- Fit: SSN / DOB validation + canonicalization where multi-branch SQL is awkward.
-- Inputs from samples/identities.json + web-ingest fixture + deliberate invalids.
--
-- Run from repo root:
--   duckdb -unsigned -markdown :memory: < spikes/ext-quickjs/02_ssn_dob.sql

INSTALL quickjs FROM community;
LOAD quickjs;

CREATE OR REPLACE MACRO js_ssn(t) AS
  quickjs_eval('(s) => {
    const d = String(s).replace(/\D/g,"");
    if (d.length !== 9) return {ok:false, digits:d, pretty:null, reason:"len!=9"};
    const area = d.slice(0,3), group = d.slice(3,5), serial = d.slice(5);
    if (area === "000" || area === "666" || area[0] === "9")
      return {ok:false, digits:d, pretty:null, reason:"bad area"};
    if (group === "00") return {ok:false, digits:d, pretty:null, reason:"bad group"};
    if (serial === "0000") return {ok:false, digits:d, pretty:null, reason:"bad serial"};
    return {ok:true, digits:d, pretty: area+"-"+group+"-"+serial, reason:"ok"};
  }', cast(t AS VARCHAR));

CREATE OR REPLACE MACRO js_dob(t) AS
  quickjs_eval('(s) => {
    s = String(s).trim();
    let m, d, y;
    let mm = s.match(/^(\\d{1,2})\\/(\\d{1,2})\\/(\\d{4})$/);
    if (mm) { m = +mm[1]; d = +mm[2]; y = +mm[3]; }
    else {
      let iso = s.match(/^(\\d{4})-(\\d{2})-(\\d{2})$/);
      if (iso) { y = +iso[1]; m = +iso[2]; d = +iso[3]; }
      else {
        let mon = s.match(/^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\\s+(\\d{1,2}),?\\s+(\\d{4})$/i);
        if (!mon) return {ok:false, iso:null, reason:"unparsed"};
        const months = {jan:1,feb:2,mar:3,apr:4,may:5,jun:6,jul:7,aug:8,sep:9,oct:10,nov:11,dec:12};
        m = months[mon[1].slice(0,3).toLowerCase()]; d = +mon[2]; y = +mon[3];
      }
    }
    if (m < 1 || m > 12 || d < 1 || d > 31 || y < 1900 || y > 2100)
      return {ok:false, iso:null, reason:"range"};
    const dt = new Date(Date.UTC(y, m - 1, d));
    if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d)
      return {ok:false, iso:null, reason:"invalid calendar date"};
    const isoOut = y + "-" + String(m).padStart(2,"0") + "-" + String(d).padStart(2,"0");
    return {ok:true, iso: isoOut, reason:"ok"};
  }', cast(t AS VARCHAR));

-- SQL control: shape-only SSN (no area/group/serial rules) + try_strptime DOB.
CREATE OR REPLACE MACRO sql_ssn_shape(t) AS
  regexp_matches(cast(t AS VARCHAR), '^[0-9]{3}[-. ]?[0-9]{2}[-. ]?[0-9]{4}$');

CREATE OR REPLACE MACRO sql_dob_iso(t) AS
  coalesce(
    strftime(try_strptime(cast(t AS VARCHAR), '%m/%d/%Y'), '%Y-%m-%d'),
    strftime(try_strptime(cast(t AS VARCHAR), '%Y-%m-%d'), '%Y-%m-%d')
  );

SELECT '=== 1. SSN validation (identities + invalids) ===' AS section;

SELECT
  raw,
  sql_ssn_shape(raw) AS sql_shape_ok,
  js_ssn(raw) AS js_ssn
FROM (VALUES
  ('450-68-9632'),   -- identities case 24-001001
  ('450 68 9632'),   -- plant spaced
  ('450.68.9632'),   -- plant dotted
  ('271-72-1446'),   -- web-ingest fixture
  ('894-15-9291'),   -- identities case 24-001002
  ('000-12-3456'),   -- invalid area
  ('666-12-3456'),   -- invalid area
  ('900-12-3456'),   -- invalid area (ITIN-ish)
  ('123-00-4567'),   -- invalid group
  ('123-45-0000'),   -- invalid serial
  ('not-an-ssn')
) t(raw);

SELECT '=== 2. DOB multi-format + calendar validity ===' AS section;

SELECT
  raw,
  sql_dob_iso(raw) AS sql_try_iso,
  js_dob(raw) AS js_dob
FROM (VALUES
  ('08/16/1979'),    -- web-ingest fixture
  ('03/01/1973'),    -- identities 24-001001
  ('05/08/1963'),    -- identities 24-001002
  ('1973-03-01'),    -- ISO form (not in roster, realistic OCR)
  ('Aug 16, 1979'),  -- month-name (awkward pure SQL)
  ('02/30/2000'),    -- invalid calendar day
  ('13/01/1990'),    -- invalid month
  ('not a date')
) t(raw);

-- Cross-format SSN identity: all plants collapse to same digits key.
SELECT '=== 3. SSN digit-key collapse (match spaced/dotted plants) ===' AS section;

WITH forms AS (
  SELECT * FROM (VALUES
    ('dashed', '450-68-9632'),
    ('spaced', '450 68 9632'),
    ('dotted', '450.68.9632')
  ) v(form, raw)
)
SELECT
  f.form,
  f.raw,
  json_extract_string(js_ssn(f.raw), '$.digits') AS digits,
  json_extract_string(js_ssn(f.raw), '$.pretty') AS pretty,
  json_extract_string(js_ssn(f.raw), '$.digits')
    = json_extract_string(js_ssn('450-68-9632'), '$.digits') AS same_as_canonical
FROM forms f;

COPY (
  SELECT raw, cast(js_ssn(raw) AS VARCHAR) AS js_ssn
  FROM (VALUES
    ('450-68-9632'), ('450 68 9632'), ('271-72-1446'),
    ('000-12-3456'), ('not-an-ssn')
  ) t(raw)
) TO 'spikes/ext-quickjs/out/02_ssn.csv' (HEADER, DELIMITER ',');

COPY (
  SELECT raw, sql_dob_iso(raw) AS sql_iso, cast(js_dob(raw) AS VARCHAR) AS js_dob
  FROM (VALUES
    ('08/16/1979'), ('1973-03-01'), ('Aug 16, 1979'),
    ('02/30/2000'), ('not a date')
  ) t(raw)
) TO 'spikes/ext-quickjs/out/02_dob.csv' (HEADER, DELIMITER ',');

SELECT 'wrote spikes/ext-quickjs/out/02_ssn.csv and 02_dob.csv' AS note;
