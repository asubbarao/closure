# Platform — DuckDB as a better FastAPI

Closure is a **full application runtime** in one process: HTTP, auth, OpenAPI, files, shell, PDF, optional Postgres peer.

## FastAPI parity

| Concern | Here |
|---------|------|
| Serve | `quackapi_serve(port, memory_limit, http_client := 'auto')` |
| Routes | `CREATE ROUTE` — GETs from `v_route_get`, POSTs explicit |
| OpenAPI | Live `/openapi.json`, `/docs`, `/redoc` |
| Auth | `CREATE AUTH` + `REQUIRE`; `CLOSURE_API_KEY` |
| Outbound | **curl_httpfs** (MultiCurl transport) + **cache_httpfs** (on-disk read cache under `.tmp/cache_httpfs`) |
| Contracts | Tables, typed params, `bbox` — no second Pydantic layer |
| Checks | `tests/check.sql` (dqtest, declarative) + Playwright e2e |
| Peer SQL | `ATTACH … AS pg` when `CLOSURE_POSTGRES` set |

**Thesis:** for data-shaped products (FOIA review, case packs, set-based bulk), this should beat FastAPI + ORM on honesty and composition.

## Path / effect planes

| Plane | Extension | Role |
|-------|-----------|------|
| Host tree | **hostfs** | `v_hostfs` — typed path scalars |
| Path pins | **scalarfs** | `variable:` / `pathvariable:` / `to_scalarfs_uri` |
| Case packs | **zipfs** | `zip://` + `archive_contents` (`v_zips`) |
| Host effects | **shellfs** | `cmd \|` — stream CSV/JSON vs batch `read_text` |
| Read cache | **cache_httpfs** | Remote https/s3/hf after curl transport |
| Schema graph | **semantic_views** | `closure_semantic.yaml` (joins + dims; not count KPIs) |
| Charts (optional) | **ggsql** | Not required for review |

## Boot order

```
build.sql: config → extensions → auth
  → hostfs + scalarfs pins → [postgres] → model
app.sql:   build.sql → routes (catalog install) → serve
```

Invariants are not in the serve path — `tests/check.sql` (dqtest) reads the same
`build.sql` model and asserts on it, run by `make check`.

## Env

| Variable | Role |
|----------|------|
| `CLOSURE_PORT` | HTTP (default 8117) |
| `CLOSURE_API_KEY` | Register API key |
| `CLOSURE_POSTGRES` | ATTACH as `pg` |
| `CLOSURE_SAMPLE_ZIP` | LE case pack path |
| `DUCKDB_BIN` | Prefer ≥ 1.5.4 (PATH may have older duckdb first) |

## Ops

Single process = shared buffer pool. Durable SoR = files + append-only `decisions`. Restart under launchd/systemd; `make check` after boot.

## Related

- [`HOW_IT_WORKS.md`](HOW_IT_WORKS.md) — product + API  
- [`DATA_MODEL.md`](DATA_MODEL.md) — tables / views  
- [`rationale.md`](rationale.md) — design write-up  
- History only: [`archive/`](archive/)
