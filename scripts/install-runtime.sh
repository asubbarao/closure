#!/usr/bin/env bash
# install-runtime.sh — put a working duckdb + quackapi extension in .deps/runtime/
# so run.sh / setup.sh just work. Graders never need to know about quackapi.
#
# Resolution (first hit wins): cached .deps/runtime → sibling ../quackapi build
# → prebuilt GitHub release tarball → clone + build from source (slow).
# Env: CLOSURE_RUNTIME_TAG CLOSURE_RUNTIME_REPO CLOSURE_QUACKAPI_GIT; --force re-installs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

DEPS="${CLOSURE_DEPS_DIR:-$ROOT/.deps}"
RT="$DEPS/runtime"
TAG="${CLOSURE_RUNTIME_TAG:-runtime-v1.5.4-1}"   # pinned: no floating "latest"
REPO="${CLOSURE_RUNTIME_REPO:-asubbarao/closure}"
GIT_URL="${CLOSURE_QUACKAPI_GIT:-https://github.com/asubbarao/quackapi.git}"
FORCE=0; [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]] && FORCE=1

probe() { # LOAD + CREATE ROUTE must parse — the whole point of quackapi
  "$1" -unsigned -cmd "LOAD '$2';" -c \
    "CREATE OR REPLACE ROUTE _probe GET '/_probe' AS SELECT 1; DROP ROUTE _probe;" >/dev/null 2>&1
}

install_pair() { # copy (not symlink) so the source tree can be deleted
  mkdir -p "$RT"
  /bin/cp -f "$1" "$RT/duckdb"; /bin/cp -f "$2" "$RT/quackapi.duckdb_extension"
  chmod +x "$RT/duckdb"
  echo "==> runtime ready: $RT/duckdb + quackapi.duckdb_extension"
}

# 1) cached
if [[ $FORCE -eq 0 ]] && probe "$RT/duckdb" "$RT/quackapi.duckdb_extension" 2>/dev/null; then
  echo "==> using cached .deps/runtime"; exit 0
fi

# 2) sibling build (skipped under --force so releases get exercised)
SIB="$(dirname "$ROOT")/quackapi/build/release"
if [[ $FORCE -eq 0 && -x "$SIB/duckdb" ]] \
   && probe "$SIB/duckdb" "$SIB/extension/quackapi/quackapi.duckdb_extension"; then
  echo "==> using sibling quackapi build"
  install_pair "$SIB/duckdb" "$SIB/extension/quackapi/quackapi.duckdb_extension"; exit 0
fi

# 3) prebuilt release: closure-<tag>-<os_arch>.tar.gz
case "$(uname -s | tr '[:upper:]' '[:lower:]')_$(uname -m)" in
  darwin_arm64) P=osx_arm64 ;; darwin_x86_64) P=osx_amd64 ;;
  linux_x86_64) P=linux_amd64 ;; linux_aarch64|linux_arm64) P=linux_arm64 ;;
  *) echo "error: unsupported platform $(uname -sm)" >&2; exit 1 ;;
esac
URL="https://github.com/$REPO/releases/download/$TAG/closure-$TAG-$P.tar.gz"
TMP="$(mktemp -d -t closure-rt.XXXXXX)"; trap 'rm -rf "$TMP"' EXIT
echo "==> trying prebuilt: $URL"
if /usr/bin/curl -fsSL --retry 3 -o "$TMP/rt.tgz" "$URL"; then
  tar -xzf "$TMP/rt.tgz" -C "$TMP"
  BIN="$(find "$TMP" -type f -name duckdb | head -1)"
  EXT="$(find "$TMP" -type f -name 'quackapi*.duckdb_extension' | head -1)"
  if [[ -n "$BIN" && -n "$EXT" ]] && chmod +x "$BIN" && probe "$BIN" "$EXT"; then
    install_pair "$BIN" "$EXT"; exit 0
  fi
  echo "warn: downloaded asset failed probe — building from source" >&2
else
  echo "warn: no prebuilt for $P — building from source" >&2
fi

# 4) source build
echo "==> building quackapi from source (first time: 10–30+ min; needs git/cmake/ninja)"
for c in git cmake ninja; do command -v "$c" >/dev/null || {
  echo "error: missing '$c' (brew install cmake ninja / apt install cmake ninja-build build-essential)" >&2; exit 1
}; done
SRC="$DEPS/src/quackapi"; mkdir -p "$DEPS/src"
if [[ ! -d "$SRC/.git" ]]; then
  git clone --recurse-submodules --depth 1 "$GIT_URL" "$SRC"
else
  git -C "$SRC" pull --ff-only || true
  git -C "$SRC" submodule update --init --recursive
fi
( cd "$SRC" && GEN=ninja make release )
BIN="$SRC/build/release/duckdb"
EXT="$SRC/build/release/extension/quackapi/quackapi.duckdb_extension"
probe "$BIN" "$EXT" || { echo "error: built runtime failed CREATE ROUTE probe" >&2; exit 1; }
install_pair "$BIN" "$EXT"
echo "==> done. Next: make setup && make run"
