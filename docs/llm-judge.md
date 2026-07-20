# Local-LLM judges — spike report

**Date:** 2026-07-19  
**Scope:** `spikes/llm-judge/**` only — **not** wired into `server/` or boot.  
**Product frame:** humans must clear ~800–3000 AI redaction suggestions fast; deterministic Pattern/Context/Prior ensemble already triages. This spike asks whether a **local** LLM can usefully second-opinion **flagged residuals**.

**Related:** `docs/detection-design.md` (judge ensemble), `docs/ext-survey-detection.md` (`ai` section — “spike later”).

---

## Honest verdict

| Decision | **demo-flag** |
|----------|----------------|
| Ship into boot / replace ensemble? | **No** |
| Skip entirely? | **No** — tech works; useful as a *demoable optional chip* |
| Promote when? | Only if Ollama is a deliberate deploy dep, model ≥~7B, async queue, and UI treats votes as advisory chips — never as `panel_signal` input |

**One line:** Local Ollama judges **work** from DuckDB SQL, cost **$0**, latency **~0.3–0.6 s/item**, quality is **model-sensitive** (qwen2.5:7b matched deterministic gold on 11/11; llama3.2:3b **missed subject name + address**). Deterministic ensemble remains the throughput engine.

---

## What we ran

### Call paths (both proven)

| Path | Status | Detail |
|------|--------|--------|
| **`http_client`.http_post** → `http://127.0.0.1:11434/api/generate` | **Preferred** | Body is JSON; model/prompt **per row**; Ollama returns `total_duration` |
| Community **`ai`** extension (`ai_classify` / `ai_complete`) | **Works** | `SET duckdb_ai_provider='ollama'`, `duckdb_ai_base_url='http://127.0.0.1:11434'` |
| `ai_classify(..., model := column)` | **Fails** | Binder: *AI option "model" must be a constant expression* — use `SET duckdb_ai_model` between batches or prefer http_post |

Probe script: `spikes/llm-judge/01_probe_paths.sql`.

### Fixture (real app data)

11 suggestions pulled from live `http://127.0.0.1:8117` (cases 1–4) + deterministic votes from `GET /api/suggestions/:id/judges`:

| Class | Examples | Deterministic majority | Expected (gold for spike) |
|-------|----------|------------------------|---------------------------|
| Flagged citations | `Feeney/Schmidt/Doyle v. Ohio,` | keep | keep |
| Street FP (review) | `Feeney Street`, `Schmidt Street` | keep | keep |
| Officer FP | `Det. R. Feeney #8086` | keep | keep |
| True PII controls | SSN, DOB, subject name, phone, address | redact | redact |

Corpus note: seed `band=flagged` is almost all **citations** with panel `agree`/keep (low seed confidence, not judge conflict). True “split/conflict” residuals are rare in this demo data — LLM value is higher on those if/when they appear.

Fixture: `spikes/llm-judge/fixture.json`.

### Independent judges (requirement: 2 models × prompts)

| Key | Model | Prompt | Path |
|-----|-------|--------|------|
| `llama32_foia` | **llama3.2:3b** | Long FOIA rule list (citations/streets/officers → keep; SSN/… → redact) | http_generate |
| `qwen25_brief` | **qwen2.5:7b** | Short triage JSON prompt | http_generate |
| `llama32_ai_classify` | llama3.2:3b | Short classify (control) | `ai_classify` |

Runner: `spikes/llm-judge/02_run_judges.sql` → `spikes/llm-judge/out/*.csv`.

---

## Does it work?

**Yes.** End-to-end from DuckDB:

1. Load `http_client` / `ai`
2. Build prompt from `text` + `kind` + `context`
3. Call local Ollama (no cloud, no API key)
4. Parse `verdict` / `score` / `reason`
5. Join to deterministic panel for comparison

Full batch (11 items × 3 configs = 33 model calls) completed in **~11 s wall** on this machine with models warm.

---

## Latency per item

