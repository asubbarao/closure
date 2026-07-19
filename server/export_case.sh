#!/usr/bin/env bash
# export_case.sh <case_id>
# No-op redaction export: copy source PDFs to exports/*_redacted.pdf for the case.
# When suggestions are seeded later, this script will be upgraded to call
# pdf_redact with accepted boxes. Today the table is empty so a byte-copy is correct.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CASE_ID="${1:?case_id required}"
MAP="exports/export_map.csv"
if [[ ! -f "$MAP" ]]; then
  echo "error: $MAP missing — run ingest first" >&2
  exit 1
fi
mkdir -p exports
n=0
# CSV: case_id,filename,source_path,out_path
while IFS=',' read -r cid filename source_path out_path; do
  [[ "$cid" == "case_id" ]] && continue
  [[ "$cid" == "$CASE_ID" ]] || continue
  cp -f "$source_path" "$out_path"
  n=$((n + 1))
done < "$MAP"
echo "exported $n document(s) for case $CASE_ID → exports/"
