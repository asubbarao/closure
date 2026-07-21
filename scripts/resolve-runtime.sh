#!/usr/bin/env bash
# resolve-runtime.sh — source this to export DUCKDB_BIN + QUACKAPI_EXT.
# Prefer .deps/runtime (from install-runtime.sh); fall back to env / sibling.
#
# Usage (from bash scripts with shebang #!/usr/bin/env bash):
#   # shellcheck source=resolve-runtime.sh
#   source "$(dirname "$0")/resolve-runtime.sh"
#   "$DUCKDB_BIN" ...
#
# Safe to source from bash or zsh. Does not toggle `set -u` on the caller.

# Locate this file (bash vs zsh) without assuming `set -u` is off for arrays.
_resolve_self=""
if [ -n "${BASH_VERSION:-}" ]; then
  _resolve_self="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  # zsh: path of the sourced file
  # shellcheck disable=SC2296
  _resolve_self="${(%):-%x}"
else
  _resolve_self="$0"
fi
_RESOLVE_ROOT="$(cd "$(dirname "$_resolve_self")/.." && pwd)"
_RUNTIME_DIR="${CLOSURE_DEPS_DIR:-$_RESOLVE_ROOT/.deps}/runtime"
unset _resolve_self

if [ -f "$_RUNTIME_DIR/env" ]; then
  # shellcheck disable=SC1091
  . "$_RUNTIME_DIR/env"
fi

# Env still wins if set after sourcing (or without install).
DUCKDB_BIN="${DUCKDB_BIN:-}"
QUACKAPI_EXT="${QUACKAPI_EXT:-${CLOSURE_QUACKAPI_EXT:-}}"

if [ -z "$DUCKDB_BIN" ] || [ -z "$QUACKAPI_EXT" ]; then
  if [ -x "$_RUNTIME_DIR/duckdb" ] && [ -f "$_RUNTIME_DIR/quackapi.duckdb_extension" ]; then
    DUCKDB_BIN="$_RUNTIME_DIR/duckdb"
    QUACKAPI_EXT="$_RUNTIME_DIR/quackapi.duckdb_extension"
  fi
fi

if [ -z "$DUCKDB_BIN" ] || [ -z "$QUACKAPI_EXT" ]; then
  _SIBLING="$(cd "$_RESOLVE_ROOT/.." && pwd)/quackapi"
  if [ -x "$_SIBLING/build/release/duckdb" ] \
     && [ -f "$_SIBLING/build/release/extension/quackapi/quackapi.duckdb_extension" ]; then
    DUCKDB_BIN="$_SIBLING/build/release/duckdb"
    QUACKAPI_EXT="$_SIBLING/build/release/extension/quackapi/quackapi.duckdb_extension"
  fi
  unset _SIBLING
fi

if [ -z "${DUCKDB_BIN:-}" ] || [ ! -x "${DUCKDB_BIN:-}" ]; then
  echo "error: DuckDB runtime not found." >&2
  echo "  Run once:  ./scripts/install-runtime.sh" >&2
  echo "  Or set:    DUCKDB_BIN=… QUACKAPI_EXT=… (quackapi-built pair)" >&2
  unset _RESOLVE_ROOT _RUNTIME_DIR
  return 1 2>/dev/null || exit 1
fi
if [ -z "${QUACKAPI_EXT:-}" ] || [ ! -f "${QUACKAPI_EXT:-}" ]; then
  echo "error: quackapi extension not found." >&2
  echo "  Run once:  ./scripts/install-runtime.sh" >&2
  unset _RESOLVE_ROOT _RUNTIME_DIR
  return 1 2>/dev/null || exit 1
fi

export DUCKDB_BIN
export QUACKAPI_EXT
export CLOSURE_QUACKAPI_EXT="$QUACKAPI_EXT"
unset _RESOLVE_ROOT _RUNTIME_DIR
