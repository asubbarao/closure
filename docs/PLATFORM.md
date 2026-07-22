# Platform — DuckDB as a better FastAPI

Closure is not “SQL instead of Python.” It is a **full application runtime**: HTTP, auth, OpenAPI, files, shell, PDF, and optional Postgres peer — one process.

## FastAPI parity (and beyond)

| Concern | Closure / quackapi |
|---------|-------------------|
| Serve | `quackapi_serve(port, memory_limit, http_client := 'auto')` |
| Routes | `CREATE ROUTE … AS SELECT / INSERT` |
| OpenAPI | Live **`/openapi.json`**, **`/docs`**, **`/redoc`** |
| Auth | `CREATE AUTH` API key / JWT + `REQUIRE`; env `CLOSURE_API_KEY` registers a key |
| Outbound HTTP | **curl_httpfs** — connection pool, HTTP/2, **async** IO (preferred by quackapi batteries) |
| Types / contracts | Tables, typed route params, `bbox` — not a second Pydantic layer |
| Checks | `server/smoke.sql` (schema + corpus invariants); optional **dqtest** when available |
| Peer SQL store | `ATTACH … AS pg (TYPE POSTGRES)` when `CLOSURE_POSTGRES` is set |
| Multi-region / scale-out | Ops topology (replicas, ATTACH, object storage) — not a reason to reintroduce a middle tier by default |

**Thesis:** for data-shaped products (FOIA review, case packs, set-based bulk), this stack should **beat** FastAPI + ORM on honesty and composition. Use a language framework only when you *want* another process — not because the database cannot be the server.

## Path / effect planes

| Plane | Extension | Role |
|-------|-----------|------|
| Discover host tree | **hostfs** | Unmat `v_hostfs` — typed scalars (`is_file`, `file_extension`, `absolute_path`, …) |
| Pin paths / in-memory files | **scalarfs** | `COPY … TO 'variable:…' (FORMAT variable)` → `pathvariable:` / `variable:` / `to_scalarfs_uri` |
| Case packs (LE zips) | **zipfs** | `archive_contents`, `zip://archive/member` (`v_zips` may be empty in dev) |
| Host effects | **shellfs** | `cmd \|` pipes — see stream vs batch below |
| Metrics | **semantic_views** | `server/config/closure_semantic.yaml` |
| Grammar-of-graphics plots | **ggsql** (optional) | SQL `VISUALISE` / Vega-Lite — case metrics dashboards, not the review loop |

### shellfs readers

| Reader | Mode |
|--------|------|
| `read_csv('cmd \|', …)` | **Streaming** |
| `read_json` / `read_json_auto('cmd \|')` | **Streaming** |
| `read_text('cmd \|')` | **Batch** (whole stdout) |

Prefer streaming for volume CSV/JSON; batch for short status / one-shot scripts. Bash for-loops are usually wrong — use set-based SQL + one-liners or pure `scripts/*.sh` invoked once.

## Boot order

```
config → extensions (incl. curl_httpfs) → auth
  → hostfs → scalarfs pins → [postgres attach]
  → model → routes → smoke → quackapi_serve → re-raise memory_limit
```

## Env

| Variable | Role |
|----------|------|
| `CLOSURE_PORT` | HTTP port (default 8117) |
| `CLOSURE_SAMPLES_DIR` / `CLOSURE_EXPORTS_DIR` / … | Path roots via `app_config` |
| `CLOSURE_API_KEY` | Register API key for scheme `closure_api` |
| `CLOSURE_POSTGRES` | ATTACH Postgres as `pg` |
| `CLOSURE_SAMPLE_ZIP` | Host path to LE case pack; pin with `server/zip_pin.sql` |
| `DUCKDB_BIN` | Prefer quackapi-capable binary when community pin lags |

## Ops / crash

Single process = shared buffer pool. Durable SoR = files + `decisions` (append-only). Restart under launchd/systemd; smoke after boot. Heavy PDF work can be a second DuckDB session if needed — still SQL, still not FastAPI by obligation.

## Optional: ggsql

[ggsql](https://duckdb.org/community_extensions/extensions/ggsql) — Grammar of Graphics in SQL (`VISUALISE … DRAW point`). Good for analyst-facing plots over `semantic_view` / suggestions. **Not** required for the FOIA keyboard loop; earn it when you want charts without a BI middle tier.

```sql
INSTALL ggsql FROM community; LOAD ggsql;
-- e.g. suggestion counts by status from the semantic model
```

## Related

- [`HOW_IT_WORKS.md`](HOW_IT_WORKS.md) — product routes  
- [`DATA_MODEL.md`](DATA_MODEL.md) — tables / views  
- [`rationale.md`](rationale.md) — assignment design write-up  
- Archive (historical surveys): [`archive/`](archive/)
