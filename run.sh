#!/usr/bin/env bash
# boot Closure on the REAL quackapi extension via the canonical composition
# root, server/app.sql. This wrapper only resolves the runtime, resets the DB,
# and preloads the extension before handing off.
#
# First-time clone (no local quackapi build required):
#   ./scripts/install-runtime.sh && make setup && make run
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8117}"
DATA_DIR="${DATA_DIR:-samples}"
DB="${DB:-closure.db}"

# Resolve DUCKDB_BIN + QUACKAPI_EXT: env → .deps/runtime → sibling checkout.
RT="$PWD/.deps/runtime"; SIB="$(dirname "$PWD")/quackapi/build/release"
DUCKDB_BIN="${DUCKDB_BIN:-$RT/duckdb}"
[[ -x "$DUCKDB_BIN" ]] || DUCKDB_BIN="$SIB/duckdb"
QUACKAPI_EXT="${QUACKAPI_EXT:-${CLOSURE_QUACKAPI_EXT:-$RT/quackapi.duckdb_extension}}"
[[ -f "$QUACKAPI_EXT" ]] || QUACKAPI_EXT="$SIB/extension/quackapi/quackapi.duckdb_extension"
[[ -x "$DUCKDB_BIN" && -f "$QUACKAPI_EXT" ]] || {
  echo "error: runtime missing — run ./scripts/install-runtime.sh" >&2; exit 1
}

if [[ ! -d "$DATA_DIR" ]]; then
  echo "error: data dir missing: $DATA_DIR" >&2
  echo "  run: make setup   (or ./scripts/setup.sh)" >&2
  exit 1
fi

# app.sql expects static_dir/exports_dir to exist; ensure both up front.
# (The decision log lives in closure.db and is never wiped — see below.)
mkdir -p exports static

# Exactly one server per port: kill any previous instance still bound to
# $PORT before wiping the DB. Without this the old process keeps serving the
# deleted inode and the new boot can't bind — two servers fighting over
# closure.db was a real observed failure mode.
OLD_PIDS="$(lsof -t -i tcp:"$PORT" -s tcp:LISTEN 2>/dev/null || true)"
if [[ -n "$OLD_PIDS" ]]; then
  echo "==> stopping previous server on :$PORT (pid $OLD_PIDS)"
  kill $OLD_PIDS 2>/dev/null || true
  for i in $(seq 1 20); do
    lsof -t -i tcp:"$PORT" -s tcp:LISTEN >/dev/null 2>&1 || break
    sleep 0.25
  done
fi

# The DB is NOT wiped here. Decisions live in it and are the evidentiary
# record; corpus tables are rebuilt in place by the model (see server/store.sql).
# To start over: make clean.

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
