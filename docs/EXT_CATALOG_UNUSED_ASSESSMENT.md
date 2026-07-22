# Community extension unused assessment (Closure + quack)

**Date:** 2026-07-22  
**Channel:** quack `:9494` (`LOAD quack` → `quack_query` / ATTACH; token `vori-quack-2026`)  
**Sources:** `ext_catalog` (fleet) + `ext_catalog_clean` (README blocks + parser-validated `query` samples)  
**Rule:** catalog first — not web list first, not `duckdb_functions()` as discovery.  
**Policy:** **Do not INSTALL without a SELECT that uses the extension.**

---

## Method

1. `DESCRIBE ext_catalog` → columns: `extension_name`, `loaded`, `installed`, `description`, `github_url`, `readme_content`.
2. Fleet dump: `SELECT extension_name, loaded, installed, description, github_url FROM ext_catalog ORDER BY 1`  
   → **313** catalog rows on this box (27 loaded, 93 installed at probe time).
3. **Used baseline** from disk + symbol grep (not “mentioned in a comment”):
   - Closure: `/Users/aloksubbarao/personal/closure/server/extensions.sql` + real symbols under `server/**/*.sql`.
   - Quack: `~/.quack/quack_serve_min.sql` LOAD list; note extras currently loaded on live `:9494`.
4. **Unused** = catalog names minus used baseline (core DuckDB extensions treated as ambient: `json`, `parquet`, `httpfs`, `icu`, `autocomplete`, `core_functions`, `shell`, `ui`, `tpch`, `tpcds`).
5. Score unused from `ext_catalog` description + `ext_catalog_clean` headings / 1–2 `query` samples where present.

| Score | Meaning |
|-------|---------|
| **A** | Clear win for **Closure** soon (deletes a layer / model power) |
| **B** | Clear win for **quack** server / agent harness |
| **C** | Nice later / niche |
| **D** | Irrelevant or theater risk |

---

## Used baseline

### Closure — `server/extensions.sql` (pack of 12)

| Extension | Status | Evidence |
|-----------|--------|----------|
| **quackapi** | **earned** | `quackapi_serve(...)` in `app.sql` |
| **pdf** | **earned** | `pdf_info` / `read_pdf` / `read_pdf_words` / `pdf_redact` in `core.sql`, routes |
| **tera** | **earned** | `tera_render(...)` file-mode in routes/views |
| **shellfs** | **earned** | `read_csv('ls -1 …/*.pdf \|', …)` → `v_samples_shell_ls` in `core.sql` |
| **hostfs** | **earned** | `ls` / `lsr` / `file_name` / `is_dir` / `hsize` inventory in `core.sql` |
| **scalarfs** | **earned** | `pathvariable:` / `variable:` readers + COPY in `core.sql` / `app.sql` |
| **rapidfuzz** | **earned** | `rapidfuzz_*` detect + remainder paths |
| **finetype** | **earned** | `finetype([...])` detect |
| **hashfuncs** | **earned** | `rapidhash(...)` entity/document ids |
| **inflector** | **earned** | `inflector_to_title_case(...)` display labels |
| **bitfilters** | **earned** | bloom create/probe before rapidfuzz |
| **splink_udfs** | **theater LOAD** | `INSTALL/LOAD` only — **no** `splink_*` / metaphone / soundex symbols in server SQL |

**Explicitly deferred** (comments in `extensions.sql`, not LOADed):

| Extension | Why deferred |
|-----------|----------------|
| `http_client` | self-dispatch / LLM judge when a route needs it |
| `us_address_standardizer` | address parse when detect stops passthrough-canon |
| `webbed` / `duck_block_utils` | HTML/block report path removed as theater |

**Comment-only (not LOADed):** `crypto` — “custody digests stay on crypto”; no `crypto_hash` calls yet.

### Quack serve — `~/.quack/quack_serve_min.sql`

| Extension | Role on :9494 |
|-----------|----------------|
| **quack** | protocol |
| **radio** | Redis/WS event bus client |
| **webbed** | HTML/XML structure |
| **crawler** | SQL crawl |
| **airport** | Arrow Flight mesh |
| **shellfs** | host pipes as rows |
| **hostfs** | typed filesystem |
| **scalarfs** | scalar VFS |
| **read_lines** | line-numbered text |
| **tera** | templates |
| **http_client** | outbound HTTP / self-dispatch loopback |
| **fts** | BM25 (`sessions` / search) |
| **rapidfuzz** | fuzzy |
| **cronjob** | in-process SQL cron |

### Live `:9494` extras (loaded at probe; not all in serve_min)

