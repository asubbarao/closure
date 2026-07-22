# Closure — AI-assisted redaction review

A working prototype of an AI-powered **PDF redaction review** tool for law
enforcement public-records release. One DuckDB process is the database, the
HTTP server, the PDF engine, and the HTML renderer.

> **Backend thesis:** DuckDB + **quackapi** *is* the backend — one process, community
> `INSTALL`/`LOAD`, FastAPI-shaped HTTP over SQL. Tera file-mode for HTML. LOC is the
> collapse scoreboard (not golf).

**Know FastAPI already?** Open [`docs/HOW_IT_WORKS.md`](docs/HOW_IT_WORKS.md) (2 min),
then read `server/app.sql` → `store.sql` → `domain/fold.sql` → top of `routes.sql`.
The “wtf” should be *SQL is the handler* — not a tangle of frameworks.

## Stack

| Concern | Implementation |
|---------|----------------|
| Process | **One** DuckDB process: `INSTALL … FROM community` / `LOAD …` (quackapi, pdf, tera, …) |
| HTTP | **quackapi** — `CREATE ROUTE` + `quackapi_serve` (FastAPI-shaped params → 422) |
| PDF text + boxes + export | `pdf` — `read_pdf_words`, `pdf_info`, `pdf_redact` |
| HTML | **tera file-mode** — `tera_render('page.html', ctx, template_path := …)` → column `html` |
| N-way / dynamic SQL | **Self-dispatch** in-query (ATTACH self / loopback) when it deletes a for-loop — same idea as airport self-`take_flight` |
| Host / API-class work | **shellfs** / `http_client` as CTE rows — no FastAPI client SDK stack |
| Page previews | Static `pages/<stem>/pN.png` from setup (`pdf_page_images` + `COPY … (FORMAT BLOB)`; no host poppler) |
| Mutations | append-only `decisions` (`INSERT` → fold → `v_suggestions`) |
| Scoreboard | **LOC / files** vs FastAPI·Fastify·Rails multi-file apps for the same surface |
| Map | [`docs/HOW_IT_WORKS.md`](docs/HOW_IT_WORKS.md) |

No React. Confidence bands and entity bulk are real.

## For reviewers — where each assignment challenge lives

| Challenge | Where to click / look |
|-----------|------------------------|
| **False positives** (e.g. "Hayes Street" / "Hayes v. Ohio" flagged for subject Hayes) | Reject (`r`) + reject-all-matching; low-confidence hits land in the FLAGGED band, which **hard-blocks export** until resolved |
| **False negatives** (missed PII) | Add-missed (`n` + drag a box) and the remainder scan (`/api/documents/:id/missed`), which re-scans uncovered text with fuzzy/format detectors |
| **Volume** (hundreds of suggestions) | Confidence bands HIGH / REVIEW / FLAGGED, keyboard triage (`j`/`k`/`a`/`r`), entity- and band-level bulk decisions |
| **Multi-document packages** | Case dashboard → document rail; entity decisions fan out across every document in the case |
| **Context / disambiguation** | The canvas shows the hit in place with surrounding text; citation-vs-subject conflicts carry flag tags and a judge panel |
| **Audit trail** | Append-only decision event log; `/cases/:id/audit` renders the full history — undo is another event, never a delete |

Design rationale (assignment Part 3): [`docs/rationale.md`](docs/rationale.md).
High-fidelity design (Part 1): [`design/`](design/).

## Prerequisites

