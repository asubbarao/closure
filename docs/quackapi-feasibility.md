# quackapi feasibility — can Closure run purely on quackapi?

**Date:** 2026-07-19  
**Question:** Can the full redaction-review app be built end-to-end on quackapi alone?  
**Sources (read-only):**
1. quackapi — `/Users/aloksubbarao/personal/quackapi` (README, `src/`, `test/`, `docs/FASTAPI_PARITY.md`)
2. Closure app — `/Users/aloksubbarao/personal/closure/server/*.sql`, `server/templates/`, `static/*.js`
3. Clean-room TS apps — `/Users/aloksubbarao/personal/closure-cleanroom/attempt-{1,2,3}` (one-way peek; not modified)
4. Live smoke against built quackapi (`build/release/duckdb` + extension, 2026-07-19)

**Write constraint:** this file only.

---

## Executive verdict

**Yes — for the redaction-review product as specified by the assignment and as already prototyped in Closure.**

The working stack is already:

```
Browser  ──HTTP──►  quackapi (httplib, 32 workers, CREATE ROUTE handlers)
                       │
                       ├─ DuckDB tables/views (cases, docs, suggestions, audit)
                       ├─ tera_render → HTML (column AS html)
                       ├─ static_dir → JS / page PNGs / exported PDFs on disk
                       ├─ mutations: COPY → exports/decisions/*.json
                       └─ pdf_redact → files under exports/  (JSON meta in response)
```

That is not a hypothetical architecture: `server/app.sql` boots it on port **8117** with `FROM quackapi_serve(8117, static_dir := '.')` (`server/app.sql:174`).

**Caveat (honest):** “Purely on quackapi” means HTTP + SQL handlers + companion community extensions (`pdf`, `tera`). It does **not** mean quackapi replaces PDF parsing or templating. Gaps that remain are **extension polish / product edges**, not a requirement for Node/FastAPI for core review workflows.

| Product shape | Pure quackapi? |
|---|---|
| Assignment MVP (queue, FP reject, FN add, bulk, multi-doc, confidence, audit) | **Yes — already largely shipped in Closure** |
| Real PDF bbox review + redacted export package | **Yes-with-pattern** (write PDF to disk + static download; not in-handler streaming) |
| Upload multi-hundred-MB source PDFs over HTTP | **NO without ext change** (8 MiB payload cap) |
| Multi-process multi-writer SaaS | **No** (DuckDB single-writer file lock — not a quackapi bug) |
| WebSockets / live multi-user presence | **NO** (not needed for assignment; not in quackapi) |

---

## 1. quackapi capability surface (exact)

### 1.1 Route DDL

Parser: `src/quackapi_ddl.cpp` (grammar comments ~212–219). State: `QuackapiRoute` in `src/include/quackapi_state.hpp:92–106`.

```sql
CREATE [OR REPLACE] ROUTE <name> <METHOD> '<pattern>'
  [STATUS <n>]
  [REQUIRE <auth>]
  [BODY SCHEMA '<json-schema>']
  [PARAM <name> [<type>] [HEADER|COOKIE|QUERY [wire-name]]
        [DEFAULT <lit>|NULL]
        [GE|GT|LE|LT <n>] [MIN_LENGTH|MAX_LENGTH <n>] …
  AS <select>;

DROP ROUTE <name>;
```

| Piece | Behavior | Cite |
|---|---|---|
| Methods | `GET POST PUT DELETE PATCH HEAD` | `quackapi_state.hpp:94`; server registers all + OPTIONS |
| Path params | `:id` or `{id}` → `$id` | README; `QuackapiRoute.pattern` |
| Query / body | Named SQL params bind from path → query → JSON/form/multipart body | `quackapi_server.cpp` bind loop ~1214+ |
| HEADER / COOKIE | `PARAM token HEADER` / `PARAM session COOKIE` | `QuackapiParamSource`; HTTP tests `headers.test.sh`, `cookies.test.sh` |
| Defaults / constraints | `DEFAULT`, `GE/GT/LE/LT`, `MIN_LENGTH/MAX_LENGTH` | `QuackapiParamSpec` |
| BODY SCHEMA | JSON Schema via community `json_schema` | `QuackapiRoute.body_schema` |
| STATUS | Success status on handler (e.g. 201, 302) | DDL `STATUS <n>` |
| REQUIRE | Auth scheme name; fail-closed if unknown | `require_auth` |
| Live registry | Routes created after serve are visible immediately | `quackapi_server.cpp:752–753` |
| Handler validation | Invalid SQL rejected at CREATE (no zombie route) | `test/sql/quackapi_routes.test` |

