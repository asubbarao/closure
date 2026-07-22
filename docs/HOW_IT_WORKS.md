# How Closure works

One DuckDB process is the app: HTTP, PDF, HTML, FS, shell. Handlers are SQL. UI is **tera SSR**. Browser is progressive enhancement (`static/app.js` → POST → reload).

Platform thesis: [`PLATFORM.md`](PLATFORM.md). Data: [`DATA_MODEL.md`](DATA_MODEL.md). Design write-up: [`rationale.md`](rationale.md).

## FastAPI map

| You know | Here |
|----------|------|
| `uvicorn` + routers | `app.sql` + `CREATE ROUTE` (from `v_route_get` + POSTs) |
| OpenAPI | Live `/docs` · `/openapi.json` · `/redoc` |
| Auth | `CREATE AUTH` + optional `REQUIRE` (`CLOSURE_API_KEY`) |
| Outbound HTTP | **curl_httpfs** (transport) + **cache_httpfs** (read cache) |
| Models / services | `store` → `core` (tables) → `views` (ctx + html) |
| Jinja | `tera_render(template, ctx, template_path := 'server/templates/**/*.html')` |
| Templates | Pages + `fragments/*`; CSS/JS in `static/` (not inlined in SQL) |
| pathlib / shell | **hostfs** / **scalarfs** / **shellfs** / **zipfs** |
| Postgres | Optional `ATTACH` (`CLOSURE_POSTGRES`) |
| Contract checks | `server/smoke.sql` · Playwright e2e |

**Do not** wrap page HTML in `parse_html` — webbed voids `<script src>` and kills `app.js`.

## Boot

```
config → extensions (httpfs → curl_httpfs → cache_httpfs → …)
  → auth → hostfs → scalarfs pins → [postgres]
  → model (store · hostfs · shellfs · http_cache · core · views)
  → routes (v_route_get → install GET DDL · POST writes)
  → smoke → quackapi_serve(http_client := 'auto')
```

```sh
make setup && make run    # http://127.0.0.1:8117/  and  /docs
# DuckDB ≥ 1.5.4:  export DUCKDB_BIN=/opt/homebrew/bin/duckdb
```

## Layers

| Layer | Owns |
|-------|------|
| **Tables** (`core.sql`) | Facts + display pins |
| **Live views** | Decision fold, marks px, export gate |
| **Ctx views** | `json_object` bags for tera (`v_*_ctx`) |
| **Page views** | `path` + `html` (`v_case_html`, `v_review_page`, …) |
| **GET routes** | `v_route_get` only → generated `CREATE ROUTE` |
| **POST routes** | Resource-nested decisions / export (explicit PARAM) |
| **Client** | `data-action` + keyboard; no SPA state |

## HTTP surface (current)

### Pages (SSR)

| Method | Path |
|--------|------|
| GET | `/`, `/cases/:id`, `/cases/:id/stream`, `/cases/:id/audit` |
| GET | `/documents/:id`, `/documents/:id/pages/:page` |

### Product API

| Method | Path | Role |
|--------|------|------|
| GET | `/api/cases/:id/nav` | Nav links |
| GET | `/api/cases/:id/metrics` | Semantic status × band |
| GET | `/api/suggestions/:id/context` | ±3 lines (read_lines) |
| POST | `/api/suggestions/:id/decision` | Decide one · **201** |
| POST | `/api/entities/:id/decision` | Entity bulk (skip flagged) · **201** |
| POST | `/api/documents/:id/bands/:band/decision` | Band bulk · **201** |
| POST | `/api/documents/:id/marks` | Manual miss · **201** |
| POST | `/api/cases/:id/accept-high` | Case-wide HIGH · **201** |
| POST | `/api/cases/:id/undo` | Undo last batch · **201** |
| POST | `/api/cases/:id/export` | `pdf_redact` if not blocked |

### Catalog (allowlisted)

| Method | Path |
|--------|------|
| GET | `/api/catalog` |
| GET | `/api/catalog/:relation` |
| GET | `/api/catalog/:relation/rows` |
| GET | `/api/catalog/:relation/summary` |

### Ops (machine / debug — not the FOIA loop)

| Method | Path |
|--------|------|
| GET | `/api/ops/hostfs`, `/zips`, `/shell` |
| GET | `/api/ops/cache`, `/cache/status`, `/cache/access` |
| GET | `/api/ops/hosts`, `/templates`, `/semantic` |

Lock routes: `REQUIRE closure_api` after `CLOSURE_API_KEY`.

## Templates & assets

```
server/templates/
  base.html · case.html · stream.html · review.html · audit.html
  fragments/   case_actions · entity_row · mark · sugg_row · status_tally
static/
  app.css · app.js     # style + data-action / keyboard only
```

## Data (short)

- **decisions** append-only; status = latest fold on `v_suggestions`
- Detect: finetype + rapidfuzz + bloom (+ metaphone) → suggestions / entities
- Export blocked while flagged pending (`v_export_blocked`)

## Checks

```sh
make test     # fresh DB + boot + Playwright (needs DuckDB ≥ 1.5.4)
make smoke    # SQL invariants on existing closure.db
```

## Not product

- SPA / second app tier for the review loop  
- Warehouse DAGs for interactive FOIA  
- Arbitrary shell over HTTP (ops recipes only)  
- Historical surveys → [`archive/`](archive/)
