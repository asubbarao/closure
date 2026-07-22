# Extension catalog audit — Closure + quack :9494

**Date:** 2026-07-22  
**Channel:** `ext_catalog_clean` on quack `:9494` (token `vori-quack-2026`) — blocks first, never invented TVF args.  
**Server truth:** `server/extensions.sql` + greps of `server/**/*.sql` (active boot path = `app.sql` → `extensions.sql` → `model.sql` → `core.sql` / `views.sql` / `routes.sql`).  
**Quack truth:** `~/.quack/quack_serve_min.sql` LOAD list.

**High-score target:** 8–12 **earned** INSTALLs on Closure boot (every LOAD has a SELECT that dies without it). Theater LOADs lose points.

---

## 1. Target packs

### 1.1 Closure boot — **11 earned** (ordered INSTALL)

| # | Extension | Why earned (one SELECT that requires it) |
|---|-----------|------------------------------------------|
| 1 | **quackapi** | `quackapi_serve(...)` + `CREATE OR REPLACE ROUTE` |
| 2 | **pdf** | `pdf_info` / `read_pdf` / `read_pdf_words` / `pdf_redact` |
| 3 | **tera** | `tera_render(..., template_path := …)` → `html` column |
| 4 | **scalarfs** | `pathvariable:` readers + `variable:` COPY for detect bags |
| 5 | **hostfs** | `v_fs_inventory`: `ls` / `lsr` / `file_name` / `hsize` / `is_dir` |
| 6 | **hashfuncs** | `rapidhash(...)` entity/doc/suggestion ids (replaced md5) |
| 7 | **splink_udfs** | `unaccent(...)` on every watchlist/line_norm path |
| 8 | **finetype** | `finetype([...])` type_hits in detect |
| 9 | **rapidfuzz** | `rapidfuzz_*` name_hits + residual_pii + search |
| 10 | **bitfilters** | bloom create @ boot + probe before rapidfuzz |
| 11 | **inflector** | `inflector_to_title_case` display/kind labels |

**Optional 12th (only when SELECT lands, not at boot):**

| Extension | Gate before LOAD |
|-----------|------------------|
| **crypto** | First custody/export seal SELECT using `crypto_hash` / `crypto_hash_agg` |
| **http_client** | First LLM judge or self-dispatch `http_post_form` in a route/CTE |
| **shellfs** | First `read_*('cmd |')` or setup-from-SQL (e.g. page PNG via pdf, not bash) |
| **us_address_standardizer** | First `addrust_parse` into `entity_address_canon` (today stubs NULL) |

**DROP from current `extensions.sql` until earned:**

| Extension | Theater today | Re-ADD when |
|-----------|---------------|-------------|
| **crypto** | LOAD only; 0 `crypto_*` in server | custody / chain seal |
| **us_address_standardizer** | LOAD only; `entity_address_canon` returns NULLs | address parse CTE |
| **webbed** | Only `xml_valid(...)` smoke in `v_run_brief` | real HTML/XML ingest or SSR block path |
| **duck_block_utils** | `duck_block` / `db_blocks_to_text` only in `v_run_brief` | product brief UI; catalog is **webbed README clone** (see §4) |
| **http_client** | LOAD only; 0 `http_*` | judge loopback / self-dispatch |

### 1.2 quack_serve (`quack_serve_min.sql`) — **different pack**

Server is a **machine shell + catalog + self-dispatch bus**, not a FOIA app.

| KEEP / always LOAD | Role |
|--------------------|------|
| **quack** | protocol + `quack_serve` |
| **shellfs** | probes, densify, chrome bridge, pipes-as-rows |
| **hostfs** | staged ls/lsr crawls, path scalars |
| **scalarfs** | variable/pathvariable surfaces |
| **http_client** | self-dispatch `http_post_form` loopback |
| **read_lines** | log / stream slices |
| **tera** | any SQL-side HTML/text |
| **fts** | sessions / BM25 surfaces |
| **rapidfuzz** | fuzzy joins (fleet notes: partial_ratio FPs documented) |
| **webbed** | catalog rebuild + DataGrip XML |
| **crawler** | catalog rebuild crawl |
| **airport** | flight mesh (secret + LOAD) |
| **radio** | bus (when live UI / pubsub consumers exist) |
| **cronjob** | in-process weekly catalog + densify |

