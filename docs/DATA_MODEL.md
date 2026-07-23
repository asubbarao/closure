# Data model

## Doctrine

| Rule | Meaning |
|------|---------|
| **Table when multi-consumer / re-run** | Something many handlers re-query is ideal for a table — if it also makes sense. |
| **Adversarial test** | “Why a table?” Valid answer: *everything downstream is simpler/robust* (less LOC, less complexity). |
| **Not a table** | One-off projection, pure live fold, or edge packing with a single consumer → view or join. |
| **No lossy count boards** | Product surfaces are grains (rows). Profiles use `SUMMARIZE` / catalog. Filter dimensions; don’t invent `pending_count`. |
| **Join, don’t nest** | Prefer `JOIN` of named relations over correlated scalar subqueries / `FROM (SELECT DISTINCT…)`. |
| **Semantic YAML** | First-class schema graph (`closure_semantic.yaml`): tables, joins, dimensions. Not a KPI laundry. |
| **SQL is verbose** | CTEs / tables / views read as English: `words_from_pdf`, `batches_from_user_events`, `hits_from_type_rules`. |
| **Trim once** | `token` / `term` stripped at the source pin; never re-`trim(text)` in judges/routes. |
| **3-value / presence** | Real content keeps `NULL` vs `''` distinct. For presence gates (env, “has a token”), `nullif(x, '') IS NOT NULL` — empty folds to NULL, one check, not `IS NOT NULL AND <> ''`. |
| **Surface, not mega-table** | If many handlers re-spell the same multi-join, name it once as an unmat **surface** view (`v_case_surface`). Do **not** materialize a denormalized “page DTO” table — live folds (status, export_blocked) would go stale. |
| **Geometry is first-class** | `bbox` (PDF) + `screen` (`screen_box`) on the mark grain — STRUCT types, not four flat columns or parse soup. Status/band stay live folds. UNNEST ok at a SQL edge if needed. |
| **Tera is the JSON edge only** | `tera_render(template, JSON)` — surfaces hold typed columns; `v_*_ctx` only maps column → template key. No geometry math in the tera bag. |

### When the multi-join / tera bag makes you ask “is the model wrong?”

| Symptom | Wrong fix | Right fix |
|---------|-----------|-----------|
| Library / stream / audit each re-join packs | Wide `case_ui` **table** | One `v_case_surface` unmat view |
| Review re-joins case + doc + page + marks | Snapshot page table | `v_document_page_surface` |
| Canvas re-runs screen math every request | Flat left/top/width/height laundry | Pin **`screen screen_box`** on `suggestions` at write |
| Fat `json_object` with `greatest` / path math | Bigger template logic | Pins + surface columns; ctx is a pure map |
| Export gate everywhere | Cache on `cases` without refresh | `v_export_blocked` live fold on the case surface |

Grain tables stay pure (`cases`, `documents`, `entities`, `suggestions`, `decisions`). Surfaces are **named joins of those grains**, not a second truth.

### Naming

| Kind | Style |
|------|--------|
| Tables, views, CTEs | Verbose snake_case — clarity over brevity |
| View prefix | `v_*` is fine (`v_suggestions`, `v_page_marks`) |
| Relation aliases | **2–3 letters** (`sug`, `doc`, `pag`, `cas`, `ent`, `jdg`) |
| Lambdas only | 1-letter ok: `list_transform(col, x -> x.bbox)` |

| What | How |
|------|-----|
| **Files** | Unmat readers (`pathvariable:` / hostfs) |
| **Host tree** | `v_hostfs` — path scalars every query |
| **Tables** | Facts + display pins; durable: `decisions`, … |
| **Live views** | Decision fold, mark px, export gate |
| **Page pipeline** | grain → surface (`case_row` / `doc_row` / `page_row` packs) → thin `v_*_ctx` → html |
| **HTTP** | `v_route_get` installs GETs; POSTs nest under resources |
| **Checks** | `smoke.sql` + e2e against catalog/product APIs |

Page HTML is **VARCHAR** from `tera_render` only — never `parse_html` on pages (breaks `<script src>`).

## Durable (`store.sql`)

- **`decisions`** — append-only; never UPDATE status in place  
- **`pipeline_runs`**, **`llm_calls`**, **`run_artifacts`** — optional telemetry  
- **Geometry types** — `bbox` (PDF), `screen_box` (canvas), `redact_box` (export). Conversions: `bbox_to_screen` / `bbox_to_redact` / `bbox_key` / `bbox_hull` only.

## Boot corpus (`core.sql`)

| Table | Why a table (adversarial) |
|-------|---------------------------|
| `cases` / `documents` / `pages` | Multi-route grain; display pins (`display_name`, `scale`, …) kill recompute |
| `words` / token spine | Detect + remainder + bloom re-run; expensive if re-extracted |
| `entities` / `suggestions` | Product grain; bulk decide, marks, export, audit all join here |
| `suggestions.bbox` / `.screen` | First-class geometry (`bbox`, `screen_box` types); mark interactor grain |
| `suggestion_judges` | FP panel; fold into `v_suggestions.band` for every consumer |
| `decisions` | Append-only legal log |

Detect: type hits + rapidfuzz → suggestions / entities.  
**Remainder (FN):** residual `is_pii` tokens not already suggested.  
**Judge (FP):** pattern/context/prior; keep|conflict → band `flagged`.  
**Audit:** `v_audit` / `v_decision_batches` (member `suggestion_ids`, not counts).

## Semantic schema

`server/config/closure_semantic.yaml` is part of the model — not a KPI board.

| Piece | Meaning |
|-------|---------|
| **tables** | `v_suggestions` · `documents` · `cases` · `entities` · `suggestion_judges` |
| **joins** | mark→doc→case, mark→entity, mark→judge |
| **dimensions** | status, band, kind, case, entity, judge votes, … |
| **metrics** | `avg_confidence` only (filter dimensions instead of inventing counts) |

```sql
CREATE SEMANTIC VIEW closure FROM YAML FILE 'server/config/closure_semantic.yaml';
FROM semantic_view('closure',
  dimensions := ['case_id', 'status', 'band'],
  metrics := ['avg_confidence']);
FROM (SUMMARIZE v_suggestions);
```

## Live + page (`views.sql`)

| View | Role |
|------|------|
| `v_suggestions` | Fold → `status` / `band` |
| `v_page_marks` | Canvas px (bbox_px once) |
| `v_export_blocked` / `v_export_plans` | Export gate + redact plan |
| **`v_case_surface`** | Case spine: case + documents[] + entities[] + export_blocked |
| **`v_document_page_surface`** | Review spine: doc + case + page pins + marks |
| `v_case_*` packs | List grains feeding the case surface |
| `v_*_ctx` / `v_*_html` | tera bags from surface (+ page-only packs) |
| `v_decide_targets` | POST decision source |
| `v_route_get` | GET path catalog |

## Load order

```
config → extensions → auth → pins → [postgres] → model → routes → smoke → serve
```