Measured from Ollama `total_duration` on the **http_generate** path (warm models, `temperature=0`, `num_predict≤100`, `format=json`):

| Judge | Model | n | avg | min | max |
|-------|-------|---|-----|-----|-----|
| `llama32_foia` | llama3.2:3b | 11 | **~334 ms** | 290 ms | 390 ms |
| `qwen25_brief` | qwen2.5:7b | 11 | **~466 ms** | 375 ms | 567 ms |

`ai_classify` control (11 items, max concurrent 1): wall **~1.8 s** total ≈ **~165 ms/item** average (no per-row duration exposed as cleanly).

### Throughput math (product-critical)

Assume **800 flagged residuals**, **two** local judges, sequential-ish:

```text
800 × 0.45 s × 2 ≈ 720 s ≈ 12 minutes
```

Even at 4-way concurrency: still multi-minute jobs. That **cannot** sit on the hot path for bulk clear. It **can** fill an async chip queue while the human works grouped entities.

Cold start (first load of a 7B model) adds multi-second / multi-ten-second spikes — not measured as steady-state above (models were already resident).

---

## Quality vs deterministic judges

### Agreement with expected gold (this fixture)

| Judge | % agree expected | % agree det majority | Failures |
|-------|------------------|----------------------|----------|
| **qwen25_brief** | **100%** (11/11) | **100%** | — |
| llama32_foia | 81.8% (9/11) | 81.8% | subject name + address → **keep** (false clear) |
| llama32_ai_classify | 63.6% (7/11) | 63.6% | over-redact streets/citations |

### Failure modes that matter for redaction

1. **Unsafe keep (false negative for protection)** — llama3.2:3b + FOIA rule prompt labeled **`Hilbert Feeney`** and **`6396 Maple St,`** as *keep*, reason: *“Street name shares surname with no house number…”* — the long “street surname” rule **over-fired** onto a real subject name and a real house address. In production that ships PII. **Disqualifies 3B as a sole judge.**
2. **Unsafe redact (false positive)** — `ai_classify` with 3B redacts citations/streets the deterministic panel correctly keeps → adds human work, opposite of the funnel.
3. **Score unreliability** — same model returned `score: 0` with `verdict: redact` on SSN (verdict right, score garbage). Do not sort the queue on LLM score.
4. **Non-determinism / prompt fragility** — a second `ai_classify` pass (slightly different prompt wording) flipped **SSN → keep** on a re-run. Deterministic SQL judges never do this. Audit trail requires storing **model id + prompt version + raw response** every time.
5. **Safety refusals** — `ai_complete` on llama3.2:3b sometimes **refuses** SSN-adjacent prompts (“I can’t provide information or guidance on redacting social security numbers…”) instead of returning judge JSON. Prefer `format: json` generate with a tight schema, and treat non-JSON / refusal text as `unsure` + error log — never as `keep`.

### Where LLM could still help

- **Split/conflict panels** (not common in current seed) — narrative context the SQL heuristics miss.
- **Messy OCR / variant spellings** outside roster regex (remainder scan already covers spaced/dotted SSN).
- **Demo theater** — “local AI second opinion” chip next to Pattern/Context/Prior.

On **this** corpus, deterministic keep/redact already matches gold for the residual FP classes (citations, streets, officers). LLM does not unlock bulk groups the SQL judges already clear.

---

## Cost story

| Item | Hosted API | **This spike (local Ollama)** |
|------|------------|-------------------------------|
| Token $ | Non-zero × hundreds of suggestions | **$0** |
| PII egress | **Legal hazard** for a redaction product | **None** (localhost) |
| Ops | API keys, secrets, rate limits | Model download (~2–5 GB), CPU/GPU, always-on `ollama serve` |
| Reproducibility | Provider drift | Model tag drift (`llama3.2:3b` digest) — pin digests if ever audited |

**All-local is the only acceptable cost/privacy story.** Hosted judges are out of scope for Closure (see ext survey).

---

## Integration shape if promoted

### When to run

