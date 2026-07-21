#!/usr/bin/env bash
# setup.sh — clone → full working Closure sample corpus + page PNGs.
#
# One command after git clone:
#   ./scripts/setup.sh
#
# What it does:
#   1. samples/gen/01_identities.sql + 02_corpus.sql via generate-samples.sh
#        (fakeit identities, write_pdf reports, 110-page consolidated,
#         multi-doc batches, FN/FP plants, messy edge-case set)
#   2. Render every samples/*.pdf page to pages/<stem>/pN.png
#        (pdftoppm preferred; DuckDB pdf_to_png fallback)
#
# Does NOT boot the app. After setup (quackapi-built binary):
#   "$DUCKDB_BIN" -unsigned closure.db -c ".read server/app.sql"
#
# Env / flags forwarded to generate-samples.sh:
#   N_CASES DOCS_PER_CASE CONSOLIDATED_PAGES REUSE_IDENTITIES DUCKDB_BIN SAMPLES_DIR
#   PNG_DPI   raster DPI for page previews (default 100)
#   SKIP_PNG  1 = skip page PNG step
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PNG_DPI="${PNG_DPI:-100}"
SKIP_PNG="${SKIP_PNG:-0}"
SAMPLES_DIR="${SAMPLES_DIR:-samples}"
PAGES_DIR="${PAGES_DIR:-pages}"

# Same binary resolution as generate-samples.sh / run.sh: env → sibling quackapi → PATH.
if [[ -z "${DUCKDB_BIN:-}" ]]; then
  _sibling="$(dirname "$ROOT")/quackapi/build/release/duckdb"
  if [[ -x "$_sibling" ]]; then
    export DUCKDB_BIN="$_sibling"
  elif command -v duckdb >/dev/null 2>&1; then
    export DUCKDB_BIN="$(command -v duckdb)"
  fi
fi

echo "==> Closure setup (repo root: $ROOT)"
[[ -n "${DUCKDB_BIN:-}" ]] && echo "    DUCKDB_BIN=$DUCKDB_BIN"

# ── 1. Generate PDFs + identities + manifest ───────────────────────────────
./scripts/generate-samples.sh "$@"

# ── 2. Page PNG previews ────────────────────────────────────────────────────
if [[ "$SKIP_PNG" == "1" ]]; then
  echo "==> skip page PNG render (SKIP_PNG=1)"
  exit 0
fi

echo "==> render page PNGs → $PAGES_DIR/ (dpi=$PNG_DPI)"

# Wipe prior page renders so stems deleted by the generator do not linger.
if [[ -d "$PAGES_DIR" ]]; then
  find "$PAGES_DIR" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
fi
mkdir -p "$PAGES_DIR"

PDFS=()
while IFS= read -r _pdf; do
  [[ -n "$_pdf" ]] && PDFS+=("$_pdf")
done < <(find "$SAMPLES_DIR" -maxdepth 1 -type f -name '*.pdf' | sort)
if [[ ${#PDFS[@]} -eq 0 ]]; then
  echo "error: no PDFs under $SAMPLES_DIR/ after generate-samples" >&2
  exit 1
fi

render_one_pdftoppm() {
  local pdf="$1"
  local stem
  stem="$(basename "$pdf" .pdf)"
  local outdir="$PAGES_DIR/$stem"
  mkdir -p "$outdir"
  # pdftoppm writes outdir/p-1.png …; rename to p1.png for quackapi static paths.
  pdftoppm -png -r "$PNG_DPI" "$pdf" "$outdir/p"
  # pdftoppm writes p-1.png or zero-padded p-001.png (when pages >= 100).
  # App static paths expect unpadded p1.png, p2.png, …
  local f
  for f in "$outdir"/p-*.png; do
    [[ -e "$f" ]] || continue
    local base num
    base="$(basename "$f")"
    num="${base#p-}"
    num="${num%.png}"
    num=$((10#$num))   # strip leading zeros; force decimal
    mv -f "$f" "$outdir/p${num}.png"
  done
  local n
  n="$(find "$outdir" -maxdepth 1 -type f -name 'p*.png' | wc -l | tr -d ' ')"
  echo "    $stem → $n pages"
}

render_all_duckdb() {
  # Fallback when poppler is missing: pdf_to_png → write each page via Python-free
  # shell hexdump is painful; use DuckDB COPY of base64 then decode.
  # Resolution: $DUCKDB_BIN (set above / generate-samples), else duckdb on PATH.
  local duck="${DUCKDB_BIN:-$(command -v duckdb 2>/dev/null || true)}"
  [[ -n "$duck" ]] || {
    echo "error: neither pdftoppm nor duckdb available for page PNG render — set DUCKDB_BIN (≥1.5.4) or install poppler" >&2
    exit 1
  }

  echo "    (using duckdb pdf_to_png fallback via $duck)"
  local pdf stem pages i b64
  for pdf in "${PDFS[@]}"; do
    stem="$(basename "$pdf" .pdf)"
    mkdir -p "$PAGES_DIR/$stem"
    pages="$("$duck" -unsigned :memory: -c "
INSTALL pdf FROM community; LOAD pdf;
SELECT page_count FROM pdf_info('$pdf');
" | awk 'NR==4 {print $2+0; exit}')"
    if [[ -z "$pages" || "$pages" -lt 1 ]]; then
      echo "error: could not read page_count for $pdf" >&2
      exit 1
    fi
    for ((i=1; i<=pages; i++)); do
      b64="$("$duck" -unsigned :memory: -c "
INSTALL pdf FROM community; LOAD pdf;
SELECT base64(pdf_to_png('$pdf', $i, $PNG_DPI));
" 2>/dev/null | awk 'NR==4 {print $2; exit}')"
      if [[ -z "$b64" ]]; then
        echo "error: pdf_to_png failed for $pdf page $i" >&2
        exit 1
      fi
      printf '%s' "$b64" | base64 -d > "$PAGES_DIR/$stem/p${i}.png"
    done
    echo "    $stem → $pages pages"
  done
}

if command -v pdftoppm >/dev/null 2>&1; then
  for pdf in "${PDFS[@]}"; do
    render_one_pdftoppm "$pdf"
  done
else
  render_all_duckdb
fi

# Sanity: every PDF has at least p1.png
missing=0
for pdf in "${PDFS[@]}"; do
  stem="$(basename "$pdf" .pdf)"
  if [[ ! -f "$PAGES_DIR/$stem/p1.png" ]]; then
    echo "error: missing $PAGES_DIR/$stem/p1.png" >&2
    missing=1
  fi
done
[[ "$missing" -eq 0 ]] || exit 1

total_png="$(find "$PAGES_DIR" -type f -name 'p*.png' | wc -l | tr -d ' ')"
echo "==> setup complete"
echo "    PDFs:  ${#PDFS[@]}"
echo "    PNGs:  $total_png under $PAGES_DIR/"
echo "    next:  \"\$DUCKDB_BIN\" -unsigned closure.db -c \".read server/app.sql\""
echo "           (DUCKDB_BIN must be a quackapi-built duckdb; see README quick start)"
