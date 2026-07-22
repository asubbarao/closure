# Detection / data-quality extension survey

**Scope:** Community extensions that might help **detection**, **judge confidence**,
**remainder-scan misses**, or **audit/data-quality** in Closure (DuckDB-is-the-backend
redaction app). Honest bar: most are **no**.

**Survey date:** 2026-07-19  
**Catalog:** DuckDB community list for stable **v1.5.4**  
**Local probe:** `/opt/homebrew/bin/duckdb` → **v1.5.4** (Variegata) `08e34c447b`, `osx_arm64`  
**Also present:** system `~/.local/bin/duckdb` is **v1.5.3** — community `ai` is **404** there;
app boot uses the quackapi **1.5.4** binary (`run.sh` `DUCKDB_BIN`).

**Install pattern (all community):**

```sql
INSTALL <name> FROM community;
LOAD <name>;
```

**CDN signed builds** = HTTP 200 on  
`https://community-extensions.duckdb.org/v1.5.4/osx_arm64/<name>.duckdb_extension.gz`  
(community-extensions CI signature). Core `vss` is under `extensions.duckdb.org`, not community.

**App context (what “useful” means here):**

| Surface | Current design |
|---------|----------------|
| Judge ensemble | Pure SQL, **deterministic**, 3 judges (pattern / context / prior) — `server/judge.sql` |
| Remainder FN catcher | Regex + finetype on remainder n-grams — `server/remainder_scan.sql` |
| Chain-of-custody | Provenance spike already uses core `sha256(content)` via `read_blob` |
| Decisions audit | Append-only JSON under `exports/decisions/` |
| Corpus size | Tiny (samples + demo) — approximate sketches / ANN indexes do not pay |

---

## Executive summary

| Verdict | Extensions |
|---------|------------|
| **Integrate now** | `crypto`, `us_address_standardizer` |
| **Spike later** | `json_schema`, `ai` (optional offline only) |
| **No** | `fuzzycomplete`, `semantic_views`, `inflector`, `mlpack`, `stochastic`, `datasketches`, `bitfilters`, `hashfuncs`, `vindex` + core `vss` |

Working SQL for the top two lives under `spikes/ext-detection/`.

---

## Master table

| Extension | CDN v1.5.3 | CDN v1.5.4 | LOAD ok @1.5.4 | Verdict | One-line why |
|-----------|:----------:|:----------:|:--------------:|---------|--------------|
| **ai** | 404 | **200** | yes | **spike later** | Real LLM-in-SQL, but breaks judge determinism, adds API-key/latency/cost; offline 4th judge only |
| **fuzzycomplete** | 200 | **200** | yes | **no** | CLI autocompletion only — zero detection surface |
| **semantic_views** | 200 | **200** | yes | **no** | BI metrics layer (`CREATE SEMANTIC VIEW`), not PII detection |
| **us_address_standardizer** | 200 | **200** | yes | **integrate now** | Structured US address parse → entity canonicalize + address residual hits |
| **inflector** | 200 | **200** | yes | **no** | Case/plural helpers; does not fix name/OCR variants better than roster regex |
| **mlpack** | 200 | **200** | yes | **no** | Train RF/AdaBoost on tables; no labeled FP set, overkill, non-SQL-native UX |
| **stochastic** | 200 | **200** | yes | **no** | Distribution PDF/CDF/sample; judge is deliberately non-random |
| **datasketches** | 200 | **200** | yes | **no** | Approx distincts/quantiles; corpus fits exact `count(DISTINCT …)` |
| **bitfilters** | 200 | **200** | yes | **no** | Probabilistic membership; exact set membership is fine at our scale |
| **hashfuncs** | 200 | **200** | yes | **no** | Fast non-crypto hashes; custody needs cryptographic digests |
| **crypto** | 200 | **200** | yes | **integrate now** | HMAC + ordered `crypto_hash_agg` seal decision chains; multi-algo digests beyond core `sha256` |
| **json_schema** | 200 | **200** | yes | **spike later** | Validate decision JSON / identities fixture shapes — DQ, not detection |
| **vindex** | 200 | **200** | yes | **no** | ANN indexes need embeddings first; hundreds of spans ≠ vector search problem |
| **vss** (core) | 200 | **200** | yes | **no** | Same as vindex — HNSW without a real embedding pipeline is cargo cult |

---

## Per-extension detail

### 1. `ai` — spike later

