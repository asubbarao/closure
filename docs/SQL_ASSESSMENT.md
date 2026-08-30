# Closure SQL — full assessment

**Date:** 2026-07-26  
**Scope:** every `server/**/*.sql` + `tests/check.sql` (product model). Stress SQL is out of product path.  
**Stance:** greenfield. No duct tape. Junior patterns die — not “softened.”

---

## 0. Thesis (non-negotiable)

| Claim | Meaning |
|-------|---------|
| **DB is the app** | quackapi is HTTP *over* DuckDB. The product interface is **tables/rowsets**, not DTO classes or join costumes. |
| **A dataframe is a handle on a relation** | If many consumers need a shape, that shape **is a table** written once. Downstream: `SELECT *` / filter. |
| **Set-based, not procedural SQL** | No EXISTS-as-boolean, no soft OR policy joins, no FILTER-enumeration columns, no re-join packs per handler. |
| **Greenfield = no coalesce laundry** | `coalesce(list, [])` means the parent grain never owned the child list. Fix the grain. |
| **All junior patterns die** | Listed below. No “acceptable for now” on product path. |

Wrong mental model (what this repo still partly is):

```
files → many tables → live multi-join views → more views packing lists
  → json_object laundry → route re-selects columns → hope status is right
```

Right mental model:

```
files → detect/judge write **product tables in final shape**
  → HTTP = SELECT * FROM product_table WHERE …
  → tera = serialize that row (no logic)
```

---

## 1. Inventory (what exists)

### 1.1 Load graph

```
app.sql
  └─ build.sql          config, extensions, auth, hostfs path pins, postgres?
       └─ model.sql
            ├─ store.sql       types, macros, durable decisions/telemetry
            ├─ hostfs.sql      v_hostfs, v_zips
            ├─ shellfs.sql     v_shell_patterns
            ├─ http_cache.sql  cache views
            ├─ core.sql        corpus + detect + judge stamp + product mark
            └─ views.sql       live folds, surfaces, tera
  └─ routes.sql         GET catalog + POST mutators + quackapi_serve (via app)
```

| File | LOC | Role |
|------|-----|------|
| `core.sql` | ~600 | Detect spine + suggestions product grain |
| `views.sql` | ~378 | **Worst layer** — re-join / pack / coalesce / tera |
| `routes.sql` | ~333 | HTTP: thin GET bodies + fat POST INSERT clones |
| `store.sql` | ~117 | Types + **5 macros** + durable tables |
| `judge.sql` | ~115 | LLM panel self-dispatch |
| `build.sql` | ~65 | Boot orchestration |
| `extensions.sql` | ~47 | INSTALL/LOAD pack |
| others | &lt;40 each | config, auth, hostfs, shellfs, cache, app, model |

**Server total ≈ 1937 LOC SQL.**

### 1.2 Relation census (product-ish)

**Durable (survive rebuild):**  
`decisions`, `llm_models`, `pipeline_runs`, `llm_calls`, `run_artifacts`

**Boot tables (CREATE OR REPLACE each model load):**  
`cases`, `documents`, `pages`, `word_raw`, `token_types`, `kind_rules`, `band_rules`,  
`token_kind`, `words`, `watchlist`, `watchlist_tokens`, `document_token_norms`,  
`name_token_term_scores`, `name_scorer_thresholds`, `name_rule_hits`, `name_token_match`,  
`name_term_tokens`, `watchlist_bloom`, `document_lines`, `detect_run`,  
`lines_passing_watchlist_bloom`, `line_watchlist_scores`, `line_watchlist_hits`,  
`mono_kinds`, `entities`, `suggestions`, `span_panel`, `template_links`,  
judge tables (`judges`, `judge_rubric`, `judge_spans`, `judge_log`, `judge_pending`,  
`judge_votes`, `judge_verdicts`)

