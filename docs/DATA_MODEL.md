# Data model

## Doctrine

| What | How |
|------|-----|
| **Files** | Unmat readers (`pathvariable:` / hostfs). Not a second architecture layer. |
| **Host tree** | Unmat **`v_hostfs`** (`server/hostfs.sql`) — full path scalars every query |
| **Tables** | Facts + **display pins** (stable after boot). Durable: `decisions`, `pipeline_runs`, … Boot corpus: `cases`, `documents`, `pages` (with `scale`/`display_*`), `words`, `entities` (with `kind_label`/`mono`), `suggestions`, … |
| **Live views** | Decision fold, mark px, export gate — change every POST. |
| **Page views** | `parse_html(tera…)` only. |
| **Routes** | `SELECT html` / `INSERT` — no second model. |
| **Checks** | `smoke.sql` on relations — schema is the type system. |

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

Corpus spine (barcode-style intermediates):

`word_raw` → `token_types` → `kind_rules` → `token_rule_hits` → `token_kind` → `words` → detect → `suggestions` / `entities`

## Host / packs / shell

| View | Role |
|------|------|
| `v_hostfs` | samples/exports/pages/templates + hostfs scalars |
| `v_zips` | `.zip` on host (LE case packs; empty OK) |
| `v_shell_patterns` | How to call shellfs (stream vs batch) — not raw HTTP shell |

Zip members: `zip://` + `archive_contents` (member names are not host paths). Pin a pack: `server/zip_pin.sql`.

## Live projections (`views.sql`)

| View | Role |
|------|------|
| `v_suggestions` | AI + manual + latest decision fold → `status` / `band` |
| `v_page_marks` | suggestions ⨝ pages.scale → canvas px |
| `v_export_blocked` | flagged pending gate |
| `v_entity_stream` | entities + hit `n` |
| `v_nav` | documents + case shell paths (`UNION ALL`) |
| `v_case_html` / `v_stream_page` / `v_review_page` / `v_audit_page` | SSR only |

## Metrics

`CREATE SEMANTIC VIEW closure FROM YAML FILE 'server/config/closure_semantic.yaml'`.  
Query: `semantic_view('closure', dimensions := […], metrics := […])`.  
Do not invent `pending_count` columns — filter the `status` dimension.

Optional charts: [ggsql](https://duckdb.org/community_extensions/extensions/ggsql) over the same grains.

## Optional Postgres

When `CLOSURE_POSTGRES` is set, `server/postgres.sql` ATTACHes as `pg`. Same app SQL can join local review state to remote SoR — still no FastAPI middle tier required.

## Load order

```
config → extensions → auth → hostfs pins → [postgres] → model → routes → smoke → serve
```