Table CRUD helper:

```sql
CREATE API FOR TABLE <table> [AT '<base>'] [KEY '<col>'];
-- GET base + GET base/:key  (read-only in this version)
```

(`src/include/quackapi_table_api.hpp`)

### 1.2 Responses

Inferred from **column names** after stripping control columns (`quackapi_server.cpp:641–669`, `1534–1573`):

| Column name | HTTP behavior |
|---|---|
| Single data col `html` | `text/html; charset=utf-8` (raw string; multi-row concat) |
| Single data col `text` | `text/plain; charset=utf-8` |
| `location` | `Location` header (stripped from body) — pair with `STATUS 302` |
| `set_cookie` / `set-cookie` | `Set-Cookie` header(s) |
| Anything else / multi-col | JSON **array of row objects**, types follow DuckDB types |
| No data cols | Empty body (redirect / cookie-only) |

**Not present:** `bytes` / `file` / `content_type` / `Content-Disposition` control columns.  
`BLOB` columns serialize through `ValueToJson` → default branch → **string**, not `application/pdf`.

Live smoke (2026-07-19):

```
GET /page   → Content-Type: text/html; charset=utf-8
GET /blob   → [{"data":"PDF-bytes"}]     # BLOB is not binary response
GET /go     → 302 Location: /hello
POST 9 MiB  → 413
```

### 1.3 Static files

```sql
SELECT * FROM quackapi_serve(port, host := '127.0.0.1',
                             static_dir := '.', cors_origins := '…');
```

- `set_mount_point("/", static_dir)` — unrouted GETs become files (`quackapi_server.hpp:25–31`, `quackapi_server.cpp:734–737`).
- **API routes win over files** (handlers registered; mount is fallback for unmatched GETs in httplib’s model as documented in comments).
- Closure uses this for `static/*.js`, `pages/**/*.png`, and post-export `exports/*_redacted.pdf`.

### 1.4 Request bodies / uploads

| Content-Type | Binding | Cite |
|---|---|---|
| `application/json` | Top-level object fields → `$name`; `$body` raw | `ExtractJsonBodyFields` |
| `application/x-www-form-urlencoded` | Fields → `$name` | `ParseFormUrlEncoded` |
| `multipart/form-data` | Text fields + files: `$file` content, `$file_filename`, convenience `$filename` | `quackapi_server.cpp:1177–1191`; `test/http/multipart.test.sh` |

**Hard limit:** `QUACKAPI_PAYLOAD_MAX_LENGTH = 8 MiB` (`quackapi_server.hpp:22–23`). Larger → **413**. Confirmed live.

File bytes are bound as **strings** into SQL params (fine for small text; awkward for binary PDFs with NULs; still must fit in 8 MiB).

### 1.5 Auth / sessions / CORS

| Feature | Mechanism | Cite |
|---|---|---|
| API keys | `CREATE AUTH site AS API_KEY [( HEADER 'X-API-Key' )]`; `quackapi_add_api_key`; SHA-256 only stored | `quackapi_auth.hpp`, `quackapi_state.hpp:17–39` |
| JWT HS256 | `CREATE AUTH … AS JWT_HS256 ( SECRET '…' )`; claims bind `$claims_<name>` | auth module |
| Route gate | `REQUIRE <auth>` on CREATE ROUTE | |
| Cookies | Param bind + `set_cookie` response | cookies HTTP test |
| CORS | Off by default; `SET quackapi_cors_origins` or serve `cors_origins` | `quackapi_extension.cpp:285–299` |
| Sessions | **No first-class session store** — build with cookies + table | intentional app pattern |

### 1.6 OpenAPI / docs

Built-in (not in `quackapi_routes()`): `GET /openapi.json`, `/docs` (Swagger UI), `/redoc` (`quackapi_openapi.cpp`, `test/http/redoc.test.sh`). FastAPI parity scorecard: **89/89** (`docs/FASTAPI_PARITY.md`).

### 1.7 Concurrency / memory / durability extras