| Do **not** force onto quack boot | Why |
|----------------------------------|-----|
| pdf / quackapi / finetype / bitfilters / hashfuncs / inflector | Closure-product surface; load on demand or in Closure process |
| sitting_duck / parser_tools | Agent/dev tooling — LOAD when analyzing SQL/AST, not every attach |
| stochastic / json_schema / dqtest | No resident consumer on min serve |

**quack already LOADs** (from serve min):  
`radio, webbed, crawler, airport, shellfs, hostfs, scalarfs, read_lines, tera, http_client, fts, rapidfuzz, cronjob` (+ `quack`).

---

## 2. Per-extension table

Legend: **USE** = keep LOAD + SELECT exists · **DROP** = remove from boot until SELECT · **ADD** = not on Closure boot but earned if product lands · **SERVER** = quack pack.

| name | score | earned use (Closure / quack) | catalog params / samples to exploit | gap today |
|------|-------|------------------------------|-------------------------------------|-----------|
| **quackapi** | **USE** | Closure: `CREATE ROUTE` + `quackapi_serve(port, static_dir, memory_limit)` | Not in community `ext_catalog` rows (local/private); treat routes as product API | Catalog empty for quackapi — discovery is repo docs, not `ext_catalog_clean` |
| **pdf** | **USE** | Closure: `pdf_info` / `read_pdf` / `read_pdf_words` / `pdf_redact` | Named: `first_page`/`last_page`, `password`, `auto_ocr`/`ocr`, `ignore_errors`; `pdf_to_png(path, page [, dpi])`; `pdf_redact(..., dpi := 200)`; forms/annotations/revisions | **setup still shells `pdftoppm`** — catalog has `pdf_to_png`; OCR knobs unused on messy scans; no `ignore_errors` per-file quarantine |
| **tera** | **USE** | Closure: file-mode SSR all HTML routes | `autoescape` (default true), `autoescape_on`, **`template_path`** glob; extends/includes | Already on file-mode ✓; keep autoescape true for HTML (XSS) |
| **rapidfuzz** | **USE** | Closure detect + residual + search; quack fleet notes | `rapidfuzz_ratio/partial/token_sort/token_set`, jaro-winkler, distances | Detect stacks 3 scores per line — fine; ensure bloom prefilter stays in front |
| **crypto** | **DROP** (until custody) | Planned: custody digests, `crypto_hash_agg` seals (docs only) | `crypto_hash(alg, …)`, `crypto_hash_agg`, `crypto_hmac`, `crypto_random_bytes`; algs sha2-256, blake3, … | **0 `crypto_*` in server/** — pure theater LOAD |
| **finetype** | **USE** | Closure `type_hits` via `finetype([word])` | list form + domain hints; `finetype_detail` confidence | Map is crude (ISBN→SSN); unused: detail confidence, `ft_profile`, domain hints |
| **us_address_standardizer** | **DROP** | None in live SQL | `addrust_parse(addr)` (no tables); `standardize_address` after `load_us_address_data()` | `entity_address_canon` is NULL stubs — **LOAD without SELECT** |
| **splink_udfs** | **USE** | **`unaccent`** everywhere on normalize paths | `unaccent`, `strip_diacritics`, `soundex`, `double_metaphone`, suffix trie | Only unaccent earned; phonetic/trie unused (OK — don't invent) |
| **scalarfs** | **USE** | `pathvariable:samples_glob` etc.; `variable:detect_*` COPY | `variable:`, `pathvariable:`, `data+varchar:`, `data:`, decompress wrappers | Multi-level glob / list pathvariables underused |
| **webbed** | **DROP** (Closure) / **SERVER** (quack) | Closure: `xml_valid` smoke; quack: catalog + DataGrip XML | `read_html`/`read_xml`, XPath extract, `html_to_duck_blocks`, table extract, schema options | Closure product is PDF geometry; HTML ingest is spike-only |
| **duck_block_utils** | **DROP** | `v_run_brief` only | **Catalog bug:** blocks == webbed README (same titles/queries) — do not trust catalog for this name | Theater brief; fix catalog rebuild mapping before leaning on it |
| **http_client** | **DROP** (Closure) / **SERVER** | Quack self-dispatch; Closure: none | `http_get`, `http_post`, `http_post_form`, `http_head` | Comment says “LLM judge later” — **no SELECT** |
| **hashfuncs** | **USE** | `rapidhash` for doc/entity/suggestion/residual ids | `rapidhash`, xxh*, murmur* + seeds | Prefer over md5 ✓ in `core.sql`; leftover md5 may exist only in stale `domain/*` |
| **inflector** | **USE** | `inflector_to_title_case` on filenames + kind labels | case transforms, pluralize, column inflection | Only title_case used — enough to earn LOAD |
| **bitfilters** | **USE** | Bloom create + probe in detect + residual | `bitfilters_duckdb_hash/create/probe` version pin `v1.5.1`; also xor/quotient/fuse | num_sectors=64 is tiny (power-of-2 OK) — may high-FP; consider larger sectors; version pin vs runtime DuckDB |
| **stochastic** | **ADD** later | Review sampling / synthetic noise (not shipped) | `setseed`, `dist_*_sample/pdf/cdf` families | No SELECT — do not LOAD |
| **shellfs** | **ADD** later / **SERVER** | Quack: pipes everywhere; Closure: comment-only | path `cmd \|` / `\| cmd`; **`SET ignore_sigpipe = true`** | Closure setup still external bash; no CTE pipe |
| **hostfs** | **USE** / **SERVER** | `v_fs_inventory`; quack crawls | `ls`/`lsr`, `cd`/`pwd` pragmas, `file_size`, `file_name`, `file_extension`, `hsize`, `is_dir`, `is_file`, `path_type`, `file_last_modified` | Good; could drive setup inventory / export cleanup without bash |
| **read_lines** | **SERVER** / skip Closure | Quack logs/streams | line ranges, path-embedded selection, trim params | No Closure consumer |
| **parser_tools** | **ADD** agent-only | Catalog `is_parsable` / `parse_tables` on SQL | `parse_tables`, `parse_functions`, `is_parsable`, … | Not product boot |
| **sitting_duck** | **ADD** agent-only | AST over `server/**/*.sql` / static JS | `read_ast(path, context := …)` named params | Not product boot |
| **json_schema** | **ADD** later | Decision JSON / watchlist validation | `json_schema_validate`, `patch`, `update` | No SELECT — `exports/decisions/_schema.json` unused in SQL |
| **dqtest** | **ADD** later | Boot integrity beyond ad-hoc CASEs | `CALL dq_init()` + tests (catalog sparse) | Replaced today by hand gates in `app.sql` |
| **radio** | **SERVER** | Bus; live UI when product needs push | subscribe/listen/transmit (catalog thin — use query.farm) | Closure has no radio SELECT |
| **crawler** | **SERVER** | Catalog rebuild only | `crawl_url`, `sitemap`, robots/delay settings | Not Closure ingest |
| **airport** | **SERVER** | Flight mesh | attach/secrets | Not Closure |
| **fts** | **SERVER** | sessions BM25 | core FTS create/index | Closure search uses rapidfuzz on lines |
| **cronjob** | **SERVER** | densify + catalog rebuild | `cron(query, schedule)`, `cron_jobs`, `cron_delete` | Not Closure process |

---

## 3. Catalog outline (headings + runnable samples)

Condensed from `ext_catalog_clean` (headings + first runnable `query` samples). Full blocks: query catalog by `extension_name` + `block_order`.

### quackapi
- **Catalog:** no rows in `ext_catalog` / `ext_catalog_clean` on this fleet (private extension).
- **Product samples (repo):** `CREATE OR REPLACE ROUTE … AS SELECT …`; `FROM quackapi_serve(port, static_dir := …, memory_limit := …)`.

### pdf (178 blocks, 40 runnable)
- Headings: Read & extract → `read_pdf` / `read_pdf_lines` / `read_pdf_words` / tables / elements / chunks → scalars (`pdf_to_text`/`markdown`/`html`/`svg`/`png`) → Inspect (`pdf_info`, forms, annotations, revisions, signatures, images) → Transform (`merge`/`split`/`encrypt`/`watermark`/`redact`/`write_pdf`) → OCR.
- Sample shapes:
  - `SELECT * FROM pdf_info('…/*.pdf');`
  - `SELECT * FROM read_pdf_words('…', first_page := n, last_page := n);`
  - `SELECT octet_length(pdf_to_png('report.pdf', 1, 300));`
  - `SELECT * FROM pdf_redact(in, out, [{'page':2,'x':…,'y':…,'w':…,'h':…}], dpi := 200);`

### tera (50 blocks, 7 runnable)
- Headings: Functions → `tera_render(template, context, ...options)` → examples → filters.
- **Named params (catalog):** `autoescape` (default true), `autoescape_on VARCHAR[]`, **`template_path`** file glob.
- Sample: `tera_render('index.html', '{…}', template_path := './templates/*.html')`.

### rapidfuzz (69 / 13)
- Headings: ratio / partial / token_sort / token_set / distances (jaro, hamming, …).
- Sample: `rapidfuzz_token_sort_ratio(a, b)` etc.

### crypto (98 / 15)
- Headings: `crypto_hash`, `crypto_hash_agg`, algorithms, `crypto_random_bytes`, `crypto_hmac`.
- Sample: `lower(to_hex(crypto_hash('sha2-256', 'hello world')));`

### finetype (59 / 1 runnable in catalog)
- Headings: DuckDB extension usage, taxonomy, limitations.
- Product sample (app): `SELECT finetype([trim(word)])`.

### us_address_standardizer (35 / 1)
- Headings: `addrust_parse`, `parse_address`, `standardize_address`, `load_us_address_data`.
- Sample: `SELECT ap.* FROM (SELECT addrust_parse('123 N Main St Apt 4, Springfield IL 62704') AS ap);`

### splink_udfs (85 / 5)
- Headings: soundex, strip_diacritics, **unaccent**, double_metaphone, levenshtein, ngrams, suffix trie.
- Sample: `SELECT unaccent('…');` / `soundex('Robert');`

### scalarfs (109 / 26)
- Headings: `variable:`, `pathvariable:`, modifiers, `data+varchar:`, `data:`, decompress wrappers.
- Sample pattern: `FROM read_json_auto('pathvariable:manifest_path')`; `COPY (…) TO 'variable:detect_summarize'`.

### webbed (141 / 15) — same body currently under **duck_block_utils**
- Headings: XML/HTML processing, schema inference, extract, tables, XPath, config options.
- Sample: `LOAD webbed; SELECT xml_extract_text(…);` / `html_extract_tables` / `xml_valid`.

### http_client (20 / 1)
- Headings: GET / POST / POST form / full example.
- Sample: `http_get(url)` / `http_post_form(url, headers, form)`.

### hashfuncs (85 / 8)
- Headings: xxHash, **RapidHash**, MurmurHash3, partitioning / bloom DIY.
- Sample: `SELECT rapidhash('key');` / `xxh3_64(...)`.

### inflector (109 / 15)
- Headings: case transforms, pluralize, ordinals, predicates, struct/table inflection, configuration.
- Sample: title/snake/camel case functions (app uses `inflector_to_title_case`).

### bitfilters (162 / 12)
- Headings: quotient / XOR / binary fuse / **DuckDB bloom** (`bitfilters_duckdb_*`).
- Sample: create filter with version `'v1.5.1'`, `num_sectors` power-of-2, probe.

### stochastic (119 / 6)
- Headings: continuous/discrete dists, sample/pdf/cdf/quantile, `setseed`.
- Sample: `SELECT setseed(0.42); SELECT dist_normal_sample(0,1);`

### shellfs (77 / 4)
- Headings: pipe read/write, exit codes, **`ignore_sigpipe`**, caveats.
- Sample: `FROM read_csv('cmd |', …)`; `SET ignore_sigpipe = true;`

### hostfs (48 / 2)
- Headings: scalar + table functions, build notes.
- Sample: `FROM lsr(path, depth)`; `file_size(path)`, `hsize(...)`, `file_extension(path)`.

### read_lines (49 / 8)
- Headings: line selection syntax, global trim params, lateral join.
- Sample: `FROM read_lines('file', lines := …)`.

### parser_tools (158 / 11)
- Headings: `parse_tables` / `parse_functions` / `is_parsable` / context.
- Sample: `SELECT * FROM parse_tables('SELECT …');`

### sitting_duck (127 / 15)
- Headings: `read_ast` overloads, **named parameters**, context levels, semantic types.
- Sample: `FROM read_ast('**/*.py', context := 'native')`.

### json_schema (47 / 1)
- Headings: validate_schema / validate / patch / update.
- Sample: `json_schema_validate(schema, data)`.

### dqtest (50 / 3)
- Headings: init, core functions (catalog install name may be `dq_test` — verify before INSTALL).
- Sample: `CALL dq_init();`

### radio / crawler / airport / fts / cronjob
- See §2; quack-oriented. Crawler: robots/delay/timeout settings. Cronjob: 6-field schedule. FTS: core PRAGMA create_fts_index patterns (catalog thin here).

---

## 4. Theater vs real (grep of active server)

Boot path: **`model.sql` → store + core + views** (not `domain/*` dual spine for serve).

| Extension | LOAD in extensions.sql | SELECT symbols in server | Verdict |
|-----------|------------------------|--------------------------|---------|
| quackapi | yes | `quackapi_serve`, ROUTE | **real** |
| pdf | yes | pdf_info, read_pdf*, pdf_redact | **real** |
| tera | yes | tera_render × many | **real** |
| rapidfuzz | yes | rapidfuzz_* × many | **real** |
| crypto | yes | **0** | **theater** |
| finetype | yes | finetype × detect | **real** |
| us_address_standardizer | yes | **0** | **theater** |
| splink_udfs | yes | unaccent × many | **real** (narrow) |
| scalarfs | yes | pathvariable:/variable: | **real** |
| webbed | yes | xml_valid (smoke) | **theater** |
| duck_block_utils | yes | duck_block / db_blocks_to_text (brief only) | **theater** |
| http_client | yes | **0** | **theater** |
| hostfs | yes | ls/lsr/file_*/hsize | **real** |
| hashfuncs | yes | rapidhash | **real** |
| inflector | yes | inflector_to_title_case | **real** |
| bitfilters | yes | bloom create + probe | **real** |

