# Platform extension survey — Closure + quackapi

**Date:** 2026-07-19  
**Scope:** Honest fit of selected DuckDB **community** extensions for the Closure app (`/Users/aloksubbarao/personal/closure`) and the quackapi platform (route SQL, audit, regression, dashboards, observability).  
**Write surface:** this file + optional spikes under `spikes/ext-platform/` only.

**Probe host:**

| Item | Value |
|------|--------|
| Default shell DuckDB | `v1.5.3` (loads most of the list; 1.5.4-only CDN packages fail INSTALL) |
| Signed-CDN probe CLI | `v1.5.4` (`/tmp/duckdb154/duckdb`, official `duckdb_cli-osx-arm64`) |
| Platform | `osx_arm64` |
| Pattern | `INSTALL <name> FROM community; LOAD <name>;` |

**Signed `osx_arm64` CDN** (`https://community-extensions.duckdb.org/{ver}/osx_arm64/<name>.duckdb_extension.gz`):

| Extension | v1.5.3 | v1.5.4 | LOAD on 1.5.4 |
|-----------|--------|--------|---------------|
| duck_diff | 404 | **200** | OK |
| duck_lineage | 200 | 200 | OK |
| duckorch | 200 | 200 | OK |
| duck_hunt | 200 | 200 | OK |
| query_condition_cache | 200 | 200 | OK |
| otlp | 200 | 200 | OK |
| read_lines | 200 | 200 | OK |
| markdown | 200 | 200 | OK |
| nsv | 200 | 200 | OK |
| rawduck | 404 | **200** | OK |
| netquack | 200 | 200 | OK |
| dns | 200 | 200 | OK |
| urlpattern | 404 | **200** | OK |
| duckpgq | 404 | **200** | OK |
| duckthink | 404 | **200** | OK |
| ggsql | 200 | 200 | OK |
| nanoarrow | 200 | 200 | OK |
| overture | 200 | 200 | OK |
| scalarfs (companion) | 200 | 200 | OK |

**Implication:** pin the platform runtime to **DuckDB ≥ 1.5.4** before counting on `duck_diff`, `urlpattern`, `duckpgq`, `rawduck`, or `duckthink`. On 1.5.3 those INSTALL paths 404.

Spikes (working SQL + captured output):

- `spikes/ext-platform/01_duck_diff.sql` (+ `.out`)
- `spikes/ext-platform/02_ggsql.sql` (+ `.out`)

---

## Executive verdict

**Most of this list is “no” for Closure/quackapi product paths.** The useful residue is small:

| Rank | Extension | Integrate? | Why in one line |
|------|-----------|------------|-----------------|
| 1 | **duck_diff** | **Yes — tests / ops** | PK table diffs for decision snapshots + words/entity corpus regression; not a runtime dependency of the app server |
| 2 | **read_lines** (+ **scalarfs**) | **Yes — platform primitive** | Line-numbered text TVF + lateral; scalarfs when the path is in-memory/`variable:` |
| 3 | **markdown** | **Maybe — later** | Real `md_to_html` / block parse of `docs/`; product help is not a near-term route |
| 4 | **duck_hunt** | **No for smoke runner; soft yes for CI log analytics** | Parses 110+ log/test formats — does **not** execute Playwright/route tests |
| 5 | **ggsql** | **No for product dashboard** | Numeric charts work; categorical status bars mis-aggregate; separate browser HTTP, ~830KB HTML |
| — | everything else below | **No** | Wrong layer, wrong domain, or overhead without a Closure need |

Owner hunches, scored honestly:

| Hunch | Result |
|-------|--------|
| **duck_diff** for decision-log diffs / corpus regression | **Confirmed useful** (spike works; multi-col PK list works) |
| **duck_hunt** to run route smoke tests | **Rejected** — log **parser**, not a test runner; Playwright text yields summary events only in our sample |
| **ggsql** for dashboard stats charts | **Rejected for in-app dashboard** — wrong transport + broken categorical bars; fine as an offline analyst toy |

---

## Integrate-now list (ranked)

1. **`duck_diff`** — add as a **test/ops** LOAD in regression SQL (not in `server/app.sql` boot unless you want it always present). Pattern: freeze `COPY (SELECT … FROM v_suggestions / audit_events) TO 'fixtures/….parquet'`, then `table_diff` / `table_diff_summary` with a boolean gate.
2. **`read_lines`** — already the right tool for SQL-native line IO (route SQL, decision JSONL, logs). Pair with **`scalarfs`** when content is a variable or literal (`variable:`, `data+varchar:`) instead of a path. No app feature work required beyond “prefer this over shell `cat` in SQL pipelines.”
3. *(optional later)* **`markdown`** — only if you ship an in-app docs/help surface from `docs/**/*.md` via `md_to_html` + quackapi HTML routes.
4. *(optional ops)* **`duck_hunt`** — post-process Playwright/pytest **text** logs in DuckDB after CI; do not replace `tests/e2e`.
5. **Stop.** Do not pull otlp/rawduck/duckorch/lineage/pgq/ggsql/urlpattern/netquack/dns/nsv/nanoarrow/overture/duckthink into the product path without a new concrete need.

