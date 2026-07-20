-- 03_quickjs_residual.sql
-- SECONDARY: only claim quickjs where finetype_cast + SQL both fail.
-- Phone digit-strip is already one regexp_replace in SQL — if that is all we
-- need, quickjs is NOT residual value for Closure.
--
-- Run from repo root:
--   duckdb -unsigned -markdown < spikes/ext-finetype/03_quickjs_residual.sql

INSTALL quickjs FROM community;
LOAD quickjs;
INSTALL finetype FROM community;
LOAD finetype;

SELECT '=== quickjs surface ===' AS section;

SELECT function_name, parameters, parameter_types, return_type
FROM duckdb_functions()
WHERE function_name IN ('quickjs', 'quickjs_eval')
ORDER BY function_name, length(parameters::VARCHAR);

SELECT '=== phone normalize: JS vs SQL vs finetype_cast ===' AS section;

SELECT
  v,
  quickjs_eval('(s) => String(s).replace(/[^0-9]/g,"")', v) AS js_digits,
  regexp_replace(v, '[^0-9]+', '', 'g') AS sql_digits,
  finetype_cast(v) AS ft_cast
FROM (VALUES
  ('(613) 235-3301'),
  ('+1 (301) 204-0543'),
  ('271-72-1446')
) t(v);

SELECT '=== residual candidates? ===' AS section;

-- Something awkward in pure SQL: multi-pass person-name title strip + case fold
-- is still doable with regexp_replace. quickjs wins only if the transform is a
-- real library algorithm (libphonenumber metadata, complex address parse, etc.).
-- We do NOT load those libraries here — just show the eval pattern works.

SELECT quickjs_eval(
  '(s) => String(s).replace(/^(Det\\.|Ofc\\.|Sgt\\.|Dr\\.)\\s+/i, "").trim()',
  'Det. Nienow'
) AS strip_title_js;

SELECT regexp_replace('Det. Nienow', '(?i)^(Det\.|Ofc\.|Sgt\.|Dr\.)\s+', '') AS strip_title_sql;

SELECT * FROM (VALUES
  ('phone digit strip', 'SQL regexp_replace',
   'quickjs not needed; finetype_cast does not strip'),
  ('SSN digit strip', 'SQL regexp_replace',
   'same as phone'),
  ('DOB to ISO', 'finetype_cast',
   'real cast win; SQL can do it with strptime too'),
  ('libphonenumber-grade parse', 'neither in-repo',
   'quickjs could host a tiny JS port; out of take-home scope'),
  ('PERSON subject vs citation vs officer', 'app context SQL (judge.sql)',
   'finetype types formats; quickjs does not add context either')
) t(task, winner, note);
