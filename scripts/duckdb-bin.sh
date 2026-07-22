#!/usr/bin/env bash
# duckdb-bin.sh — resolve a usable DuckDB CLI and print its path on stdout.
#
# Community `quackapi` first ships for DuckDB 1.5.4, so anything older is
# unusable here (the extension URL 404s). Rather than telling a fresh clone to
# go install the right version, we find one — and if the machine hasn't got it,
# download the official CLI into .deps/ (gitignored) and use that.
#
# Order: $DUCKDB_BIN → duckdb on PATH → brew/local installs → .deps cache → download.
# All progress goes to stderr so `$(scripts/duckdb-bin.sh)` captures only a path.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MIN="1.5.4"
PIN="${DUCKDB_VERSION:-1.5.4}"
DEST="$ROOT/.deps/runtime"

# usable <path> — executable and reporting a version >= MIN
usable() {
  local p="${1:-}" v
  [ -n "$p" ] && [ -x "$p" ] || return 1
  v="$("$p" --version 2>/dev/null | head -1)" || return 1
  v="${v#v}"; v="${v%% *}"
  [ -n "$v" ] || return 1
  [ "$(printf '%s\n%s\n' "$MIN" "$v" | sort -V | head -1)" = "$MIN" ]
}

for cand in "${DUCKDB_BIN:-}" "$(command -v duckdb || true)" \
            /opt/homebrew/bin/duckdb /usr/local/bin/duckdb "$DEST/duckdb"; do
  if usable "$cand"; then
    echo "$cand"
    exit 0
  fi
done

case "$(uname -s)/$(uname -m)" in
  Darwin/*)                  asset="duckdb_cli-osx-universal.zip" ;;
  Linux/x86_64)              asset="duckdb_cli-linux-amd64.zip" ;;
  Linux/aarch64|Linux/arm64) asset="duckdb_cli-linux-arm64.zip" ;;
  *)
    echo "error: no prebuilt DuckDB CLI for $(uname -s)/$(uname -m)." >&2
    echo "       install DuckDB >= $MIN and re-run with DUCKDB_BIN=/path/to/duckdb" >&2
    exit 1
    ;;
esac

echo "==> no DuckDB >= $MIN found; fetching v$PIN into .deps/runtime" >&2
mkdir -p "$DEST"
url="https://github.com/duckdb/duckdb/releases/download/v${PIN}/${asset}"
curl -fsSL --connect-timeout 10 --max-time 300 -o "$DEST/duckdb.zip" "$url" || {
  echo "error: could not download $url" >&2
  echo "       offline? install DuckDB >= $MIN and set DUCKDB_BIN=/path/to/duckdb" >&2
  exit 1
}
unzip -oq "$DEST/duckdb.zip" -d "$DEST"
rm -f "$DEST/duckdb.zip"
chmod +x "$DEST/duckdb"

usable "$DEST/duckdb" || {
  echo "error: downloaded CLI at $DEST/duckdb is not usable" >&2
  exit 1
}
echo "$DEST/duckdb"
