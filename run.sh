#!/usr/bin/env bash
# boot Closure on the REAL quackapi extension (not the brain/SQL prototype).
#
# Stack: DuckDB + LOAD quackapi → CREATE ROUTE … → quackapi_serve(port)
# Tera renders HTML; pdf extension supplies word/coords; suggestions stay empty.
#
# Why a sequential stdin session (not one giant `duckdb -c "LOAD; CREATE ROUTE"`):
#   Parser-extension DDL (CREATE ROUTE) is registered at LOAD time. Feeding all
#   statements in one -c string can parse CREATE ROUTE before LOAD runs. A
#   sequential interactive/FIFO session (stdin heredoc) LOADs first, then
#   parses route DDL.
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(pwd)"
PORT="${PORT:-8117}"
DATA_DIR="${DATA_DIR:-samples}"
DB="${DB:-closure.db}"

# Real quackapi binary (v1.5.4) + built extension. System/homebrew duckdb may
# load the .duckdb_extension table functions but will not activate CREATE ROUTE
# unless it is the quackapi-built shell (parser extension registration).
DUCKDB_BIN="${DUCKDB_BIN:-/Users/aloksubbarao/personal/quackapi/build/release/duckdb}"
QUACKAPI_EXT="${QUACKAPI_EXT:-/Users/aloksubbarao/personal/quackapi/build/release/extension/quackapi/quackapi.duckdb_extension}"

if [[ ! -x "$DUCKDB_BIN" ]]; then
  echo "error: duckdb binary not found at $DUCKDB_BIN" >&2
  echo "  build quackapi (GEN=ninja make release) or set DUCKDB_BIN" >&2
  exit 1
fi
if [[ ! -f "$QUACKAPI_EXT" ]]; then
  echo "error: quackapi extension not found at $QUACKAPI_EXT" >&2
  exit 1
fi
if [[ ! -d "$DATA_DIR" ]]; then
  echo "error: data dir missing: $DATA_DIR" >&2
  exit 1
fi

mkdir -p exports static
: >> exports/audit_sidecar.jsonl

# Fresh DB each boot — ingest is the source of truth.
rm -f "$DB" "${DB}.wal"

echo "==> duckdb $($DUCKDB_BIN --version 2>/dev/null | head -1)"
echo "==> quackapi_ext=$QUACKAPI_EXT"
echo "==> data_dir=$DATA_DIR  port=$PORT  db=$DB"
echo "==> pages dir: $( [[ -d pages ]] && echo pages/ || echo '(none — word boxes only)' )"

export DATA_DIR CLOSURE_DB="$ROOT/$DB" DUCKDB_BIN

# ── Phase 1: schema + ingest + templates + routes (no serve yet) ───────────
# Sequential heredoc so LOAD registers the parser extension before CREATE ROUTE.
"$DUCKDB_BIN" -unsigned "$DB" <<SQL
INSTALL pdf FROM community;
LOAD pdf;
INSTALL tera FROM community;
LOAD tera;
INSTALL shellfs FROM community;
LOAD shellfs;
-- REAL quackapi extension (not brain_thing / serve_brain / framework.sql).
LOAD '${QUACKAPI_EXT}';

SET memory_limit = '4GB';
SET threads = 4;
SET preserve_insertion_order = false;
SET VARIABLE data_dir = '${DATA_DIR}';

.print '==> schema (suggestions table empty by design this pass)'
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

.print '==> templates'
.read server/load_templates.sql

.print '==> ingest (real PDFs + identities + manifest; suggestions stay empty)'
.read server/ingest.sql

.print '==> per-PDF extraction counts'
SELECT d.filename, d.page_count, count(w.word) AS words
FROM documents d
LEFT JOIN words w ON w.document_id = d.id
GROUP BY d.filename, d.page_count
ORDER BY d.filename;

.print '==> static render (dev fallback under static/)'
.read server/render_static.sql

.print '==> CREATE ROUTE (real quackapi DDL)'
.read server/routes.sql

.print '==> prove real extension: quackapi_routes()'
SELECT name, method, pattern, status FROM quackapi_routes() ORDER BY name;
SQL

# ── Phase 2: identity-copy export (bash; no shellfs, no lock fight) ────────
echo "==> identity-copy export (suggestions empty → byte-copy is correct)"
if [[ -f exports/export_map.csv ]]; then
  cut -d, -f1 exports/export_map.csv | grep -v case_id | sort -u | while read -r cid; do
    bash server/export_case.sh "$cid" || true
  done
else
  echo "  (no export_map.csv — skip)"
fi

# ── Phase 3: serve (same DB file; routes already registered in-process…) ───
# Route registry is in-process, not durable — re-LOAD + re-.read routes, then serve.
echo "==> serve on :${PORT}"
exec "$DUCKDB_BIN" -unsigned "$DB" <<SQL
INSTALL pdf FROM community;
LOAD pdf;
INSTALL tera FROM community;
LOAD tera;
INSTALL shellfs FROM community;
LOAD shellfs;
LOAD '${QUACKAPI_EXT}';

SET memory_limit = '4GB';
SET threads = 4;
SET preserve_insertion_order = false;

-- Re-attach views that are not in the file as permanent objects if needed.
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

-- Templates + routes are not durable across process restart — reload.
.read server/load_templates.sql
.read server/routes.sql

SELECT name, method, pattern, status FROM quackapi_routes() ORDER BY name;

SELECT * FROM quackapi_serve(${PORT}, host := '127.0.0.1', static_dir := '.');

.print '==> prove real extension: quackapi_servers()'
SELECT * FROM quackapi_servers();

SELECT 'Closure ready at http://127.0.0.1:${PORT}/ — Ctrl-C to stop' AS status;
SELECT 'suggestions empty (seed deferred); real words/entities/audit live' AS note;
SELECT sleep_ms(86400000);
SQL