---

## Per-extension assessment

Legend: **Yes** / **Maybe** / **No**. “Mechanism” only when it matters for how you’d wire it.

### duck_diff — **Yes (tests/ops)**

| | |
|--|--|
| **What** | Diff two relations by primary key → `identical` / `different` / `left_only` / `right_only` + `diff_data` JSON of changed columns; `table_diff_summary` counts; `schema_diff` for column sets |
| **Functions** | `table_diff(left, right, pk := …)`, `table_diff_summary(…)`, `schema_diff(left, right)` |
| **Signed** | **v1.5.4 only** on CDN (404 on 1.5.3) |
| **Why yes** | Closure’s audit model is append-only events with projected state (`v_suggestions`). Diffing two frozen projections (or two `words` extracts) is exactly regression CI for “did re-ingest / re-seed change answers?” |
| **Why not runtime** | Relations are query **strings** (`'FROM decisions_v1'`), not live triggers; no substitute for `audit_events` |
| **Mechanism** | `pk` is `VARCHAR | LIST`; multi-key: `pk := ['document_id','page_no','seq']`. Args must be full `FROM …` / `SELECT …` strings, not bare table names |
| **Spike** | `spikes/ext-platform/01_duck_diff.sql` — decision snapshot + geometry drift both work |

### duck_lineage — **No**

| | |
|--|--|
| **What** | OpenLineage emitter: settings `duck_lineage_url`, `_api_key`, `_namespace`, `_debug`; captures query lineage → HTTP backend (Marquez etc.) |
| **Why no** | Closure’s audit story is **domain events** (accept/reject/add-missed), not warehouse column lineage. Needs an external OpenLineage collector. Zero product value for redaction review |

### duckorch — **No**

| | |
|--|--|
| **What** | Asset-centric orchestration: `PRAGMA orch_register/run/sensor_*`, dynamic assets, OpenLineage hooks, DAG/Mermaid |
| **Why no** | Closure boot is `server/app.sql` + route files, not a dbt/Dagster-in-SQL warehouse. Orchestration of PDF ingest can stay shell/`run.sh`/cronjob. Massive surface for no MVP need |

### duck_hunt — **No (as smoke runner); Maybe (CI log analytics)**

| | |
|--|--|
| **What** | Parse CI/CD and test **logs** (110 formats): `read_duck_hunt_log`, `parse_duck_hunt_log`, `duck_hunt_formats`, diagnose helpers, `status_badge` |
| **Signed** | 1.5.3 + 1.5.4 |
| **Why not smoke tests** | Does **not** HTTP-hit quackapi routes or drive Playwright. You still run `tests/e2e`; duck_hunt only reads the log file afterward |
| **Probe notes** | `playwright_text` parsed our sample → **summary** events only (`1 failed` / `2 passed`), not per-spec rows. `pytest_text` → per-test PASS/FAIL. JUnit **XML** needs **webbed** loaded (`Invalid Input Error: XML parsing requires the 'webbed' extension`) |
| **Honest use** | Warehouse of CI history: `CREATE TABLE ci_events AS SELECT * FROM read_duck_hunt_log('artifacts/*.txt', 'auto')` |

### query_condition_cache — **No**

| | |
|--|--|
| **What** | Optimizer cache for repeated filter predicates (`use_query_condition_cache`, `condition_cache_build/info/stats`) aimed at metrics-monitor style workloads |
| **Why no** | quackapi handlers are diverse short queries over a small local DB, not millions of near-identical dashboard filters. Adds magic, not product capability |

### otlp — **No (now); Maybe (ops later)**

| | |
|--|--|
| **What** | `read_otlp_*` file readers; `otlp_serve` / `otap_serve` live OTLP/HTTP ingest into DuckDB tables; seal/flush/export |
| **Why no for quackapi requests** | This is an **OTLP collector/query surface**, not automatic instrumentation of quackapi handlers. Wiring would mean a second protocol port + exporter from the server — quackapi does not emit OTLP today |
| **Maybe later** | If you already ship traces elsewhere and want SQL analysis of exported files |

### read_lines — **Yes (platform primitive)**

