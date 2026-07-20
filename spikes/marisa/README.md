# Spike: marisa trie vs hash join for PII dictionary matching

Isolated evaluation of the DuckDB community extension **marisa**
(`INSTALL marisa FROM community`) against Closure’s current seed-matcher shape:
normalized equality join of dictionary phrases onto same-line word n-grams
(`v_grams` / `server/seed.sql`).

**Not wired into** `server/`, templates, static, or samples.

## Question

For matching a **large** PII dictionary (tens of thousands of names / streets /
terms) against document words at scale, does a marisa trie beat the current
approach (normalized equality join / n-gram join over a `words` table)?

## Prerequisites

```text
DuckDB CLI ≥ 1.5.3 with -unsigned (pdf community ext is unsigned here)
osx_arm64 community builds:
  INSTALL marisa FROM community;   -- signed; v1.5.3/v1.5.4 present
  INSTALL fakeit FROM community;
  INSTALL pdf FROM community;      -- needs -unsigned on this machine
```

## Run

From **repo root**:

```bash
bash spikes/marisa/run_bench.sh
# optional: N_ITERS=7 bash spikes/marisa/run_bench.sh
```

This:

1. Builds `spikes/marisa/out/bench.db` via `00_setup.sql`
   (real `samples/*.pdf` words × 10 stem repeats, fakeit dicts @ 10k/100k,
   prebuilt tries).
2. Times hash join / semi-join / marisa_lookup in **one** duckdb process
   (`.timer on` — no process-startup noise).
3. Writes metrics under `spikes/marisa/out/`.

| Output | Contents |
|--------|----------|
| `out/results.csv` | Per-iter elapsed_ms + hits |
| `out/summary.csv` / `summary.json` | Medians, vs-join ratios, correctness |
| `out/corpus.json` | Word/gram/dict/trie sizes |
| `out/timer_raw.log` | Full `.timer` transcript |

## Files

| Path | Role |
|------|------|
| `00_setup.sql` | Corpus + dictionaries + tries |
| `run_bench.sh` | Canonical timed driver |
| `01_benchmark.sql` | Optional single-file SQL sketch (less accurate timing) |
| `out/` | Captured metrics from a successful local run |
| `README.md` | This file |

## What is measured

| Method | SQL shape (conceptually) |
|--------|--------------------------|
| **hash_join** | `grams g JOIN dict d ON g.text_norm = d.text_norm` (seed-matcher style) |
| **hash_semijoin** | `g WHERE g.text_norm IN (SELECT text_norm FROM dict)` |
| **marisa_lookup** | Build `marisa_trie(dict)` once; `WHERE marisa_lookup(trie, g.text_norm)` |

Both sides use the same normalized keys (`qnorm` = lower + trim punctuation),
same 1–4 same-line n-grams as `server/ingest.sql` / `schema.sql` `v_grams`.

## Headline result (this machine)

| Dict | hash_join median | marisa_lookup median | Ratio |
|-----:|-----------------:|---------------------:|------:|
| 10k | 3 ms | 482 ms | **~161× slower** |
| 100k | 8 ms | 488 ms | **~61× slower** |

Corpus: 464k words / 1.67M grams (10× samples). Hit counts agree across methods.

## Verdict summary

See [`docs/marisa-verdict.md`](../../docs/marisa-verdict.md).

**Do not integrate.** Keep the seed matcher as a hash equality join on
`v_grams.text_norm`. Marisa is a fine compact trie for prefix/predictive
workloads; it is the wrong tool for Closure’s exact-phrase detector.
