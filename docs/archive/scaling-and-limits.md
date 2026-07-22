# Scaling and limits — prototype vs production

**Date:** 2026-07-19  
**Scope:** Closure (`DuckDB + quackapi + pdf + tera`)  
**Method:** source read of quackapi (`/Users/aloksubbarao/personal/quackapi/src`) + live HTTP/SQL experiments against a seeded `closure.db` (11 docs, 22 247 words, 1 328 suggestions, 4 cases).  
**Write constraint:** this file is the only write for this investigation.

---

## Executive verdict

| Question | Honest answer for *this* app |
|---|---|
| “Don’t use DuckDB for OLTP” — does it kill Closure? | **No, not at reviewer scale.** Decision POSTs are append-only, tiny, and (in-process) concurrent. |
| Where does DuckDB actually bite? | **Multi-process writers** (file lock), **not** “many simultaneous accept/reject in one process.” |
| Where does the stack actually bite? | **quackapi 256 MB serve stomp**, **shared global memory pool**, **full response buffering**, **HTML render CPU**, **`v_suggestions` cost growing with decision JSON file count**, **huge-PDF open RSS ≈ file size**, **unsigned custom extension**, **no real multi-user auth/session product surface**. |
| Would this architecture hold for a few clerks on one agency’s caseload? | **Yes, with boot discipline (raise memory after serve) and page-scoped routes.** |
| Would I ship it as multi-tenant SaaS / multi-node prod? | **No.** Move HTTP + object storage + Postgres (or keep DuckDB as analytics/PDF engine only). |

**One-line product verdict:** For interactive accept/reject by a handful of reviewers on case-sized corpora, DuckDB is fine; the failure modes are the HTTP shell’s memory policy, single-process coupling, and full-document/PDF work — not classic OLTP row-lock contention.

---

## 0. Prototype vs production framing

Closure is a **single-process prototype**:

```
Browser ──HTTP──► quackapi (httplib, 32 workers)
                      │
                      ├─ Connection-per-request on ONE DuckDB instance
                      ├─ tera_render → full HTML string body
                      ├─ pdf extension (geometry / redact)
                      └─ mutations: COPY → exports/decisions/*.json  (append-only events)
```

Production expectations people smuggle in (HA, multi-writer clusters, per-tenant isolation, streaming multi-GB downloads, SOC2 session/auth, unsigned-extension policy) are **not** what this process is designed for. The right evaluation is:

1. Does the *workload shape* match DuckDB’s strengths?  
2. Where do *measured* limits show up before theoretical ones?  
3. What would you change if a real records division depended on it?

---

## 1. “Don’t use DuckDB for OLTP” — why people say it, and what we measured

### 1.1 Why the claim exists (and which parts are real)

People say “DuckDB is not for OLTP” because of a cluster of true design choices, not one myth:

| Claim | What it actually means | Relevant to Closure? |
|---|---|---|
| Analytical engine, columnar, vectorized | Optimized for scans/aggregations, not millions of tiny point updates/sec with row-level locking | Weakly — decisions are rare human events |
| **Single-writer / one process holds the DB file** | Another process cannot open the same file for write; `Conflicting lock is held…` | **Yes for ops** (no second app server writing the same file) |
| No multi-node consensus / connection pooling across machines | Not Postgres/MySQL | Yes if you scale out HTTP workers as separate processes |
| MVCC + optimistic conflicts | Concurrent updates of the *same row* can conflict; not a row-lock OLTP scheduler | Weakly — Closure doesn’t UPDATE suggestion rows |
| WAL/checkpoint behavior under write bursts | Different from InnoDB; large write batches shine, pathological high-QPS single-row churn does not | Unimportant at human click rates |

DuckDB docs and community guidance target **OLAP / embedded analytics**. That is correct as *positioning*. It is **not** a proof that a few concurrent `INSERT`/`COPY` handlers inside one process will melt.

### 1.2 What Closure actually does for “writes”

Runtime decisions are **not** `UPDATE suggestions SET status=…`. They are **append-only events**:

```sql
-- server/routes.sql (simplified)
POST /api/suggestions/:id/decision
  → COPY (SELECT 'decision', $id, $status, …)
    TO 'exports/decisions'
    (FORMAT JSON, FILENAME_PATTERN 'dec_{uuid}', …)
```