`domain/*.sql` still has older `md5` / parallel detect — **not** on `model.sql` boot; treat as dead branch until deleted or re-wired.

---

## 5. Top 10 improvements (LOC / deps deleted)

Ranked by **deps deleted or shell/LOC removed**, not theater stack growth.

| # | Improvement | Effect |
|---|-------------|--------|
| 1 | **`pdf_to_png` replace `pdftoppm` in setup** | Drop poppler host dep + `scripts/setup.sh` loop; SQL CTE writes `pages/<stem>/pN.png` |
| 2 | **DROP theater LOADs** (crypto, us_address, webbed, duck_block_utils, http_client) | −5 INSTALL/LOAD; faster boot; honest pack size |
| 3 | **Delete or stop dual `domain/*` spine** | Kill md5 remainder / duplicate detect; one source of truth (`core.sql`) |
| 4 | **Drop `v_run_brief` duck_block/xml_valid smoke** | Removes only product “use” of webbed/blocks theater |
| 5 | **`addrust_parse` into `entity_address_canon` *or* drop address kind path** | Either earn us_address or stop implying address standardization |
| 6 | **pdf `ignore_errors` / per-file pdf_info quarantine** | One bad sample PDF no longer aborts whole glob ingest |
| 7 | **finetype_detail confidence → band** | Delete hand CASE mapping / fake confidence 75 where detail exists |
| 8 | **bitfilters num_sectors sizing** | Fewer false bloom admits → less rapidfuzz work (measure FPR) |
| 9 | **crypto custody only when export seals** | One earned crypto path beats empty LOAD; implement or stay dropped |
| 10 | **shellfs CTE for one-off ops *or* never mention shellfs** | Comment promises shellfs; zero pipes — either earn or silence |

