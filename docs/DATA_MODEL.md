# Data model

## Doctrine

| What | How |
|------|-----|
| **Files** | Unmat readers (`pathvariable:` / hostfs) |
| **Host tree** | `v_hostfs` — path scalars every query |
| **Tables** | Facts + display pins; durable: `decisions`, … |
| **Live views** | Decision fold, mark px, export gate |
| **Page pipeline** | `v_*_ctx` (JSON) → `v_*_html`/`v_*_page` (`path` + `html`) |
| **HTTP** | `v_route_get` installs GETs; POSTs nest under resources |
| **Checks** | `smoke.sql` + e2e against catalog/product APIs |

Page HTML is **VARCHAR** from `tera_render` only — never `parse_html` on pages (breaks `<script src>`).

## Durable (`store.sql`)

- **`decisions`** — append-only; never UPDATE status in place  
- **`pipeline_runs`**, **`llm_calls`**, **`run_artifacts`** — optional telemetry  

## Boot corpus (`core.sql`)

| Table | Notes |
|-------|--------|
| `documents` | `display_name`, `size_label` pins |
| `pages` | `scale`, `display_w`, `display_h` |
| `entities` | `kind_label`, `mono` |
| `suggestions` | AI + fold via `v_suggestions` |
| `words` / token spine | finetype + rules + detect |

Detect: type hits + rapidfuzz watchlist → suggestions / entities.

## Host / packs / shell / cache

| View | Role |
|------|------|
| `v_hostfs` / `v_zips` | samples, exports, pages, templates; LE zips |
| `v_shell_patterns` | shellfs recipes (not raw HTTP shell) |
| `v_http_cache*` | cache_httpfs status (`server/http_cache.sql`) |

## Live + page (`views.sql`)

| View | Role |
|------|------|
| `v_suggestions` | Fold → `status` / `band` |
| `v_page_marks` | Canvas px |
| `v_export_blocked` / `v_export_plans` | Export gate + redact plan |
| `v_entity_stream` / `v_nav` | Stream + nav |
| `v_tpl_*` / `v_*_ctx` | Shared bags + tera context |
| `v_case_html` · `v_stream_page` · `v_review_page` · `v_audit_page` | `path` + `html` |
| `v_decide_targets` | POST decision source |
| `v_route_get` | Defined in `routes.sql` — GET path catalog |

## Metrics

```sql
CREATE SEMANTIC VIEW closure FROM YAML FILE 'server/config/closure_semantic.yaml';
SELECT * FROM semantic_view('closure', dimensions := ['status', 'band'], metrics := ['n', …]);
```

## Load order

```
config → extensions → auth → pins → [postgres] → model → routes → smoke → serve
```