```text
boot → seed → deterministic judge.sql  (always, free, deterministic)
     → remainder_scan                  (FN catcher)
     → serve UI

async (optional):
  residual = flagged band OR panel split/conflict
  enqueue residual → local LLM judges → advisory chips only
```

**Never:** boot-path CTAS for all ~1.3k suggestions.  
**Never:** change `panel_signal` or auto-accept from LLM alone.  
**Never:** block export on LLM completion.

### Preferred mechanism

```sql
-- per residual row (batch ≤32)
http_post(
  'http://127.0.0.1:11434/api/generate',
  map {'Content-Type': 'application/json'},
  {
    'model': 'qwen2.5:7b',          -- ≥7B; avoid 3B as sole judge
    'prompt': <macro>,
    'stream': false,
    'format': 'json',
    'options': {'temperature': 0, 'num_predict': 100}
  }::JSON
)
```

Persist like decisions: **one JSON file per vote** under `exports/llm_votes/` (append-only, no INSERT setup path), read back with `read_json`. Include `model`, `prompt_style`, `raw_json`, `latency_ms`, `ts`.

### Async queue (quackapi)

quackapi exposes `CREATE QUEUE` + enqueue/dequeue/ack (see `docs/quackapi-feasibility.md`). Sketch:

```text
CREATE QUEUE llm_judge_jobs;
UI or post-boot SQL → quackapi_enqueue(suggestion_id, model)
Worker process / cron tick → dequeue → http_post → COPY vote JSON → ack
GET /api/suggestions/:id/llm-judges → rows from read_json glob (empty until ready)
```

Full sketch (not loaded): `spikes/llm-judge/sketch_routes_judge_llm.sql`.

### UI contract (if demo-flagged)

- Chip: **`LLM · local`** with verdict + one-line reason (same density as Pattern/Context/Prior).
- Badge: **advisory** — does not change band alone.
- Only request for items already in the **human residual queue** (or explicit “Ask local judges” action).
- Grouped bulk view stays SQL/entity driven; LLM is per-span enrichment, not the group key.

---

## Relation to product funnel

```text
~3k suggestions
  → high-confidence auto-pass + bulk groups     ← deterministic ensemble (keep)
  → residual ~800 human review (grouped)        ← LLM optional async chip HERE only
  → false-negative rail                         ← remainder_scan (keep); LLM not needed
```

Everything still serves **throughput + auditability**:

| Requirement | Deterministic panel | Local LLM spike |
|-------------|---------------------|-----------------|
| Throughput | Instant CTAS | ~0.3–0.6 s/item — async only |
| Auditability | Fully reproducible | Needs model pin + raw response log |
| FP bulk clear | Already strong on citations/streets/officers | Redundant when panel agrees keep |
| Safety | No PII egress | Local OK; 3B unsafe keeps measured |

---

## Reproduce

```bash
# Ollama
ollama list   # need llama3.2:3b and qwen2.5:7b (or pull)

cd /Users/aloksubbarao/personal/closure
duckdb -unsigned -markdown :memory: < spikes/llm-judge/01_probe_paths.sql
rm -f spikes/llm-judge/out/run.duckdb
duckdb -unsigned spikes/llm-judge/out/run.duckdb < spikes/llm-judge/02_run_judges.sql
# inspect spikes/llm-judge/out/comparison.csv latency_summary.csv
```

---

## Bottom line

| Question | Answer |
|----------|--------|
| Does it work? | **Yes** (DuckDB → local Ollama via http_client **or** `ai` extension) |
| Latency / item | **~300–500 ms** warm (3B–7B generate); batch 800 is **minutes**, not interactive |
| Quality vs det judges | **qwen2.5:7b matched 100%** on fixture; **3B is unsafe** (missed subject/address) |
| Cost | **$0** tokens; ops cost is model + Ollama |
| Integration | Residuals only, **async queue**, advisory chips, pin model, store raw votes |
| **Verdict** | **demo-flag** — show in a spike/demo; do **not** ship as boot ensemble or sole triage |
