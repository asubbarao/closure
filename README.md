# Closure

AI-assisted **PDF redaction review** for FOIA / public-records release.

**One process:** DuckDB is the app. HTTP is quackapi (`CREATE ROUTE`). HTML is tera. Mutations are append-only SQL. Browser is progressive enhancement (`static/app.js` → POST + reload).

Thesis: **better FastAPI for data products** — auth, OpenAPI, async outbound HTTP, host FS, shell, PDF, optional Postgres peer — without a second type system or ORM middle tier. See [`docs/PLATFORM.md`](docs/PLATFORM.md).

## Product loop

| Step | Surface |
|------|---------|
| Library | `GET /` · `GET /cases/:id` |
| Entity stream | `GET /cases/:id/stream` — decide once, case-wide |
| Page peek | `GET /documents/:id` · `/pages/:n` — PNG + marks |
| Decide | POST suggestion / entity / band / accept-high / undo / add |
| Export | POST export (blocked while flagged pending) |
| Audit | `GET /cases/:id/audit` |
| OpenAPI | `GET /docs` · `/openapi.json` · `/redoc` |

Details: [`docs/HOW_IT_WORKS.md`](docs/HOW_IT_WORKS.md) · data: [`docs/DATA_MODEL.md`](docs/DATA_MODEL.md) · design: [`design/`](design/) · assignment write-up: [`docs/rationale.md`](docs/rationale.md).

## Stack

| Concern | How |
|---------|-----|
| Process | DuckDB ≥ **1.5.4** (prefer quackapi-capable binary: `DUCKDB_BIN`) |
| HTTP | **quackapi** — routes, live OpenAPI, `CREATE AUTH` |
| Outbound HTTP | **curl_httpfs** — pool, HTTP/2, async |
| PDF | **pdf** — words, pages, `pdf_redact` |
| HTML | **tera** → **webbed** `parse_html` |
| Host tree | **hostfs** unmat `v_hostfs` (typed path scalars) |
| Path pins | **scalarfs** `pathvariable:` / `variable:` / `to_scalarfs_uri` |
| Case packs | **zipfs** (`v_zips`, optional `CLOSURE_SAMPLE_ZIP` + `zip_pin.sql`) |
| Shell | **shellfs** — `read_csv`/`read_json` **stream**; `read_text` **batch** |
| Metrics | **semantic_views** (`server/config/closure_semantic.yaml`) |
| Checks | `server/smoke.sql` (`make smoke`) |
| Optional Postgres | `ATTACH` when `CLOSURE_POSTGRES` set |
| Optional charts | **ggsql** (Grammar of Graphics in SQL) — not required for review |
| Client | `static/app.js` only (no SPA) |

## Quick start

```sh
# DuckDB ≥ 1.5.4 on PATH (or DUCKDB_BIN=…/quackapi/build/release/duckdb)
make install   # probe extensions
make setup     # samples + page PNGs
make run       # → http://127.0.0.1:8117/  and  /docs
```

| Env | Role |
|-----|------|
| `CLOSURE_PORT` | Port (default 8117) |
| `CLOSURE_API_KEY` | Register API key (`closure_api`; add `REQUIRE` on routes to lock) |
| `CLOSURE_POSTGRES` | ATTACH Postgres as `pg` |
| `CLOSURE_SAMPLE_ZIP` | Host path to LE `.zip` case pack |
| `DUCKDB_BIN` | Override duckdb binary |

## Tests

```sh
make test      # fresh DB + boot + Playwright
make smoke     # SQL invariants on existing closure.db
```

## Layout

```
server/            SQL app
  app.sql          boot + serve
  extensions.sql   community pack (incl. curl_httpfs)
  auth.sql         CREATE AUTH
  hostfs.sql       v_hostfs / v_zips
  shellfs.sql      shell recipes (stream vs batch)
  smoke.sql        schema/product gates
  postgres.sql     optional ATTACH
  zip_pin.sql      pin sample_* from a case zip
  config/          detector_rules.json, closure_semantic.yaml
  templates/       tera pages
static/app.js
samples/ pages/ exports/
tests/e2e/
docs/              PLATFORM, HOW_IT_WORKS, DATA_MODEL, rationale; archive/ for history
design/
```

## License

See `LICENSE`.
