#!/usr/bin/env bash
# boot Closure: stock DuckDB + community extensions (INSTALL quackapi FROM community).
#   make setup && make run
# LE case pack (optional): CLOSURE_SAMPLE_ZIP=/path/to/pack.zip make run
#   → app.sql sets sample_zip_path; ops can .read server/zip_pin.sql in-session
#   or: duckdb closure.db -c "SET VARIABLE sample_zip_path='…'; .read server/zip_pin.sql"
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8117}"
DATA_DIR="${DATA_DIR:-samples}"
DB="${DB:-closure.db}"
DUCKDB_BIN="${DUCKDB_BIN:-$(command -v duckdb || true)}"

[[ -n "${DUCKDB_BIN}" && -x "$DUCKDB_BIN" ]] || {
  echo "error: duckdb not on PATH (need ≥1.5.4 for community quackapi)" >&2
  echo "  https://duckdb.org/docs/installation/" >&2
  echo "  override: DUCKDB_BIN=/path/to/duckdb ./run.sh" >&2
  exit 1
}

if [[ ! -d "$DATA_DIR" ]]; then
  echo "error: data dir missing: $DATA_DIR" >&2
  echo "  run: make setup" >&2
  exit 1
fi

mkdir -p exports static

OLD_PIDS="$(lsof -t -i tcp:"$PORT" -s tcp:LISTEN 2>/dev/null || true)"
if [[ -n "$OLD_PIDS" ]]; then
  echo "==> stopping previous server on :$PORT (pid $OLD_PIDS)"
  kill $OLD_PIDS 2>/dev/null || true
  for i in $(seq 1 20); do
    lsof -t -i tcp:"$PORT" -s tcp:LISTEN >/dev/null 2>&1 || break
    sleep 0.25
  done
fi

echo "==> duckdb $($DUCKDB_BIN --version 2>/dev/null | head -1)"
echo "==> data_dir=$DATA_DIR  port=$PORT  db=$DB"
[[ -n "${CLOSURE_SAMPLE_ZIP:-}" ]] && echo "==> CLOSURE_SAMPLE_ZIP=$CLOSURE_SAMPLE_ZIP (host path; zipfs pin via server/zip_pin.sql if you .read it)"

export CLOSURE_PORT="$PORT"
export CLOSURE_SAMPLES_DIR="$DATA_DIR"

echo "==> boot + serve via server/app.sql"
exec "$DUCKDB_BIN" "$DB" -c ".read server/app.sql"
