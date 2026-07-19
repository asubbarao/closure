-- app.sql — alternate single-file entrypoint (same stack as run.sh).
-- Prefer ./run.sh: it uses a sequential heredoc session so CREATE ROUTE
-- parses after LOAD (parser-extension timing).
--
-- Usage from repo root (sequential -c flags, LOAD first):
--   DUCKDB=/Users/aloksubbarao/personal/quackapi/build/release/duckdb
--   EXT=/Users/aloksubbarao/personal/quackapi/build/release/extension/quackapi/quackapi.duckdb_extension
--   $DUCKDB -unsigned closure.db \
--     -c "INSTALL pdf FROM community; LOAD pdf; INSTALL tera FROM community; LOAD tera; INSTALL shellfs FROM community; LOAD shellfs; LOAD '$EXT';" \
--     -c ".read server/app.sql"
--
-- HARD RULE this pass: no seed.sql — suggestions stay empty.

SET VARIABLE data_dir = coalesce(getvariable('data_dir'), 'samples');

.read server/schema.sql

CREATE OR REPLACE VIEW v_audit AS
SELECT id, ts, actor, action, suggestion_id, case_id, target, reason, 'main' AS source
FROM audit_events
UNION ALL BY NAME
SELECT
    try_cast(json_extract_string(j.json, '$.id') AS INTEGER) AS id,
    try_cast(json_extract_string(j.json, '$.ts') AS TIMESTAMP) AS ts,
    json_extract_string(j.json, '$.actor') AS actor,
    json_extract_string(j.json, '$.action') AS action,
    try_cast(json_extract_string(j.json, '$.suggestion_id') AS INTEGER) AS suggestion_id,
    try_cast(json_extract_string(j.json, '$.case_id') AS INTEGER) AS case_id,
    json_extract_string(j.json, '$.target') AS target,
    json_extract_string(j.json, '$.reason') AS reason,
    'sidecar' AS source
FROM read_json_objects('exports/audit_sidecar.jsonl', filename := true) j
WHERE j.json IS NOT NULL;

.read server/load_templates.sql
.read server/ingest.sql
.read server/render_static.sql
.read server/routes.sql

SELECT 'boot summary' AS phase,
       (SELECT count(*) FROM cases) AS cases,
       (SELECT count(*) FROM documents) AS documents,
       (SELECT count(*) FROM words) AS words,
       (SELECT count(*) FROM entities) AS entities,
       (SELECT count(*) FROM suggestions) AS suggestions;

SELECT name, method, pattern FROM quackapi_routes() ORDER BY name;

FROM quackapi_serve(8117, host := '127.0.0.1', static_dir := '.');
SELECT * FROM quackapi_servers();
SELECT 'Closure ready at http://127.0.0.1:8117/ — Ctrl-C to stop' AS status;
SELECT sleep_ms(86400000);
