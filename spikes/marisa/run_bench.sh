#!/usr/bin/env bash
# run_bench.sh — wall-clock benchmark: hash join vs marisa lookup.
# Single duckdb process + .timer on (avoids process-startup noise).
#
# Run from repo root:
#   bash spikes/marisa/run_bench.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"
OUT="$ROOT/spikes/marisa/out"
DB="$OUT/bench.db"
N_ITERS="${N_ITERS:-5}"
mkdir -p "$OUT"
rm -f "$DB" "$DB.wal" "$OUT/timer_raw.log" "$OUT/results.csv" "$OUT/summary.csv" "$OUT/summary.json"

echo "== setup =="
# -bail: stop on first SQL error (default duckdb exits 0 even after binder errors)
if ! duckdb -unsigned -bail "$DB" < spikes/marisa/00_setup.sql >"$OUT/setup.log" 2>&1; then
  echo "setup FAILED; tail of log:" >&2
  tail -40 "$OUT/setup.log" >&2
  exit 1
fi
grep -E 'Error|error|status|n_words|n_grams' "$OUT/setup.log" | tail -30 || true
duckdb -unsigned "$DB" -c "SELECT * FROM corpus_stats;" | tee "$OUT/corpus.txt"

echo "== generating timed SQL (N_ITERS=$N_ITERS) =="
TIMED_SQL="$OUT/_timed.sql"
{
  echo ".timer on"
  echo "LOAD marisa;"
  echo "SET threads = 4;"
  echo "SET memory_limit = '4GB';"
  echo "-- each SELECT count(*) is one timed statement; labels via preceding SELECT"

  for size in 10000 100000; do
    dict="dict_10k"; trie="trie_10k"
    [[ "$size" == "100000" ]] && dict="dict_100k" && trie="trie_100k"

    for i in 1 2 3; do
      echo "SELECT '${size}|marisa_build_only|${i}' AS label;"
      echo "SELECT octet_length(marisa_trie(text_norm)) AS hits FROM ${dict};"
    done

    for i in $(seq 1 "$N_ITERS"); do
      echo "SELECT '${size}|hash_join|${i}' AS label;"
      echo "SELECT count(*) AS hits FROM grams g JOIN ${dict} d ON g.text_norm = d.text_norm;"

      echo "SELECT '${size}|hash_semijoin|${i}' AS label;"
      echo "SELECT count(*) AS hits FROM grams g WHERE g.text_norm IN (SELECT text_norm FROM ${dict});"

      echo "SELECT '${size}|marisa_lookup|${i}' AS label;"
      echo "SELECT count(*) AS hits FROM grams g, ${trie} t WHERE marisa_lookup(t.trie, g.text_norm);"
    done

    for i in 1 2; do
      echo "SELECT '${size}|marisa_build_plus_lookup|${i}' AS label;"
      echo "SELECT count(*) AS hits FROM grams g
            CROSS JOIN (SELECT marisa_trie(text_norm) AS trie FROM ${dict}) t
            WHERE marisa_lookup(t.trie, g.text_norm);"
    done
  done
} > "$TIMED_SQL"

echo "== running timed probes =="
# Capture everything; duckdb prints "Run Time (s): real X user Y sys Z" after each stmt
duckdb -unsigned "$DB" < "$TIMED_SQL" >"$OUT/timer_raw.log" 2>&1 || {
  echo "timed run failed; tail of log:" >&2
  tail -40 "$OUT/timer_raw.log" >&2
  exit 1
}

echo "== parse timer log =="
python3 - "$OUT" <<'PY'
import csv, json, re, statistics, os, sys
from collections import defaultdict

out = sys.argv[1]
log = open(os.path.join(out, "timer_raw.log")).read().splitlines()

# Stream: label line (from SELECT 'size|method|iter'), then a hits table, then Run Time.
# Pattern for label:
label_re = re.compile(r"^\s*(\d+)\|(hash_join|hash_semijoin|marisa_lookup|marisa_build_only|marisa_build_plus_lookup)\|(\d+)\s*$")
# hits: integer line after a header, or in markdown-ish ascii tables
# DuckDB default box mode: │  5040 │ etc.
hits_re = re.compile(r"│\s*(\d+)\s*│")
time_re = re.compile(r"Run Time \(s\):\s*real\s+([0-9.]+)")

rows = []
cur_label = None
cur_hits = None
# Also capture plain label from box output rows
box_label_re = re.compile(
    r"│\s*(\d+)\|(hash_join|hash_semijoin|marisa_lookup|marisa_build_only|marisa_build_plus_lookup)\|(\d+)\s*│"
)

i = 0
while i < len(log):
    line = log[i]
    m = box_label_re.search(line) or (label_re.match(line.strip()) and None)
    if box_label_re.search(line):
        bm = box_label_re.search(line)
        cur_label = (int(bm.group(1)), bm.group(2), int(bm.group(3)))
        cur_hits = None
    elif label_re.match(line.strip()):
        bm = label_re.match(line.strip())
        cur_label = (int(bm.group(1)), bm.group(2), int(bm.group(3)))
        cur_hits = None

    # hits value: look for a single-integer box cell after label
    if cur_label and cur_hits is None:
        hm = hits_re.findall(line)
        # skip if this line is the label itself
        if hm and not box_label_re.search(line):
            # Prefer last integer on hits lines; length(blob) can be large
            cur_hits = int(hm[-1])

    tm = time_re.search(line)
    if tm and cur_label is not None:
        real_s = float(tm.group(1))
        # Label SELECT also gets a timer (~0ms). We only record when we have hits
        # from the subsequent count/length query. Strategy: pair time with last
        # completed query. Label queries have no numeric hits in a count sense.
        # Better approach: times alternate — label (tiny), work (real).
        # We store every timed statement with current label, then keep the LARGER
        # time per label (work query >> label select).
        rows.append({
            "dict_size": cur_label[0],
            "method": cur_label[1],
            "iter": cur_label[2],
            "elapsed_ms": real_s * 1000.0,
            "hits": cur_hits if cur_hits is not None else -1,
        })
    i += 1

