-- 00_setup.sql
-- Install + LOAD quickjs (community, signed build on DuckDB ≥ 1.5.3 osx_arm64).
-- Run from repo root:
--   duckdb -unsigned -markdown -c "INSTALL quickjs FROM community; LOAD quickjs; SELECT 1;"
-- Or pipe this file:
--   duckdb -unsigned -markdown :memory: < spikes/ext-quickjs/00_setup.sql

INSTALL quickjs FROM community;
LOAD quickjs;

-- Surface inventory (parameter lists from catalog; args are effectively variadic for eval).
SELECT function_name, function_type, return_type, description
FROM duckdb_functions()
WHERE function_name ILIKE '%quickjs%'
ORDER BY function_name, function_type;

-- Smoke: scalar expression → VARCHAR; eval → JSON; table form → rows from JS array.
SELECT quickjs('2+2') AS scalar_expr;
SELECT quickjs_eval('(a, b) => a + b', 5, 3) AS eval_sum;
SELECT * FROM quickjs('[{n:1},{n:2},{n:3}]');