| Topic | Reality | Cite |
|---|---|---|
| Workers | httplib `ThreadPool(32)` | `quackapi_server.cpp:740–742` |
| Per request | Fresh `Connection` on shared DB instance | scaling docs / server handler |
| Serve memory stomp | `SET memory_limit TO '256MB'` inside `ApplyServeResourceGuards` | `quackapi_extension.cpp:97–123` |
| Override | Post-serve `SET memory_limit='4GB'` sticks (Closure does this) | `server/app.sql:176–178` |
| Response model | **Fully materialize** all result rows → one `res.body` string | `quackapi_server.cpp:1479–1573` |
| Queues | `CREATE QUEUE`; `quackapi_enqueue/dequeue/ack/nack` durable table | `quackapi_queue.*`, `test/sql/quackapi_queue.test` |
| Outbound HTTP | `quackapi_http_fetch` (no libcurl in-process shell-out) | `quackapi_http_fetch.hpp` |

### 1.8 Explicit non-capabilities (today)

| Missing | Evidence |
|---|---|
| Binary / FileResponse body from SQL | Only `html` / `text` / JSON modes |
| Streaming response / chunked body / SSE | Full materialize path |
| WebSocket upgrade | No code path |
| Configurable payload max | Hard-coded 8 MiB |
| Configurable serve memory | Hard-coded 256 MB then optional post-serve SET |
| Custom response headers beyond Location / Set-Cookie | No general header columns |
| Multipart → typed BLOB param | Content bound as string map values |

---

## 2. What Closure already relies on (HTTP surface)

### 2.1 HTML pages (`server/routes.sql:546–559`)

| Method | Path | Mechanism |
|---|---|---|
| GET | `/` | `render_case(1)` → `AS html` via tera |
| GET | `/cases/:id` | case dashboard SSR |
| GET | `/cases/:id/library` | same render |
| GET | `/cases/:id/audit` | audit SSR |
| GET | `/documents/:id` | review page 1 |
| GET | `/documents/:id/pages/:page` | page-scoped review |
| GET | `/ui/reject`, `/ui/add-missed`, `/ui/bulk` | shell HTML from `app_templates` |

### 2.2 JSON GET

| Path | Role |
|---|---|
| `/api/documents/:id/suggestions` | Queue + overlays |
| `/api/documents/:id/page_map` | Minimap counts |
| `/api/cases/:id/documents` | Multi-doc rail |
| `/api/cases/:id/suggestions` | Case-wide bulk/entity |
| `/api/search?case=&q=` | Word hit search (LIMIT 200) |
| `/api/cases/:id/audit` | Audit feed |
| `/api/stats` | Global counters |
| `/api/cases/:id/export_plan` | Preview boxes / SQL plan |

### 2.3 Mutations (POST)

| Path | Pattern |
|---|---|
| `/api/suggestions/:id/decision` | `COPY (…) TO 'exports/decisions'` JSON shards |
| `/api/entities/:id/decision` | Bulk by entity_id (flagged excluded) |
| `/api/documents/:id/band/:band/decision` | Band bulk accept/reject |
| `/api/documents/:id/add` | Manual FN add (accepted + coords) |
| `/api/cases/:id/export` | `pdf_redact` via boot macros + JSON meta |
| `/api/cases/:id/export/run` | `run_sql($sql)` from export_plan |

### 2.4 Static / client interactions (`static/*.js`)

Already implemented against the above:

- Keyboard triage accept/reject (`review.js`)
- Multi-select bulk + entity bulk sheet (`bulk.js`)
- Reject-FP sheet with reason logging (`reject.js`)
- Drag-to-add missed redaction + scope (`addmissed.js`)
- Confidence / band presentation
- Case library multi-select HIGH accept + export button (`dashboard.js`)
- Audit list refresh
- Page PNGs under `pages/` served as static files

**Conclusion:** Closure’s production path is already a pure-quackapi app. Export does **not** stream PDF bytes in the HTTP response; it writes files and returns JSON counts (`dashboard.js:626–655` posts export, toasts counts).

---

## 3. Clean-room “proper app” feature census (attempt-1/2/3)

One-way read of Next/React/Tailwind clean-rooms. They use SQLite + API routes; they are the **feature checklist**, not the target stack.

### 3.1 Shared feature set (all three)