Also **loaded** when assessed: `markdown`, `yaml`, `parser_tools`, `stochastic`, `lpts`, `rate_limit_fs` (plus core json/httpfs/icu/parquet…). Treat as **quack-in-use / ops-surface** even if not re-registered in `quack_serve_min.sql` every boot story.

### Combined “already in” (exclude from unused, or mark already-in)

```
# Closure pack (earned)
quackapi pdf tera shellfs hostfs scalarfs rapidfuzz finetype hashfuncs inflector bitfilters

# Closure theater (still “in pack”, not a discovery win)
splink_udfs

# Quack serve + live ops
quack radio webbed crawler airport read_lines http_client fts cronjob
markdown yaml parser_tools stochastic lpts rate_limit_fs

# Core ambient (not scored as community “add”)
json parquet httpfs icu autocomplete core_functions shell
```

---

## Special-attention candidates (user list)

| Extension | Status | Score if still unused | Note |
|-----------|--------|----------------------|------|
| **hashfuncs** | Closure **earned** | — | `rapidhash` ids |
| **inflector** | Closure **earned** | — | title labels |
| **bitfilters** | Closure **earned** | — | watchlist prefilter |
| **hostfs** | both **earned** | — | inventory |
| **shellfs** | both **earned** | — | host pipes |
| **radio** | **quack** loaded; Closure unused | **A** | live UI / events without Redis app layer |
| **stochastic** | **quack** loaded; Closure unused | **A** | review sampling / reproducible noise |
| **tributary** | unused both | **C** | Kafka; historical arm64 gaps — use radio/QUEUE until proven |
| **read_lines** | **quack** | **C** for Closure | line readers for non-PDF text dumps |
| **parser_tools** | **quack** loaded | — (B surface already) | catalog SQL structure; harness skill |
| **sitting_duck** | installed, not product spine | **B** | tree-sitter AST as tables for agent code |
| **json_schema** | unused product | **B** (quack) / **C** (Closure) | validate watchlist/manifest/detect JSON |
| **dqtest** | unused | **B** | in-SQL data-quality tests for marts |
| **markdown** | **quack** loaded | — | docs / memories / catalog rebuild |
| **yaml** | **quack** loaded | — | config / frontmatter |
| **plinking_duck** | unused | **D** | PLINK genomics — wrong product |
| **func_apply** | unused | **C** | dynamic scalar call-by-name; easy theater |
| **zim** | unused | **C** | offline knowledge corpora — not FOIA core |
| **whisper** | unused | **C** | STT when audio FOIA path lands |
| **http_client** | quack earned; Closure deferred | **A** | next Closure wire for self-dispatch / Ollama |
| **crypto** | unused product symbols | **A** | custody digests at export |
| **us_address_standardizer** | deferred | **A** | only with real standardize SELECT |
| **fts** | quack earned; Closure unused | **A**/ **C** | in-app search over lines/entities |

---

## Recommended **add next 5–8** for Closure (high-score pack path)

Current earned pack is **11 real + 1 theater** (`splink_udfs`). Target remains ~8–12 **earned** symbols, not LOAD count.

### Do next (in order)

| # | Extension | Why | Concrete SQL use | File that would change |
|---|-----------|-----|------------------|------------------------|
| 1 | **http_client** | Self-dispatch + Ollama judge without FastAPI client | `http_post_form` / `http_post` loopback or `http://127.0.0.1:11434/api/generate` | `extensions.sql` + detect/judge route or CTE in `core.sql` / `routes.sql` |
| 2 | **stochastic** | Review sampling, reproducible synthetic noise, confidence sims | `setseed(0.42); dist_normal_sample(...)` / Bernoulli sample of remainder rows | `extensions.sql` + sampling view in `views.sql` / bulk review |
| 3 | **crypto** | Custody digests (export / decision log integrity) separate from `rapidhash` | `lower(to_hex(crypto_hash('sha2-256', payload)))` | `extensions.sql` + export path in `routes.sql` / `serve/extras.sql` |
| 4 | **radio** | Live UI / multi-tab events without Redis sidecar app | `radio_subscribe` / `radio_transmit_message` for detect-complete | `extensions.sql` + optional panel route when live UI lands |
| 5 | **us_address_standardizer** | Real address entities (today canon is passthrough) | standardize address text → `entity_address_canon` | `extensions.sql` + `views.sql` / `serve/extras.sql` |
| 6 | **fts** | Search lines / entities / decisions in-process | `pragma_create_fts_index` + `match_bm25` on `document_lines` | `extensions.sql` + search route |
| 7 | **encodings** | FOIA charset mess → UTF-8 without Python | decode bytes/columns that are not UTF-8 | `core.sql` / ingest path when non-UTF samples appear |
| 8 | **json_schema** | Fail-closed watchlist/manifest shape | validate `watchlist.json` / detect raw before insert | `core.sql` boot integrity |

