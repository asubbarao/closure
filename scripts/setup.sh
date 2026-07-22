#!/usr/bin/env bash
# setup.sh — clone → sample corpus + page PNGs. Then: make run.
# Knobs (env): N_CASES DOCS_PER_CASE CONSOLIDATED_PAGES REUSE_IDENTITIES
#              SAMPLES_DIR PAGES_DIR PNG_DPI SKIP_PNG DUCKDB_BIN
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
[[ "${1:-}" == "--reuse-identities" ]] && REUSE_IDENTITIES=1

# runtime: env → .deps/runtime → sibling checkout → install-runtime.sh
RT="$ROOT/.deps/runtime"; SIB="$(dirname "$ROOT")/quackapi/build/release"
DUCKDB_BIN="${DUCKDB_BIN:-$RT/duckdb}"
[[ -x "$DUCKDB_BIN" ]] || DUCKDB_BIN="$SIB/duckdb"
[[ -x "$DUCKDB_BIN" ]] || { ./scripts/install-runtime.sh; DUCKDB_BIN="$RT/duckdb"; }
export DUCKDB_BIN

SAMPLES_DIR="${SAMPLES_DIR:-samples}" PAGES_DIR="${PAGES_DIR:-pages}" PNG_DPI="${PNG_DPI:-100}"
find "$SAMPLES_DIR" -maxdepth 1 -type f -name '*.pdf' -delete 2>/dev/null || true

echo "==> corpus (samples/gen/corpus.sql)"
"$DUCKDB_BIN" -unsigned :memory: <<SQL
SET VARIABLE n_cases = ${N_CASES:-4};
SET VARIABLE docs_per_case = ${DOCS_PER_CASE:-2};
SET VARIABLE consolidated_pages = ${CONSOLIDATED_PAGES:-110};
SET VARIABLE reuse_identities = ${REUSE_IDENTITIES:-0};
SET VARIABLE samples_dir = '${SAMPLES_DIR}';
.read samples/gen/corpus.sql
SQL

[[ "${SKIP_PNG:-0}" == "1" ]] && { echo "==> skip PNGs (SKIP_PNG=1)"; exit 0; }
command -v pdftoppm >/dev/null || {
  echo "error: pdftoppm (poppler) required for page PNGs — brew install poppler / apt install poppler-utils" >&2
  echo "       (the pdf extension's built-in rasterizer ships no fonts → blank pages)" >&2
  exit 1
}

echo "==> page PNGs → $PAGES_DIR/ (dpi=$PNG_DPI, pdftoppm)"
rm -rf "$PAGES_DIR"; mkdir -p "$PAGES_DIR"
for pdf in "$SAMPLES_DIR"/*.pdf; do
  stem="$(basename "$pdf" .pdf)"
  mkdir -p "$PAGES_DIR/$stem"
  pdftoppm -png -r "$PNG_DPI" "$pdf" "$PAGES_DIR/$stem/p"
  # pdftoppm pads page numbers (p-1.png / p-001.png); app wants p1.png
  for f in "$PAGES_DIR/$stem"/p-*.png; do
    n="${f##*/p-}"; n="${n%.png}"
    mv -f "$f" "$PAGES_DIR/$stem/p$((10#$n)).png"
  done
done

echo "==> setup complete: $(ls "$SAMPLES_DIR"/*.pdf | wc -l | tr -d ' ') PDFs, $(find "$PAGES_DIR" -name 'p*.png' | wc -l | tr -d ' ') PNGs. Next: make run"
