#!/usr/bin/env bash
# generate-samples.sh — build the Closure sample corpus with pure DuckDB.
#
# Stack (hard rules): DuckDB + community fakeit + community pdf.
# No Python, no Typst. This shell is a thin build-time wrapper only.
#
# Usage (from repo root, or any cwd — script cds to repo root):
#   ./scripts/generate-samples.sh
#   N_CASES=6 DOCS_PER_CASE=3 ./scripts/generate-samples.sh
#   ./scripts/generate-samples.sh --n-cases 4 --docs-per-case 2 --consolidated-pages 110
#   ./scripts/generate-samples.sh --reuse-identities   # keep samples/identities.json
#
# Env / flags (all optional):
#   N_CASES              number of synthetic cases          (default: 4)
#   DOCS_PER_CASE        folder documents per case          (default: 2)
#   CONSOLIDATED_PAGES   multi-page consolidated target     (default: 110; 0=skip)
#   REUSE_IDENTITIES     1 = keep committed identities.json (default: 0)
#   DUCKDB_BIN           duckdb binary (default: duckdb on PATH)
#   SAMPLES_DIR          output dir relative to repo root   (default: samples)
#
# On a fresh clone, running this script produces the whole sample corpus:
#   samples/identities.json, samples/watchlist.json, samples/manifest.json,
#   samples/*.pdf, samples/messy/* (+ samples/messy/manifest.json).
# Does not touch samples/stress/ (owned elsewhere).
# Prefer scripts/setup.sh (this + page PNG render) for a full working app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

N_CASES="${N_CASES:-4}"
DOCS_PER_CASE="${DOCS_PER_CASE:-2}"
CONSOLIDATED_PAGES="${CONSOLIDATED_PAGES:-110}"
REUSE_IDENTITIES="${REUSE_IDENTITIES:-0}"
SAMPLES_DIR="${SAMPLES_DIR:-samples}"

# Resolution: $DUCKDB_BIN env, else duckdb on PATH, else error.
# Needs a v1.5.4+ binary with community pdf (write_pdf / pdf_encrypt / pdf_rotate).
DUCKDB_BIN="${DUCKDB_BIN:-$(command -v duckdb 2>/dev/null || true)}"
if [[ -z "$DUCKDB_BIN" ]]; then
  echo "error: duckdb not found — set DUCKDB_BIN (e.g. DUCKDB_BIN=\$HOME/personal/quackapi/build/release/duckdb) or put duckdb on PATH" >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --n-cases)              N_CASES="$2"; shift 2 ;;
    --docs-per-case)        DOCS_PER_CASE="$2"; shift 2 ;;
    --consolidated-pages)   CONSOLIDATED_PAGES="$2"; shift 2 ;;
    --reuse-identities)     REUSE_IDENTITIES=1; shift ;;
    --samples-dir)          SAMPLES_DIR="$2"; shift 2 ;;
    --duckdb)               DUCKDB_BIN="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "error: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

# Basic validation
[[ "$N_CASES" =~ ^[1-9][0-9]*$ ]] || { echo "error: N_CASES must be positive int" >&2; exit 1; }
[[ "$DOCS_PER_CASE" =~ ^[1-9][0-9]*$ ]] || { echo "error: DOCS_PER_CASE must be positive int" >&2; exit 1; }
[[ "$CONSOLIDATED_PAGES" =~ ^[0-9]+$ ]] || { echo "error: CONSOLIDATED_PAGES must be >= 0" >&2; exit 1; }
[[ -x "$DUCKDB_BIN" || -n "$(command -v "$DUCKDB_BIN" 2>/dev/null)" ]] || {
  echo "error: not executable: $DUCKDB_BIN" >&2; exit 1;
}

mkdir -p "$SAMPLES_DIR/gen" "$SAMPLES_DIR/messy"

echo "==> generate-samples"
echo "    duckdb:              $DUCKDB_BIN ($("$DUCKDB_BIN" --version 2>/dev/null | head -1))"
echo "    samples_dir:         $SAMPLES_DIR"
echo "    n_cases:             $N_CASES"
echo "    docs_per_case:       $DOCS_PER_CASE"
echo "    consolidated_pages:  $CONSOLIDATED_PAGES"
echo "    reuse_identities:    $REUSE_IDENTITIES"

# Remove prior folder PDFs only (never stress/, never messy/ here — SQL owns messy).
# shellcheck disable=SC2086
find "$SAMPLES_DIR" -maxdepth 1 -type f -name '*.pdf' -print -delete 2>/dev/null | sed 's/^/    rm /' || true

if [[ "$REUSE_IDENTITIES" == "1" ]]; then
  if [[ ! -f "$SAMPLES_DIR/identities.json" ]]; then
    echo "error: --reuse-identities requires $SAMPLES_DIR/identities.json" >&2
    exit 1
  fi
fi

# Pipeline: identities (fakeit) → optional fixture overlay → corpus (PDFs/manifest/messy).
# Overlay must run AFTER 01 and BEFORE 02 so plants/PDFs use the frozen cast.
REUSE_SQL_LINE=""
if [[ "$REUSE_IDENTITIES" == "1" ]]; then
  REUSE_SQL_LINE=".read samples/gen/reuse_identities.sql"
fi

"$DUCKDB_BIN" -unsigned :memory: <<SQL
-- Parameter surface for samples/gen/*.sql (no case-specific hardcoding).
SET VARIABLE n_cases = ${N_CASES};
SET VARIABLE docs_per_case = ${DOCS_PER_CASE};
SET VARIABLE consolidated_pages = ${CONSOLIDATED_PAGES};
SET VARIABLE reuse_identities = ${REUSE_IDENTITIES};
SET VARIABLE samples_dir = '${SAMPLES_DIR}';

.print '==> samples/gen/01_identities.sql'
.read samples/gen/01_identities.sql
${REUSE_SQL_LINE}
.print '==> samples/gen/02_corpus.sql'
.read samples/gen/02_corpus.sql
SQL

echo "==> done"
echo "    identities: $SAMPLES_DIR/identities.json"
echo "    watchlist:  $SAMPLES_DIR/watchlist.json"
echo "    manifest:   $SAMPLES_DIR/manifest.json"
echo "    messy:      $SAMPLES_DIR/messy/"
ls -la "$SAMPLES_DIR"/*.pdf 2>/dev/null | awk '{print "    pdf:", $NF, "(" $5 " bytes)"}'
ls -la "$SAMPLES_DIR/messy"/*.{pdf,json} 2>/dev/null | awk '{print "    messy:", $NF}' || true
