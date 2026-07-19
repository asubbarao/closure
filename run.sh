#!/usr/bin/env bash
# boot Closure: schema → ingest → static render → quackapi on :8117
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(pwd)"
PORT="${PORT:-8117}"
DATA_DIR="${DATA_DIR:-samples}"
DB="${DB:-closure.db}"

# quackapi CREATE ROUTE is a parser extension — must use the duckdb binary
# built alongside quackapi (not a plain homebrew shell).
DUCKDB_BIN="${DUCKDB_BIN:-/Users/aloksubbarao/personal/quackapi/build/release/duckdb}"
QUACKAPI_EXT="${QUACKAPI_EXT:-/Users/aloksubbarao/personal/quackapi/build/release/extension/quackapi/quackapi.duckdb_extension}"

if [[ ! -x "$DUCKDB_BIN" ]]; then
  echo "error: duckdb binary not found at $DUCKDB_BIN" >&2
  exit 1
fi
if [[ ! -f "$QUACKAPI_EXT" ]]; then
  echo "error: quackapi extension not found at $QUACKAPI_EXT" >&2
  exit 1
fi

mkdir -p exports static

# Fresh DB each boot so ingest stays the source of truth.
rm -f "$DB"

echo "==> duckdb $($DUCKDB_BIN --version 2>/dev/null | head -1)"
echo "==> data_dir=$DATA_DIR  port=$PORT  db=$DB"

# Symlink page PNGs for static review pages (optional, already under web/pages)
mkdir -p static/pages
if [[ -d web/pages ]]; then
  # relative links from /static/pages/<doc>/pN.png → ../../web/pages/...
  # For the live server we serve files from the repo root via quackapi static
  # if available; otherwise the word-box layer alone is enough.
  :
fi

export DATA_DIR
export CLOSURE_DB="$ROOT/$DB"
export DUCKDB_BIN="$DUCKDB_BIN"

# One session: load extensions, schema, ingest, routes, static render, serve.
# -unsigned: local quackapi build is unsigned; community pdf is signed but
#            -unsigned is required for the local .duckdb_extension path.
exec "$DUCKDB_BIN" -unsigned "$DB" <<SQL
INSTALL pdf FROM community;
LOAD pdf;
INSTALL tera FROM community;
LOAD tera;
INSTALL shellfs FROM community;
LOAD shellfs;
LOAD '${QUACKAPI_EXT}';

SET VARIABLE data_dir = '${DATA_DIR}';

.print '==> schema'
.read server/schema.sql

-- Sidecar file for POST mutation audit (JSONL; no lock conflict with closure.db).
CREATE OR REPLACE VIEW v_audit AS
SELECT id, ts, actor, action, suggestion_id, case_id, target, reason, 'main' AS source
FROM audit_events
UNION ALL BY NAME
SELECT
    try_cast(json_extract_string(j.json, '$.id') AS INTEGER) AS id,
    try_cast(json_extract_string(j.json, '$.ts') AS TIMESTAMP) AS ts,
    json_extract_string(j.json, '$.actor') AS actor,
    json_extract_string(j.json, '$.action') AS action,
    NULL::INTEGER AS suggestion_id,
    try_cast(json_extract_string(j.json, '$.case_id') AS INTEGER) AS case_id,
    json_extract_string(j.json, '$.target') AS target,
    NULL::VARCHAR AS reason,
    'sidecar' AS source
FROM read_json_objects('exports/audit_sidecar.jsonl') j;

.print '==> templates'
.read server/load_templates.sql

.print '==> ingest'
.read server/ingest.sql

.print '==> per-PDF extraction counts'
SELECT d.filename, d.page_count, count(w.word) AS words
FROM documents d
LEFT JOIN words w ON w.document_id = d.id
GROUP BY d.filename, d.page_count
ORDER BY d.filename;

.print '==> static render (dev fallback)'
.read server/render_static.sql

.print '==> routes'
.read server/routes.sql

SELECT * FROM quackapi_routes();

.print ''
.print 'Closure listening — open http://127.0.0.1:${PORT}/'
.print '  static fallback: static/index.html  static/case_1.html  static/document_1_p1.html'
.print '  api: GET /api/stats'
.print ''

SELECT * FROM quackapi_serve(${PORT}, host := '127.0.0.1');

-- Keep the process alive: quackapi_serve returns after spawning listener threads,
-- so without a wait the CLI would exit and tear the server down.
SELECT 'Closure ready at http://127.0.0.1:${PORT}/ — Ctrl-C to stop' AS status;
SELECT sleep_ms(86400000);  -- 24h
SQL