**Unmat file readers:**  
`v_src_pdf_*`, `v_src_manifest`, `v_src_watchlist`, `v_src_decisions`, `v_src_templates`, …

**Product-ish views (should mostly die or become thin filters):**  
`v_suggestions`, `v_decide_targets`, `v_latest_decision`,  
`v_flagged_pending`, `v_remainder_pending`, `v_entity_work`,  
`v_case_*` (many), `v_document_*`, `v_pages`, `v_review_page`,  
`v_export_*`, `v_audit`, `v_decision_batches`, `v_nav`, …

**HTTP:** ~15 GET route bodies + ~10 POST `INSERT INTO decisions` clones.

---

## 2. Layer verdicts

### 2.1 Boot / platform — mostly fine

| Piece | Verdict |
|-------|---------|
| `build.sql` path pins via hostfs → scalarfs | Correct (discovery as rows) |
| `extensions.sql` earned LOADs | OK; func_apply already removed |
| `hostfs` / `shellfs` / `http_cache` as unmat views | OK ops surfaces |
| `config.sql` getenv coalesce | Acceptable for **env defaults only** — not product grain |
| `auth.sql` | Fine |
| `app.sql` = build + routes + serve | **The elegant thesis is real here** — DB *is* the server |

### 2.2 `store.sql` — mixed

| Piece | Verdict | Kill? |
|-------|---------|-------|
| `TYPE bbox` / `screen_box` / `redact_box` | Correct | Keep |
| `CREATE MACRO bbox_*` (5) | **Junior / banned** | **Die** — pin columns at write; one inline expression in the single CTAS that needs it |
| `decisions` append-only | Correct event log | Keep; enforce complete writes |
| telemetry tables raw-first | OK | Keep |

### 2.3 `core.sql` — detect spine improving; product incomplete

| Piece | Verdict |
|-------|---------|
| File → words → token_kind pipeline | Solid set-based spine |
| `name_token_term_scores` + threshold filter → `name_rule_hits` | **Right** (ratios as columns, then filter) |
| `line_watchlist_scores` as ratio columns | **Right** |
| `ANTI JOIN` remainder (exact text) | **Right** (EXISTS died) |
| Entity hard equality | **Right** (soft OR starts_with died) |
| `suggestions` pins: kind, group_key, entity_text, judge_*, band | **Right direction** |
| Judge stamp UPDATE then band CASE | OK (policy as CASE, not soft OR join) |
| Manuals `INSERT INTO suggestions` from decisions ANTI JOIN | **Right** (no reconstruct view) |
| `v_suggestions` = mark + one status join | Acceptable interim; **target = status column stamped on decide** |
| `band_rules` table still loaded, unused by product | Dead dual truth — **die from product path** or generate CASE once from it at boot only |
| `v_decide_targets` re-joins documents every decide | Should be **case_id / filename pinned on mark** at write |
| `v_suggestion_line_context` lateral every time | Optional pin or accept as rare edge |

### 2.4 `judge.sql` — acceptable mechanism, messy ops

| Piece | Verdict |
|-------|---------|
| Span grain = distinct (kind, text) | Correct |
| Append-only vote log + ANTI JOIN pending | Correct set-based pending |
| Shell self-dispatch for multi-model | Ugly but earned (session-global model) |
| Rubric JOIN + QUALIFY first mention | OK |
| `contains(lower(response), verdict)` | Soft string match — acceptable for LLM text, not for product keys |

### 2.5 `views.sql` — **primary crime scene**

This file is why the app feels like FastAPI with extra steps. Almost every multi-consumer shape is a **live join pack** instead of a **product table**.