| | |
|--|--|
| **Docs** | https://duckdb.org/community_extensions/extensions/ai.html |
| **Install** | `INSTALL ai FROM community; LOAD ai;` |
| **osx_arm64 signed** | **v1.5.4 yes**; **v1.5.3 no** (CDN 404) |
| **Key functions** | `ai_complete`, `ai_classify`, `ai_classify_labels`, `ai_extract` / `ai_extract_record`, `ai_redact`, `ai_filter`, `ai_embed`, `ai_similarity`, `ai_rerank`, `ai_complete_json`, `ai_usage`, … |
| **Providers** | Ollama / llama.cpp / OpenAI-compatible + OpenAI, Anthropic, Gemini, … |
| **Secrets** | `CREATE SECRET … (TYPE duckdb_ai, AI_PROVIDER …, API_KEY …)` or env — **not** SQL args |

**Could it power the judge ensemble or real suggestion scoring?**

| Idea | Assessment |
|------|------------|
| Replace Pattern/Context/Prior with `ai_classify(text \|\| context, ['redact','keep','unsure'])` | Works technically; **destroys** product invariants: determinism, offline demo, zero-cost boot, no network |
| Optional 4th “LLM” judge chip | Possible offline with Ollama; still non-reproducible across machines/models; latency ~100ms–seconds **per suggestion** kills bulk review |
| `ai_redact` on remainder text | Interesting FN catcher, but opaque, slow, and ships PII to a model unless fully local |
| `ai_embed` + similarity for entity clustering | Needs embedding model + storage; roster is 4 cases — exact string + finetype already win |

**Cost / latency / API-key story**

- Hosted: per-token cost × hundreds of suggestions; needs secret management; egress of **PII** (SSNs, DOBs) is a product/legal hazard for a redaction app.
- Local Ollama: free tokens, but model install, GPU/CPU load, non-deterministic answers, still multi-second bulk runs.
- Extension itself is well-built (caching, rate limits, `ai_usage()`, allowlist) — **implementation quality is not the blocker**; product fit is.

**Mechanism if used later (offline spike only):**

```sql
-- NOT for production judge; example shape only
SET duckdb_ai_provider = 'ollama';
SET duckdb_ai_model = '…';
SELECT suggestion_id,
       ai_classify(
         concat_ws(' | ', text, coalesce(context, ''), coalesce(kind, '')),
         ['redact', 'keep', 'unsure']
       ) AS llm_verdict
FROM v_suggestions;
```

**Verdict: spike later** — only as an optional offline experiment, never as the boot-path ensemble.

---

### 2. `fuzzycomplete` — no

| | |
|--|--|
| **Install** | `INSTALL fuzzycomplete FROM community; LOAD fuzzycomplete;` |
| **osx_arm64** | v1.5.3 + v1.5.4 **yes** |
| **Functions added** | **None** (overloads shell/REPL completion) |

**Why no:** Developer UX for typing SQL in the CLI. Zero intersection with PII detection, scoring, or audit.

---

### 3. `semantic_views` — no

| | |
|--|--|
| **Install** | `INSTALL semantic_views FROM community; LOAD semantic_views;` |
| **osx_arm64** | yes both |
| **API** | `CREATE SEMANTIC VIEW … DIMENSIONS/METRICS`; `semantic_view('name', dimensions := […], metrics := […])` |

**Why no:** Looker/MetricFlow-style semantic layer for dashboards. Closure’s “views” are already thin SQL (`v_judge_panel`, `v_suggestions_judged`). Not a detector.

---

### 4. `us_address_standardizer` — integrate now

| | |
|--|--|
| **Docs** | https://duckdb.org/community_extensions/extensions/us_address_standardizer.html |
| **Install** | `INSTALL us_address_standardizer FROM community; LOAD us_address_standardizer;` |
| **osx_arm64** | yes both |
| **Key functions** | `addrust_parse(text)` · `load_us_address_data()` · `parse_address` / `standardize_address` (PAGC tables) |

**Probed output (real):**

```text
addrust_parse('123 N Main St Apt 4, Springfield IL 62704')
→ street_number=123, pre_direction=N, street_name=MAIN, suffix=STREET,
  unit_type=APT, unit=4, city=SPRINGFIELD, state=IL, zip=62704

addrust_parse('Nienow Street')   -- FP street bait
→ street_name=NIENOW, suffix=STREET, city/state/zip NULL
```

**Mechanism for Closure:**

