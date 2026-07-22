# Observability assessment — Closure (prototype)

**Date:** 2026-07-19  
**Question:** Does this take-home need OpenTelemetry / metrics, or is that overkill?  
**Sources (read-only):**
1. Closure `docs/*`, `server/app.sql`, `server/schema.sql`, `server/routes/**`
2. quackapi request path — `/Users/aloksubbarao/personal/quackapi/src` (`quackapi_server.cpp`, extension, policy/state headers)
3. DuckDB community **`otlp`** extension (LOAD on 1.5.4; function catalog)
4. Existing measurement surfaces: `GET /api/stats`, boot summary, `tests/stress` `stress_metrics`, `docs/scaling-and-limits.md`, `docs/llm-judge.md`, `docs/scanned-docs.md`

**Write constraint:** this file only.

---

## Executive verdict

| Question | Answer |
|---|---|
| Does the prototype **need** OpenTelemetry / a metrics stack? | **No.** Overkill. |
| Does quackapi expose timing / metrics hooks today? | **No.** |
| Does the `otlp` community extension instrument the app for free? | **No** — it is an OTLP *collector / file reader*, not auto-instrumentation of `CREATE ROUTE`. |
| Is there anything tiny already in-scope that is “good enough”? | **Yes, already present:** boot summary + integrity asserts, `GET /api/stats`, triage funnel JSON, stress-harness timings, domain audit log. |
| Recommendation for the take-home | **Skip** OTel, skip `otlp`, skip a live `/metrics` pipeline. Keep offline/bench measurement where it already lives. |

**One line:** For a single-process demo whose singular requirement is *human funnel throughput + audit trail*, product counters and stress SQL already answer “is it working?”; full observability is a production ops problem, not a redaction-UX problem.

---

## 1. What already exists (do not reinvent)

### 1.1 Boot integrity + boot summary (`server/app.sql`)

At start:

- `ingest_orphan_diag()` + hard fail if `documents=0` or `suggestions=0`
- `SELECT 'boot summary' …` → cases / documents / words / entities / suggestions
- Per-filename suggestion counts printed to the console

That is **process liveness + corpus health** for a demo operator. If boot prints hollow stats, the app is wrong before any browser opens.

### 1.2 `GET /api/stats` (`server/routes/search.sql`)

```sql
CREATE OR REPLACE ROUTE api_stats GET '/api/stats' AS SELECT
    cases, documents, pages, words, entities, suggestions, v_suggestions;
```

Global counters only — not latency, not QPS, not export duration. Enough for “did re-ingest change the world?” smoke checks and UI sanity.

There is **no** Closure `/health` or `/metrics` route. quackapi’s own docs show a **recipe** (`CREATE ROUTE health GET '/health' AS SELECT 'ok'`) and deliberately **skip** a `CREATE PROBE` DDL feature (`docs/FEATURE_STATUS.md` — health = “Recipes only”). Closure never added even that one-liner; OpenAPI `/docs` + responding routes are the de facto liveness check.

### 1.3 Product “metrics” that matter more than infra

| Surface | What it measures | Why it is the real observability for this product |
|---|---|---|
| `GET /api/cases/:id/triage` | total / pending / auto_passable / residual by threshold | Funnel math for 1000+ suggestions |
| `GET …/triage/groups` | residual groups for batch judgment | Throughput residual, not p99 HTTP |
| `GET /api/documents/:id/scan`, case scan | OCR vs text-layer badges | Silent FN gap if image-only |
| Judge panel + `GET /api/suggestions/:id/judges` | ensemble votes | Ambiguity / flagged |
| Remainder / missed APIs | FN candidates | Catch false negatives |
| Decision JSONL + `v_audit` / history | Who did what when; undo | **Legal audit trail** (not request logs) |
| Provenance recheck | Custody / fingerprint drift | Chain-of-custody, not APM |

These are **domain signals**. A reviewer clearing a residual queue does not need Prometheus; they need residual count, group size, scan badges, and an append-only decision log they can undo.

### 1.4 Offline / bench measurement (already the right tool)

| Tool | Location | Shape |
|---|---|---|
| `stress_metrics` table | `tests/stress/00_setup.sql` | `step, status, wall_ms, n, n2, mem_mb, spill_mb, …` |
| Export of same | `07_export_metrics.sql` → CSV/JSON under `samples/stress/` | CI / `pdf-stress` narrative |
| External HTTP storms | `docs/scaling-and-limits.md` | decision QPS, p50/p95 via client-side timing |
| LLM judge | `docs/llm-judge.md` + spike | ~0.3–0.6 s/item, batch wall |
| Boot / tradeoff smoke | `docs/tradeoff-analysis.md` | live suggestion counts, RSS notes |

