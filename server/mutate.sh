#!/usr/bin/env bash
# mutate.sh — side effects for quackapi SELECT routes.
# Appends one JSON object per line to exports/audit_sidecar.jsonl (no DB lock).
# Export PDFs → exports/*_redacted.pdf (byte-copy while suggestions empty).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CMD="${1:?usage: mutate.sh decision|export ...}"
SIDECAR="exports/audit_sidecar.jsonl"
mkdir -p exports
ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
next_id() {
  if [[ -f "$SIDECAR" ]]; then
    wc -l < "$SIDECAR" | tr -d ' '
  else
    echo 0
  fi
}

case "$CMD" in
  decision)
    SID="${2:?suggestion id}"
    ACT="${3:?action}"
    # When suggestions is empty (this pass), still write a real audit row so the
    # POST path is proven end-to-end. Once suggestions are seeded, a later
    # pass can enrich target with the matched phrase/page.
    nid=$(( $(next_id) + 1 ))
    row=$(printf '{"id":%s,"ts":"%s","actor":"A. Subbarao","action":"%s","suggestion_id":%s,"case_id":null,"target":"decision on suggestion #%s (lookup pending seed)"}' \
      "$nid" "$ts" "$ACT" "$SID" "$SID")
    printf '%s\n' "$row" >> "$SIDECAR"
    printf '[%s]\n' "$row"
    ;;
  export)
    CID="${2:?case id}"
    log="$(bash server/export_case.sh "$CID" | tr -d '\r' | tr '\n' ' ' | sed 's/"/\\"/g')"
    nid=$(( $(next_id) + 1 ))
    row=$(printf '{"id":%s,"ts":"%s","actor":"A. Subbarao","action":"exported","case_id":%s,"target":"%s"}' \
      "$nid" "$ts" "$CID" "$log")
    printf '%s\n' "$row" >> "$SIDECAR"
    printf '[%s]\n' "$row"
    ;;
  *)
    echo "unknown command: $CMD" >&2
    exit 1
    ;;
esac