| Feature | attempt-1 | attempt-2 | attempt-3 | Closure today |
|---|---|---|---|---|
| Case list / multi-document package | ✓ | ✓ | ✓ | ✓ SSR + JSON |
| Suggestion queue (pending-first) | ✓ | ✓ | ✓ | ✓ |
| Accept / reject single | PATCH/POST | decide | decide | POST decision |
| Bulk accept/reject (ids or similar_key) | `/suggestions/bulk` | `/bulk-decide` | `/suggestions/bulk` | entity + band + client multi-POST |
| Manual add missed redaction | POST suggestions | `/manual-redactions` | `/redactions/manual` | POST `/add` |
| Confidence bands (high/med/low UI) | ✓ | ✓ | ✓ | band + conf in views |
| Audit trail (who/when/what) | `/audit/[caseId]` | case audit | `/audit` | HTML + JSON |
| Keyboard-first review | ✓ | ✓ | ✓ | `review.js` |
| Multi-doc navigation | ✓ | ✓ | ✓ | case library + review |
| Apply / burn blackouts (logical) | `/redactions/apply` | accept = black bar | accept | accept status → export boxes |
| Real PDF upload / stream export | not MVP | “with more time” | “with more time” | disk export + static |
| Auth / multi-reviewer product | stub actor | reviewers table | reviewers | actor string param |
| WebSockets / presence | no | no | no | no |

### 3.2 Data model (clean-room) vs Closure

Clean-rooms: `cases`, `documents` (+ `pages_json`), `suggestions` (status in-row or decision table), `manual_redactions`, `audit_events`, optional `reviewers`.

Closure: same domain, with **event-sourced decisions** (`exports/decisions/*.json` ∪ seed) projected through `v_suggestions` / `v_audit` — a deliberate DuckDB-friendly write shape (append-only `COPY`, no hot-row UPDATE).

Nothing in the clean-room model requires an HTTP capability Closure lacks.

### 3.3 Ideal extras (clean-room “with more time”)

| Extra | quackapi today |
|---|---|
| PDF.js real rendering | Browser-side; serve page assets via `static_dir` or route |
| Export redacted PDF + audit CSV | PDF: yes-with-pattern (disk); CSV: `COPY` + static or JSON rows |
| Role-based multi-reviewer | API_KEY / JWT + SQL roles table |
| Dual-control sensitive categories | Pure SQL policy in handlers |
| Live collab presence | **Needs WebSocket/SSE** — gap |

---

## 4. Capability matrix (app needs → quackapi)

Legend:

- **yes** — first-class, use as-is  
- **yes-with-pattern** — works via documented composition (disk static, cookies+table, etc.)  
- **NO-needs-ext-change** — cannot ship correctly without changing quackapi

| # | Feature needed | Status | Mechanism or missing piece |
|---|---|---|---|
| 1 | Named REST routes (GET/POST/…) | **yes** | `CREATE ROUTE … AS SELECT` |
| 2 | Path params (`:id`) typed 422 | **yes** | `$id::INTEGER` + FastAPI-shaped errors |
| 3 | Query + JSON body params | **yes** | auto-bind; optional `BODY SCHEMA` |
| 4 | SSR HTML pages | **yes** | `SELECT tera_render(…) AS html` |
| 5 | Static JS/CSS/images | **yes** | `quackapi_serve(…, static_dir := '.')` |
| 6 | JSON list/detail APIs | **yes** | default JSON array envelope |
| 7 | Accept/reject mutation | **yes** | `COPY`/`INSERT` in handler |
| 8 | Bulk by entity / band / ids | **yes** | set-based SQL (Closure entity/band); bulk-ids via `json_each($ids)` pattern |
| 9 | Manual FN add with bbox | **yes** | POST body doubles + `COPY` |
| 10 | Confidence / band projection | **yes** | SQL views (not an HTTP feature) |
| 11 | Audit trail read | **yes** | GET route over `v_audit` |
| 12 | Search within case | **yes** | GET `/api/search` |
| 13 | Redirects | **yes** | `STATUS 302` + `AS location` |
| 14 | Cookies / Set-Cookie | **yes** | `PARAM … COOKIE` + `set_cookie` |
| 15 | API keys / JWT gate | **yes** | `CREATE AUTH` + `REQUIRE` |
| 16 | CORS for SPA host | **yes** | `cors_origins` |
| 17 | OpenAPI for handoff | **yes** | `/openapi.json` `/docs` |
| 18 | Background export jobs | **yes-with-pattern** | `CREATE QUEUE` + poll route, or sync `pdf_redact` as now |
| 19 | Serve page raster images | **yes-with-pattern** | pre-render `pages/` + static, or `pdf`→file then static |
| 20 | Download redacted PDF | **yes-with-pattern** | `pdf_redact` → `exports/…` → client `GET /exports/…` via static |
| 21 | Export progress feedback | **yes-with-pattern** | poll job table / queue; not push SSE |
| 22 | Actor identity | **yes-with-pattern** | query param today; upgrade to JWT claims / cookie session table |
| 23 | Small file upload (config, small PDF) | **yes** | multipart if ≤8 MiB |
| 24 | Large PDF upload over HTTP | **NO-needs-ext-change** | 8 MiB `QUACKAPI_PAYLOAD_MAX_LENGTH`; also string-bound file body |
| 25 | In-response binary PDF stream | **NO-needs-ext-change** | no FileResponse / `bytes`+`content_type`; BLOB→JSON string (live proof) |
| 26 | Streaming large HTML/JSON | **NO-needs-ext-change** (soft) | full buffer; OK for page-sized HTML, bad for multi-MB JSON dumps |
| 27 | SSE progress channel | **NO-needs-ext-change** | no event-stream |
| 28 | WebSockets | **NO-needs-ext-change** | none; not required by assignment |
| 29 | Serve-time memory policy for PDF | **yes-with-pattern / soft NO** | post-serve raise works; hard 256 MB stomp is footgun → should be configurable |
| 30 | Custom `Content-Disposition: attachment` | **NO-needs-ext-change** (soft) | static files may set via filesystem MIME only; no header column |
| 31 | Multi-process write scale-out | **N/A (DuckDB)** | single process holds DB file |