Pattern: **measure hard paths offline with SQL `epoch_ms(now())` deltas or curl**, write a row or a doc, move on. That matches a one-DuckDB-process prototype better than a always-on scrape target.

---

## 2. quackapi request handling — timing / metrics hooks?

**Source:** `quackapi_server.cpp` `HandleRequest` (~866–1860+).

Request path (simplified):

1. CORS / built-in OpenAPI `/docs` / `/openapi.json` / `/redoc`
2. Match `CREATE ROUTE` / stream by method + path
3. Auth / row-policy rewrite (if configured)
4. `Connection(*db)` → `Prepare(handler_sql)` → bind path/query/body params
5. `Execute` → **fully materialize** all rows into memory
6. Serialize body (`html` / `text` / JSON array) → set status → return

What exists that *sounds* like observability but is not:

| Feature | Reality |
|---|---|
| `std::chrono` includes | JWT expiry, stream poll sleep — **not** request duration |
| `fprintf(stderr, "quackapi: …")` | Error paths only (conversion, client-input → 422, etc.) |
| `group.policy` / middleware name on state | Comment: **“Seam for future shared policy / middleware … Unused in v1”** (`quackapi_state.hpp`) |
| Built-in health / metrics routes | **None** (OpenAPI only among built-ins) |
| `Server-Timing` / `X-Request-Id` / access log | **None** |
| Per-route timing registry | **None** |

**Conclusion:** quackapi does **not** expose timing or metrics hooks an app can opt into. You cannot “turn on request latency” with a setting. Any live latency series today means **wrapping outside** (curl, Playwright timings, OS tools) or **instrumenting inside the extension C++** (out of Closure’s take-home scope).

---

## 3. Community `otlp` extension — what it actually is

Probed on DuckDB **1.5.4** (`INSTALL otlp FROM community; LOAD otlp`):

| Surface | Functions (sample) |
|---|---|
| Live ingest server | `otlp_serve`, `otlp_stop`, `otlp_flush`, `otlp_server_list`, `otlp_seal_list` |
| File / lake readers | `read_otlp_traces`, `read_otlp_logs`, `read_otlp_metrics*` , `read_otap_*` |

Also noted in `docs/ext-survey-platform.md`:

> **otlp — No (now); Maybe (ops later).** This is an **OTLP collector/query surface**, not automatic instrumentation of quackapi handlers. Wiring would mean a second protocol port + exporter from the server — quackapi does not emit OTLP today.

Implications for Closure:

1. Loading `otlp` into the same process does **nothing** to `CREATE ROUTE` latency.
2. `otlp_serve(…)` is a **second HTTP listener** waiting for OTLP payloads from something that already speaks OpenTelemetry.
3. There is no emitter: no spans for “review page tera_render”, no histograms for “export pdf_redact”.
4. Sibling `rawduck` is another telemetry-lake kit — same “wrong product” class for a redaction funnel demo.

**Using `otlp` here would be gold-plating a collector with no producer.** Skip.

---

## 4. What would actually be worth measuring (product-shaped)

Aligned to the singular requirement (clear 1000+ suggestions / 1000+ pages via funnel + residual hand-review + FN catch + audit/revert):

| Signal | Why it matters | Cheap way today |
|---|---|---|
| **Funnel residual size** (auto-pass vs residual groups) | Is the human queue small enough? | Already: triage routes + UI |
| **Suggestion / page / doc counts** | Corpus scale, re-seed drift | Already: boot summary, `/api/stats`, `v_document_stats` |
| **Decision / bulk / undo rates** | Human throughput, not HTTP QPS | Already: decision JSONL + audit views; count files / `v_decision_log` |
| **Route latency (review HTML, suggestions JSON, search)** | Interactive feel; heavy HTML is the known p95 driver (`scaling-and-limits`) | Client `curl -w '%{time_total}'` or Playwright; **not** OTel required |
| **Export wall time + box count** | Redact of multi-doc cases can dominate | Time the POST export once; log row into stress_metrics style table **if** debugging export |
| **OCR fallbacks** | Silent zero-suggestion pages | Already: scan status + badges; count `source='ocr'` words |
| **Judge throughput** | Optional second-opinion cost | Spike already: Ollama `total_duration`; keep offline |
| **Memory ceiling after serve** | 256 MB stomp footgun | `current_setting('memory_limit')` after boot; documented |

