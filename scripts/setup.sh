#!/usr/bin/env bash
# setup.sh — thin entry: env knobs → SET VARIABLE → setup.sql + setup_pages.sql
# Knobs: N_CASES DOCS_PER_CASE CONSOLIDATED_PAGES REUSE_IDENTITIES
#        SAMPLES_DIR PAGES_DIR PNG_DPI SKIP_PNG DUCKDB_BIN PDF_EXTENSION
# Flag:  --reuse-identities  (same as REUSE_IDENTITIES=1)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
[[ "${1:-}" == "--reuse-identities" ]] && REUSE_IDENTITIES=1

DUCKDB_BIN="$(./scripts/duckdb-bin.sh)"
ver="$("$DUCKDB_BIN" --version 2>/dev/null | head -1 || true)"

# Optional font-bundled local pdf for rasters (after corpus; write_pdf uses community).
PAGES_PDF_LOAD=""
DUCK_FLAGS=()
if [[ -n "${PDF_EXTENSION:-}" ]]; then
  [[ -f "$PDF_EXTENSION" ]] || {
    echo "error: PDF_EXTENSION not a file: $PDF_EXTENSION" >&2
    exit 1
  }
  echo "==> pages will LOAD local pdf: $PDF_EXTENSION"
  DUCK_FLAGS+=(-unsigned)
  PAGES_PDF_LOAD="LOAD '${PDF_EXTENSION}';"
fi

mkdir -p .tmp
# Real public court filings alongside the generated corpus — opt-in, because
# they carry no watchlist (a published opinion has no known-PII list) and would
# otherwise become the default landing case, showing a reviewer a case with no
# name matches. COURT_DOCS=1 make setup  → the real-document cold-start demo.
# Either way the manifest is written, so corpus.sql's read never faults.
if [[ "${COURT_DOCS:-0}" == "1" ]]; then
  SAMPLES_DIR="${SAMPLES_DIR:-samples}" ./scripts/fetch-public.sh
else
  mkdir -p "${SAMPLES_DIR:-samples}"
  echo '[]' > "${SAMPLES_DIR:-samples}/court_manifest.json"
fi

echo "==> setup (corpus + page PNGs) via $DUCKDB_BIN ($ver)"
# CLI meta-commands (.read) need the SQL shell, not -c.
"$DUCKDB_BIN" "${DUCK_FLAGS[@]}" :memory: <<SQL
SET VARIABLE n_cases = ${N_CASES:-4};
SET VARIABLE docs_per_case = ${DOCS_PER_CASE:-2};
SET VARIABLE consolidated_pages = ${CONSOLIDATED_PAGES:-110};
SET VARIABLE reuse_identities = ${REUSE_IDENTITIES:-0};
-- Typed once here. SQL only coalesce-defaults if unset (no try_cast).
SET VARIABLE samples_dir = '${SAMPLES_DIR:-samples}';
SET VARIABLE pages_dir = 'pages';
SET VARIABLE png_dpi = ${PNG_DPI:-100};
SET VARIABLE skip_png = ${SKIP_PNG:-0};
.read scripts/setup.sql
${PAGES_PDF_LOAD}
.read scripts/setup_pages.sql
SQL

if [[ "${SKIP_PNG:-0}" != "1" ]]; then
  n_png="$(find "${PAGES_DIR:-pages}" -type f -name 'p*.png' 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$n_png" -gt 0 ]] || {
    echo "error: no page PNGs under ${PAGES_DIR:-pages}/" >&2
    exit 1
  }
  min_b="$(find "${PAGES_DIR:-pages}" -type f -name 'p*.png' -exec stat -f%z {} \; 2>/dev/null | sort -n | head -1)"
  min_b="${min_b:-0}"
  if [[ "$min_b" -lt 5000 ]]; then
    echo "warning: smallest page PNG is ${min_b} bytes (often blank — community pdf without base-14 fonts)." >&2
    echo "         Font-bundled build: PDF_EXTENSION=/path/to/pdf.duckdb_extension ./scripts/setup.sh" >&2
    echo "         (duckdb -unsigned). Not a pdftoppm path." >&2
  fi
  echo "==> setup complete: $(ls "${SAMPLES_DIR:-samples}"/*.pdf 2>/dev/null | wc -l | tr -d ' ') PDFs, ${n_png} PNGs. Next: make run"
else
  echo "==> setup complete (SKIP_PNG=1). Next: make run"
fi