# Collapse: for each (dict, method, iter) keep the row with max elapsed_ms
# (filters out the tiny label SELECT timings)
best = {}
for r in rows:
    key = (r["dict_size"], r["method"], r["iter"])
    if key not in best or r["elapsed_ms"] > best[key]["elapsed_ms"]:
        best[key] = r

final = sorted(best.values(), key=lambda r: (r["dict_size"], r["method"], r["iter"]))

notes = {
    "hash_join": "grams JOIN dict ON text_norm",
    "hash_semijoin": "WHERE text_norm IN (SELECT FROM dict)",
    "marisa_lookup": "marisa_lookup(prebuilt_trie, text_norm) [build excluded]",
    "marisa_build_plus_lookup": "inline marisa_trie + lookup (no reuse)",
    "marisa_build_only": "SELECT octet_length(marisa_trie(text_norm)) FROM dict",
}

with open(os.path.join(out, "results.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=["dict_size","method","iter","elapsed_ms","hits","notes"])
    w.writeheader()
    for r in final:
        w.writerow({
            "dict_size": r["dict_size"],
            "method": r["method"],
            "iter": r["iter"],
            "elapsed_ms": f"{r['elapsed_ms']:.3f}",
            "hits": r["hits"],
            "notes": notes.get(r["method"], ""),
        })

def med(xs):
    xs = sorted(xs)
    n = len(xs)
    if not n: return None
    if n % 2: return xs[n//2]
    return 0.5 * (xs[n//2 - 1] + xs[n//2])

groups = defaultdict(list)
hits = {}
for r in final:
    key = (r["dict_size"], r["method"])
    groups[key].append(r["elapsed_ms"])
    if r["hits"] is not None and r["hits"] >= 0:
        hits[key] = r["hits"]

summary = []
for (ds, method), xs in sorted(groups.items()):
    summary.append({
        "dict_size": ds,
        "method": method,
        "ms_min": round(min(xs), 3),
        "ms_max": round(max(xs), 3),
        "ms_median": round(med(xs), 3),
        "ms_mean": round(statistics.mean(xs), 3),
        "n_iters": len(xs),
        "hits": hits.get((ds, method), -1),
    })

base = {s["dict_size"]: s["ms_median"] for s in summary if s["method"] == "hash_join"}
for s in summary:
    b = base.get(s["dict_size"])
    if b and b > 0:
        s["x_vs_hash_join"] = round(s["ms_median"] / b, 2)
        if s["method"] == "hash_join":
            s["vs_join"] = "baseline"
        elif s["ms_median"] < b * 0.85:
            s["vs_join"] = "faster"
        elif s["ms_median"] > b * 1.15:
            s["vs_join"] = "slower"
        else:
            s["vs_join"] = "roughly_equal"
    else:
        s["x_vs_hash_join"] = None
        s["vs_join"] = "?"

correct = []
for ds in sorted({s["dict_size"] for s in summary}):
    def hit(m):
        return next((s["hits"] for s in summary if s["dict_size"]==ds and s["method"]==m), None)
    hj, hs, ml = hit("hash_join"), hit("hash_semijoin"), hit("marisa_lookup")
    correct.append({
        "dict_size": ds,
        "hash_join_hits": hj,
        "hash_semijoin_hits": hs,
        "marisa_lookup_hits": ml,
        "all_agree": hj is not None and hj == hs == ml,
    })

with open(os.path.join(out, "summary.csv"), "w", newline="") as f:
    fields = list(summary[0].keys()) if summary else []
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    w.writerows(summary)

# corpus from duckdb json if present
corpus = None
cpath = os.path.join(out, "corpus.json")

payload = {"timings": summary, "correctness": correct}
print("\n=== SUMMARY (median ms) ===")
print(f"{'dict':>8}  {'method':<28}  {'median_ms':>10}  {'x_vs_join':>9}  {'hits':>10}  vs")
for s in summary:
    print(f"{s['dict_size']:>8}  {s['method']:<28}  {s['ms_median']:>10.3f}  {str(s.get('x_vs_hash_join')):>9}  {s['hits']:>10}  {s.get('vs_join')}")
print("\n=== CORRECTNESS ===")
for c in correct:
    print(c)

json.dump(payload, open(os.path.join(out, "summary.json"), "w"), indent=2)
print(f"\nwrote {out}/results.csv summary.csv summary.json")
print(f"parsed {len(final)} timed probes from {len(rows)} raw timer lines")
if not final:
    print("WARNING: no probes parsed — inspect timer_raw.log", file=sys.stderr)
    sys.exit(2)
PY

# merge corpus
duckdb -unsigned "$DB" -json -c "SELECT * FROM corpus_stats;" > "$OUT/corpus.json" 2>/dev/null || true
python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
summary = json.load(open(os.path.join(out, "summary.json")))
cp = os.path.join(out, "corpus.json")
if os.path.exists(cp):
    raw = open(cp).read().strip()
    try:
        c = json.loads(raw)
        summary["corpus"] = c[0] if isinstance(c, list) and c else c
    except Exception as e:
        summary["corpus_error"] = str(e)
json.dump(summary, open(os.path.join(out, "summary.json"), "w"), indent=2)
print("merged corpus")
if "corpus" in summary:
    print(json.dumps(summary["corpus"], indent=2))
PY

echo "== done =="
ls -la "$OUT"