1. **Entity canonicalize** — store `addrust_parse(entity.text)` components on ADDRESS entities; match residual spans by house+street+zip instead of brittle full-string equality.
2. **Remainder scan address hits** — on multi-token remainder n-grams, parse; flag when `(house# OR po_box) AND (city OR zip)`; street-only (`suffix` set, no number/locality) → FP bait / NOT PII prior (aligns with “Feeney Street” judge logic).
3. **Corpus gen** (already noted in `docs/data-improvements.md`) — validate fakeit addresses have real suffix + ZIP/state coherence.

**Verdict: integrate now** — pure SQL, local, deterministic, directly improves address detection quality.

Spike: `spikes/ext-detection/01_address_parse.sql`.

---

### 5. `inflector` — no

| | |
|--|--|
| **Install** | `INSTALL inflector FROM community; LOAD inflector;` |
| **osx_arm64** | yes |
| **Key functions** | `inflector_to_plural/singular`, `inflector_to_*_case`, case predicates |

**Why no:** Name/OCR misses in this corpus are plants like `Robyn Prce` ← Price, spaced SSNs — not English pluralization. Case folding is already `lower()` / `upper()`.

---

### 6. `mlpack` — no

| | |
|--|--|
| **Install** | `INSTALL mlpack FROM community; LOAD mlpack;` |
| **osx_arm64** | yes |
| **Key functions** | `mlpack_random_forest_train/pred`, `mlpack_adaboost_*`, linear/logistic, `mlpack_kmeans` |

**Why no:** Needs feature tables + labels. We have no offline labeled FP dataset large enough to beat the deterministic rule panel. Model JSON in a side table fights the “pure SQL views at boot” architecture. Experimental MVP UI (table-name strings).

---

### 7. `stochastic` — no

| | |
|--|--|
| **Install** | `INSTALL stochastic FROM community; LOAD stochastic;` |
| **osx_arm64** | yes |
| **Key functions** | `dist_*_{pdf,cdf,sample,quantile,…}` for many distributions |

**Why no:** Judge design forbids `random()`; scores use `hash(suggestion_id)` jitter only. Probability distributions do not classify SSN vs citation.

---

### 8. `datasketches` — no

| | |
|--|--|
| **Install** | `INSTALL datasketches FROM community; LOAD datasketches;` |
| **osx_arm64** | yes |
| **Key functions** | HLL/CPC/Theta cardinality, KLL/t-digest quantiles, frequent items |

**Why no:** Cross-doc corroboration is `count(DISTINCT document_id)` on a few hundred rows. Approximate sketches shine at millions of events — we are not there. Exact is simpler and correct.

---

### 9. `bitfilters` — no

| | |
|--|--|
| **Install** | `INSTALL bitfilters FROM community; LOAD bitfilters;` |
| **osx_arm64** | yes |
| **Key functions** | `xor8/16_filter`, `binary_fuse*_filter`, `quotient_filter`, `*_contains` |

**Why no:** Approximate set membership of “already-seen entity text” is a join/`IN` list at our size. False positives are **exactly** what redaction review cannot afford without a second exact check — so you pay for exact anyway.

---

### 10. `hashfuncs` — no

| | |
|--|--|
| **Install** | `INSTALL hashfuncs FROM community; LOAD hashfuncs;` |
| **osx_arm64** | yes |
| **Key functions** | `xxh3_64/128`, `xxh64`, `rapidhash`, `murmurhash3_*` |

**Why no:** Excellent for hash joins / sketch keys; **not** for chain-of-custody. Non-cryptographic digests are wrong for legal “this PDF byte content is H” claims. Prefer core `sha256` / community `crypto`.

---

### 11. `crypto` — integrate now

| | |
|--|--|
| **Docs** | https://duckdb.org/community_extensions/extensions/crypto.html · query.farm |
| **Install** | `INSTALL crypto FROM community; LOAD crypto;` |
| **osx_arm64** | yes both |
| **Key functions** | `crypto_hash(algo, value)`, `crypto_hash_agg(algo, value ORDER BY …)`, `crypto_hmac(algo, key, message)`, `crypto_random_bytes(n)` |
| **Algos** | blake3, sha2-256, sha2-512, sha3-256, sha3-512, md5, sha1, … |

**Honest baseline:** provenance spikes already fingerprint PDFs with **core** `sha256(content)` from `read_blob`. That remains sufficient for simple “bytes changed?” checks.

**What `crypto` adds that is genuinely useful:**