Status is a **projection** (`v_suggestions` / `v_latest_decision` over `exports/decisions/*.json` ∪ seed tables). That is closer to event sourcing than classic OLTP CRUD.

### 1.3 Experiments (live quackapi on port 8127, memory raised to ~3.7 GiB after serve)

Hardware context: local macOS arm64, DuckDB **1.5.4**, quackapi built from source, DB snapshot with **1 328 suggestions / 22 247 words**.

#### A. Multi-process writers (the real DuckDB OLTP footgun)

10 processes each trying to `INSERT` into the same `.db` file:

| Result | Value |
|---|---|
| Workers succeeding | **2 / 10** |
| Workers failing | **8 / 10** |
| Error | `IO Error: Could not set lock on file "…": Conflicting lock is held in …/duckdb (PID …)` |
| Wall for the race | ~48 ms (failures are fast) |

While the HTTP server held `serve.db`, a second Python `duckdb.connect(serve.db)` failed with the same lock error.

**Verdict:** multi-process multi-writer is **not supported**. This is the core of the OLTP warning. Closure’s architecture (one duckdb process = web + DB) sidesteps it — until you try to run two servers on one file or scale-out app replicas.

#### B. Same-process concurrent table `INSERT` via quackapi (unique PKs)

Route shape: `INSERT INTO oltp_http … RETURNING id, worker` (validated at `CREATE ROUTE`).

| Concurrency | N | OK | Fail | Wall | QPS | p50 ms | p95 ms | p99 ms |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 worker | 500 | 500 | 0 | 0.74 s | **676** | 1.37 | 2.12 | 2.87 |
| 4 workers | 500 | 500 | 0 | 0.23 s | **2227** | 1.70 | 2.59 | 3.71 |
| 16 workers | 1000 | 1000 | 0 | 0.29 s | **3501** | 4.28 | 7.15 | 8.63 |
| 32 workers | 2000 | 2000 | 0 | 0.58 s | **3478** | 8.41 | 15.30 | 19.74 |

Append-only `INSERT INTO audit_events … RETURNING id` (sequence PK, no client-chosen id):

| Concurrency | N | OK | QPS | p50 ms | p95 ms |
|---|---:|---:|---:|---:|---:|
| 1 | 100 | 100 | 708 | 1.39 | 1.91 |
| 8 | 200 | 200 | **3518** | 2.19 | 2.95 |
| 16 | 400 | 400 | **3483** | 4.12 | 7.50 |

When the same id range was reused across waves, failures were **only** `Constraint Error: Duplicate key "id: …" violates primary key` → HTTP 500 — **not** lock timeouts and **not** “single writer queue full.”

**Verdict:** inside one DuckDB instance (exactly quackapi’s model: `Connection con(*db)` per request), concurrent append inserts are healthy at **thousands of QPS** with single-digit–low-double-digit millisecond latency. That is orders of magnitude above “a few reviewers mashing `a`/`r`.”

#### C. Closure’s real mutation path: concurrent `COPY` decision files

| Concurrency | N | OK | QPS | p50 ms | p95 ms | p99 ms |
|---|---:|---:|---:|---:|---:|---:|
| 1 | 100 | 100 | 473 | 1.80 | 2.82 | 21.61 |
| 4 | 200 | 200 | **2236** | 1.65 | 2.48 | 3.20 |
| 20 | 500 | 500 | **3487** | 5.02 | 9.40 | 16.73 |

Real route `POST /api/suggestions/:id/decision`:

| Concurrency | N | OK | QPS | p50 ms | p95 ms |
|---|---:|---:|---:|---:|---:|
| sequential | 50–100 | 100% | ~500–550 | **1.7–2.0** | ~2–4 |
| 4 workers | 200 | 200 | **1657–2017** | **1.9–2.3** | ~3 |
| 20 workers | 500 | 500 | **2871–3900** | **4.8–6.3** | ~7–11 |

**Zero failures** across these decision storms. Latency stays interactive.

#### D. Concurrent read + write (latency under load)