| | |
|--|--|
| **What** | `read_lines(path, …)` → `line_number`, `content`, `file_path`; `read_lines_lateral` for per-row paths |
| **Signed** | 1.5.3 + 1.5.4 |
| **Why yes** | Native, typed line reader for SQL/scripts/logs/JSONL decision sidecars without shelling out |
| **scalarfs note** | When the “file” is already a string/variable, `LOAD scalarfs` and use `variable:` / `data+varchar:` / `pathvariable:` URIs so `read_lines` (and friends) can open them. scalarfs is a companion FS, not a substitute for read_lines |

### markdown — **Maybe**

| | |
|--|--|
| **What** | `read_markdown`, `read_markdown_blocks`, `read_markdown_sections`, `md_to_html`, `md_to_text`, `md_stats`, extractors, `COPY … (FORMAT MARKDOWN)`, `duck_blocks_to_md` |
| **Probe** | `docs/rationale.md` → 3974 bytes, `md_to_html` produced real `<h1>`/`<p>` HTML |
| **Why maybe** | Excellent if you render `docs/` inside the app; overkill if docs stay GitHub-only. Prefer this over hand-rolling MD if help pages appear |

### nsv — **No**

| | |
|--|--|
| **What** | `read_nsv` — Newline-Separated Values format |
| **Why no** | Closure uses JSON/JSONL decisions + parquet/csv fixtures. NSV is a niche interchange; no consumer |

### rawduck — **No**

| | |
|--|--|
| **What** | Schema-less JSON + OTEL ingest (`raw_ingest`, `raw_serve`, projections, transforms) — observability warehouse kit |
| **Signed** | **v1.5.4 only** |
| **Why no** | Parallel product to otlp/raw telemetry lakes; not redaction review. Overlaps otlp without simplifying quackapi |

### netquack — **No (for Closure)**

| | |
|--|--|
| **What** | URL/domain/IP parse: `extract_*`, `is_valid_url`, `normalize_url`, base64, Tranco rank, `ipcalc`, … |
| **Why no** | Useful generally; Closure routes are local paths and quackapi already binds `:id` params. No URL analytics product surface |

### dns — **No**

| | |
|--|--|
| **What** | `dns_lookup`, `dns_lookup_all`, `reverse_dns_lookup`, cache/config setters |
| **Why no** | No DNS-dependent feature in Closure/quackapi |

### urlpattern — **No (for quackapi routing)**

| | |
|--|--|
| **What** | WHATWG URLPattern: `urlpattern_init`, `urlpattern_test`, `urlpattern_exec` → struct with `matched`, path parts, `groups` map |
| **Signed** | **v1.5.4 only** |
| **Why no** | quackapi already has `CREATE ROUTE … '/cases/:id'` with param binding. Probe: `urlpattern_test` works boolean-true, but `groups` map was **empty** for `:id` patterns in our smoke — not a trustworthy param extractor yet |
| **Not a router** | Match helper only; does not register HTTP handlers |

### duckpgq — **No**

| | |
|--|--|
| **What** | SQL/PGQ property graphs: `create_property_graph`, `duckpgq_match`, `pagerank`, `shortestpath`, WCC, CSR helpers |
| **Signed** | **v1.5.4 only** |
| **Why no for entity graphs across documents** | Tempting story (entities ↔ docs ↔ suggestions), but Closure already models that with FKs (`entities`, `suggestions.entity_id`, `documents`). Graph algorithms do not unlock review UX; cost is new mental model + PGQ syntax |

### duckthink — **No**

| | |
|--|--|
| **What** | `ask` / `ask_sql` NL→SQL grounded in a **dbt Semantic Layer**; `duckthink_metrics` |
| **Signed** | **v1.5.4 only** |
| **Why no** | No dbt semantic layer in Closure. External LLM dependency class of tool — wrong for a deterministic redaction audit app |

### ggsql — **No (product dashboard); Maybe (offline charts)**

| | |
|--|--|
| **What** | Grammar-of-Graphics in SQL: `VISUALISE … DRAW …` or scalar `ggsql('…')`; modes `ggsql_output` = `silent|url|spec|html`; in-process chart HTTP server + optional browser open |
| **Signed** | 1.5.3 + 1.5.4 |
| **Probe (spike 02)** | Numeric `VISUALISE x, y DRAW line` → 10 points in Vega-Lite **spec** OK; `url` → `http://127.0.0.1:<port>/#plot/…`; `html` → **~833KB** blob. Categorical `VISUALISE status, n DRAW bar` → **broken**: single dummy bar with count=3 (row count), not accept/reject/pending heights |
| **Why no for Closure dashboard** | Product UI is custom HTML/JS (`static/dashboard.js`) on quackapi. ggsql opens a **second** server and browser tab, does not nest cleanly into tera templates, and fails the exact chart shape (status counts) the dashboard wants |
| **Maybe** | Analyst notebook / local deep-dive with `GGSQL_NO_OPEN_BROWSER=1` + `spec`/`html` export |
| **Spike** | `spikes/ext-platform/02_ggsql.sql` |

