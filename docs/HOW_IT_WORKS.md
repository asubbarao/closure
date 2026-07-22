# How Closure works

One DuckDB process is the application: DB + HTTP + PDF + HTML + FS + shell. Handlers are SQL. UI is tera SSR. Browser mutates then reloads.

This is intentional as a **better FastAPI for data products** — not a downgrade. Platform notes: [`PLATFORM.md`](PLATFORM.md).

## FastAPI map

| You know | Here |
|----------|------|
| `uvicorn` + routers | `app.sql` + `CREATE ROUTE` |
| OpenAPI / Swagger | **`/docs`**, **`/openapi.json`**, **`/redoc`** (quackapi, live) |
| Depends / API key / JWT | `CREATE AUTH` + `REQUIRE` (`server/auth.sql`; `CLOSURE_API_KEY`) |
| httpx / async client | **curl_httpfs** (pool, HTTP/2, async outbound) |
| models / services | `store` → `core` (tables) → `views` (live + pages) |
| Jinja | `tera_render(…, template_path := …)` → `parse_html` |
| subprocess / pathlib | **shellfs** / **hostfs** / **scalarfs** / **zipfs** |
| Postgres | Optional `ATTACH` (`CLOSURE_POSTGRES`, `server/postgres.sql`) |
| pytest types | **`server/smoke.sql`** / optional dqtest — schema is the contract |
| SPA re-paint | POST + `location.reload()` (`static/app.js`) |

## Boot

```
config → extensions (curl_httpfs + …) → auth
  → hostfs views → scalarfs path pins
  → optional postgres attach
  → model → routes → smoke → quackapi_serve → re-raise memory_limit
```

Entry: `make run` → `run.sh` → `.read server/app.sql`.

## Model layers

| Layer | Owns | Extend by |
|-------|------|-----------|
| **Tables** (`core.sql`) | Facts + display pins | New stable column at CTAS |
| **Live views** | Decision fold, mark px, export gate | Thin join over live state |
| **Page views** | `parse_html(tera…)` only | Pack JSON once at page edge |
| **Routes** | `SELECT html` / `INSERT … RETURNING` | Never re-derive labels |

## Formats & planes

| Kind | How |
|------|-----|
| Host tree | Unmat **`v_hostfs`** (hostfs scalars — not string path hacks) |
| Path pins | scalarfs `COPY … (FORMAT variable)` → `pathvariable:` |
| LE zip packs | **zipfs** `archive_contents` / `zip://…/member` (`v_zips`) |
| Shell | **stream:** `read_csv` / `read_json(_auto)` on `cmd \|` · **batch:** `read_text` |
| JSON | `read_json_auto` (manifest, watchlist, detector_rules) |
| YAML | `read_yaml` + semantic `FROM YAML FILE` |
| HTML | tera → webbed `parse_html` |
| Metrics | `semantic_view('closure', …)` — dimensions not count pivots |
| Charts (optional) | **ggsql** Grammar of Graphics — see PLATFORM.md |

## Product routes

| Method | Path | Role |
|--------|------|------|
| GET | `/`, `/cases/:id` | Library |
| GET | `/cases/:id/stream` | Entity stream |
| GET | `/documents/:id`, `/pages/:n` | Review peek |
| GET | `/cases/:id/audit` | Audit |
| GET | `/docs`, `/openapi.json`, `/redoc` | OpenAPI |
| GET | `/api/cases/:id/nav` | Doc + shell hrefs |
| GET | `/api/cols`, `/api/rel/:relation` | Catalog (allowlisted) |
| GET | `/api/hostfs`, `/api/zips`, `/api/shell/patterns` | Host / pack / shell recipes |
| POST | `/api/suggestions/:id/decision` | Decide one |
| POST | `/api/entities/:id/decision` | Entity bulk (no flagged) |
| POST | `/api/documents/:id/band/:band/decision` | Band bulk |
| POST | `/api/cases/:id/accept-high` | Accept high confidence |
| POST | `/api/documents/:id/add` | Manual miss |
| POST | `/api/undo` | Inverse latest batch |
| POST | `/api/cases/:id/export` | `pdf_redact` when not blocked |

Lock a route: `REQUIRE closure_api` after `CLOSURE_API_KEY` is registered.

## Data model (short)

- **decisions** append-only; status = fold (`max_by` latest event) on `v_suggestions`
- Detect: finetype + rapidfuzz (+ bloom) → `suggestions` + `entities`
- Export hard-block while any flagged pending (`v_export_blocked`)

## Checks

```sh
make smoke    # after a boot that left closure.db
# or: duckdb closure.db -c ".read server/smoke.sql"
```

## Not product

- Warehouse DAG tools (e.g. duck-orch) — wrong shape for interactive FOIA
- Raw HTTP shell execution of arbitrary `cmd` — recipes only (`v_shell_patterns`)
- SPA / second app tier for the graded loop

## Size

SQL + few templates + one JS file. If a line doesn’t delete a host/SPA layer or earn a real relation, it doesn’t belong.
