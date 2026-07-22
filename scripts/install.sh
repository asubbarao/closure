#!/usr/bin/env bash
# install.sh — probe community quackapi (stock DuckDB ≥ 1.5.4 on PATH).
#   INSTALL quackapi FROM community; LOAD quackapi;
set -euo pipefail

DUCKDB_BIN="${DUCKDB_BIN:-$(command -v duckdb || true)}"
[[ -n "${DUCKDB_BIN}" && -x "$DUCKDB_BIN" ]] || {
  echo "error: install DuckDB ≥ 1.5.4 first" >&2
  echo "  https://duckdb.org/docs/installation/" >&2
  exit 1
}

ver="$("$DUCKDB_BIN" --version 2>/dev/null | head -1 || true)"
echo "==> $ver"
# community quackapi ships for 1.5.4+ (1.5.3 → HTTP 404)
case "$ver" in
  *v1.5.[4-9]*|*v1.[6-9]*|*v[2-9].*) ;;
  *)
    echo "error: need DuckDB ≥ 1.5.4 for community quackapi (got: $ver)" >&2
    echo "  brew install duckdb  # or download from duckdb.org" >&2
    echo "  (if PATH has an older duckdb first, set DUCKDB_BIN=/path/to/1.5.4+)" >&2
    exit 1
    ;;
esac

"$DUCKDB_BIN" -c "INSTALL quackapi FROM community; LOAD quackapi; SELECT 'quackapi ok' AS status;"
echo "==> ready — make setup && make run"
