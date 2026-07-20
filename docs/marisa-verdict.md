# Marisa trie vs hash join — PII dictionary matching

**Verdict: do not integrate.**  
DuckDB’s vectorized hash join (the shape already used by `server/seed.sql`)
beats `marisa_lookup` by **~60–160×** on the workloads that matter for
Closure. Hit counts match exactly across methods; this is not a correctness
tradeoff.

---

## Question

For matching a **large** PII dictionary (tens of thousands of names / streets /
terms) against document words at scale, does a marisa trie beat the current
approach (normalized equality join / n-gram join over a `words` table)?

## What marisa is

Community extension (`INSTALL marisa FROM community`; signed osx_arm64 build
present for DuckDB v1.5.3 / v1.5.4):

| Function | Kind | Role |
|----------|------|------|
| `marisa_trie(VARCHAR)` | aggregate → `BLOB` | Build a static MARISA trie from keys |
| `marisa_lookup(BLOB, VARCHAR)` | scalar → `BOOLEAN` | Exact key membership |
| `marisa_common_prefix(BLOB, VARCHAR, INT)` | scalar → `VARCHAR[]` | Dict keys that are prefixes of the query |
| `marisa_predictive(BLOB, VARCHAR, INT)` | scalar → `VARCHAR[]` | Dict keys that start with the query |

MARISA is a compact static trie. The extension is real and works. The question
is whether it is the right tool for **seed-style exact phrase membership** over
`v_grams`.

## Current app shape (baseline)

From `server/ingest.sql` + `server/seed.sql`:

1. `words` ← `read_pdf_words(samples/*.pdf)`
2. `v_grams` — same-line 1–4 n-grams, `qnorm` keys
3. Seed matcher:

```sql
FROM _seed_targets t
JOIN documents d ON d.case_id = t.case_id
JOIN v_grams g
  ON g.document_id = d.id
 AND g.n = t.n_tokens
 AND g.text_norm = t.text_norm
```

That is a **hash equality join** on normalized phrase strings. Remainder scan
(`server/remainder_scan.sql`) is a different path (regex + finetype on residual
words) — it is **not** a large dictionary join today.

## Benchmark harness

| Path | Role |
|------|------|
| `spikes/marisa/00_setup.sql` | Load real PDFs → words → grams; fakeit dicts @ 10k/100k; prebuild tries |
| `spikes/marisa/run_bench.sh` | Single-process `.timer on` probes; CSV/JSON metrics |
| `spikes/marisa/out/` | `results.csv`, `summary.json`, `corpus.json`, timer log |

**Run (repo root):**

```bash
bash spikes/marisa/run_bench.sh
```

### Corpus (this machine)

| Metric | Value |
|--------|------:|
| DuckDB | v1.5.3, 4 threads, `memory_limit` 3.7 GiB |
| Source | `samples/*.pdf` via `read_pdf_words` (9 docs) |
| Word amplification | **10×** stem repeats (stress scale) |
| Words | 464,390 |
| Grams (1–4, same-line) | 1,674,380 |
| Unique gram keys | 6,743 |
| Dict 10k / 100k | exact row counts (distinct) |
| Planted real phrases | 200 (guaranteed non-zero hits) |
| Rest of dict | `fakeit` full names + last names + streets |

Dictionary = 200 real document n-grams + synthetic fakeit noise. All three
match methods returned **identical** hit counts.

### Methods compared

| Method | SQL shape |
|--------|-----------|
| `hash_join` | `grams g JOIN dict d ON g.text_norm = d.text_norm` |
| `hash_semijoin` | `g WHERE g.text_norm IN (SELECT text_norm FROM dict)` |
| `marisa_lookup` | prebuilt `marisa_trie(dict)`; `WHERE marisa_lookup(trie, g.text_norm)` |
| `marisa_build_only` | `octet_length(marisa_trie(text_norm))` from dict |
| `marisa_build_plus_lookup` | inline build + lookup (cold path) |

---

## Numbers (median wall time, N=5)

Measured with DuckDB CLI `.timer on` in one process (no process-startup noise).

### Full corpus (1.67M grams)

| Dict | Method | Median ms | vs hash join | Hits |
|-----:|--------|----------:|-------------:|-----:|
| 10k | **hash_join** | **3** | 1.0× | 61,310 |
| 10k | hash_semijoin | 2 | 0.7× | 61,310 |
| 10k | marisa_lookup | 482 | **161× slower** | 61,310 |
| 10k | marisa_build_only | 3 | — | (trie bytes 36,104) |
| 10k | marisa_build_plus_lookup | 489 | 163× slower | 61,310 |
| 100k | **hash_join** | **8** | 1.0× | 69,410 |
| 100k | hash_semijoin | 8 | 1.0× | 69,410 |
| 100k | marisa_lookup | 488 | **61× slower** | 69,410 |
| 100k | marisa_build_only | 25 | — | (trie bytes 296,440) |
| 100k | marisa_build_plus_lookup | 511 | 64× slower | 69,410 |

### Single-copy samples (167k grams, filter `document_id LIKE '1::%'`)

