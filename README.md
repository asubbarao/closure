# Closure

AI-assisted **PDF redaction review** for FOIA / public-records release.

**One process.** DuckDB builds the case model, serves HTTP, renders HTML, and writes decisions. There is no FastAPI/Fastify app beside it.

If you have never used [quackapi](https://github.com/query-systems/quackapi): treat `CREATE ROUTE` like a router registration, and `quackapi_serve` like `uvicorn.run`. Handlers are SQL. OpenAPI is live at `/docs`.

## Product loop

| Step | Surface |
|------|---------|
| Library | `GET /` · `GET /cases/:id` |
| Entity stream | `GET /cases/:id/stream` — decide once, multi-doc |
| Review | `GET /documents/:id` · `/pages/:n` — PNG + marks |
| Decide | `POST /api/…/decision` · bulk · undo · manual marks |
| Export | `POST /api/cases/:id/export` (blocked while flagged pending) |
| Audit | `GET /cases/:id/audit` |
| OpenAPI | `GET /docs` · `/openapi.json` |

## Quick start

```sh
export DUCKDB_BIN=/opt/homebrew/bin/duckdb   # if `duckdb --version` < 1.5.4
make install
make setup     # samples + page PNGs
make run       # → http://127.0.0.1:8117/  and  /docs
make check     # SQL invariants (no server)
make test      # check + Playwright e2e
```

| Env | Role |
|-----|------|
| `CLOSURE_PORT` | Port (default 8117) |
| `CLOSURE_API_KEY` | Optional API key on routes |
| `DUCKDB_BIN` | DuckDB ≥ 1.5.4 |

## Layout (outsider map)

```
server/
  app.sql            entrypoint: build model → register routes → serve
  build.sql          construct the model (no HTTP) — shared by app + tests
  model.sql          load order: store → paths → core → views
  store.sql          durable tables (decisions, telemetry types)
  core.sql           PDF pack → detect → suggestions / entities
  views.sql          product views + HTML pages (tera)
  routes.sql         HTTP: GET catalog + POST decision writers
  extensions.sql     INSTALL/LOAD community extensions once
  auth.sql           optional API key
  config.sql         env → app_config
  hostfs.sql         samples/pages/exports as typed path rows
  shellfs.sql        shell-as-table patterns (setup / ops)
  http_cache.sql     optional remote read-cache views
  judge.sql          LLM panel (votes on detect hits)
  templates/         SSR pages + fragments/
  config/            detector_rules.json · judges.json · semantic yaml
static/              app.css · app.js  (POST + reload — no SPA)
samples/             case PDFs + manifest.json + watchlist.json
pages/               page PNG previews (make setup)
exports/             redacted output
tests/
  check.sql          build model → dqtest (make check)
  dq_tests.json      invariants as data
  e2e/               Playwright
docs/                PLATFORM · HOW_IT_WORKS · DATA_MODEL · rationale
                     archive/ = history only
design/              UI mocks (not runtime)
```

**Boot path (read this once):**

```
app.sql
  └─ build.sql
       config → extensions → auth → hostfs pins → model.sql
         store → hostfs → shellfs → http_cache → core → views
  └─ routes.sql → quackapi_serve
```

`make check` runs the same `build.sql` and asserts on the tables — no HTTP.

## Stack in one table

| Concern | Mechanism |
|---------|-----------|
| Process | DuckDB ≥ 1.5.4 |
| HTTP + OpenAPI | **quackapi** (`CREATE ROUTE`, `quackapi_serve`) |
| PDF words / redact | **pdf** community extension |
| HTML | **tera** templates under `server/templates/` |
| Files | **hostfs** + **scalarfs** path pins (`samples/…`) |
| Zip members | **zipfs** (`LOAD` in extensions; open `zip://…` like any path) |
| Shell effects | **shellfs** (`cmd \|` as table source) |
| Checks | `tests/check.sql` (dqtest) · Playwright e2e |

## Docs

| Start here | |
|------------|--|
| [`docs/HOW_IT_WORKS.md`](docs/HOW_IT_WORKS.md) | product + routes |
| [`docs/PLATFORM.md`](docs/PLATFORM.md) | why DuckDB instead of FastAPI |
| [`docs/DATA_MODEL.md`](docs/DATA_MODEL.md) | tables / views |
| [`docs/rationale.md`](docs/rationale.md) | design write-up |

## License

See `LICENSE`.