| Workload | Result |
|---|---|
| 24 workers mixing `INSERT` + light `GET`s (n=1200) | **1200/1200 OK**, ~4.5 k QPS, p50 ≈ 4.9 ms |
| 20% decision POST + 80% stats/page GET (n=500, 20 workers) | **500/500 OK**; light paths stay ~ms; heavy stats dominate the high percentiles (p95 ~1.4 s) |
| HTML review page + decision mix (12 workers, n=60) | **60/60 OK**; decisions still ~ms (min observed ~2.6 ms); HTML drives p50 ~2.1 s / p95 ~5.3 s |

**Writes do not collapse under concurrent reads.** Heavy *reads* (status projection, tera HTML) dominate p95/p99.

#### E. Python single-connection microbench (for scale context)

| Pattern | Result |
|---|---|
| 5000 single-row inserts, one connection | ~3017 QPS, ~0.33 ms/insert average |
| 5000-row batch `INSERT…SELECT range` | ~1.5 M “rows/s” (batch, not HTTP) |

### 1.4 Where OLTP lore bites *this* app vs where it doesn’t

| Scenario | Bites? | Symptom |
|---|---|---|
| 1–10 reviewers, keyboard accept/reject, one process | **No** | p50 decision ~2–6 ms even at artificial 20-way concurrency |
| Two app servers / two duckdb processes on one `closure.db` | **Yes** | Immediate file lock `IO Error` |
| High-frequency `UPDATE` of the same suggestion rows from many clients | Untested / wrong model | Would need conflict handling; Closure avoids this with events |
| Multi-tenant SaaS, many orgs, horizontal HTTP pods | **Yes** | Cannot share one writeable DuckDB file across pods |
| Millions of tiny debit/credit transactions /sec | **Yes (wrong tool)** | Not Closure’s workload |

**OLTP verdict for Closure:** the slogan is **directionally right for multi-process / multi-node writers** and **wrong as a scare story for this interactive, append-only, single-process review UI**. Measured decision throughput under stress is ~**3k QPS** with p50 &lt; 10 ms — a human team will never approach that on the mutation path.

---

## 2. quackapi / quack limits (concrete)

### 2.1 Memory hard-cap — confirmed in source

`quackapi/src/quackapi_extension.cpp` — `ApplyServeResourceGuards`:

```cpp
// Cap memory so a single range()/hash join cannot OOM the host.
auto res = con.Query("SET memory_limit TO '256MB'");
```

Called unconditionally from `ServeExec` before `StartServer`.

| Observation | Value |
|---|---|
| Literal cap | **`256MB`** (not configurable in serve args today) |
| Effective display after set | **`244.1 MiB`** (`current_setting('memory_limit')`) |
| Scope | **Database-global** buffer pool — not per HTTP worker |
| Pre-serve `SET memory_limit='4GB'` | **Overwritten** at serve |
| Post-serve `SET memory_limit='4GB'` | **Sticks** for subsequent handlers |
| Empirically | `before_serve = 3.7 GiB` → `after_serve = 244.1 MiB` |

Closure’s `server/app.sql` re-raises after serve; **`run.sh` phase 3 does not** (boot via `run.sh` alone leaves the hostile cap). See also `docs/backend-oom-and-fastapi.md`.

### 2.2 Concurrency model / thread pool

From `quackapi_server.cpp`:

| Knob | Value |
|---|---|
| Worker pool | **`ThreadPool(32)`** (`new_task_queue`) |
| Keep-alive | max **128**, timeout **10 s** |
| Per request | **new `Connection(*db)`**, prepare handler SQL, execute |
| Route registry | In-process, **not durable** across process restart |

Implications:

- Up to ~32 handlers can run queries **concurrently** on one DuckDB.
- They share **one** `memory_limit` pool — one fat query starves siblings.
- DuckDB `threads` (Closure sets **4**) further bounds parallel operators inside each query.

### 2.3 No streaming responses

Handler results are **fully materialized** into a `vector` of rows, then concatenated into one `res.body` string (`quackapi_server.cpp` ~1479–1547). HTML mode concatenates the `html` column; JSON builds a full array string.

| Evidence | |
|---|---|
| Review page response | `Content-Length: 48417` (fixed length, fully buffered) |
| Consequence | Large JSON dumps or accidental whole-doc HTML allocate twice (engine + HTTP body) |

There is a comment that multi-row `html` fragments are “concatenated… so a query returning fragments streams a page” — that is **SQL-side chunking into one body**, not HTTP chunked transfer to the client.