| Dict | hash_join | marisa_lookup | Ratio |
|-----:|----------:|--------------:|------:|
| 10k | 2 ms | 25 ms | ~12× slower |
| 100k | 8 ms | 36 ms | ~4.5× slower |

Even on pure sample scale (no amplification), the join wins cleanly.

### Memory / size

| Structure | Size |
|-----------|-----:|
| Dict 10k raw key bytes | ~136 KB |
| Trie 10k blob | **36 KB** (~3.8× denser) |
| Rough hash-table lower bound @ 10k | ~0.4 MB |
| Dict 100k raw key bytes | ~1.3 MB |
| Trie 100k blob | **296 KB** (~4.5× denser) |
| Rough hash-table lower bound @ 100k | ~4 MB |

**Trie wins on density.** At 100k PII strings that savings is still tiny next to
PDF word tables, page images, and the 4 GB app memory headroom. Density is not
the bottleneck for Closure.

---

## Why the join wins (physical plan)

```
hash path:     SEQ_SCAN(grams) ⋈ HASH_JOIN ⋈ SEQ_SCAN(dict)
marisa path:   SEQ_SCAN(grams) ⋈ BLOCKWISE_NL_JOIN ⋈ SEQ_SCAN(trie)
               condition: marisa_lookup(trie, text_norm)   ← scalar UDF per row
```

DuckDB’s hash join is vectorized and builds a hash table once over the smaller
side (dict). Marisa membership is a **row-at-a-time scalar UDF** inside a
blockwise nested-loop join. Trie probe asymptotics are fine; **extension
call overhead + lack of vectorization** are not.

Rough cost on the amplified corpus: ~0.3 µs per `marisa_lookup` call × 1.67M
grams ≈ 0.5 s — matches the measured ~480–490 ms.

---

## Where integration would go (if we did it)

| Surface | Would marisa help? | Why |
|---------|--------------------|-----|
| **Seed matcher** (`server/seed.sql` → `_seed_hits`) | **No** | Exact `text_norm` equality; hash join already optimal |
| **Remainder scan** (`server/remainder_scan.sql`) | **No** (today) | Regex + finetype, not a dictionary join |
| Hypothetical “huge residual name list” on remainder words | **Still no** for exact match | Same hash join shape beats trie; only change would be `JOIN name_dict` |
| Prefix / autocomplete UI over a dictionary | **Maybe** | `marisa_predictive` / `marisa_common_prefix` — different product problem |

### SQL shape if someone still forced marisa into the seed matcher

```sql
-- NOT recommended — kept only as the integration sketch.
CREATE OR REPLACE TABLE _pii_trie AS
SELECT marisa_trie(text_norm) AS trie
FROM (SELECT DISTINCT text_norm FROM _seed_targets);

CREATE OR REPLACE TABLE _seed_hits AS
SELECT t.*, g.document_id, g.page_no, g.seq AS start_seq,
       g.text_raw, g.x0, g.y0, g.x1, g.y1
FROM _seed_targets t
JOIN documents d ON d.case_id = t.case_id
JOIN v_grams g
  ON g.document_id = d.id
 AND g.n = t.n_tokens
CROSS JOIN _pii_trie tr
WHERE marisa_lookup(tr.trie, g.text_norm)
  AND g.text_norm = t.text_norm;   -- still need target metadata join
```

That is strictly more work than the existing equality join: you still need to
recover which target matched (kind, confidence, entity), so the hash join on
`text_norm` remains. Marisa only answers membership, not “which of 100k
targets.”

The **right** seed shape stays:

```sql
FROM _seed_targets t
JOIN documents d ON d.case_id = t.case_id
JOIN v_grams g
  ON g.document_id = d.id
 AND g.n = t.n_tokens
 AND g.text_norm = t.text_norm
```

If the dictionary grows to hundreds of thousands of phrases, keep it as a
table (or `DISTINCT` view) and let DuckDB hash it. At multi-million keys, still
prefer a join first; only re-benchmark marisa if a **prefix** or **streaming
non-SQL** path appears.

---

## Honest bottom line

1. **Do not integrate marisa** into the seed matcher or remainder scan for
   exact PII dictionary matching.
2. DuckDB hash joins are extremely fast at 10k–100k dict × ~0.1–1.7M n-grams
   (milliseconds). The plain join wins.
3. Marisa’s advantages (compact static trie, prefix/predictive search) do not
   map onto Closure’s current detector, which is equality on short normalized
   phrases with rich target metadata.
4. Revisit only if product needs **prefix autocomplete** over a huge static
   lexicon, or a non-SQL hot path where a prebuilt trie blob is shared outside
   DuckDB — neither is on the table for seed/remainder today.

## Repro

```bash
cd /Users/aloksubbarao/personal/closure
bash spikes/marisa/run_bench.sh
# artifacts: spikes/marisa/out/summary.json  results.csv  corpus.json
```

Machine note: `pdf` community extension requires `duckdb -unsigned` on this
host; `marisa` and `fakeit` install signed from community.