| Need | Why | How |
|------|-----|-----|
| **DuckDB ≥ 1.5.4** on `PATH` | Host binary | [Install DuckDB](https://duckdb.org/docs/installation/) |
| **Network (first run)** | `INSTALL … FROM community` (`quackapi`, `pdf`, `tera`, …) | Ordinary HTTPS |
| **Node 18+** | Playwright e2e only | `make test` |

Page PNG previews are produced by the community **`pdf`** extension
(`pdf_page_images` + `COPY … (FORMAT BLOB)`), not host `pdftoppm`/poppler.
Prefer a **pdf** build that bundles base-14 fonts (duckdb-read_pdf ≥ **0.7.3**);
older community packages can emit blank pages. To force a local extension:

```sh
PDF_EXTENSION=/path/to/pdf.duckdb_extension ./scripts/setup.sh
```

**quackapi** is a normal community extension:

```sql
INSTALL quackapi FROM community;
LOAD quackapi;
```

## Quick start (graders)

```sh
git clone https://github.com/asubbarao/closure.git
cd closure

# DuckDB 1.5.4+ on PATH, then:
make install          # INSTALL quackapi FROM community (probe)
make setup            # sample PDFs + page PNGs
make run              # → http://127.0.0.1:8117/
```

`make run` → `run.sh` → `duckdb closure.db -c ".read server/app.sql"`.  
`make test` wipes `closure.db` then boots + Playwright.  
`make clean` drops `closure.db`.

### No-make path

```sh
duckdb -c "INSTALL quackapi FROM community; LOAD quackapi;"
./scripts/setup.sh
./run.sh
```

### Configuration — one relation

All knobs live in `app_config(key, value, source)` (`server/config.sql`).
`CLOSURE_<KEY>` env wins when set and non-empty, else the default.

| Env | app_config key | Default | Purpose |
|-----|----------------|---------|---------|
| `CLOSURE_PORT` | `port` | `8117` | HTTP listen port |
| `CLOSURE_STATIC_DIR` | `static_dir` | `.` | `quackapi_serve` static root |
| `CLOSURE_SAMPLES_DIR` | `samples_dir` | `samples` | ingest PDF/manifest dir |
| `CLOSURE_EXPORTS_DIR` | `exports_dir` | `exports` | redacted-PDF prefix |
| `CLOSURE_ACTOR` | `actor` | `$USER` | reviewer identity in templates |
| `DUCKDB_BIN` | — | `duckdb` on `PATH` | override binary |

`GET /api/routes` returns the full route map as JSON — generated from the live
`quackapi_routes()` registry joined to the parsed `CREATE ROUTE` declarations
(`v_routes`), so it cannot drift; the boot summary prints the route count.

After `quackapi_serve` starts, boot re-raises `memory_limit` / `max_memory` to
**4GB** (quackapi’s serve guard stomps them to 256MB).

Boot **fails loudly** if `documents=0` or `suggestions=0` (sample triad desync
of `manifest.json` × `identities.json` × `samples/*.pdf`), with orphan diagnostics.

## Layout

```
server/
  app.sql             main: config → extensions → model → routes → serve
  store.sql           durable decisions table + bbox type
  model.sql           load order (raw → typed → domain → serve)
  raw/  typed/        file readers → join-ready views
  domain/             facts CTAS, detect, fold → v_suggestions
  serve/              UI marts + optional extras
  routes.sql          CREATE ROUTE (HTTP only)
  templates/          Tera HTML
samples/              PDFs + manifest + watchlist
pages/                page PNG previews (static)
exports/              redacted PDF output
static/               client JS
docs/HOW_IT_WORKS.md  read this first if you know FastAPI
tests/e2e             Playwright
```

## Routes (primary)

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/` | Case dashboard (case 1 wired today) |
| GET | `/cases/:id` | Case dashboard |
| GET | `/documents/:id` · `/documents/:id/pages/:page` | Review canvas |
| GET | `/cases/:id/audit` | Audit log HTML |
| GET | `/ui/add-missed` · `/ui/reject` · `/ui/bulk` | FN / FP / bulk shells |
| GET | `/api/cases/:id/suggestions` | JSON suggestions |
| GET | `/api/documents/:id/suggestions` | Per-doc suggestions |
| POST | `/api/suggestions/:id/decision?status=` | Accept / reject / undo |
| POST | `/api/entities/:id/decision?status=` | Entity-wide bulk decision |
| POST | `/api/documents/:id/band/:band/decision?status=` | Band bulk (flagged excluded) |
| POST | `/api/documents/:id/add` | Manual add-missed (coords as DOUBLE) |
| GET | `/api/search?q=&case=` | Case word search |
| GET | `/api/routes` | Full route map (from `quackapi_routes()` + parsed declarations) |
| GET | `/api/cases/:id/export_plan` | Live plan + `blocked` / box SQL |
| POST | `/api/cases/:id/export` | **Live** `pdf_redact` from plan `sql` body; **hard-block** if flagged pending (`exported:0`, no files) |

POST bodies: send `Content-Type: application/json` with `{}` when the client has no body fields (query/path still bind).

## Data model (decisions)

1. **Append-only table** — `decisions` (`INSERT` only). Status is a **projection**
   in `v_suggestions` (latest event per `suggestion_id` + AI / manual proposals).
2. **Geometry** — type `bbox`; pack once from `read_pdf_words`. Export flips Y
   once for `pdf_redact` (bottom-left).
3. **Entities / suggestions** — built at boot from samples + detect (watchlist,
   finetype, rapidfuzz). Detectors never write status.

## Export contract

- Boxes are built **at request time** from current `status='accepted'` rows
  (`GET …/export_plan` → `export_sql` with live `{page,x,y,w,h}` literals).
- `POST …/export` with JSON
  `{"sql":"<export_sql from plan>","blocked":<plan.blocked>}` runs that SQL
  (DuckDB `query()` requires a foldable string — not a subquery of
  `build_export_sql`). `blocked` defaults to **true** (fail-closed). The case
  dashboard does plan-then-export automatically.
- If any `band='flagged'` suggestion is still `pending`, pass `blocked:true`
  (and a no-op `sql`); the foldable short-circuit means **no** `pdf_redact`
  and `{exported:0, blocked:true, flagged_remaining:N}`.
- When clear, every case document is redacted to
  `exports/{stem}_redacted.pdf`.

## Test status

```sh
cd tests/e2e && npm install && npx playwright install chromium   # first time
npx playwright test --reporter=line
```

Latest run: **25 passed, 1 failed, 2 skipped** (28 total, chromium; the skips
are data-state guards on an almost-fully-decided corpus, not broken features).

## Honest limits

- **Not** a multi-tenant SaaS; localhost demo with a single reviewer actor string.
- **Not** a claim that interactive open of ~1 GB PDFs fits under DuckDB
  `memory_limit` — Poppler RSS tracks file size; samples are small; stress
  corpus lives under `samples/stress/` for offline probes.
- Image-only scans, AcroForm `/V`, and annotation text can survive word-box
  redaction (out of MVP).
- `pages/` PNGs must match ingested stems or the canvas background 404s
  (boxes still paint).
- **Known issue:** `tests/e2e/specs/06-confidence-display.spec.ts` — "band
  filters hide and show suggestions" — when toggling a band empties the queue,
  the UI does not render the `#q-list .empty-q` placeholder the spec expects.
  Cosmetic (filtering itself works); surfaces only on a nearly-fully-decided
  corpus.
- `run.sh` is a thin wrapper (env/path resolution + fresh DB) that delegates
  straight to `server/app.sql`, which does all schema/ingest/route/serve
  ordering — use `make run` or `run.sh` and it'll always match `app.sql`.

## Regenerating samples

```sh
./scripts/setup.sh
# optional: N_CASES=4 DOCS_PER_CASE=2 CONSOLIDATED_PAGES=110 ./scripts/setup.sh
# optional: ./scripts/setup.sh --reuse-identities   # keep identities.json cast
```

`scripts/setup.sh` runs pure DuckDB (`samples/gen/corpus.sql` via fakeit +
`write_pdf`) then rasters `pages/<stem>/pN.png` with community **`pdf`**
(`pdf_page_images` → `COPY … (FORMAT BLOB)`; see `scripts/setup_pages.sql`).
No host poppler. DuckDB is whatever is on `PATH` (or `$DUCKDB_BIN`, ≥ 1.5.4).
Commit no sample PDFs — clone → install → setup → boot.

## Design rationale

See `docs/rationale.md` (assignment Part 3) and `docs/punch-list.md` for the
execution queue of known gaps.