### Pack hygiene (same PR energy, not new installs)

| Action | Why |
|--------|-----|
| **Earn or drop `splink_udfs`** | LOAD-only is theater; either call phonetic/normalize UDFs in detect or remove from pack |
| Do **not** re-LOAD `webbed` / `duck_block_utils` until a product SELECT needs HTML blocks | Avoid costume high-score |

### Target Closure pack shape (illustrative 12 earned)

```
quackapi · pdf · tera · hostfs · shellfs · scalarfs
rapidfuzz · finetype · hashfuncs · inflector · bitfilters
http_client
```
Then layer **stochastic · crypto · radio · fts** as product features land (each with a SELECT).  
Replace theater **splink_udfs** with one of the above when you hit 12.

---

## Recommended **add next** for quack (if different)

Quack already owns shell/fs/http/fts/cron/radio/crawler. Gaps are **agent harness + quality + obs**, not PDF redaction.

| # | Extension | Why | Concrete SQL use | Where |
|---|-----------|-----|------------------|--------|
| 1 | **sitting_duck** | Code-as-tables for agent work (maximus doctrine) | `SELECT * FROM read_ast('**/*.{py,sql,ts}', …)` | ad-hoc + optional unmat views over personal/ skills |
| 2 | **dqtest** | Quality gates on stream/catalog marts | define/run SQL DQ tests as tables | quack views / cron job |
| 3 | **otlp** | Live OTEL into Duck / DuckLake | stream traces/logs as relations | obs path (complements file QueryLog) |
| 4 | **json_schema** | Catalog / config validation | validate rebuilt catalog rows or YAML→JSON | `ext_catalog_rebuild` pipeline |
| 5 | **sazgar** or **system_stats** | Host health as SQL (CPU/mem/disk) | table functions → fleet health views | replace fragile shell-only probes where it earns |
| 6 | **agent_data** | Query local agent history dirs | conversations/plans/todos as tables | sessions-adjacent tooling |
| 7 | **zipfs** / **tarfs** | Archives without unpack scripts | `read_*` inside zip/tar | sample packs, log bundles |
| 8 | **magic** | libmagic type + “read almost anything” | `magic_type(path)` on hostfs inventory | crawl / conduit |

**Keep loaded if used:** `parser_tools`, `markdown`, `yaml`, `stochastic` — already on live quack; pin in serve_min only when a boot consumer needs them every restart.

**Avoid re-loading fragile party** (`llm` / `flock` / `infera` / `mlpack` via broken `http_request`) unless offline binaries proven — see serve_min history comments.

---

## Full **A** table (Closure soon)

| Extension | One-line why | Concrete use | File |
|-----------|--------------|--------------|------|
| **http_client** | Self-dispatch + local LLM without app SDK | `http_post` Ollama / `http_post_form` loopback | `extensions.sql`, judge/detect CTE, `routes.sql` |
| **stochastic** | Sampling & reproducible synthetic noise in SQL | `dist_*_sample` + `setseed` for review cohorts | `views.sql` / bulk review |
| **crypto** | Real custody digests ≠ rapidhash | `crypto_hash('sha2-256', …)` on export payload | export route |
| **radio** | In-process pub/sub client for live UI | transmit detect-complete / listen panel | panel routes when UI lands |
| **us_address_standardizer** | Earn address canon (today fake standardized_text) | standardize → `entity_address_canon` | `views.sql`, `serve/extras.sql` |
| **fts** | BM25 over document lines / decisions | FTS index + search API route | `routes.sql`, index build in core |
| **encodings** | FOIA non-UTF text without Python | decode columns/files to UTF-8 | ingest / `core.sql` |

---

## Full **B** table (quack / agent harness)