| Mechanism | Use in Closure |
|-----------|----------------|
| `crypto_hash('sha2-256', content)` | Same as core for BLOBs; also blake3/sha3 policy choice |
| **`crypto_hash_agg(… ORDER BY …)`** | Deterministic **decision-log seal** over ordered accept/reject events |
| **`crypto_hmac`** | Export-manifest signature with a local signing secret (not in SQL args if you use env/app config) |
| `crypto_random_bytes` | Nonce / opaque export batch ids (not detection) |

**Mechanism (custody + audit):**

```sql
-- Per-source PDF fingerprint (hex for storage/display)
SELECT filename AS source_path,
       lower(hex(crypto_hash('sha2-256', content))) AS source_sha256,
       lower(hex(crypto_hash('blake3', content)))   AS source_blake3
FROM read_blob('samples/*.pdf');

-- Ordered seal over decisions (tamper-evident append log)
SELECT lower(hex(crypto_hash_agg(
         'sha2-256',
         concat_ws('|', kind, suggestion_id, status, actor, ts)
         ORDER BY ts, suggestion_id
       ))) AS decision_chain_seal
FROM decisions_log;
```

**Verdict: integrate now** for audit/custody (pair with provenance work), not as a PII detector.

Spike: `spikes/ext-detection/02_crypto_custody.sql`.

---

### 12. `json_schema` — spike later

| | |
|--|--|
| **Install** | `INSTALL json_schema FROM community; LOAD json_schema;` |
| **osx_arm64** | yes |
| **Key functions** | `json_schema_validate(schema, instance)`, `json_schema_validate_schema`, `json_schema_patch`, `json_schema_update` |

**Probed:** valid decision-shaped object → `true`; bad enum/types → throws validation error (fail-closed).

**Mechanism:** gate `read_json('exports/decisions/*.json')` rows against a frozen schema before dashboard counts; same for `identities.json` regeneration.

**Verdict: spike later** — real data-quality win, not detection. Lower urgency than address parse + custody seals.

---

### 13. `vindex` + core `vss` — no

| | |
|--|--|
| **vindex** | community ANN: HNSW / IVF / DiskANN / SPANN + quantizers |
| **vss** | core HNSW (`INSTALL vss; LOAD vss;`) |
| **osx_arm64** | both yes on 1.5.3 + 1.5.4 |
| **API** | `CREATE INDEX … USING HNSW (embedding)`; `ORDER BY array_cosine_distance(…)` rewrites |

**Why no for this app:**

1. Need embeddings first (`ai_embed` or external) — circular dependency on `ai` / network / model weights.
2. Detection targets are **structured** (SSN, phone, DOB, roster names), not “semantically similar paragraphs.”
3. Scale is hundreds of spans; exact joins + regex beat ANN.
4. Embedding PII of redaction subjects into a vector index is a sensitive data store you then have to protect.

**Verdict: no** until product explicitly wants near-duplicate page search at multi-GB corpora.

---

## Ranked “integrate now” list

| Rank | Extension | Primary hook in Closure | Effort |
|-----:|-----------|-------------------------|--------|
| **1** | **`crypto`** | Decision-log `crypto_hash_agg` seal + optional HMAC on export lineage; multi-algo PDF digests next to existing core `sha256` | Small — load at boot; macros in provenance/export path |
| **2** | **`us_address_standardizer`** | `addrust_parse` on ADDRESS entities + remainder n-grams; distinguish full address vs street-name FP bait | Small — pure scalar in seed/remainder_scan |

**Do not** integrate the rest without a new product requirement.

**Next (not integrate):** `json_schema` for decision JSON validation; `ai` only as a deliberate offline research spike with local Ollama and **no** PII egress.

---

## Spikes

| File | What it proves |
|------|----------------|
| `spikes/ext-detection/01_address_parse.sql` | `addrust_parse` on roster addresses + FP streets; residual-style full-address gate |
| `spikes/ext-detection/02_crypto_custody.sql` | PDF digests match core `sha256`; ordered decision-chain seal + HMAC over real `exports/decisions/` |

Run from repo root with DuckDB ≥ 1.5.4:

```bash
duckdb -unsigned -markdown :memory: < spikes/ext-detection/01_address_parse.sql
duckdb -unsigned -markdown :memory: < spikes/ext-detection/02_crypto_custody.sql
```

---

## Non-goals of this survey

- Does not modify `server/*` or wire extensions into `app.sql`.
- Does not re-run the webapp-extension survey (`docs/duckdb-webapp-extensions.md`).
- Does not replace finetype (already in remainder scan) or fakeit (corpus gen).
