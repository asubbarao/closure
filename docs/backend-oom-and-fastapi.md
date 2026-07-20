# Backend OOM root cause + FastAPI architecture assessment

**Date:** 2026-07-19  
**Scope:** Closure (`/Users/aloksubbarao/personal/closure`) + local quackapi (`/Users/aloksubbarao/personal/quackapi/src`)  
**Method:** code citation + empirical runs on the real binary/extension (DuckDB 1.5.4 + quackapi + community `pdf`/`tera`).  
**Write constraint:** this is the only file written for this investigation.

---

## Executive summary

1. **The OOM was not mysterious host pressure.** It was DuckDB’s own buffer-pool ceiling after quackapi’s serve path forcibly ran `SET memory_limit TO '256MB'`. That setting reports as **`244.1 MiB`** — the exact number in the failure message.
2. **The limit is database-global, not per HTTP worker.** Each request opens a fresh `Connection`, but all workers share one buffer pool / `memory_limit`.
3. **`SET memory_limit='4GB'` before serve does not stick across `quackapi_serve()`.** Serve always re-lowers it. A **post-serve** `SET` does stick and is visible on subsequent HTTP handlers. That is why `server/app.sql` re-raises after serve; **`run.sh` does not** (still vulnerable if used as boot path).
4. **Page-scoped review renders are small** on current sample data (~45–50 MiB process RSS peak). The 256 MB guard leaves almost no headroom after extension/route load, so OOMs are flaky-but-real. Raising the limit to 4 GB is a **real fix for the accidental cap**, not a placebo — but it is **not** a complete scale plan for 1 GB / 10k–130k page PDFs.
5. **The scary scale risk is PDF open + full ingest / full-doc ops**, not “HTTP inside DuckDB” per se. Even `pdf_info` / one-page `read_pdf_words` on `monster_huge.pdf` (~709 MiB, 130 419 pages) peaks near **file size in RSS**. FastAPI does not magically fix that if it still calls the same DuckDB `pdf` extension.
6. **Verdict:** keep quackapi **with a proper fix** (stop hard-capping, make limit configurable, set spill dir, keep page-scoped HTML). Move HTTP to FastAPI only if you want ops/isolation/streaming product reasons — not as the first OOM cure.

---

## Part 1 — Root-cause the OOM

### 1.1 Where quackapi caps memory (precise)

**File:** `quackapi/src/quackapi_extension.cpp`

```96:132:../quackapi/src/quackapi_extension.cpp
//! Apply resource guards recommended for production serve (valsafe HARDENING P1-2).
//! Operators can raise memory_limit before/after serve if handlers need more.
static void ApplyServeResourceGuards(ClientContext &context) {
	try {
		Connection con(*context.db);
		// Cap memory so a single range()/hash join cannot OOM the host.
		// DuckDB 1.5.4 has no statement_timeout; memory_limit is the main lever.
		auto res = con.Query("SET memory_limit TO '256MB'");
		// ...
	}
}

static void ServeExec(...) {
	// ...
	// P1-2: default memory ceiling for the serve lifetime (override with SET).
	ApplyServeResourceGuards(context);
	// ...
	QuackapiState::Get(*context.db).StartServer(...);
}
```

Facts from the code:

| Claim | Reality |
|---|---|
| Hard-coded 256 MB? | **Yes** — literal `'256MB'` string, not a parameter. |
| Per-connection limit? | **No.** `SET memory_limit` updates `DBConfig::options.maximum_memory` and `BufferManager::SetMemoryLimit` (database-global). |
| Per HTTP worker isolation? | **No.** Workers share the pool. |
| Does app pre-serve `SET` stick? | **No** — `ServeExec` always re-applies the guard. |
| Can operators override? | **Yes after serve** (comment admits it). Nothing re-applies 256 MB on each request. |

### 1.2 Request path: one Connection per request, shared pool

**File:** `quackapi/src/quackapi_server.cpp`

- Thread pool: **32 workers** (`new_task_queue` → `ThreadPool(32)` ~line 740).
- Handler: `Connection con(*db);` then `Prepare` + `Execute` (~lines 1018–1374).
- Response: **fully materializes** result rows into a `vector`, then builds `res.body` as one string (~lines 1479–1547). HTML is not streamed to the client.

So:

- Concurrency = many Connections / queries against **one** DuckDB instance.
- Memory accounting for query execution is the **global** buffer pool.
- HTTP body buffering is an additional (usually small for page HTML) copy outside DuckDB’s limit.

