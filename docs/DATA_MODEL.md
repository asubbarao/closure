# Data model

## Doctrine

| What | How |
|------|-----|
| **Files** | Stay files. Unmaterialized views open them (`pdf_info` / `read_json_auto` via scalarfs `pathvariable:`). Not a “layer” — just IO. Never rewrite fixtures in SQL; use shellfs if you must `mv`. |
| **Tables** | Real app relations (like any server). Durable: `decisions`, `llm_models`, `pipeline_runs`, `llm_calls`, `run_artifacts`. Boot-derived: `cases`, `documents`, `pages`, `words`, `document_lines`, `watchlist`, `entities`, `suggestions`. |
| **Views** | Unmaterialized projections only (`CREATE VIEW`). **No `MATERIALIZED VIEW`.** |
| **Routes** | Thin HTTP over views/tables. No second model. |

## Durable (store.sql)

- **`decisions`** — append-only human events; status never UPDATEd in place  
- **`llm_models`** — detector/LLM registry (`raw` JSON; seeded every boot)  
- **`pipeline_runs`** — one row per detect/judge/export/…  
- **`llm_calls`** — raw-first request+response JSON (future LLM; empty until wired)  
- **`run_artifacts`** — export paths per run  

## Derived at boot (core.sql)

Corpus tables from sample PDFs + manifest + watchlist. Detect stamps  
`suggestions.source_run_id` + `detector_key` and finishes a `pipeline_runs` row.

## Projections (views.sql)

`v_suggestions` folds latest decision → status/band. UI/API views are unmat.  
`v_suggestion_lineage` joins suggestions → runs → models.

## Load order

`config → extensions → path variables → store → core → views → routes → quackapi_serve`