| Extension | One-line why | Concrete use | Surface |
|-----------|--------------|--------------|---------|
| **sitting_duck** | AST rows over codebases | `read_ast` on skills/SQL/TS | agent queries, not Closure app |
| **parser_tools** | *(already loaded)* SQL structure on catalog | `is_parsable` / `parse_functions` on `ext_catalog_clean.query` | ext-catalog skill |
| **markdown** | *(already loaded)* structured MD | `read_markdown` for memories/docs | stream / memories views |
| **yaml** | *(already loaded)* config as tables | `read_yaml` for agent/project config | harness |
| **dqtest** | DQ tests stay in Duck | test suite tables over marts | cron + CI-as-SQL |
| **json_schema** | Schema-validate JSON blobs | validate catalog/config/API bodies | rebuild + ingress |
| **otlp** | Queryable traces/metrics | OTLP stream → tables | obs beyond QueryLog CSVs |
| **agent_data** | Agent history as relations | read plans/todos/usage from local dirs | sessions-adjacent |
| **sazgar** / **system_stats** | Host metrics as SQL | CPU/mem/disk/process TFs | fleet health |
| **zipfs** / **tarfs** | Archives as filesystems | open nested samples/logs | crawl tools |
| **magic** | MIME/type + smart reader | type hostfs paths | crawl |
| **lpts** | *(already loaded)* plan inspect / transpile | optimized plan rows | SQL craft |
| **poached** | SQL parse for IDE/tools | introspection TFs | editor/agent tooling |
| **textplot** | ASCII charts in SQL | ops dashboards in terminal | ad-hoc |
| **cronjob** / **radio** / **crawler** / **airport** / **fts** / **http_client** / **read_lines** | *(already serve_min)* | keep earned | boot |

---

## Top **15 C** (nice later / niche)

| Extension | Why later |
|-----------|-----------|
| **tributary** | Kafka bus; prefer radio until install/platform proven |
| **whisper** | Audio FOIA / interview transcripts later |
| **zim** | Offline wiki/StackExchange corpora — product adjacent only |
| **fakeit** | Demo fixtures; not production detect |
| **jwt** | Auth tokens if Closure grows multi-user API |
| **netquack** | URL/domain parse if crawl/link features grow |
| **html_query** / **html_readability** | Better HTML extract with crawler/webbed |
| **lsh** | Near-duplicate document clustering at scale |
| **marisa** | Compact trie for huge watchlists |
| **datasketches** | Mergeable approx counts/quantiles across partitions |
| **func_apply** | Dynamic call-by-name — useful, high theater risk |
| **quickjs** / **lua** / **evalexpr_rhai** | Script escape hatches; prefer pure SQL + shellfs first |
| **minijinja** | Second template engine; tera already earned |
| **vss** / **faiss** / **quackformers** / **pic2vec** | Embedding search — only after detect needs semantic ANN |
| **spatial** / **h3** / **a5** | Geo panel if FOIA geodata becomes real |
| **sheetreader** / **excel** / **gsheets** | Spreadsheet FOIA packs |
| **redis** | External cache/sessions if radio insufficient |
| **httpserver** / **duckdbi** / **dash** | Alternate HTTP/BI shells — Closure already on quackapi |
| **ai** / **open_prompt** / **llm** | Hosted/local LLM sugar; Closure docs prefer `http_client`→Ollama for binder freedom |
| **cozip** | Cloud-optimized zip variants |

---

## **D** — short name list (irrelevant or theater risk)

Domain mismatch / demo / scanners / lakehouses / unrelated science / fragile stacks:

`a5`, `acp`, `adbc`, `adbc_scanner`, `aixchess`, `altertable`, `anndata`, `anofox_forecast`, `anofox_statistics`, `anofox_tabfm`, `anofox_tabular`, `astro`, `avro`, `aws`, `azure`, `behavioral`, `bigquery`, `blockduck`, `boilstream`, `brew`, `bvh2sql`, `cache_httpfs`, `cache_prewarm`, `capi_quack`, `cassandra`, `celestial`, `chaos`, `chess`, `chsql`, `chsql_native`, `cityjson`, `clamp`, `cloudfront`, `cloudfs`, `cwiqduck`, `datadog`, `dazzleduck`, `dbn`, `decimal_arithmetic`, `deferred_columns`, `delta*`, `dicom`, `dns`, `dplyr`, `dryrun`, `dta`, `duck_delta_share`, `duck_dggs`, `duck_diff`, `duck_geoarrow`, `duck_hunt`, `duck_lineage`, `duck_lk`, `duck_tails`, `duckdb_delta_sharing`, `duckdb_geoip_rs`, `duckdb_mcp`, `duckdb_slack`, `duckgl`, `duckherder`, `duckhog`, `duckhts`, `ducklake*`, `ducklink`, `ducknng`, `duckorch`, `duckpgq`, `ducksmiles`, `ducksync`, `duckthink`, `ducktinycc`, `duckton`, `eeagrid`, `eenddb`, `elasticsearch`, `erpl_*`, `eurostat`, `events`, `file_dialog`, `finance`, `fire_*`, `firebird`, `fit`, `fivetran`, `flock`, `fsquery`, `fuzzycomplete`, `gaggle`, `gcs`, `gdx`, `geography`, `geosilo`, `geotiff`, `ggsql`, `gh`, `gorz`, `h3`, `h5db`, `harbor`, `hdf5`, `hedged_request_fs`, `highs`, `hive_metastore`, `hnsw_acorn`, `holtfs`, `http_request`, `http_stats`, `httpd_log`, `httpfs_timeout_retry`, `iceberg`, `inet`, `infera`, `ion`, `jsonata`, `keboola`, `lance`, `lastra`, `latency_injection_fs`, `laterite_ags4`, `level_pivot`, `lindel`, `loki`, `lttb`, `maxmind`, `midi`, `miint`, `miniplot`, `mlpack`, `monetary`, `mongo`, `mooncake`, `motherduck*`, `mpduck`, `msolap`, `mssql`, `mysql_scanner`, `nanoarrow`, `nanodbc`, `nats_js`, `nsv`, `oast`, `observefs`, `odbc_scanner`, `ofquack`, `onager`, `onelake`, `osmium`, `overture`, `pac`, `paimon`, `pbi_scanner`, `pbix`, `pcap_*`, `pdal`, `pfc`, `pivot_table`, `plinking_duck`, `polyglot`, `postgres_scanner`, `protoduck`, `prql`, `psql`, `pst`, `psyduck`, `pyroscope`, `quack_oauth`, `quackfix`, `quackscale`, `quackstats`, `quackstore`, `query_condition_cache`, `query_limiter`, `qvd`, `raquet`, `raster`, `rawduck`, `rdf`, `read_dbf`, `read_stat`, `robust`, `rrd`, `rusty_*`, `salesforce`, `scrooge`, `se3`, `semantic_views`, `sitemap`, `snowflake`, `splunk`, `spxlsx`, `sqlite_scanner`, `sqlsmith`, `sshfs`, `st_read_multi`, `stats_duck`, `substrait`, `sudan`, `table_guard`, `table_inspector`, `talib`, `three_d`, `title_mapper`, `tpch_rust`, `tsid`, `ulid`, `urlpattern`, `valhalla_routing`, `vindex`, `vortex`, `waddle`, `warc`, `web_archive`, `web_search`, `webdavfs`, `webmacro`, `wireduck`, `yardstick`, `zarr`, `zeek`, `arrow` (alias), `waddle`

*(D is intentionally broad: “not wrong forever,” but not Closure FOIA review or quack harness spine without a named SELECT.)*

---

## Theater / anti-score notes

| Pattern | Example | Rule |
|---------|---------|------|
| LOAD without SELECT | `splink_udfs` in Closure pack | Drop or earn |
| Comment as architecture | “custody on crypto” without `crypto_hash` | Install only with export SELECT |
| Second template / LLM stack | minijinja, flock, open_prompt, ai | Prefer tera + http_client→Ollama |
| Enumerate scanners | postgres/mysql/snowflake/… | Irrelevant to FOIA app |
| Kafka before radio works | tributary | Stay on radio |

---

## Explicit install rule

```text
Do not INSTALL <ext> FROM community
  unless there is a SELECT (or CREATE VIEW … AS SELECT)
  that calls a symbol only that extension provides.
```

Smoke shape (any extension):

```sql
INSTALL foo FROM community;
LOAD foo;
SELECT <foo_symbol>(...);   -- must succeed and be product-meaningful
```

Self-dispatch / loopback remains:

```sql
-- only after http_client is earned on Closure
SELECT http_post_form('http://127.0.0.1:9494/', MAP{}, MAP{'q': qsql});
```

---

## Catalog inventory note

- **313** names in `ext_catalog` at assessment time.  
- Descriptions for scoring came from `ext_catalog.description` and `ext_catalog_clean` blocks for A/B candidates.  
- Web list (https://duckdb.org/community_extensions/list_of_extensions) **not** used as primary source — catalog rows were non-empty for all assessed names.

---

## Summary

| Product | Already strong | Next earned moves | Drop/avoid |
|---------|----------------|-------------------|------------|
| **Closure** | pdf · tera · quackapi · hostfs · shellfs · scalarfs · rapidfuzz · finetype · hashfuncs · inflector · bitfilters | **http_client → stochastic → crypto → radio → us_address → fts** | theater **splink_udfs**; webbed/duck_block until product SELECT |
| **quack** | radio · shellfs · hostfs · http_client · fts · cronjob · crawler · airport · parser_tools · markdown · yaml · stochastic | **sitting_duck · dqtest · otlp · json_schema · host metrics · zipfs/tarfs** | fragile llm/flock party; tributary until needed |

**Report is the product.** No change to `extensions.sql` from this assessment.
