# Closure — AI-assisted redaction review

A working prototype of an AI-powered **PDF redaction review** tool for law
enforcement public-records release. One DuckDB process is the database, the
HTTP server, the PDF engine, and the HTML renderer.

> **Backend thesis:** DuckDB + the real **quackapi** extension *is* the backend;
> Tera renders the frontend. Not the old SQL-only `brain` / `serve_brain`
> prototype — `LOAD` the built `.duckdb_extension`, `CREATE ROUTE`, `quackapi_serve`.

> This pass ships the **real machine on real data**: PDF word boxes, pages,
> entities from the answer key, event-sourced audit, and the review UI shell.
> The `suggestions` table is **empty** — seeding AI proposals is a later step.

## Stack

| Concern | Implementation |
|---------|----------------|
| Database | DuckDB (serverless) |
| PDF text + coordinates | `pdf` community extension (`read_pdf_words`, `pdf_info`, `pdf_redact`) |
| HTML | `tera` extension (`tera_render`) |
| HTTP | **real** quackapi extension (`CREATE ROUTE` + `quackapi_serve`) |
| Mutations | `shellfs` + `server/mutate.sh` (JSONL audit sidecar — no lock fight) |

No React. No fabricated confidence scores in this pass. No `brain_thing()`,
no `serve_brain`, no hand-rolled `framework.sql` route table.

## Quick start

```sh
./run.sh
# → http://127.0.0.1:8117/
```

Requires the quackapi-built duckdb binary and extension (defaults):

- `DUCKDB_BIN` → `/Users/aloksubbarao/personal/quackapi/build/release/duckdb` (v1.5.4)
- `QUACKAPI_EXT` → `…/extension/quackapi/quackapi.duckdb_extension`

`run.sh` feeds SQL via a sequential stdin session so `LOAD quackapi` registers
the parser extension **before** `CREATE ROUTE` is parsed.

### Static fallback (no server)

After ingest, HTML is also written to `static/`:

- `static/index.html` — all cases
- `static/case_1.html` — case dashboard
- `static/document_1_p1.html` — review page with real word boxes

## Layout

```
server/
  schema.sql          data model (event-sourced audit; empty suggestions)
  ingest.sql          real PDF + identities/manifest load (no VALUES)
  load_templates.sql  server/templates/*.html → app_templates
  routes.sql          real CREATE ROUTE DDL + tera macros
  render_static.sql   COPY HTML → static/
  mutate.sh           POST decision/export side effects
  export_case.sh      identity-copy export while suggestions empty
  seed.sql            DEFERRED — not loaded at boot
  templates/          Tera HTML (mockup CSS verbatim)
design/               hi-fi mockups (source of CSS)
samples/              real PDFs + identities.json + manifest.json
pages/                pre-rendered page PNGs (static_dir)
exports/              redacted PDFs + audit_sidecar.jsonl
static/               rendered HTML fallback
run.sh                boot: LOAD real quackapi → routes → serve
```

## Routes

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/` | Multi-case dashboard (real counts) |
| GET | `/cases/:id` | Case dashboard (mockup 01) |
| GET | `/documents/:id` | Review page, page 1 (mockup 02) |
| GET | `/documents/:id/pages/:page` | Review page N |
| GET | `/cases/:id/audit` | Audit log |
| POST | `/cases/:id/export` | Export → `exports/` + audit row |
| POST | `/suggestions/:id/decision?action=` | Decision → audit row |
| GET | `/api/stats` | JSON counts |
| GET | `/api/documents/:id/words` | Real word boxes (page 1 sample) |
| GET | `/ui/reject`, `/ui/add-missed`, `/ui/bulk` | Mockup shells |

POST bodies: send `Content-Type: application/json` with `{}` (empty body → 400).

Prove the real extension while the server is up:

```sql
SELECT * FROM quackapi_routes();
SELECT * FROM quackapi_servers();
```

## Data model (decisions)

1. **Append-only audit** — decisions are events; suggestion status is a projection (`v_suggestions`).
2. **Geometry** — PDF points, top-left origin from `read_pdf_words`.
3. **Entities** — PII catalog from `identities.json` (real answer-key values).
4. **Suggestions** — empty this pass (seed deferred).

## Regenerating samples

See `samples/gen/` (fakeit → typst). `identities.json` is a frozen answer key.