### 1.3 Empirical confirmation (reproduced)

#### A. Serve overwrites 4 GB → 244.1 MiB; post-serve SET sticks on HTTP

```text
before_serve:          memory_limit = 3.7 GiB
after quackapi_serve:  memory_limit = 244.1 MiB   ← same number as OOM text
GET /probe (no raise): {"memory_limit":"244.1 MiB", ...}
after SET 4GB:         memory_limit = 3.7 GiB
GET /probe (raised):   {"memory_limit":"3.7 GiB", ...}
```

`244.1 MiB` is simply DuckDB’s human-readable form of the effective max after `SET memory_limit TO '256MB'` (not an httplib cap).

#### B. Main renders under the 256 MB guard

On `closure.db` (11 docs, 22 247 words, 1 328 suggestions, consolidated = 110 pages):

| Query | Under `memory_limit=256MB` (~244.1 MiB) | Under 4 GB |
|---|---|---|
| `render_document(3,1)` | **OOM** observed: `failed to allocate 32.0 MiB (232.3 MiB/244.1 MiB used)`; sometimes succeeds when residual is lower | OK, HTML ~111 KB |
| `render_document(3,50)` | OK in one run (~106 KB HTML) | OK |
| `render_case(1)` | OOM in one clean session; OK in another | OK, ~29 KB |
| `render_home()` / `render_audit(1)` | OK when headroom remains | OK |

Process peak RSS for successful page/case renders under 4 GB: **~45–50 MiB**.  
Under the hostile 256 MB *accounting* ceiling, DuckDB can report ~230 MiB “used” even when RSS is lower — the failure mode is the **enforced pool limit**, not the Mac running out of RAM.

#### C. Closure’s awareness / incomplete mitigation

`server/app.sql` documents the issue and re-raises after serve:

```14:22:server/app.sql
-- Runtime headroom for pdf_redact + large review pages.
-- NOTE: quackapi_serve() forcibly re-SETs memory_limit TO '256MB' in
-- ApplyServeResourceGuards (see quackapi_extension.cpp). That is why OOM
-- errors report "~244.1 MiB used" — DuckDB's effective cap under 256MB after
-- internal reservations, NOT a httplib cap and NOT a per-connection limit.
-- memory_limit/max_memory are database-global buffer-pool settings; we raise
-- them again immediately after serve starts (below).
SET memory_limit = '4GB';
```

```174:182:server/app.sql
FROM quackapi_serve(8117, static_dir := '.');

-- Re-raise after quackapi's serve-time 256MB resource guard (must be AFTER serve).
SET memory_limit = '4GB';
SET max_memory = '4GB';
```

**`run.sh` phase 3 does not re-raise after serve** (sets 4 GB, then `quackapi_serve`, then `sleep_ms` only). Boot via `run.sh` leaves the process at **244.1 MiB** for the entire serve lifetime. That alone is enough to re-create the incident.

### 1.4 Real memory behavior of the app (not just the cap)

#### Page-scoped *runtime* (good)

`render_document` is deliberately page-scoped (`server/routes.sql`):

- `word_rows` / marks: `WHERE document_id = did AND page_no = pg.page_no`
- suggestion queue hard-capped (`rn <= 80`)
- Comments explicitly reject whole-doc word lists in tera context

On current data, peak RSS for a review page is tens of MiB. **A 4 GB pool is not “required” for page HTML** — it is required only because the accidental 256 MB ceiling collides with DuckDB’s internal reservations + any concurrent query.

#### Full materialization points (risks)

| Path | Materializes? | Scale risk |
|---|---|---|
| Ingest `CREATE TABLE words AS SELECT … FROM read_pdf_words('samples/*.pdf')` | Full CTAS of all words in matching files | **High** for 1 GB / multi-k page corpora |
| `v_grams` (1–4 word n-grams over `words`) | View; evaluated when scanned (seed joins it) | **High** at seed time on large `words` |
| Seed `_seed_hits` join targets ⨯ `v_grams` | Full match table | High if words large |
| `render_document` words/marks | Current page only | Low if words table is indexed/filtered well |
| `api_*_suggestions` | All suggestions for doc/case | Medium if suggestion count explodes |
| `pdf_redact` whole source PDF | Whole-file PDF open + write | **High** on huge files |
| quackapi response body | Full HTML/JSON string in process | Low for page HTML; high if a route returns huge JSON |

