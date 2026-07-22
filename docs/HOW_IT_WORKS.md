# How Closure works

**One process:** DuckDB + community `quackapi`. Handlers are SQL. UI is **tera SSR**. Browser only mutates then reloads.

## FastAPI map

| You know | Here |
|----------|------|
| `uvicorn` + routers | `app.sql` + `CREATE ROUTE` |
| models / services | `store.sql` → `core.sql` → `views.sql` |
| Jinja | `tera_render('page.html', ctx, template_path := …)` → `parse_html` (HTML type) |
| POST JSON + SPA re-paint | POST + **`location.reload()`** (~300 LOC `static/app.js`) |

## Boot

```
config → extensions → hostfs path lists → model → routes → quackapi_serve
```

Empty hostfs / empty CTAS is the integrity signal — no second gate layer.

## Formats (simple)

| Kind | How |
|------|-----|
| **paths** | hostfs discover → scalarfs `variable:` / `pathvariable:` |
| **JSON** | `read_json_auto` (manifest, watchlist, detector_rules) |
| **YAML** | `read_yaml` + `CREATE SEMANTIC VIEW … FROM YAML FILE` (`closure_semantic.yaml`) |
| **HTML** | tera file-mode → `parse_html` → `HTML` column; templates via `read_html_objects` |

## Model layers (extend like tables)

| Layer | Owns | When to change |
|-------|------|----------------|
| **Tables** (`core.sql`) | Facts + **display pins** (`display_name`, `size_label`, page `scale`/`display_*`, entity `kind_label`/`mono`) | New stable field → **column on table** at CTAS |
| **Live views** | Decision fold, mark px, export gate, entity hits | New join over live state → thin view |
| **Page views** | `parse_html(tera…)` only | New UI field → pack list at page edge once |
| **Routes** | `SELECT html` / `INSERT` | Never re-derive labels |

Rule: if a value is the same after boot until re-ingest, it belongs on a **table**, not recomputed in every view.

## Product loop

1. **Library** `GET /` · `GET /cases/:id` — `v_case_html`
2. **Entity stream** `GET /cases/:id/stream` — `v_stream_page` (decide-once)
3. **Page peek** `GET /documents/:id` · `…/pages/:n` — `v_review_page`
4. **Decide** POST decision / entity / band / accept-high / undo / add
5. **Export** POST export (blocked if flagged pending)
6. **Audit** `GET /cases/:id/audit` — `v_audit_page`
7. **Nav / catalog** `v_nav`, `v_cols`, allowlisted `api_rel`

## Data model

- **decisions** append-only · status = fold (`max_by` latest event)
- writers: `INSERT INTO decisions BY NAME … FROM v_decide_targets` (same shape)
- detect: finetype + rapidfuzz (+ bloom prefilter) → suggestions table

## Size

SQL + 4 templates + one JS file. No second SPA. If a line doesn’t delete a host/SPA layer, it doesn’t belong.