| View cluster | What’s wrong |
|--------------|--------------|
| `v_flagged_pending` / `v_remainder_pending` | Re-project 15 columns + join docs for filename/case_id every read |
| `v_export_blocked` | `coalesce(list, [])` — parent didn’t aggregate from `cases` |
| `v_entity_work` | **FILTER enumeration**: four `list(...) FILTER (...)` + coalesce + len renames |
| `v_case_surface` | Multi LEFT JOIN pack + coalesce documents/entities + struct_pack DTO cosplay |
| `v_document_page_surface` | Re-joins case+doc+page; lateral list of suggestions; coalesce marks |
| `v_case_flagged_*` / remainder packs | Same facts re-listed 3 ways |
| `v_pages` / `v_review_page` | `json_object` + coalesce laundry at tera edge |
| `v_export_plans` | Recompute redact boxes every read; coalesce boxes |
| `v_decision_batches` | Complex but list-first is OK; still a view over events (fine for audit) |

**Doctrine file still lies** (`DATA_MODEL.md`): “do not materialize case UI table — live folds stay live.” That doctrine **produced this mess**. It dies with the junior patterns.

### 2.6 `routes.sql` — HTTP face half-right

| Piece | Verdict |
|-------|---------|
| GET = `SELECT … FROM v_* WHERE $id` | Right *shape* if `v_*` were real tables |
| POST decide × N clones | Junior copy-paste; one writer pattern missing |
| `coalesce(nullif($reason,''), CASE…)` per bulk route | Reason laundry |
| mark_add → `INSERT suggestions` only | Product-right; **audit dual-write still open** |
| export `exists (FROM pdf_redact(...))` | Side-effect TVF — OK as effect, not an EXISTS antipattern |

---

## 3. Junior pattern kill list

Every item is **banned on product path**. No soften.

### P1 — Schema / grain (the fire)

| ID | Pattern | Where now | Dies by becoming |
|----|---------|-----------|------------------|
| **G1** | Multi-join “surface” as product interface | `v_case_surface`, `v_document_page_surface` | **Tables** `case_app`, `page_app` (or plain names) written once at end of boot / on mutation |
| **G2** | Status only via live latest-decision join | `v_suggestions` | `suggestions.status` stamped on every decide POST (+ boot backfill) |
| **G3** | case_id / filename missing on mark | every case filter joins `documents` | Pin `case_id`, `filename` on `suggestions` at write |
| **G4** | Manual vs AI dual path residue | mark_add vs boot insert | One mark table; mark_add writes product **and** decision event (shared writer) |
| **G5** | band_rules dead dual policy | table loaded + CASE stamp | One policy source; other deleted from product |
| **G6** | DATA_MODEL “live fold forever” | docs + views | Rewrite: **table = interface** |

### P2 — Set-based literacy

| ID | Pattern | Dies as |
|----|---------|---------|
| **S1** | `EXISTS` / `NOT EXISTS` for presence | `SEMI JOIN` / `ANTI JOIN` only |
| **S2** | Soft OR join `(x IS NULL OR x = y)` | Hard keys or stamped column |
| **S3** | Soft OR entity `starts_with` | Hard equality or precomputed match table |
| **S4** | Score macros + `apply()` | Score **tables** (done for names; keep the law) |
| **S5** | Inline `greatest(metric1, metric2, metric3)` without table | Ratio columns on a scores table, then filter (line path mostly done) |
| **S6** | Correlated scalar “is covered?” | ANTI JOIN on equality keys |

### P3 — Enumeration & laundry

| ID | Pattern | Dies as |
|----|---------|---------|
| **E1** | `list(...) FILTER (a)`, `list(...) FILTER (b)` as model | One child table of rows; filter at read **or** one `list(row)` |
| **E2** | `n_pending`, `n_flagged`, `n_*` stored/forced columns | `len(list)` only if list already exists; prefer filter on rows |
| **E3** | `coalesce(list, [])` | Aggregate **from parent key** so empty group = `[]` |
| **E4** | `coalesce(actor, 'reviewer')` on audit read | Require complete decision writes |
| **E5** | Column laundry SELECT of 15 fields repeating mark | `SELECT * FROM marks WHERE …` |
| **E6** | `count(*) FILTER (WHERE status=…)` stacks | Banned forever (mostly gone; never return) |

