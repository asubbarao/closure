#!/usr/bin/env bash
# boot Closure on the REAL quackapi extension via the canonical composition
# root, server/app.sql (see that file's header for the documented boot
# command). This wrapper only resolves env/paths, resets the DB, and
# preloads the quackapi extension before handing off — all schema/ingest/
# template/route/serve ordering lives in server/app.sql itself.
#
# Prior versions of this script hand-rolled the boot sequence (schema →
# templates → ingest → routes) instead of delegating to app.sql. That order
# was wrong (ingest.sql DROPs+recreates app_templates, so templates must load
# AFTER ingest, not before) and it skipped modules app.sql wires in (seed,
# judge, remainder_scan, provenance, pdf_store, and the triage/history/
# remainder/judge/provenance/geo/store/export routes) — so several routes
# 404'd and suggestions never got seeded. Delegating to app.sql fixes both.
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8117}"
DATA_DIR="${DATA_DIR:-samples}"
DB="${DB:-closure.db}"

# Real quackapi binary (v1.5.4) + built extension. System/homebrew duckdb may
# load the .duckdb_extension table functions but will not activate CREATE ROUTE
# unless it is the quackapi-built shell (parser extension registration).
# Default layout: quackapi checked out as a SIBLING of this repo; override
# with QUACKAPI_ROOT (or DUCKDB_BIN / QUACKAPI_EXT individually).
REPO_ROOT="$(pwd)"
QUACKAPI_ROOT="${QUACKAPI_ROOT:-$(dirname "$REPO_ROOT")/quackapi}"
DUCKDB_BIN="${DUCKDB_BIN:-$QUACKAPI_ROOT/build/release/duckdb}"
QUACKAPI_EXT="${QUACKAPI_EXT:-$QUACKAPI_ROOT/build/release/extension/quackapi/quackapi.duckdb_extension}"

if [[ ! -x "$DUCKDB_BIN" ]]; then
  echo "error: duckdb binary not found at $DUCKDB_BIN" >&2
  echo "  build quackapi (GEN=ninja make release) or set QUACKAPI_ROOT / DUCKDB_BIN" >&2
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

# app.sql COPYs a decision-log sentinel into exports/decisions/ at boot and
# expects static_dir/exports_dir to exist; ensure both up front.
mkdir -p exports/decisions static

# Fresh DB each boot — ingest is the source of truth.
rm -f "$DB" "${DB}.wal"

echo "==> duckdb $($DUCKDB_BIN --version 2>/dev/null | head -1)"
echo "==> quackapi_ext=$QUACKAPI_EXT"
echo "==> data_dir=$DATA_DIR  port=$PORT  db=$DB"
echo "==> pages dir: $( [[ -d pages ]] && echo pages/ || echo '(none — word boxes only)' )"

# Map this script's knobs onto app_config's CLOSURE_* env overrides
# (server/config.sql); defaults already match (port 8117, samples_dir samples).
export CLOSURE_PORT="$PORT"
export CLOSURE_SAMPLES_DIR="$DATA_DIR"
export CLOSURE_QUACKAPI_EXT="$QUACKAPI_EXT"

echo "==> boot + serve via server/app.sql"
exec "$DUCKDB_BIN" -unsigned "$DB" -cmd "LOAD '${QUACKAPI_EXT}';" -c ".read server/app.sql"