### nanoarrow — **No**

| | |
|--|--|
| **What** | Arrow IPC: `read_arrow`, `to_arrow_ipc`, `scan_arrow_ipc`, `arrow_scan` |
| **Why no** | Interop polish for Arrow pipelines. Closure stays on DuckDB tables + PDF + JSON. No Arrow boundary in the product |

### overture — **No**

| | |
|--|--|
| **What** | Overture Maps macros: `read_overture_places/buildings/roads`, category helpers |
| **Why no** | Geospatial basemap data. Zero overlap with case-file redaction |

---

## Special deep-dives

### duck_diff × decision log / corpus

**Fit is real.** Recommended pattern (do not implement in this survey pass):

```sql
-- after a golden re-seed
COPY (SELECT * FROM v_suggestions ORDER BY id) TO 'tests/fixtures/suggestions_golden.parquet' (FORMAT PARQUET);

-- in CI
LOAD duck_diff;
SELECT *
FROM table_diff_summary(
  $$ FROM read_parquet('tests/fixtures/suggestions_golden.parquet') $$,
  $$ FROM v_suggestions $$,
  pk := 'id'
);
-- assert n_different + n_left_only + n_right_only = 0
```

Same shape for `words` with `pk := ['document_id','page_no','seq']` to catch PDF extract drift. Prefer this over ad-hoc `EXCEPT` when you want **per-key status + column-level `diff_data`**.

### duck_hunt × route smoke tests

**Cannot replace** Playwright e2e or curl smoke against quackapi. Correct framing:

```text
Playwright / curl  →  produces logs / JUnit  →  duck_hunt parses  →  SQL analytics
         ↑
   still required
```

If you want SQL-native smokes, write them as `CREATE ROUTE` self-dispatch or shell `http_get` against the live server — not duck_hunt.

### ggsql × dashboard stats

For Closure’s case dashboard (counts by status, queue depth, etc.):

| Approach | Verdict |
|----------|---------|
| ggsql `html`/`url` embedded in quackapi response | **No** — second server, huge HTML, browser coupling |
| ggsql `spec` JSON returned to frontend Vega | **Fragile** — categorical bar path wrong in probe |
| Keep Chart.js / CSS bars / simple SQL aggregates in `dashboard.js` | **Yes** — already the product path |

---

## Function cheat-sheet (loaded on v1.5.4)

| Extension | Primary surface |
|-----------|-----------------|
| duck_diff | `table_diff`, `table_diff_summary`, `schema_diff` |
| duck_lineage | settings only (`duck_lineage_*`) — no SQL functions |
| duckorch | many `PRAGMA orch_*` + `orch_build_dag` / `orch_render_mermaid` |
| duck_hunt | `read_duck_hunt_log`, `parse_duck_hunt_log`, `duck_hunt_formats`, diagnose_*, `status_badge` |
| query_condition_cache | `condition_cache_build/info/stats`, setting `use_query_condition_cache` |
| otlp | `read_otlp_*`, `otlp_serve`, `otlp_stop`, `otlp_flush`, `otap_*` |
| read_lines | `read_lines`, `read_lines_lateral` |
| markdown | `read_markdown*`, `md_to_html`, `md_stats`, `md_extract_*`, `duck_blocks_to_md` |
| nsv | `read_nsv` |
| rawduck | `raw_ingest*`, `raw_serve*`, `raw_project`, `raw_records`, … |
| netquack | `extract_*`, `is_valid_url`, `normalize_url`, IP helpers |
| dns | `dns_lookup`, `reverse_dns_lookup`, … |
| urlpattern | `urlpattern_init/test/exec`, component getters |
| duckpgq | `create_property_graph`, `duckpgq_match`, `pagerank`, `shortestpath`, WCC |
| duckthink | `ask`, `ask_sql`, `duckthink_metrics` |
| ggsql | `ggsql(varchar)`, `VISUALISE` parser, setting `ggsql_output` |
| nanoarrow | `read_arrow`, `to_arrow_ipc`, `scan_arrow_ipc` |
| overture | `read_overture*` macros, `overture_categories` |

---

## Bottom line

Treat this list as a **mostly-negative filter** with two keepers:

1. **`duck_diff`** — integrate into regression/CI SQL (decision + corpus), after runtime is on **1.5.4+**.  
2. **`read_lines`** (+ **scalarfs** when needed) — keep as the SQL-side line IO primitive.

Park **duck_hunt** and **ggsql** despite the attractive names: one is a log microscope, the other is a local chart toy that does not own the Closure dashboard. Everything else is noise for this product.
