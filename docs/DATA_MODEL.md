# Data model

## Doctrine

| What | How |
|------|-----|
| **Files** | Unmat readers (`pathvariable:` / hostfs). Not a second architecture layer. |
| **Tables** | Facts + **display pins** (stable after boot). Durable: `decisions`, `pipeline_runs`, … Boot corpus: `cases`, `documents`, `pages` (with `scale`/`display_*`), `words`, `entities` (with `kind_label`/`mono`), `suggestions`, … |
| **Live views** | Decision fold, mark px, export gate — change every POST. |
| **Page views** | `parse_html(tera…)` only. |
| **Routes** | `SELECT html` / `INSERT` — no second model. |

## Durable (`store.sql`)

- **`decisions`** — append-only; never UPDATE status in place  
- **`pipeline_runs`**, **`llm_calls`**, **`run_artifacts`** — optional LLM/export bookkeeping  

## Boot corpus (`core.sql`)

From samples + detect. Pins that used to be re-derived in every view:

| Table | Display pins |
|-------|----------------|
| `documents` | `display_name`, `size_label` |
| `pages` | `scale`, `display_w`, `display_h` (680px review) |
| `entities` | `kind_label`, `mono` |

## Live projections (`views.sql`)

| View | Role |
|------|------|
| `v_suggestions` | AI + manual + latest decision fold → `status` / `band` |
| `v_page_marks` | suggestions ⨝ pages.scale → canvas px |
| `v_export_blocked` | flagged pending gate |
| `v_entity_stream` | entities + hit `n` |
| `v_nav` | documents + shell path unnest |
| `v_*_html` / `v_stream_page` / `v_review_page` | SSR only |

## Metrics

`CREATE SEMANTIC VIEW closure FROM YAML FILE 'server/config/closure_semantic.yaml'`.  
Query: `semantic_view('closure', dimensions := […], metrics := […])`.  
Do not invent `pending_count` columns — filter the `status` dimension.

## Load order

```
config → extensions → auth → hostfs pins → [postgres] → model → routes → smoke → serve
```
