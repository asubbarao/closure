# Closure

AI-assisted **PDF redaction review** for FOIA / public-records release.

**One process:** DuckDB is the app. HTTP is quackapi. HTML is tera SSR. Mutations are append-only SQL. Browser: `static/app.js` (POST + reload) — no SPA.

Thesis: **better FastAPI for data products** — see [`docs/PLATFORM.md`](docs/PLATFORM.md).

## Product loop

| Step | Surface |
|------|---------|
| Library | `GET /` · `GET /cases/:id` |
| Entity stream | `GET /cases/:id/stream` — decide once, multi-doc |
| Review | `GET /documents/:id` · `/pages/:n` — PNG + marks |
| Decide | `POST /api/suggestions|entities/…/decision` · bands · accept-high · undo · marks |
| Export | `POST /api/cases/:id/export` (blocked while flagged pending) |
| Catalog | `GET /api/catalog/…` |
| Ops | `GET /api/ops/…` |
| Audit | `GET /cases/:id/audit` |
| OpenAPI | `GET /docs` · `/openapi.json` · `/redoc` |

Full route table: [`docs/HOW_IT_WORKS.md`](docs/HOW_IT_WORKS.md). Data: [`docs/DATA_MODEL.md`](docs/DATA_MODEL.md). Design write-up: [`docs/rationale.md`](docs/rationale.md).

## Stack

| Concern | How |
|---------|-----|
| Process | DuckDB ≥ **1.5.4** (`DUCKDB_BIN` if PATH is older) |
| HTTP | **quackapi** — `v_route_get` GETs + nested POSTs |
| Outbound | **curl_httpfs** + **cache_httpfs** (`.tmp/cache_httpfs`) |
| PDF | **pdf** — words, pages, `pdf_redact`, setup `pdf_to_png` |
| HTML | **tera** pages + `fragments/*` · **static/app.css** · **static/app.js** |
| Host / pins | **hostfs** · **scalarfs** · **zipfs** · **shellfs** |
| Schema graph | **semantic_views** (`closure_semantic.yaml`) |
| Checks | `smoke.sql` · Playwright e2e |

## Quick start

```sh
export DUCKDB_BIN=/opt/homebrew/bin/duckdb   # if `duckdb --version` < 1.5.4
make install
make setup     # samples + page PNGs
make run       # → http://127.0.0.1:8117/  and  /docs
make test      # fresh DB + Playwright
```

| Env | Role |
|-----|------|
| `CLOSURE_PORT` | Port (default 8117) |
| `CLOSURE_API_KEY` | Register API key; add `REQUIRE` to lock routes |
| `CLOSURE_POSTGRES` | ATTACH Postgres as `pg` |
| `CLOSURE_SAMPLE_ZIP` | LE case pack path |
| `DUCKDB_BIN` | DuckDB binary |

## Layout

```
server/
  app.sql            boot + serve
  extensions.sql     earned pack
  routes.sql         v_route_get + POST product writes
  views.sql          live views · ctx · page html
  core.sql · store.sql · hostfs · shellfs · http_cache · smoke
  templates/         pages + fragments/
  config/
static/              app.css · app.js
samples/ pages/ exports/
tests/e2e/           Playwright (smoke · FOIA loop · bulk/keyboard)
docs/                PLATFORM · HOW_IT_WORKS · DATA_MODEL · rationale
                     archive/ = history only
design/              UI mocks (not runtime)
```

## License

See `LICENSE`.