### P4 — Macros & ceremony

| ID | Pattern | Dies as |
|----|---------|---------|
| **M1** | `bbox_to_screen` / `_redact` / `_key` / `_hull` / `_positive` macros | Pin `screen` at write; pin `redact_box` on export plan table; id hash inline once; validity in dqtest inline |
| **M2** | `if_status` / decision_rows macros (already killed) | Stay dead |
| **M3** | struct_pack case_row/doc_row/page_row as fake DTO | Columns on `page_app` **or** the page table already has them; tera maps columns |

### P5 — HTTP / mutation

| ID | Pattern | Dies as |
|----|---------|---------|
| **H1** | 10 near-identical POST INSERT bodies | One `mutation` / batch writer SQL; routes pass params into it |
| **H2** | Reason default CASE per route | Default in writer; routes pass raw reason |
| **H3** | GET re-joins for case scope | Marks already have `case_id` |
| **H4** | json_object coalesce at tera | `page_app` / `case_app` columns already lists; json_object is pure rename map only |

### P6 — Docs that encode junior law

| ID | Pattern | Dies as |
|----|---------|---------|
| **D1** | DATA_MODEL: surfaces not tables | Flip: multi-consumer → **table** |
| **D2** | SCHEMA_CONTRACT freeze of fold columns | Freeze **product table** columns instead |
| **D3** | “status/band live folds forever” | Status/band are columns |

---

## 4. Target product relations (the elegant app)

These **are** the interface. HTTP and tera only read them.

```
decisions              -- append-only events (audit / undo)
suggestions            -- PRODUCT MARK (all pins + status + case_id + filename)
entities               -- entity grain
cases / documents / pages
entity_marks           -- (entity_id, suggestion_id) fact rows — not FILTER lists
case_app               -- one row per case: documents[], entities[], export_blocked, …
page_app               -- one row per page: marks[], case/doc/page pins, …
export_plan            -- document_id, boxes[], blocked, out_path (built set-based)
decision_batches       -- can stay view over decisions (audit is event-native)
```

### Mark row (suggestions) — complete product grain

```
id, case_id, document_id, filename, page_no, line_no,
bbox, screen, text, text_lower, context, context_lower,
kind, kind_lower, confidence, flag_tag, reason,
entity_id, entity_text, group_key,
source, detector_key, source_run_id, created_at,
judge_panel, judge_agreement, judge_votes, judge_reason,
band, status
```

Queues become **filters**, not views with new schemas:

```sql
SELECT * FROM suggestions WHERE band = 'flagged' AND status = 'pending';
SELECT * FROM suggestions WHERE detector_key = 'detector:remainder' AND status = 'pending';
SELECT * FROM suggestions WHERE case_id = $id ORDER BY document_id, page_no, id;
```

### case_app / page_app

Built **once** at end of `core.sql` (and rebuilt or patched on mutation):

- From `cases` LEFT JOIN children → `list(doc)`, `list(entity)` — empty = `[]` by aggregation  
- From `pages` LEFT JOIN suggestions → `list(mark)`  
- No coalesce  
- No re-join in `v_pages`

### HTTP

```sql
-- GET
SELECT * FROM case_app WHERE case_id = $id;
SELECT * FROM page_app WHERE document_id = $id AND page_no = $page;
SELECT * FROM suggestions WHERE case_id = $id AND status = 'pending';

-- POST decide
INSERT INTO decisions …;
UPDATE suggestions SET status = $status WHERE id = $id;  -- multi-stmt or mutation writer
```

**Disbelief-level simplicity:** the server is the database; the API is SQL over product tables.

---

## 5. What’s already not junior (keep)