#### PDF extension behavior (critical for “1 GB PDF” fear)

`read_pdf_words` **does** support `first_page` / `last_page` (confirmed via `duckdb_functions()`).  
Spill: DuckDB uses `temp_directory` (here `closure.db.tmp` when attached to `closure.db`; default `.tmp` for `:memory:`). Spills help **query operators** (hash, sort) under a tight `memory_limit`; they do **not** stop native PDF libraries from mapping/loading document structures.

Empirical RSS peaks:

| Workload | Peak process RSS (approx.) |
|---|---|
| CTAS all words from `_dense500.pdf` (817 pages, ~505 k words), `memory_limit=1GB` | **~83 MiB** |
| CTAS all words from `monster_5k.pdf` (5 000 pages, 27 MiB file), `memory_limit=2GB` | **~100 MiB** |
| `pdf_info(monster_huge.pdf)` (130 419 pages, **709 MiB** file) | **~749 MiB** |
| `read_pdf_words(monster_huge, first_page:=1, last_page:=1)` | **~749 MiB** |

**Interpretation:** for the huge stress PDF, opening the document (even for one page of words or for `pdf_info`) costs on the order of **the file size in RSS**. Page parameters reduce *word rows produced*, not necessarily *PDF open cost*. DuckDB spill will not save you from that native cost.

So:

- **Is 4 GB a genuine fix for the observed render OOM?**  
  **Yes** — it undoes quackapi’s hostile 256 MB serve default so page/case HTML can allocate. Residual render cost on current samples is << 4 GB.
- **Will 4 GB still blow up on a 1 GB / 10k–130k page PDF?**  
  **It can**, depending on the op:
  - Page-scoped *SQL over an already-ingested* `words` table: likely fine if ingest succeeded and filters hit.
  - Any path that **opens** a 1 GB PDF in-process (`pdf_info`, full `read_pdf_words`, `pdf_redact` on the original): can need **~file size + query** memory regardless of “page-scoped SQL.”
  - Full-corpus ingest without chunking: will grow `words` / seed intermediates unboundedly.

### 1.5 Correct fix (smallest → proper)

#### A. Patch quackapi (correct fix for the class of bug)

In `ApplyServeResourceGuards` / `ServeExec`:

1. **Do not hard-cap to 256 MB.** Prefer:
   - named param on `quackapi_serve(..., memory_limit := '4GB')`, **or**
   - respect existing `memory_limit` if already set, **or**
   - only set a default when unset / still at DuckDB default.
2. If a guard remains desirable for multi-tenant demos, make it **configurable** (`SET quackapi_default_memory_limit` / serve named param), default maybe `2GB` or “leave alone,” never a silent 256 MB stomp.
3. Optionally log the effective limit at serve start (`fprintf` once).

#### B. Closure boot (works today without rebuild)

1. **Always re-`SET memory_limit` / `max_memory` after `quackapi_serve`** (already in `app.sql`; **add to `run.sh` phase 3**).
2. Set spill explicitly:
   ```sql
   SET temp_directory = 'closure.db.tmp';  -- or a large disk path
   SET preserve_insertion_order = false;   -- already in run.sh; helps some plans
   SET threads = 4;                        -- lower under tight RAM
   ```
3. Keep renders page-scoped; never feed whole-doc word lists into `tera_render`.
4. For huge PDFs: **offline / chunked ingest** using `first_page`/`last_page` batches; do not `read_pdf_words('*.pdf')` on multi-hundred-MB files in one CTAS on the interactive server.
5. Treat `pdf_redact` of huge originals as a **batch job** with its own memory budget (or external tool), not a synchronous HTTP handler under the UI process if file size ≈ RAM.

#### C. What *not* to believe

- “Each HTTP worker gets 256 MB” — **false**.
- “Spill makes PDF open free” — **false**.
- “4 GB means we can stream 130k-page PDFs in the request path” — **false**; open cost and full-file ops still dominate.

---

## Part 2 — FastAPI equivalence (honest)

### 2.1 Same contract, different HTTP host

Closure’s frontend needs roughly:

| Surface | Today | FastAPI sketch |
|---|---|---|
| HTML pages | `CREATE ROUTE … AS SELECT tera_render(…) AS html` | Jinja2/templates or keep `tera` via DuckDB SQL and return `HTMLResponse` |
| JSON GET | routes returning row sets → JSON array | `JSONResponse` from `con.execute(...).fetchall()` / `df.to_dict` |
| Mutations | `COPY (SELECT …) TO 'exports/decisions/…'` | same SQL via Python, or write JSON files with pathlib |
| Static | quackapi `static_dir` | `StaticFiles` for `pages/`, `static/` |
| PDF geometry | community `pdf` extension | same extension through DuckDB Python API |
| Detection SQL | `ingest.sql` / `seed.sql` / views | **unchanged** if DuckDB remains the engine |

Sketch (one process, still “DuckDB is the database,” not the web server):

```
┌─────────────┐     HTTP      ┌──────────────────┐
│  Browser    │ ────────────► │  FastAPI (uvicorn)│
└─────────────┘               │  routes ≈ routes.sql
                              │  templates or tera via SQL
                              └─────────┬────────┘
                                        │ duckdb.connect("closure.db")
                                        ▼
                              ┌──────────────────┐
                              │ DuckDB engine    │
                              │ + pdf + (optional tera)
                              │ words/suggestions tables
                              └──────────────────┘
```

Moving parts:

1. Python runtime + deps (`fastapi`, `uvicorn`, `duckdb`, maybe `jinja2`).
2. Route modules mirroring `server/routes.sql`.
3. One shared DuckDB connection **or** connection-per-request (still one file lock / one writer semantics to respect).
4. Process manager (systemd / launchd / docker) instead of `duckdb … sleep_ms`.
5. Same on-disk schema, samples, exports, pages PNGs.

If SQLite instead of DuckDB: you **lose** `read_pdf_words`, `pdf_redact`, `tera_render`, and most of the detection SQL as written. That is a rewrite of the data plane, not a swap of the HTTP shell.

### 2.2 Axis comparison (what matters for this product)

| Axis | quackapi-in-DuckDB (today) | FastAPI + DuckDB-as-library |
|---|---|---|
| **Memory safety under huge PDFs** | Dominated by DuckDB + pdf ext + **shared pool** + accidental 256 MB stomp. Fixable. | Same DuckDB/pdf memory model for queries. HTTP layer has its own heap; can isolate batch jobs in **child processes**. Slight edge for isolation, not for “free” huge PDF. |
| **Streaming** | Response fully buffered (`vector` of rows → one `body` string). | Easy `StreamingResponse` for large JSON/export; HTML still usually buffered. Edge: FastAPI. |
| **Concurrency** | 32 httplib workers → concurrent queries on **one** DB; one heavy query can starve pool memory for all. | Same if one process + one DuckDB. Better if multi-worker with **read-only replicas** or job queue for heavy PDF. |
| **Operational simplicity** | One binary, one SQL boot, thesis purity. Fragile footguns (`ApplyServeResourceGuards`, routes non-durable, dual boot paths). | Familiar Python stack; more files/deps; clearer process boundaries; standard metrics/logging. |
| **Deployability** | Custom extension + matching duckdb build (`-unsigned`, parser extensions). Harder to ship to strangers. | `pip install` + community duckdb wheels + `INSTALL pdf`. Easier for most hosts. |
| **Carry-over of current work** | 100% (schema, seed SQL, tera templates, routes as SQL). | **Schema / detection / pdf SQL: ~all.** Route DDL → Python wrappers. `tera` optional (Jinja can replace). quackapi-specific auth/DDL unused. |
| **Failure modes** | OOM becomes HTTP 500 with DuckDB message; whole process can die. | Same if single process; can sandbox PDF work. |

### 2.3 Stress case: 1 GB+ / thousands–100k pages

**Which architecture is more memory-safe?**

- **If both keep “open full PDF in the web process and run SQL”:** **neither wins.** The ~file-size RSS on `monster_huge` shows the liability is **PDF open + engine**, not httplib vs uvicorn.
- **If FastAPI moves heavy PDF ingest/redact to a worker process / queue** (or external tool) and the web process only serves page-scoped SQL over tables: **FastAPI (or any thin HTTP) is safer** because the UI process never maps the 1 GB file.
- **If quackapi stays but ingest is offline and serve only hits tables:** **quackapi is fine** and matches the product thesis — provided the 256 MB stomp is gone and concurrency is bounded.

**Is HTTP-inside-DuckDB the liability?**  
Partially:

- Real liability #1: **hard-coded serve memory stomp** (bug/policy).
- Real liability #2: **single shared memory pool for all concurrent handlers**.
- Real liability #3: **full response materialization** (minor for HTML pages).
- Real liability #4: **PDF extension open cost** (shared by both architectures).

HTTP-inside-DuckDB is *not* inherently “cannot scale to large PDFs.” It is *inherently* “one process owns web + query + PDF,” so a bad query or PDF open hurts the whole product surface. That is a real operational tradeoff, not a moral failing of DuckDB.

### 2.4 Verdict

**Recommendation: keep quackapi, with the fix — do not move HTTP solely to chase this OOM.**

Reasoning:

1. The incident is **explained and reproducible** as a serve-time 256 MB global cap (`244.1 MiB`). That is a one-function fix + boot discipline.
2. Page-scoped review already matches how a large-PDF product should work; peak render RSS is small.
3. FastAPI does not change DuckDB spill or poppler open cost; it only helps if you **also** redesign process boundaries for heavy PDF work.
4. Moving now throws away the SQL route surface and the “one process” thesis for little memory gain on the render path.

**When to move to FastAPI/Fastify instead:**

- You need multi-user concurrency with process isolation.
- You need streaming exports, standard APM, auth middleware ecosystems.
- You want deploy without a custom duckdb+extension binary.
- You are willing to re-express routes in Python and keep DuckDB as pure engine.

### 2.5 Smallest change that de-risks OOM (either path)

**Minimum viable de-risk (do this regardless of architecture):**

1. **quackapi:** stop unconditional `SET memory_limit TO '256MB'` (or make it configurable; default leave-alone / 4 GB).
2. **Closure boot:** after serve (and in `run.sh`), set:
   - `memory_limit` / `max_memory` to a conscious budget (e.g. 4 GB),
   - `temp_directory` on a large disk,
   - `preserve_insertion_order=false`, bounded `threads`.
3. **Expose a live probe** (you already can): `GET` returning `current_setting('memory_limit')` so a silent stomp is visible.
4. **Never full-scan huge PDFs on the interactive serve process**; chunk ingest with `first_page`/`last_page`; treat whole-file `pdf_redact` as batch.
5. **Keep page-scoped HTML** (already done in `render_document`).

**If staying on quackapi:** items 1–5.  
**If moving to FastAPI:** items 2–5 + port routes; still do **not** call full-file PDF open on the request thread for 1 GB files.

---

## Appendix A — Key file map

| Path | Role |
|---|---|
| `quackapi/src/quackapi_extension.cpp` L96–132 | `ApplyServeResourceGuards` / `ServeExec` 256 MB stomp |
| `quackapi/src/quackapi_server.cpp` L740–742 | 32-thread httplib pool |
| `quackapi/src/quackapi_server.cpp` L1018+ | per-request `Connection` |
| `quackapi/src/quackapi_server.cpp` L1479–1547 | full response materialization |
| `closure/server/app.sql` L14–22, L174–182 | documents stomp; post-serve 4 GB raise |
| `closure/run.sh` L135–170 | serve path **without** post-serve raise |
| `closure/server/routes.sql` L205–394 | page-scoped `render_document` |
| `closure/server/ingest.sql` L86–102 | full `read_pdf_words('samples/*.pdf')` CTAS |
| `closure/samples/stress/monster_huge.pdf` | 709 MiB / 130 419 pages stress artifact |

## Appendix B — Experiments run (this session)

1. `:memory:` serve on ports 18765/18766: before/after memory settings + HTTP `/probe`.
2. `render_*` under 256 MB vs 4 GB on live `closure.db`.
3. Process RSS sampling during renders and PDF CTAS.
4. `pdf_info` / page-ranged `read_pdf_words` on `monster_huge.pdf` and smaller stress PDFs.
5. `duckdb_functions()` for `read_pdf_words` parameters (`first_page`, `last_page`, …).

## Appendix C — One-line root cause for the incident log

> quackapi’s `ApplyServeResourceGuards` forced a **global** `memory_limit` of **256 MB (displayed 244.1 MiB)** at `quackapi_serve()`; main HTML renders then failed DuckDB allocations near that ceiling. Raising `memory_limit` **after** serve (or removing the hard cap) restores headroom; residual scale risk for multi-hundred-MB PDFs is **PDF open / full ingest / full redact**, not page-scoped tera render.