---

## 5. Honest gaps → extension punch-list

Ordered by impact on *this* app (not abstract FastAPI parity).

### P0 — fix before treating serve as production-default

1. **Configurable `memory_limit` on serve (stop silent 256 MB stomp)**  
   - Today: `ApplyServeResourceGuards` forces `'256MB'` (`quackapi_extension.cpp:97–123`).  
   - Closure works only because `app.sql` re-raises after serve.  
   - **Ext change:** `quackapi_serve(..., memory_limit := '4GB')` or `SET quackapi_memory_limit` read once at serve; default can stay conservative but must be documented and overridable without race knowledge.

### P1 — needed for “upload + download” product story without disk hacks

2. **Binary FileResponse from SQL**  
   - Columns e.g. `file_bytes BLOB`, `content_type VARCHAR`, optional `content_disposition VARCHAR`.  
   - Response: raw bytes, correct MIME, no JSON envelope.  
   - Enables `SELECT read_blob('exports/foo_redacted.pdf') AS file_bytes, 'application/pdf' AS content_type, …` without relying on static_dir tree exposure.

3. **Configurable payload max (and prefer BLOB bind for multipart files)**  
   - Today: 8 MiB hard cap (`QUACKAPI_PAYLOAD_MAX_LENGTH`).  
   - **Ext change:** serve option / setting `payload_max_length`; multipart file parts bind as `BLOB` when param type is BLOB (avoid NUL truncation / UTF-8 issues).

### P2 — nice for long exports / ops polish

4. **Optional response streaming** for large `html`/`text`/`file_bytes` (httplib chunked write; avoid double-buffering multi-MB bodies).  
5. **Generic response header column(s)** or `headers JSON` map (beyond Location/Set-Cookie) for `Cache-Control`, `Content-Disposition`, CSP.  
6. **SSE mode** (column `event_stream` or route flag) for export progress — only if product wants push; polling queue is enough for MVP.

### Explicitly **not** required for Closure / assignment

| Gap | Why skip |
|---|---|
| WebSockets | Clean-rooms don’t implement; single-reviewer keyboard workflow |
| Full session middleware | JWT/API key + actor claim sufficient |
| GraphQL | REST is the product surface |
| Multipart > memory streaming upload | Prefer path-based ingest (`samples/`, `read_pdf_*` from disk) for giant files |

### App-side patterns that are *not* quackapi gaps

| Concern | Pattern already valid |
|---|---|
| “Can’t return PDF in JSON” | Write with `pdf_redact(path_out, …)`; link `/exports/…` |
| Dynamic `pdf_redact` args | Boot macros / `export_plan` + `run_sql` (see `app.sql:130–135` comments) |
| Concurrent reviewers same process | Append-only decisions + 32 workers; raise memory |
| Second process writing same `.db` | Don’t; one duckdb process is the app |

---

## 6. How to build the whole app purely on quackapi (recipe)

If starting green-field with today’s quackapi (no ext changes):