| Thing | Why it stays |
|-------|----------------|
| Typed `bbox` / `screen` on mark | Geometry as values |
| Detect score tables → filter | Set-based detect |
| ANTI JOIN remainder | Relational presence |
| Hard entity equality | Relational identity |
| Judge pending ANTI JOIN log | Incremental set-based panel |
| decisions append-only | Event log |
| list for batch members | List doctrine (not count columns as fact) |
| hostfs path pins | FS as relations |
| quackapi routes as SQL | DB-in-HTTP thesis |
| dqtest as data (`dq_tests.json`) | Invariants as rows |

---

## 6. Kill order (implementation sequence)

Do not “fix coalesce” in place. Replace missing tables.

| Step | Work | Kills |
|------|------|-------|
| **1** | Pin `case_id`, `filename` on suggestions at write; stamp `status` default `pending`/`accepted` | G3, H3 |
| **2** | Decide POSTs: INSERT decisions **and** UPDATE suggestions.status (mutation writer) | G2, H1 |
| **3** | mark_add: product + decision same ids | G4 |
| **4** | CTAS `entity_marks` from suggestions; kill FILTER lists in entity_work | E1, E2 |
| **5** | CTAS `case_app`, `page_app` from parent keys + list(); kill v_case_surface join costume | G1, E3, M3 |
| **6** | CTAS `export_plan` with redact boxes; kill live export fold coalesce | E3, export recompute |
| **7** | Delete bbox macros; only pins + one-shot inline in CTAS | M1 |
| **8** | Collapse POST clones to one writer | H1, H2 |
| **9** | `v_pages` / `v_review_page` = tera over case_app/page_app only | H4, E3 |
| **10** | Rewrite DATA_MODEL / kill dead band_rules product dual | G5, G6, D* |
| **11** | Delete dead views; v_cols allowlist = product tables | — |

`make check` + e2e after each step. No big-bang with half costumes.

---

## 7. LOC / complexity target

| Layer | Now | Target posture |
|-------|-----|----------------|
| `views.sql` | ~378 LOC join cosplay | **&lt;80** — thin filters + tera map only |
| `routes.sql` GET bodies | re-join / column laundry | **one-liners** on product tables |
| `routes.sql` POST | 10 clones | **1 writer + thin routes** |
| `core.sql` | ~600 | stays large (detect is real work) + **end-of-file product CTAS** |
| `store.sql` macros | 5 | **0** |

Success metric: a stranger reads `routes.sql` and thinks “that’s just SQL on tables,” not “that’s an ORM missing a language.”

---

## 8. Explicit non-goals

- Not FastAPI / not “real” DTO classes in TypeScript for product grain  
- Not MATERIALIZED VIEW ceremony as architecture (tables written at boot are fine)  
- Not micro-optimizing judge shell dispatch before product grain is right  
- Not preserving DATA_MODEL’s “live fold forever” rule  

---

## 9. One-paragraph summary

Closure’s **runtime idea is elite** (DuckDB + quackapi = the app). The **SQL product layer is still junior**: multi-join surfaces, coalesce empty lists, FILTER enumerations, missing pins on the mark, status as a live join, macros for geometry, and a views file that re-implements a dataframe interface poorly. Greenfield forbids that. **Product tables in final shape; HTTP is SELECT/INSERT; all junior patterns die.**

---

## 10. Sign-off checklist (before claiming “done”)

- [ ] Zero `CREATE MACRO` in product path  
- [ ] Zero `coalesce(..., [])` on list product columns  
- [ ] Zero `list(...) FILTER` as multi-column entity model  
- [ ] Zero soft OR policy joins  
- [ ] Zero EXISTS for relational presence  
- [ ] `suggestions` has case_id, filename, status, band, judge_*, entity_text  
- [ ] `case_app` / `page_app` tables; views don’t re-join them  
- [ ] GET routes are filters on those tables  
- [ ] Decide stamps status (events still append)  
- [ ] DATA_MODEL matches reality  
- [ ] `make check` green  

**This file is the assessment. Implementation follows the kill order when approved.**