### 2.4 Request size limits

```cpp
// quackapi_server.hpp
static constexpr size_t QUACKAPI_PAYLOAD_MAX_LENGTH = 8ull * 1024ull * 1024ull; // 8 MiB
server->set_payload_max_length(QUACKAPI_PAYLOAD_MAX_LENGTH);
```

Empirical: ~9 MiB JSON body → **HTTP 413** (empty body).

Fine for decision POSTs (`{}` + query params). Insufficient as a raw PDF upload API without chunking/out-of-band storage.

### 2.5 Auth / session gaps

quackapi **has** `CREATE AUTH` (API key, JWT HS256) and per-route `REQUIRE` — but Closure routes are **public** by default.

Measured:

| Request | HTTP |
|---|---|
| `GET /` without credentials | **200** |
| `POST …/decision` without credentials | **200** |

No session store, no CSRF model, no per-reviewer identity unless you add `CREATE AUTH` + wire `actor` from claims. Prototype-acceptable; **prod-unacceptable** for law-enforcement case data.

### 2.6 Unsigned / unpublished extension

| Fact | |
|---|---|
| Load path | `duckdb -unsigned` + path to local `quackapi.duckdb_extension` |
| Distribution | **Not** on DuckDB community extensions CDN (unlike `pdf` / `tera`) |
| Binary | Custom-built shell + extension (~28 MB dylib, arm64) |
| Deploy cost | Pin DuckDB version (here **1.5.4**), build pipeline, code-sign policy, no `INSTALL quackapi FROM community` |

This is a real production tax independent of query performance.

### 2.7 Other shell limits that matter

| Limit | Detail |
|---|---|
| Routes non-durable | Restart must re-`LOAD` + re-`.read routes.sql` |
| Handler SQL | Must prepare cleanly; broken routes fail at `CREATE ROUTE` |
| INSERT-in-subquery | `SELECT … FROM (INSERT …)` rejected by DuckDB parser; top-level `INSERT … RETURNING` works as handler |
| Static mount | `static_dir` via httplib; API routes win over files |
| CORS | Off unless `cors_origins` set |

---

## 3. Failure boundary — when *this* architecture breaks

### 3.1 Workload axes

| Axis | Current prototype | Starts to hurt | Hard break / redesign |
|---|---|---|---|
| **Reviewer concurrency** | 1–few humans | ~10 simultaneous HTML-heavy sessions (CPU + memory) | Multi-node active-active writers on one file (**impossible**) |
| **Decision QPS** | ≪ 10/s | Still fine at 100s–1000s/s (measured) | Not the limiting axis |
| **Suggestions / case** | ~1.3 k total | UI triage + `v_suggestions` projection over growing decision file set | Tens–hundreds of k events as **per-request glob/scan** of JSON decisions |
| **Words / pages** | 22 k words, ≤110 pages/doc | Page-scoped SQL still OK if ingested | Full-corpus unscoped renders; seed/n-gram over multi-M words |
| **PDF file size** | Samples small; stress corpus to **~709 MiB / 130 k pages** exists under `samples/stress/` | `pdf_info` / open ≈ **file-size RSS** | Interactive `pdf_redact` / ingest of multi-hundred-MB PDFs in the UI process |
| **Decision files on disk** | Experiment left **~2.6 k** JSON files (~10 MB) | `v_suggestions` / stats p50 **~70–100 ms** seq, **~1 s** under 16-way concurrency | Directory-as-log does not replace a table/index |
| **Process RSS** | Idle serve ~130 MiB | After HTML storms **~0.6–2.5 GiB** observed under 4 GB cap | Concurrent fat renders under **244 MiB** cap → OOM 500s |
| **memory_limit** | Must be raised post-serve | 256 MB + review HTML → flaky OOM (`failed to allocate … 244.1 MiB`) | Any concurrent heavy query under stomp |

### 3.2 Symptoms by failure mode

