-- routes/export.sql — case export plan + live redact at request time.
--
-- Purpose: thin HTTP controllers over server/pdf_io.sql macros.
-- Dependencies: pdf_io (export_case_exec, build_export_sql, run_sql).
--
-- P0-2: boxes built LIVE via build_export_sql / export_plan. Execution uses
--       run_sql(sql) with a foldable SQL string parameter — DuckDB forbids
--       subqueries inside query()/pdf_redact (no run_sql(build_export_sql(cid))).
-- P0-3: when flagged remain, NO pdf_redact. DuckDB eagerly evaluates uncorrelated
--       run_sql() even under CASE/UNION/WHERE on table-derived flags. The only
--       proven short-circuit is a foldable boolean constant on WHERE is_blocked.
--       Callers pass plan.blocked (DEFAULT true = fail-closed). Dashboard does
--       GET export_plan then POST with {sql, blocked} from the plan.
--
-- Boot-baked export_sql_case_N() macros are RETIRED (see _export_macros.sql).

-- Live export. `sql` and `is_blocked` must be foldable (route params).
CREATE OR REPLACE MACRO export_case_live(cid, sql, is_blocked, act) AS TABLE
WITH
flagged AS (
    SELECT count(*)::INTEGER AS n
    FROM v_suggestions s
    JOIN documents d ON d.id = s.document_id
    WHERE d.case_id = cid AND s.band = 'flagged' AND s.status = 'pending'
)
-- Foldable short-circuit: when is_blocked is the constant true, the UNION
-- arm with run_sql is not executed (no pdf_redact side effects).
SELECT
    0 AS exported,
    true AS blocked,
    (SELECT n FROM flagged) AS flagged_remaining
WHERE is_blocked

UNION ALL BY NAME

SELECT
    (SELECT count(*)::INTEGER FROM run_sql(sql)) AS exported,
    false AS blocked,
    0 AS flagged_remaining
WHERE NOT is_blocked;

CREATE OR REPLACE ROUTE api_case_export_plan GET '/api/cases/:id/export_plan' AS
SELECT
    CASE WHEN blocked THEN 0 ELSE exported END AS exported,
    blocked,
    flagged_remaining,
    export_sql
FROM export_case_exec($id::INTEGER, 'planner');

-- Primary export. Pass body/query: sql=<export_plan.export_sql>, blocked=<plan.blocked>.
-- DEFAULT blocked=true is fail-closed (never redact without an explicit clear plan).
CREATE OR REPLACE ROUTE api_case_export POST '/api/cases/:id/export'
  PARAM sql VARCHAR DEFAULT 'SELECT 0 AS document_id, 0 AS pages WHERE false'
  PARAM blocked BOOLEAN DEFAULT true
  PARAM actor VARCHAR DEFAULT 'reviewer'
AS
SELECT exported, blocked, flagged_remaining
FROM export_case_live($id::INTEGER, $sql::VARCHAR, $blocked::BOOLEAN, $actor::VARCHAR);

-- Dynamic re-run of server-built plan SQL (same foldable $sql constraint).
CREATE OR REPLACE ROUTE api_case_export_run POST '/api/cases/:id/export/run'
  PARAM sql VARCHAR
AS
SELECT * FROM run_sql($sql::VARCHAR);