---

## 6. Anti-theater rules

**Must NOT LOAD without a SELECT that fails without the extension:**

1. No “for later LLM/judge” LOADs (`http_client`, `radio`, `stochastic`).
2. No “docs say custody” without `crypto_hash` in the boot graph.
3. No address extension while `entity_address_canon` returns hard-coded NULLs.
4. No webbed/duck_block for a single `xml_valid('<article>…')` constant.
5. **Quack rule (different product):** min serve may LOAD shellfs/hostfs/http_client because **other** resident views/cron use them; Closure must not copy that list blindly.
6. **Catalog rule:** if `duck_block_utils` content == webbed, fix rebuild before writing product SQL against “blocks” docs.

---

## 7. Earned-use SQL snippets (catalog-aligned)

### Detect spine (finetype + bloom + rapidfuzz + unaccent + rapidhash)

```sql
-- boot bloom (bitfilters + splink unaccent)
SET VARIABLE watchlist_bloom = (
  SELECT bitfilters_duckdb_bloom_filter_create('v1.5.1', 64, hv)
  FROM (
    SELECT bitfilters_duckdb_hash('v1.5.1', lower(trim(unaccent(term)))) AS hv FROM watchlist
  )
);

-- type hit
SELECT finetype([trim(w.word, '.,;:()"''[]')]) AS ft FROM words w;

-- name hit prefilter then score
WHERE bitfilters_duckdb_bloom_filter_probe(
  'v1.5.1', getvariable('watchlist_bloom'), lower(trim(unaccent(token)))
)
-- then rapidfuzz_token_sort_ratio / partial_ratio / jaro_winkler

-- stable id (hashfuncs)
SELECT format('{:x}', rapidhash(doc || chr(31) || page || chr(31) || text)) AS id;
```

