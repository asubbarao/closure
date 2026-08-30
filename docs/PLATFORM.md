# Platform — DuckDB as a better FastAPI

**Role (post–takehome):** Closure is the **first quackapi reference app**, not a product to ship.
Point next projects (lookdown, …) here for **schema layout, route shape, extension composition**.
Product FOIA workflow is frozen; densify layout and feed **quackapi** / **pdf** extensions.

## FastAPI parity

| Concern | Here |
|---------|------|
| Serve | `quackapi_serve(port, …)` in `app.sql` |
| Routes | `CREATE ROUTE` — GETs from `v_route_get`, POSTs in `routes.sql` |
| OpenAPI | Live `/openapi.json`, `/docs`, `/redoc` |
| Auth | `CREATE AUTH` + optional `REQUIRE` (`CLOSURE_API_KEY`) |
| Outbound | **curl_httpfs** + **cache_httpfs** (`.tmp/cache_httpfs`) |
| Contracts | Tables + typed params — no second Pydantic layer |
| Checks | `tests/check.sql` (dqtest) + Playwright e2e |

**Thesis:** for data-shaped products (FOIA review, case packs, set-based bulk), this should beat FastAPI + ORM on honesty and composition.

**Densification:** score work by **debt deleted** (net LOC down after factoring), not AI-generated volume. Ideal surface: routes = `SELECT *`, HTML = unmat `tera_render` views, schema free from catalog, tables only for Poppler cost / append-only truth, path pins not dump yards. Cleanroom FastAPI trees are proof-of-contrast — not the target shape.

## Reference target (layout)

| Layer | Target shape | Today drag |
|-------|--------------|------------|
| Sources | unmat `v_src_*` over `pathvariable:` / hostfs | mostly good |
| PDF pins | `read_pdf_words` + `read_pdf_lines` → thin tables | good grain; still too many mid-tables |
| Detect | few pins + unmat folds | **`core.sql` ~560 LOC / 29 tables** — main lever → **~70–90 LOC** |
| Product | unmat `v_suggestions`, tera pages, `SELECT *` routes | routes OK; POST clones fat |
| Durable | append-only `decisions` | good |

**Primary lever now:** shrink `server/core.sql` (detect middle), not product features.
**Secondary:** Closure friction → **quackapi gap** or **pdf extension** enhancement (upstream), not app workarounds.

## Where Closure proves quackapi > FastAPI

- One process: HTTP + PDF + files + SQL model (no ORM/DTO skew)
- Routes are relations; OpenAPI from the same catalog
- Set-based detect/export in-process (`pdf_redact`, path pins)
- Append-only decisions without a second service

Real gaps (fix in **quackapi**, not by bolting uvicorn): see `~/personal/quackapi/docs/SUPERIORITY_ORDER.md` + bench; do **not** invent WebSockets/OIDC as “missing” without community stack (`radio`, `quack_oauth`, …).

## Path / effect planes

| Plane | Extension | Role |
|-------|-----------|------|
| Host tree | **hostfs** | typed path rows over `samples/`, `pages/`, … |
| Path pins | **scalarfs** | `pathvariable:` lists for multi-PDF pack |
| Archives | **zipfs** | `LOAD zipfs` once; read `zip://archive/member` like a file |
| Host effects | **shellfs** | `cmd \|` as a table source |
| Read cache | **cache_httpfs** | remote https/s3 after curl transport |
| Schema graph | **semantic_views** | `closure_semantic.yaml` |

## Boot order

```
build.sql: config → extensions → auth → hostfs pins → model
app.sql:   build.sql → routes → serve
```

Invariants are **not** on the serve path: `make check` → `tests/check.sql` reads the same `build.sql`.

## Env

| Variable | Role |
|----------|------|
| `CLOSURE_PORT` | HTTP (default 8117) |
| `CLOSURE_API_KEY` | Register API key |
| `DUCKDB_BIN` | Prefer ≥ 1.5.4 |

## Related

- [`HOW_IT_WORKS.md`](HOW_IT_WORKS.md) — product + API  
- [`DATA_MODEL.md`](DATA_MODEL.md) — tables / views  
- [`rationale.md`](rationale.md) — design write-up  
- History only: [`archive/`](archive/)
