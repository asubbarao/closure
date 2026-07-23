-- check.sql — SQL invariants as DATA, run by dqtest over the built model.
--
-- Why this exists: server/smoke.sql used to hand-roll each invariant as a
-- CASE WHEN (SELECT …) THEN error(…) block in the boot path — the assertion and
-- its message repeated the same subquery, and the whole thing lived in the serve
-- SQL. It could only ask "is this table non-empty", which is exactly the check
-- that cannot see a dead detector arm: a UNION arm matching nothing still leaves
-- its table non-empty. See docs/DETECTION.md for the metaphone bug that slipped
-- through for the life of the repo.
--
-- The fix is structural, not cosmetic:
--   1. server/build.sql is the model — no HTTP — so we can assert on it without
--      booting a server (this file just .read's it, same as app.sql does).
--   2. tests/dq_tests.json is the suite as DATA (same posture as
--      detector_rules.json). Each invariant is a row, not a CASE arm.
--   3. dqtest runs them; the gate is ONE relational error() over the failures,
--      not a per-check CASE ladder.
--
-- Run:  make check   (duckdb :memory: -c ".read tests/check.sql")

.read server/build.sql

INSTALL dqtest FROM community; LOAD dqtest;
CALL dq_init();

-- Definitions are a relation. test_params is the VARCHAR column dqtest wants;
-- read the JSON objects straight into it (forced VARCHAR serializes them back).
INSERT INTO dq_tests (test_name, table_name, column_name, test_type, test_params, description)
SELECT test_name, table_name, column_name, test_type, test_params, description
FROM read_json_auto('tests/dq_tests.json',
     columns := {test_name:   'VARCHAR', table_name: 'VARCHAR', column_name: 'VARCHAR',
                 test_type:    'VARCHAR', test_params:'VARCHAR', description: 'VARCHAR'});

CREATE OR REPLACE TEMP TABLE check_results AS FROM dq_run_tests();

-- Full board first (pass and fail), so a run shows every invariant it enforced.
SELECT test_name, status, rows_failed, rows_total
FROM check_results ORDER BY status, test_name;

-- Gate: a relation of failures with error() applied per row. Empty ⇒ nothing
-- raised; one failing invariant ⇒ the process aborts non-zero with its name.
SELECT error(format('check FAILED: {} ({} offending row(s)) — {}',
             test_name, rows_failed, coalesce(error_message, compiled_sql)))
FROM check_results WHERE status = 'fail';

SELECT format('check: {} invariants passed', count(*)) AS check_ok
FROM check_results;