### PDF + scalarfs + tera + hostfs

```sql
FROM pdf_info('pathvariable:samples_glob');
FROM read_pdf_words('pathvariable:samples_glob');
SELECT tera_render('review.html', ctx::JSON,
  template_path := 'server/templates/**/*.html') AS html;
FROM ls(getvariable('samples_dir'));  -- hostfs
```

### Export (pdf_redact — bottom-left points)

```sql
FROM pdf_redact(source_path, out_path, boxes);  -- boxes: page,x,y,w,h BL origin
```

### Missed power (not in app yet)

```sql
-- page PNG without poppler
SELECT pdf_to_png(source_path, page_no, 150) AS png_blob FROM pages;

-- address (earn us_address or don't load)
SELECT addrust_parse(canonical_text) FROM entities WHERE starts_with(kind, 'ADDRESS');

-- custody (earn crypto)
SELECT lower(to_hex(crypto_hash('sha2-256', content))) FROM read_blob(source_path);
```

---

## 8. Recommended `extensions.sql` body

```sql
-- extensions.sql — Closure product pack (earned only). DuckDB ≥ 1.5.4.
-- Theater LOADs banned: every line must have a failing SELECT if removed.

INSTALL quackapi FROM community; LOAD quackapi;           -- routes + serve
INSTALL pdf FROM community; LOAD pdf;                     -- words/info/redact
INSTALL tera FROM community; LOAD tera;                   -- SSR file-mode
INSTALL scalarfs FROM community; LOAD scalarfs;           -- pathvariable:/variable:
INSTALL hostfs FROM community; LOAD hostfs;               -- ls/lsr inventory
INSTALL hashfuncs FROM community; LOAD hashfuncs;         -- rapidhash ids
INSTALL splink_udfs FROM community; LOAD splink_udfs;     -- unaccent normalize
INSTALL finetype FROM community; LOAD finetype;           -- type_hits
INSTALL rapidfuzz FROM community; LOAD rapidfuzz;         -- name_hits / residual
INSTALL bitfilters FROM community; LOAD bitfilters;       -- watchlist bloom
INSTALL inflector FROM community; LOAD inflector;         -- display labels

-- ADD only when a SELECT lands in the boot graph:
-- INSTALL crypto FROM community; LOAD crypto;            -- custody / seals
-- INSTALL http_client FROM community; LOAD http_client;  -- judge / loopback
-- INSTALL shellfs FROM community; LOAD shellfs;          -- CTE pipes
-- INSTALL us_address_standardizer FROM community; LOAD us_address_standardizer;
-- INSTALL webbed FROM community; LOAD webbed;            -- HTML/XML ingest
-- (duck_block_utils: fix catalog identity first; then only with real brief UI)
```

**Count: 11 earned INSTALLs** (inside 8–12 high-score band).

### Quack serve (reference only — already in `quack_serve_min.sql`)

Do not shrink quack to Closure’s 11. Keep:

```text
quack · shellfs · hostfs · scalarfs · read_lines · tera · http_client
· fts · rapidfuzz · webbed · crawler · airport · radio · cronjob
```

---

## 9. Method notes

- Discovery: `ext_catalog_clean` headings + `query IS NOT NULL` samples; fleet `ext_catalog.loaded/installed`.
- Usage: ripgrep over `closure/server/**/*.sql` for symbol patterns (counts in session: crypto 0, http 0, address 0, shellfs comment-only, pdf/tera/rapidfuzz/finetype/hostfs/hashfuncs/bitfilters/inflector/unaccent real).
- **duck_block_utils catalog pollution:** `extension_name = 'duck_block_utils'` blocks start with “DuckDB Webbed Extension” — rebuild classification bug; treat as non-authoritative until fixed.
- **quackapi** absent from catalog — document from product SQL, not community README.

---

*End of audit. Next engineering move: apply §8 body + land `pdf_to_png` setup replacement; do not re-add dropped LOADs without a SELECT in the same PR.*
