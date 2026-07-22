# How Closure works

One DuckDB process is DB + HTTP + PDF + HTML. Handlers are SQL. UI is tera SSR. Browser mutates then reloads.

## FastAPI map

| You know | Here |
|----------|------|
| `uvicorn` + routers | `app.sql` + `CREATE ROUTE` |
| models / services | `store` → `core` (tables) → `views` (live + pages) |
| Jinja | `tera_render(…, template_path := 'server/templates/**/*.html')` → `parse_html` |
| SPA re-paint | POST + `location.reload()` (`static/app.js`) |

## Boot

```
config → extensions → auth (optional key)
  → hostfs views → scalarfs path pins
  → optional postgres attach
  → model (tables + live views) → routes → smoke → quackapi_serve
```

## Model layers (extend like tables)

| Layer | Owns | Extend by |
|-------|------|-----------|
| **Tables** (`core.sql`) | Facts + display pins (`display_name`, page `scale`, entity `kind_label`, …) | New stable column at CTAS |
| **Live views** | Decision fold, mark px, export gate | Thin join over live state |
| **Page views** | `parse_html(tera…)` only | Pack JSON once at page edge |
| **Routes** | `SELECT html` / `INSERT … RETURNING` | Never re-derive labels |

## Formats

| Kind | Reader |
|------|--------|
| paths | hostfs → scalarfs `pathvariable:` / `variable:` |
| JSON | `read_json_auto` (manifest, watchlist, detector_rules) |
| YAML | `read_yaml` + semantic `FROM YAML FILE` |
| HTML | tera → webbed `parse_html`; templates `read_html_objects` |

## Product routes

| Method | Path | Role |
|--------|------|------|
| GET | `/`, `/cases/:id` | Library |
| GET | `/cases/:id/stream` | Entity stream |
| GET | `/documents/:id`, `/pages/:n` | Review peek |
| GET | `/cases/:id/audit` | Audit |
| GET | `/api/cases/:id/nav` | Doc + shell hrefs |
| GET | `/api/cols`, `/api/rel/:relation` | Catalog (allowlisted) |
| POST | `/api/suggestions/:id/decision` | Decide one |
| POST | `/api/entities/:id/decision` | Entity bulk (no flagged) |
| POST | `/api/documents/:id/band/:band/decision` | Band bulk |
| POST | `/api/cases/:id/accept-high` | Accept high confidence |
| POST | `/api/documents/:id/add` | Manual miss |
| POST | `/api/undo` | Inverse latest batch |
| POST | `/api/cases/:id/export` | `pdf_redact` when not blocked |

## Data model (short)

- **decisions** append-only; status = fold (`max_by` latest event) on `v_suggestions`
- Detect: finetype + rapidfuzz (+ bloom) → `suggestions` + `entities`
- Export hard-block while any flagged pending (`v_export_blocked`)

## duck-orch and friends

[duck-orch](https://github.com/nkwork9999/duck-orch) is a DuckDB **asset/DAG orchestrator** (partitions, sensors, OpenLineage). Useful for warehouse-style pipelines. **Not** Closure product: FOIA review is interactive routes + decision log, not scheduled asset materialization. Do not `INSTALL` for this app.

Same bar for `events` (hooks to external programs): harness/ops, not the FOIA loop.

## Size

SQL + 5 templates + one JS file. If a line doesn’t delete a host/SPA layer or earn a real relation, it doesn’t belong.
