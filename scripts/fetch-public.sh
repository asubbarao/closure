#!/usr/bin/env bash
# fetch-public.sh — real U.S. court documents into samples/, next to the
# generated corpus. Same directory, same glob, same ingest path: to the app a
# SCOTUS slip opinion is just another source PDF.
#
# Public-domain U.S. government works (judicial opinions and DOJ filings).
# Each file is checksummed; a mismatch is deleted, not ingested. Network
# failure is not an error — the app boots on the generated corpus alone, and
# corpus.sql only lists the court files that actually landed.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
DIR="${SAMPLES_DIR:-samples}"

# The docket/case grouping below is DECLARED, not inferred: we picked these
# files and know which matter each belongs to (the two Google filings share
# 1:20-cv-03010). Nothing downstream parses this back out of PDF text — same
# principle as _cases in corpus.sql, where case_no is assigned once and
# carried as a column, never rediscovered from the document body.
#
# file                                    case_no        sha256                                                             url
FILES=$(cat <<'EOF'
court_scotus_galette_v_nj_transit.pdf   24-1021        9982ca223713d263c2128a81e61fcf7bfe54576a8416affa8f1c92bbdd8d4659 https://www.supremecourt.gov/opinions/25pdf/24-1021_p860.pdf
court_scotus_pung_v_isabella_county.pdf 25-95          d4db4fb7164892957fbf17b98860148e82ee4cbd4269a4a8b283c366dbdd271c https://www.supremecourt.gov/opinions/25pdf/25-95_dc8e.pdf
court_scotus_trump_v_barbara.pdf        25-365         dccc4217c8590e0768c2af4c3563accb0d51eb0daad73bc61b989bda3ac79b8b https://www.supremecourt.gov/opinions/25pdf/25-365_4hdj.pdf
court_doj_us_v_google_complaint.pdf     1-20-cv-03010  e9d06d227e14aff439055b55cffe8e721ce3268ab88333c705a998dc0a66db6e https://www.justice.gov/opa/press-release/file/1328941/download
court_doj_us_v_google_sj_opinion.pdf    1-20-cv-03010  f03a07f08175f4c1f64a047080d702fa4a2bbc89fb47badcafc9901c084a285f https://www.justice.gov/d9/2023-10/416980.pdf
EOF
)

got=0 have=0
manifest="$DIR/court_manifest.json"
rows=()
while read -r name case_no want url; do
  [ -n "$name" ] || continue
  path="$DIR/$name"
  if [ -f "$path" ] && [ "$(shasum -a 256 "$path" | cut -d' ' -f1)" = "$want" ]; then
    have=$((have + 1)); rows+=("{\"filename\":\"$name\",\"case_no\":\"$case_no\"}"); continue
  fi
  curl -fsSL --connect-timeout 10 --max-time 120 -o "$path.part" "$url" 2>/dev/null || { rm -f "$path.part"; continue; }
  if [ "$(shasum -a 256 "$path.part" | cut -d' ' -f1)" = "$want" ]; then
    mv -f "$path.part" "$path"; got=$((got + 1)); rows+=("{\"filename\":\"$name\",\"case_no\":\"$case_no\"}")
  else
    echo "   checksum mismatch, discarding: $name" >&2; rm -f "$path.part"
  fi
done <<< "$FILES"

IFS=,; echo "[${rows[*]}]" > "$manifest"; unset IFS

n=$((got + have))
echo "==> court documents: $n/5 present ($got fetched, $have cached) → $manifest"
[ "$n" -eq 5 ] || echo "    offline or upstream moved — app runs on the generated corpus alone" >&2
exit 0
