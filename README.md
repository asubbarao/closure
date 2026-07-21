# Closure — AI-assisted redaction review

A working prototype of an AI-powered **PDF redaction review** tool for law
enforcement public-records release. One DuckDB process is the database, the
HTTP server, the PDF engine, and the HTML renderer.

> **Backend thesis:** DuckDB + the real **quackapi** extension *is* the backend;
> Tera renders the frontend. Load the built `.duckdb_extension`, `CREATE ROUTE`,
> `quackapi_serve`.

## Stack

| Concern | Implementation |
|---------|----------------|
| Database | DuckDB (serverless file DB) |
| PDF text + coordinates | `pdf` community extension (`read_pdf_words`, `pdf_info`, `pdf_redact`) |
| HTML | `tera` extension (`tera_render`) |
| HTTP | **quackapi** (`CREATE ROUTE` + `quackapi_serve`) |
| Mutations | append-only JSON under `exports/decisions/*.json` (event log → `v_suggestions`) |

No React. No shellfs. No `mutate.sh`. Confidence bands and entity bulk are real.

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
| **macOS or Linux** | Prebuilt runtime / source build | Windows not supported yet |
| **Network (first run)** | Download runtime + community extensions (`pdf`, `tera`, `fakeit`, `rapidfuzz`, `finetype`, `us_address_standardizer`) | Ordinary HTTPS |
| **poppler** (recommended) | Fast page-PNG previews | `brew install poppler` / `apt install poppler-utils` |
| **Node 18+** | Playwright e2e only | `make test` installs deps under `tests/e2e` |

You do **not** need to clone or understand [quackapi](https://github.com/asubbarao/quackapi). Closure installs a pinned DuckDB + quackapi **binary pair** into local `.deps/runtime/` (gitignored). quackapi source is **never** vendored into this repo.

## Quick start (graders)

```sh
git clone https://github.com/asubbarao/closure.git
cd closure

make install          # download (or build) DuckDB + quackapi → .deps/runtime/
make setup            # sample PDFs + page PNGs
make run              # → http://127.0.0.1:8117/
```

`make install` is `./scripts/install-runtime.sh`:

1. Reuse `.deps/runtime` if already installed  
2. Else copy a sibling `../quackapi/build/release` (local dev only)  
3. Else download a prebuilt tarball from this repo’s [Releases](https://github.com/asubbarao/closure/releases)  
4. Else clone + build quackapi into `.deps/src/` (needs `cmake` + `ninja`; 10–30+ min)

`make setup` generates the sample corpus and will call `install-runtime` if `.deps/runtime` is missing.  
`make run` boots fresh (`run.sh` → `server/app.sql`).  
`make test` boots and runs Playwright.  
`make clean` drops `closure.db` and decision JSON (not `.deps/`).

### No-make path

```sh
./scripts/install-runtime.sh
./scripts/setup.sh
./run.sh
# → http://127.0.0.1:8117/
```

### Configuration — one relation

All knobs live in `app_config(key, value, source)` (`server/config.sql`,
loaded first). Every row obeys one rule: `CLOSURE_<KEY>` env wins when set and
non-empty, else the committed default. The boot log prints the resolved table.

| Env | app_config key | Default | Purpose |
|-----|----------------|---------|---------|
| `CLOSURE_PORT` | `port` | `8117` | HTTP listen port |
| `CLOSURE_STATIC_DIR` | `static_dir` | `.` | `quackapi_serve` static root |
| `CLOSURE_SAMPLES_DIR` | `samples_dir` | `samples` | ingest PDF/manifest/identities dir |
| `CLOSURE_EXPORTS_DIR` | `exports_dir` | `exports` | redacted-PDF target prefix |
| `CLOSURE_DECISIONS_GLOB` | `decisions_glob` | `exports/decisions/*.json` | decision-log **read** glob (writes are `COPY TO` literals under `exports/decisions/`) |
| `CLOSURE_QUACKAPI_EXT` | `quackapi_ext` | `.deps/runtime/…` after install | path to `quackapi.duckdb_extension` |
| `CLOSURE_ACTOR` | `actor` | `A. Subbarao` | "Reviewing as" identity stamped into templates |
| `DUCKDB_BIN` | — | `.deps/runtime/duckdb` after install | DuckDB binary for `run.sh` / setup |
| `CLOSURE_RUNTIME_TAG` | — | `runtime-v1.5.4-1` | GitHub Release tag for the prebuilt runtime |

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
  app.sql             boot: config → extensions → ingest → seed → integrity → routes → serve
  config.sql          app_config(key, value, source) — env-overridable knobs + cfg_* macros
  ingest.sql          PDF + identities/manifest CTAS load
  seed.sql            roster-matched suggestions + v_suggestions projection
  pdf_io.sql          sole live export SQL builders (boxes + pdf_redact)
  load_templates.sql  server/templates/*.html → app_templates
  routes/             CREATE ROUTE by resource (pages, documents, decisions, export, …)
  templates/          Tera HTML
samples/              PDFs + identities.json + manifest.json
pages/                pre-rendered page PNGs (served as static)
exports/              redacted PDFs + decisions/*.json event log
static/               client JS (review, dashboard, add-missed, …)
docs/                 design notes + extension surveys
design/               UX flows and wireframes
spikes/               isolated feasibility experiments behind design decisions
                      (marisa vs hash join, pdf_revisions custody, OCR, …);
                      each owns only its own dir — nothing here is loaded by the app
tests/                Playwright e2e (tests/e2e) + stress harness (tests/stress)
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

1. **Append-only event log** — each decision/add is a JSON file under
   `exports/decisions/`. Suggestion status is a **projection** (`v_suggestions`
   = seed rows ∪ latest decision ∪ manual adds).
2. **Geometry** — PDF points, top-left origin from `read_pdf_words`. Export flips
   Y once in `pdf_io.sql` for `pdf_redact` (bottom-left).
3. **Entities** — PII catalog from `identities.json` (answer key).
4. **Suggestions** — seeded at boot from roster × word n-grams (not empty).

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

`scripts/setup.sh` runs pure DuckDB (`samples/gen/01_identities.sql` +
`02_corpus.sql` via fakeit + `write_pdf`) then renders `pages/<stem>/pN.png`
with `pdftoppm`. Scripts resolve DuckDB via `.deps/runtime` (after
`make install`), then `$DUCKDB_BIN`, then PATH. Commit no sample PDFs —
clone → install → setup → boot.

## Design rationale

See `docs/rationale.md` (assignment Part 3) and `docs/punch-list.md` for the
execution queue of known gaps.
