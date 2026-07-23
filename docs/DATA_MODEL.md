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

| What | How |
|------|-----|
| **Files** | Unmat readers (`pathvariable:` / hostfs) |
| **Host tree** | `v_hostfs` — path scalars every query |
| **Tables** | Facts + display pins; durable: `decisions`, … |
| **Live views** | Decision fold, mark px, export gate |
| **Page pipeline** | named packs → `JOIN` → `v_*_ctx` → `v_*_html`/`v_*_page` |
| **HTTP** | `v_route_get` installs GETs; POSTs nest under resources |
| **Checks** | `smoke.sql` + e2e against catalog/product APIs |

Page HTML is **VARCHAR** from `tera_render` only — never `parse_html` on pages (breaks `<script src>`).

## Durable (`store.sql`)

- **`decisions`** — append-only; never UPDATE status in place  
- **`pipeline_runs`**, **`llm_calls`**, **`run_artifacts`** — optional telemetry  
- **`bbox` TYPE + macros** — pack once at the edge; unpack once per destination (`bbox_px` / `bbox_pdf` / `bbox_key`)

## Boot corpus (`core.sql`)

| Table | Why a table (adversarial) |
|-------|---------------------------|
| `cases` / `documents` / `pages` | Multi-route grain; display pins (`display_name`, `scale`, …) kill recompute |
| `words` / token spine | Detect + remainder + bloom re-run; expensive if re-extracted |
| `entities` / `suggestions` | Product grain; bulk decide, marks, export, audit all join here |
| `suggestion_judges` | FP panel; fold into `v_suggestions.band` for every consumer |
| `decisions` | Append-only legal log |

Detect: type hits + rapidfuzz → suggestions / entities.  
**Remainder (FN):** residual `is_pii` tokens not already suggested.  
**Judge (FP):** pattern/context/prior; keep|conflict → band `flagged`.  
**Audit:** `v_audit` / `v_decision_batches` (member `suggestion_ids`, not counts).

## Semantic schema

```yaml
# server/config/closure_semantic.yaml
# joins + dimensions = the review graph
# metrics: only real measures (avg_confidence) — no n=COUNT(*) product field
```

```sql
CREATE SEMANTIC VIEW closure FROM YAML FILE 'server/config/closure_semantic.yaml';
-- ad-hoc slice (console / ops), not embedded page KPIs:
FROM semantic_view('closure', dimensions := ['case_id', 'status', 'band'],
                   metrics := ['avg_confidence']);
FROM (SUMMARIZE v_suggestions);
```

## Live + page (`views.sql`)

| View | Role |
|------|------|
| `v_suggestions` | Fold → `status` / `band` |
| `v_page_marks` | Canvas px (bbox_px once) |
| `v_export_blocked` / `v_export_plans` | Export gate + redact plan |
| `v_case_*` packs | Multi-consumer list grains → JOIN in ctx |
| `v_*_ctx` / `v_*_html` | tera bags + `path` + `html` |
| `v_decide_targets` | POST decision source |
| `v_route_get` | GET path catalog |

## Load order

```
config → extensions → auth → pins → [postgres] → model → routes → smoke → serve
```