What is **not** worth measuring in the prototype:

- Distributed traces across services (there is one process)
- Multi-tenant RED/USE dashboards
- Cardinality-heavy per-suggestion histogram series
- Alert managers, Grafana, OTLP collectors

---

## 5. Cheapest ways in a one-DuckDB-process app

Ranked by cost / honesty for *this* architecture:

| Approach | Cost | Fit for take-home | Notes |
|---|---|---|---|
| **A. Do nothing new** — use boot + `/api/stats` + triage + stress SQL + external curl | Zero | **Best** | Already answers demo + scale narrative |
| **B. Tiny enrichment of `/api/stats`** (pending by band, OCR doc count, `memory_limit`) | ~10 lines SQL | Optional polish only | Still not latency; not OTel |
| **C. App-level `metrics` table + `INSERT` from hot routes** | Medium | Poor | Routes are pure SELECTs / COPY; wrapping every handler with before/after `epoch_ms` is noisy and mutates the golden “handler = query” model |
| **D. Live `GET /metrics` Prometheus text** | Medium–high | Overkill | Needs scrape target, series design, no alert consumer in demo |
| **E. `otlp` extension + external collector** | High | **Wrong tool** | No emitter; second port; ops theater |
| **F. Patch quackapi for Server-Timing / access log** | High (C++) | Platform work, not Closure take-home | Correct long-term if quackapi is productized |

**Cheapest latency story that already works:** the scaling doc’s client-side timing of decision POSTs and review GETs. For PDF/export, the stress harness’s `wall_ms` columns. Both keep measurement **out of the request hot path**.

---

## 6. Honest recommendation

### Prototype (this assignment)

**Skip OpenTelemetry, skip the `otlp` extension, skip a production-style metrics pipeline.**

Reasons, stacked:

1. **Single process, local demo** — no service mesh, no multi-node fan-out, no on-call rotation.
2. **The product already exposes the metrics that matter** (funnel residual, scan/OCR, audit, suggestion counts).
3. **quackapi has no timing hooks** — any “real” APM means either external clients or C++ work outside the assignment.
4. **`otlp` does not instrument SQL routes**; loading it is cargo-cult observability.
5. **Hard paths are already measured offline** (stress_metrics, scaling experiments, judge spike).
6. Gold-plating a `/metrics` table would consume time better spent on funnel UX, FN remainder quality, or export correctness — the actual singular requirement.

If a reviewer asks “how do you know export is slow?”, point at a one-off timed export and `docs/pdf-stress.md` / `stress_metrics`, not a Grafana panel.

### Optional one-liner only if you touch routes anyway

Not required. If a health check is demanded for packaging:  
`CREATE ROUTE health GET '/health' AS SELECT 'ok' AS status, current_setting('memory_limit') AS memory_limit;`  
That is a **liveness recipe**, not observability. Do not expand it into a metrics product.

---

## 7. In production I’d add OTel + these spans (rationale paragraph)

In production—with multi-reviewer sessions, real FOIA SLAs, and a split of HTTP tier + object storage + Postgres (or DuckDB as a geometry/analytics side-engine only)—I would instrument the app server with OpenTelemetry: root span per HTTP request (method, route template, status, duration); child spans for `v_suggestions` / triage projection, tera HTML render, `pdf_redact` / export package build, OCR ingest, and any LLM-judge batch (items, model, latency, error rate); plus RED metrics on decision/bulk/export endpoints and gauges for residual queue depth and OCR-gap page counts. Export via OTLP to the agency’s collector (or cloud APM), with sampling on high-QPS GETs and always-on traces for export and bulk mutations. That stack earns its keep once you have multi-node deploys, real incident response, and SLO burn alerts; it is pure overhead on a single-process take-home whose “collector” would have nothing to scrape and no pager to wake.

---

## Bottom line

| | |
|---|---|
| **Need OTel / metrics for the prototype?** | **No — overkill.** |
| **Need `otlp` extension?** | **No.** |
| **Need quackapi timing hooks?** | They **don’t exist**; don’t invent a fake layer in SQL. |
| **What to rely on instead** | Boot integrity/summary, `/api/stats`, triage funnel, scan/OCR badges, append-only audit, stress_metrics + external timing for hard paths. |
| **Prod story** | §7 above — real OTel on a real app tier when there is something multi-instance to operate. |