| Failure | Symptom |
|---|---|
| 256 MB stomp still active | HTTP 500 with DuckDB `Out of Memory Error: failed to allocate … (…/244.1 MiB used)` |
| Multi-process second writer | Client cannot open DB: `Conflicting lock is held in …` |
| PK / constraint on INSERT routes | HTTP 500 `{"detail":"Internal Server Error"}`; stderr: `Constraint Error: Duplicate key…` |
| Oversized body | **413** |
| Decision log explosion | Dashboard/stats/review projections slow (100 ms → seconds) though POSTs stay fast |
| Concurrent HTML | Latency multiplies roughly with concurrency (seq p50 ~0.45 s → 8-wide p50 ~2.8 s on one page); RSS climbs |
| Huge PDF open | Process RSS jumps by ~file size; can kill the only server process |
| Extension unsigned / wrong duckdb build | Boot failure: cannot `LOAD` / `CREATE ROUTE` not registered |

### 3.3 Read-path measurements (where humans feel pain first)

Sequential baselines (20 samples, warm-ish):

| Endpoint | p50 ms | Notes |
|---|---:|---|
| `GET /exp/light` | 0.3 | Floor |
| `GET /exp/page` (count words page 1) | 0.4 | Cheap filter |
| `GET /exp/sugg_count` (base table) | 0.3 | |
| `GET /exp/vsugg_count` (`v_suggestions`) | **70** | Projection + decision log |
| `GET /exp/stats` | **91** | Multiple subqueries + pending |
| `GET /api/stats` | **77** | App route |
| `GET /documents/1/pages/1` (tera HTML) | **449** | Full page render ~45–70 KB HTML |

Under concurrency:

| Endpoint | Workers | N | p50 ms | QPS |
|---|---:|---:|---:|---:|
| light | 32 | 1000 | 4.1 | ~7.1 k |
| page word count | 32 | 500 | 3.8 | ~7.2 k |
| base `suggestions` count | 16 | 200 | 1.9 | ~7.4 k |
| `v_suggestions` count | 16 | 200 | **1025** | **~17** |
| stats | 16 | 200 | **1075** | **~16** |
| HTML review page | 8 | 40 | **2785** | **~2.7** |

**Interpretation:** mutation path scales; **status projection and HTML SSR** are the interactive bottlenecks. That is app design (views + tera), not “DuckDB can’t write.”

### 3.4 Contrast: conventional prod stack

| Concern | Closure (today) | Postgres + app server + object storage |
|---|---|---|
| Decision writes | `COPY` JSON files / optional `audit_events` | `INSERT` events or `UPDATE` with row locks; connection pool |
| Multi-node web | **Broken** (one writeable DB file) | Normal (many stateless app workers) |
| Auth / sessions | DIY / optional quackapi AUTH | Mature middleware (OIDC, cookies, CSRF) |
| PDF blobs | Local `samples/` + `exports/` on disk | S3/GCS; app signs URLs; workers pull |
| PDF CPU | Same process as UI | Worker queue; UI stays responsive |
| HTML | tera inside DuckDB, buffered | Template engine; optional streaming |
| Analytics / detection SQL | **Excellent** in DuckDB | Often a second store or `fdw`/export |
| Ops | One binary, custom extension, `-unsigned` | Boring, hireable, observable (APM, pgbouncer) |
| Cost of “doing it right” | Low for demo; high for compliance multi-tenant | Higher base complexity; lower tail risk |

**What Postgres+app+object store buys:** horizontal web tier, durable multi-writer, blob lifecycle, standard auth, process isolation for PDF, observability.  
**What it costs:** lose “one SQL file is the backend”; re-express routes; dual systems for analytical detection vs transactional audit unless you keep DuckDB as a side engine.

**What keeping DuckDB for this workload buys:** set-based detection (`read_pdf_words` → n-grams → roster match), in-process redact, zero ORM skew, extremely fast local iteration.  
**What it costs:** single-box coupling; extension supply chain; memory-pool blast radius; you must not pretend it is RDS.

---

## 4. If this were production, I would …

Prioritized, honest list — not a rewrite fantasy:

1. **Fix quackapi memory policy** — stop unconditional `SET memory_limit TO '256MB'`; make it a serve parameter or “leave existing.” Until then, **always** re-`SET` after `quackapi_serve` in *every* boot path (`app.sql` and `run.sh`).
2. **Keep DuckDB for detection + page-scoped review SQL** — the OLTP scare does not apply to append-only decisions at human scale; evidence above.
3. **Move durable decisions into tables (or a real log)**, not unbounded `exports/decisions/*.json` globs — POSTs stay fast while reads of `v_suggestions` already degrade with file count.
4. **Treat PDF open/redact/ingest of large files as batch jobs** (separate process/queue). Never open a multi-hundred-MB PDF on the interactive request thread; chunk `read_pdf_words` with `first_page`/`last_page`.
5. **Bound concurrency for HTML SSR** (or cache page shells) — 8 concurrent full tera renders already multi-second and multi-GB RSS risk.
6. **Add auth** (`CREATE AUTH` + `REQUIRE`, or put a reverse proxy + SSO in front) before any real case data.
7. **If multi-user multi-box is required:** split  
   - **Postgres** (or single primary DuckDB only if single-box HA is enough) for events/users,  
   - **object storage** for PDFs,  
   - **workers** for ingest/redact,  
   - optional **DuckDB** as the analytics/PDF geometry engine — not as the horizontally scaled HTTP tier.
8. **Do not multi-process write one `.db`.** Read replicas / `duckdb` export snapshots are fine; shared writeable files are not.
9. **Publish or vendor the extension properly** (signed artifacts, version pin, or replace quackapi with FastAPI/uvicorn calling DuckDB) before enterprise deploy reviews.

### Bottom line

- **DuckDB genuinely scales fine for this prototype’s interactive decision workload** — measured multi-thousand QPS appends, p50 a few milliseconds, zero failures under 20-way decision storms inside one process.  
- **It does not scale as a multi-writer network database**; that is a real boundary, not FUD.  
- **The prototype will break first** on: forgotten 256 MB cap, HTML/PDF memory coupling, decision-log read amplification, and operational/auth gaps — **not** on “two clerks accepted suggestions at the same time.”

---

## Appendix A — Experiment inventory

| ID | What | Key result |
|---|---|---|
| MP-1 | 10× CLI processes INSERT same file | 8/10 lock failures |
| MP-2 | Python connect while server holds file | lock failure |
| HTTP-INS | Concurrent unique-PK INSERT via quackapi | 32×2000 OK, ~3.5 k QPS, p50 8.4 ms |
| HTTP-AUD | Concurrent audit_events INSERT | 16×400 OK, ~3.5 k QPS |
| HTTP-COPY | Concurrent COPY decision files | 20×500 OK, ~3.5 k QPS |
| HTTP-DEC | Real `/api/suggestions/:id/decision` | 20×500 OK, p50 ~5–6 ms |
| HTTP-READ | light/page vs v_suggestions/stats/HTML | light ~7 k QPS; vsugg ~17 QPS; HTML ~2.7 QPS @8-wide |
| MEM-1 | memory_limit before/after serve | 3.7 GiB → **244.1 MiB** |
| PAY-1 | 9 MiB POST body | **413** |
| AUTH-1 | unauthenticated decision | **200** |
| RSS-1 | HTML load | RSS from ~130 MiB → **0.6–2.5 GiB** under storms |

## Appendix B — Source map

| Path | Relevance |
|---|---|
| `quackapi/src/quackapi_extension.cpp` | 256 MB `ApplyServeResourceGuards` |
| `quackapi/src/quackapi_server.cpp` | 32-thread pool, 8 MiB payload, full body materialization |
| `quackapi/src/include/quackapi_server.hpp` | `QUACKAPI_PAYLOAD_MAX_LENGTH` |
| `closure/server/routes.sql` | Decision `COPY`, page-scoped `render_document` |
| `closure/server/app.sql` | Post-serve memory re-raise |
| `closure/run.sh` | Serve path without re-raise (footgun) |
| `closure/docs/backend-oom-and-fastapi.md` | Prior OOM / FastAPI analysis |

## Appendix C — Dataset under test

| Metric | Value |
|---|---|
| cases | 4 |
| documents | 11 |
| pages (rows) | 210 |
| words | 22 247 |
| suggestions | 1 328 |
| entities | 54 |
| largest doc pages | 110 (`consolidated_case_file_2024-0117`) |
| `closure.db` size (cold) | ~3.5–4 MB |
| stress PDF (not served interactively here) | `samples/stress/monster_huge.pdf` ~709 MiB / 130 419 pages (see OOM doc for RSS) |
