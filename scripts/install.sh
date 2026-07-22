#!/usr/bin/env bash
# install.sh — resolve a DuckDB >= 1.5.4 (downloading one if the machine lacks
# it) and prove community quackapi loads. `make setup` resolves the same way,
# so this is only a preflight check.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

DUCKDB_BIN="$(./scripts/duckdb-bin.sh)"
echo "==> $DUCKDB_BIN — $("$DUCKDB_BIN" --version 2>/dev/null | head -1)"

"$DUCKDB_BIN" -c "INSTALL quackapi FROM community; LOAD quackapi; SELECT 'quackapi ok' AS status;"
echo "==> ready — make setup && make run"