1. **Boot** — `LOAD quackapi; LOAD tera; LOAD pdf;` raise memory **after** serve.  
2. **Schema** — cases/documents/pages/words/entities/suggestions + decision event files or tables.  
3. **SSR** — `CREATE ROUTE … AS SELECT tera_render(...) AS html`.  
4. **Static** — `static_dir := '.'` for JS + pre-rendered page images + export dir.  
5. **JSON APIs** — one route per resource; typed path/query params.  
6. **Mutations** — `COPY`/`INSERT`/`UPDATE` in the route SELECT (or table-returning macros).  
7. **Bulk** — set-based SQL (`WHERE entity_id = $id`, band filters, or `json_each($ids)`).  
8. **FN add** — POST geometry fields → accepted suggestion row/event.  
9. **Export** — `pdf_redact` to `exports/`; return JSON `{exported, blocked, flagged_remaining}`; UI links static files.  
10. **Auth (when needed)** — `CREATE AUTH` + `REQUIRE`; bind `$claims_sub` as actor.  
11. **Long jobs (optional)** — `CREATE QUEUE export_jobs`; worker SQL loop dequeues and runs redact.

This is exactly Closure’s architecture. Clean-room React UIs can be served as static SPA **if** CORS + JSON APIs are enough; or keep tera SSR as Closure does.

---

## 7. Verdict (one page)

### Can the whole redaction-review app be built purely on quackapi?

**Yes.**  
Proof: Closure already does (HTML + JSON + mutations + PDF export + static assets) on the real extension. Clean-room feature lists add no HTTP capability that quackapi cannot express, except optional realtime collab.

### What is *not* pure-quackapi?

Companion extensions and OS files: **`pdf`**, **`tera`**, filesystem under `static_dir` / `exports/`. That is still “DuckDB-as-backend,” not a Node app server.

### What to add to quackapi first (punch-list)

| Priority | Change | Unblocks |
|---|---|---|
| **P0** | Configurable serve `memory_limit` (no blind 256 MB stomp) | Reliable review/export without secret post-serve SET |
| **P1** | Binary FileResponse (`file_bytes` + `content_type` [+ disposition]) | True download endpoints without static tree exposure |
| **P1** | Configurable payload max + multipart → BLOB | HTTP import of real PDFs |
| **P2** | Stream large responses | Huge HTML/JSON/file without double memory |
| **P2** | Generic response headers / SSE | Attachment polish; push progress |

Until those land: **use disk + static_dir + post-serve memory raise** — already proven.

### Bottom line

| Statement | Truth |
|---|---|
| “We need FastAPI for the review UI/API” | **False** for this product |
| “We need FastAPI to stream redacted PDFs” | **Only if** you refuse disk/static pattern and refuse the P1 FileResponse ext change |
| “quackapi is incomplete for Closure” | **Mostly false** — mature FastAPI-parity HTTP surface; remaining gaps are binary download, large upload, and serve memory config |
| “Build 100% inside CREATE ROUTE SQL?” | **Yes** for interactive review + audit + bulk + export-to-disk |

---

## Appendix A — key citations (paths)

| Topic | Path |
|---|---|
| Payload 8 MiB | `quackapi/src/include/quackapi_server.hpp:22–23` |
| Thread pool 32 | `quackapi/src/quackapi_server.cpp:740–742` |
| Response modes html/text/JSON | `quackapi/src/quackapi_server.cpp:652–669, 1534–1573` |
| Multipart bind | `quackapi/src/quackapi_server.cpp:1177–1191` |
| Memory stomp 256 MB | `quackapi/src/quackapi_extension.cpp:97–123` |
| Closure serve + memory raise | `closure/server/app.sql:174–178` |
| Closure routes | `closure/server/routes.sql:546–809` |
| FastAPI parity 89/89 | `quackapi/docs/FASTAPI_PARITY.md` |
| Clean-room APIs | `closure-cleanroom/attempt-*/src/app/api/**` |

## Appendix B — live experiment notes

Against built quackapi (2026-07-19):

| Probe | Result |
|---|---|
| JSON route | `[{"msg":"world"}]` |
| `AS html` | `Content-Type: text/html; charset=utf-8` |
| `AS BLOB` column | JSON string body, **not** binary |
| `STATUS 302` + `location` | 302 + `Location` header |
| Body > 8 MiB | **413** |

---

*End of feasibility assessment.*
