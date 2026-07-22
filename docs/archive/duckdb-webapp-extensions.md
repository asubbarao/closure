# DuckDB as a web backend — community extension survey

**Scope:** Read-only survey of the [DuckDB Community Extensions catalog](https://duckdb.org/community_extensions/list_of_extensions.html) (stable listing for **v1.5.4**) and per-extension pages, focused on using an embedded DuckDB process as an HTTP/app server (“DuckDB IS the web backend”).

**Survey date:** 2026-07-19  
**Catalog claim:** Community list is for latest stable **DuckDB v1.5.4**.  
**Local probe host:** DuckDB CLI reported `v1.5.3` on this machine; CDN binaries checked at  
`https://community-extensions.duckdb.org/{v1.5.3|v1.5.4}/osx_arm64/<name>.duckdb_extension.gz`.

**Install pattern (all community extensions):**

```sql
INSTALL <name> FROM community;
LOAD <name>;
```

Community builds are **signed and distributed** by the [community-extensions CI](https://duckdb.org/2024/07/05/community-extensions.html). “Signed osx_arm64” below means a successful HTTP **200** on the community CDN for that version/platform (or “catalog-listed” when listed for v1.5.4 but CDN path not re-probed).

---

## Executive summary

| Goal | Best available pieces | Gap vs Node/Python |
|------|----------------------|--------------------|
| **HTTP app server** | `httpserver` (SQL-over-HTTP OLAP API + play UI); `duckdbi` / `dash` (embedded BI UIs) | **No named app routes**, no Express-style routing, no first-class static file tree, no middleware stack |
| **SSR HTML** | `tera` (`tera_render`) | One-shot template render; no layout inheritance as a full framework; must glue to a server yourself |
| **Server logic (JS)** | `quickjs` | Experimental; not a request lifecycle runtime |
| **PDF** | `pdf` (read/OCR/render/redact/write) | Excellent **in-SQL** document toolkit; not a web framework |
| **Sessions / auth** | `httpserver` Basic/X-API-Key; `quack_oauth` (for **Quack** protocol, not httpserver); `crypto`; `redis`; `boilstream` | No cookie/session middleware; OAuth is for Quack client-server, not general web apps |
| **Realtime** | `radio` (WebSocket / Redis pub-sub **client**) | No SSE server; radio is event-bus **client**, not “upgrade this HTTP route to WS” |
| **Outbound HTTP** | `http_client`, `erpl_web` (`http_get`/`http_post`…), core `httpfs` | Fine for fan-out / self-dispatch; not for serving |
| **quackapi** | **Not in community catalog** | Local/private only if you built it |

**Architecture reality check:** Today’s stack can make DuckDB a **tiny multiplayer SQL API** or **local BI shell**, plus strong SQL-side I/O (HTML parse, PDF, templates, fake data). It does **not** replace FastAPI/Express for multi-route HTML apps, OAuth cookie sessions, websockets-as-server, or production edge auth. Closest “full product” servers are **httpserver** (query API) and **duckdbi/dash** (opinionated UIs), not a general web framework.

---

## Master table

| Extension | What it does | INSTALL / LOAD | Key functions / API surface | Routes / static / HTML / JSON? | Signed `osx_arm64` v1.5.x | Tradeoffs vs Node/Python API |
|-----------|--------------|----------------|----------------------------|--------------------------------|---------------------------|------------------------------|
| **[httpserver](https://duckdb.org/community_extensions/extensions/httpserver.html)** | Turns DuckDB into an **HTTP OLAP API**: POST SQL, get results; embedded **play** SQL UI | `INSTALL httpserver FROM community; LOAD httpserver;` | `httpserve_start(host, port, auth)`, `httpserve_stop()` | **Endpoints:** `/` (GET/POST query), `/ping`. Auth: Basic (`user:pass`) or `X-API-Key`. Formats: `JSONEachRow`, `JSONCompact`. **No** named app routes, **no** static-file mount, **no** HTML SSR API | **v1.5.4: yes**; **v1.5.3: no** (CDN 404) | Single process, zero deploy surface for “run SQL over HTTP.” Auth is a shared secret, not users/roles/sessions. Concurrent writes are DuckDB’s model (not a connection-pooled app server). Experimental. Prefer `-readonly` for safety. |
| **[duckdbi](https://duckdb.org/community_extensions/extensions/duckdbi.html)** | Embedded **BI dashboard SPA** (Plotly + Gridstack) served from DuckDB | `INSTALL duckdbi FROM community; LOAD duckdbi;` | `duckdbi_start(host, port)`, `duckdbi_stop()` | Fixed UI + `/api/query` JSON. **Not** a general router | **yes** (1.5.3 + 1.5.4) | Instant local dashboards; not multi-tenant SaaS auth, not custom product UI. |
| **[dash](https://duckdb.org/community_extensions/extensions/dash.html)** | Visual explorer / dashboards / DAG pipelines; GUI queries become macros | `INSTALL dash FROM community; LOAD dash;` | `PRAGMA dash;`, `start_dash`, `stop_dash`, `query_result` | Hosts a GUI (product UI), not arbitrary routes | **yes** | Strong for analyst UX; macro sync is clever; still not an app framework. |
| **[tera](https://duckdb.org/community_extensions/extensions/tera.html)** | **Tera** templates → text/HTML from SQL | `INSTALL tera FROM community; LOAD tera;` | `tera_render(template [, json_context])` | Renders strings only; **does not serve HTTP** | **yes** | Pair with httpserver/shell only if you invent the glue. Vs Jinja/Express: no request context, flash, CSRF, etc. |
| **[quickjs](https://duckdb.org/community_extensions/extensions/quickjs.html)** | Embedded **QuickJS-NG** JS engine in SQL | `INSTALL quickjs FROM community; LOAD quickjs;` | `quickjs(...)`, `quickjs_eval(fn, …)` (scalar + table) | Logic snippets, not a web runtime | **yes** | Handy for transforms hard in SQL; **experimental**; sandbox/perf/security weaker than a real Node service. |
| **[pdf](https://duckdb.org/community_extensions/extensions/pdf.html)** | Full PDF **read / OCR / layout / redact / write / convert** in SQL (Poppler, Tesseract, qpdf, libharu) | `INSTALL pdf FROM community; LOAD pdf;` | See [PDF functions](#pdf-function-inventory) below | `pdf_to_html`, `pdf_to_png`, `write_pdf`, `pdf_redact`, … — content, not HTTP | **v1.5.4: yes**; **v1.5.3: no** (CDN 404). Page claims macOS arm64 support | Best-in-class **document plane** for a DuckDB backend. GPL-2.0-or-later. LibreOffice needed for `to_pdf`. Table extraction is geometric, not ML. |
| **[fakeit](https://duckdb.org/community_extensions/extensions/fakeit.html)** | 120+ fake data generators (names, HTTP status, UAs, cards, …) | `INSTALL fakeit FROM community; LOAD fakeit;` | `fakeit_name_full()`, `fakeit_contact_email()`, `fakeit_status_code_*`, `fakeit_uuid_v4()`, … | Dev/demo data only | **yes** | Replaces Faker.js/Python for SQL-native demos; not production identity. |
| **[webbed](https://duckdb.org/community_extensions/extensions/webbed.html)** | XML/HTML parse, XPath, table extract, `html_to_duck_blocks` / `duck_blocks_to_html` | `INSTALL webbed FROM community; LOAD webbed;` | `read_html`, `html_extract_*`, `html_to_duck_blocks`, `duck_blocks_to_html`, `xml_*` | **Produce/consume HTML** as data; no HTTP server | **yes** | Great with crawler/SSR pipelines; composition of blocks → HTML is SSR-adjacent but not a full template stack. |
| **[shellfs](https://duckdb.org/community_extensions/extensions/shellfs.html)** | Unix **pipes as filesystems** (`cmd \|` input, `\| cmd` output) | `INSTALL shellfs FROM community; LOAD shellfs;` | Path convention + `ignore_sigpipe` setting (no SQL functions) | Can shell out to `curl`, static generators, etc. | **yes** | Escape hatch for anything missing; security nightmare if untrusted SQL; vs subprocess in Python: same power, less control. |
| **[hostfs](https://duckdb.org/community_extensions/extensions/hostfs.html)** | Filesystem navigation in SQL | `INSTALL hostfs FROM community; LOAD hostfs;` | `ls`/`lsr`, `cd`/`pwd`, `file_size`, `is_dir`, `path_split`, … | Inventory static assets; not serve them | **yes** | Useful for “what files can I serve?” planning; still need a server. |
| **[http_client](https://duckdb.org/community_extensions/extensions/http_client.html)** | Outbound HTTP client | `INSTALL http_client FROM community; LOAD http_client;` | `http_get`, `http_post`, `http_post_form`, `http_head` | Client only | **yes** | Self-dispatch / call other services (incl. httpserver). Experimental. |
| **[erpl_web](https://duckdb.org/community_extensions/extensions/erpl_web.html)** | Enterprise APIs (OData, Graph, …) **plus** generic REST helpers | `INSTALL erpl_web FROM community; LOAD erpl_web;` | `http_get/post/put/patch/delete` (table), `odata_*`, Graph/SharePoint/… | Client / connector | **yes** | Heavier than `http_client`; great when you need Graph/OData. Not a server. |
| **[cronjob](https://duckdb.org/community_extensions/extensions/cronjob.html)** | In-process **cron** of SQL statements | `INSTALL cronjob FROM community; LOAD cronjob;` | `cron(query, schedule)`, `cron_jobs()`, `cron_delete(id)` | Background jobs, not HTTP | **yes** | Replaces a tiny Celery/APScheduler for SQL-only jobs; experimental; process must stay up. |
| **[crypto](https://duckdb.org/community_extensions/extensions/crypto.html)** | Hashes, HMAC, CSPRNG | `INSTALL crypto FROM community; LOAD crypto;` | `crypto_hash`, `crypto_hmac`, `crypto_hash_agg`, `crypto_random_bytes` | Building blocks for tokens/API keys | **yes** | Not full JWT library / password KDF suite (bcrypt/argon2 not listed). |
| **[redis](https://duckdb.org/community_extensions/extensions/redis.html)** | Redis client (strings, hashes, lists, scan) | `INSTALL redis FROM community; LOAD redis;` | `redis_get/set`, `redis_hget/hset`, `redis_lpush`, `redis_keys`, … + `TYPE redis` secrets | Session/cache store **if** Redis exists | **yes** (1.5.3+) | Same role as `ioredis`/`redis-py` client; no server-side session cookie wiring. Experimental. |
| **[radio](https://duckdb.org/community_extensions/extensions/radio.html)** | **WebSocket & Redis pub/sub** event buses | `INSTALL radio FROM community; LOAD radio;` | `radio_subscribe`, `radio_listen`, `radio_transmit_message`, `radio_received_messages`, … | Client/subscription model | **yes** | Realtime **as a bus client**, not “SSE endpoint on /events”. Docs: [query.farm radio](https://query.farm/duckdb_extension_radio.html). |
| **[jsonata](https://duckdb.org/community_extensions/extensions/jsonata.html)** | JSONata transforms in SQL | `INSTALL jsonata FROM community; LOAD jsonata;` | `jsonata(...)` | Response shaping | **yes** | Complements core **json** extension for complex document munging. |
| **[crawler](https://duckdb.org/community_extensions/extensions/crawler.html)** | SQL-native crawl + HTML extract + MERGE | `INSTALL crawler FROM community; LOAD crawler;` | `crawl`, `crawl_url`, `read_html`, `jq`, `htmlpath`, `sitemap` | Ingest web, not serve | **yes** | Scrapy-in-SQL vibe; robots/rate-limit settings. |
| **[netquack](https://duckdb.org/community_extensions/extensions/netquack.html)** | URL/domain/IP parse & validate | `INSTALL netquack FROM community; LOAD netquack;` | `extract_*`, `is_valid_url`, `normalize_url`, `base64_*`, … | Request URL parsing helpers | **yes** | Replaces bits of `urllib`/`new URL()`. |
| **[duckdb_mcp](https://duckdb.org/community_extensions/extensions/duckdb_mcp.html)** | MCP **client + server** over SQL | `INSTALL duckdb_mcp FROM community; LOAD duckdb_mcp;` | `mcp_server_start`, `mcp_publish_table/query/tool`, `mcp_call_tool`, … | Agent protocol server, not browser HTTP | **yes** | Excellent “DuckDB as tool host for agents”; different from REST webapps. |
| **[quack_oauth](https://duckdb.org/community_extensions/extensions/quack_oauth.html)** | OAuth2/OIDC for **DuckDB Quack** server | `INSTALL quack_oauth FROM community; LOAD quack_oauth;` | `quack_oauth_check_token`, `quack_oauth_check_authorization`, `quack_oauth_acquire`, device/login/refresh, audit tables | Authz for **Quack** attach, not httpserver routes | **yes** | Serious multi-user analytics auth — for Quack protocol (core preview), not the community httpserver. |
| **[boilstream](https://duckdb.org/community_extensions/extensions/boilstream.html)** | Remote secrets + OPAQUE login + ducklake attach | `INSTALL boilstream FROM community; LOAD boilstream;` | `boilstream_login`, `boilstream_secrets`, create ducklake, … | Secret/session for multi-tenant **data**, not web cookies | **yes** | Enterprise secrets plane; requires compatible REST API. |
| **[webmacro](https://duckdb.org/community_extensions/extensions/webmacro.html)** | Load SQL macros from URL (e.g. gist) | `INSTALL webmacro FROM community; LOAD webmacro;` | `load_macro_from_url(url)` | Remote code loading | **yes** | Dev convenience; supply-chain risk if untrusted URLs. |
| **[zim](https://duckdb.org/community_extensions/extensions/zim.html)** | Offline website archives (Kiwix ZIM) as tables + `zim://` FS | `INSTALL zim FROM community; LOAD zim;` | `read_zim`, `zim_search`, `zim_get_text`, … | Content store for offline sites | **yes** | Serve knowledge corpora from SQL; still need HTTP layer to expose HTML. GPL (libzim). |
| **[cloudfront](https://duckdb.org/community_extensions/extensions/cloudfront.html)** | CloudFront signed cookies for **httpfs** reads | `INSTALL cloudfront FROM community; LOAD cloudfront;` | `cloudfront_version` (+ httpfs integration) | Client auth for CDN objects | **yes** | Access private static origins; not cookie issuance for your app users. |
| **quackapi** | — | **Not listed** in community catalog / GitHub `extensions/` | — | — | **n/a** | If this is a local/private extension (user stack), keep it out-of-band; no signed community build. |
| **http_request** / **httpd_log** | Client / Apache log reader (pages exist) | Listed in GitHub community-extensions tree; **not** on v1.5.4 list page | See pages if published later | — | **CDN 404** all platforms v1.5.4 | Treat as **not currently installable** for v1.5.x until CI publishes binaries. Prefer `http_client` / `erpl_web` / core `httpfs`. |

### Core companions (not community, but required mental model)

| Extension | Role for webapp-from-DuckDB |
|-----------|----------------------------|
| **json** (core) | Request/response JSON parse, `json_object`, etc. |
| **httpfs** (core) | Read remote files/HTTP; secrets for headers |
| **Quack** (core preview / 2.0 track) | True client-server DuckDB protocol (multi-user analytics); pair with **quack_oauth** — different product from **httpserver** |

---

## Category notes

### 1. HTTP servers / routing

**httpserver** ([page](https://duckdb.org/community_extensions/extensions/httpserver.html), [GitHub](https://github.com/Query-farm/httpserver)) is the primary answer:

```sql
INSTALL httpserver FROM community;
LOAD httpserver;
SELECT httpserve_start('0.0.0.0', 9999, 'user:pass');  -- or API key string, or '' for open
-- SELECT httpserve_stop();
```

| Capability | Supported? |
|------------|------------|
| Named routes (`/api/users/:id`) | **No** — only `/` and `/ping` |
| Serve static files (`/assets/*`) | **No** (UI is embedded play interface) |
| Return HTML | Only the embedded play UI; query API returns **JSON** formats |
| Return JSON | **Yes** (`JSONCompact`, `JSONEachRow`) |
| Auth | Basic or `X-API-Key` shared secret |
| WebSocket / SSE | **No** |

**duckdbi** / **dash** are specialized HTTP UIs (BI), not general routers.

**Implication:** “DuckDB as web backend” with community extensions means **SQL-over-HTTP API** or **embedded BI**, not Express/FastAPI-style apps. Custom HTML products need either (a) a thin real web server in front, or (b) a private extension (e.g. local **quackapi**) that registers routes.

### 2. HTML templating / SSR

**tera** ([page](https://duckdb.org/community_extensions/extensions/tera.html)):

```sql
INSTALL tera FROM community;
LOAD tera;
SELECT tera_render('Hello {{ name }}!', '{"name": "World"}');
SELECT tera_render('Hello World!');  -- no context
```

**webbed** can rebuild HTML from structured blocks (`duck_blocks_to_html`) and escape HTML — useful for composing pages from query results.

**SSR path today:** `SELECT tera_render(...)` (or webbed blocks) → somehow emit via httpserver (today: mostly as **JSON field**, not `Content-Type: text/html` app pages unless you extend the server).

### 3. JS execution

**quickjs** ([page](https://duckdb.org/community_extensions/extensions/quickjs.html)):

```sql
INSTALL quickjs FROM community;
LOAD quickjs;
SELECT quickjs('2+2');
SELECT quickjs_eval('(a, b) => a + b', 5, 3);
SELECT * FROM quickjs('parsed_arg0.map(x => x * arg1)', '[1,2,3]', 3);
```

Use for string/JSON transforms, small business rules, array expansion. **Do not** treat as request handler framework; marked experimental.

### 4. PDF — confirmed surface

**pdf** ([page](https://duckdb.org/community_extensions/extensions/pdf.html), maintainer `asubbarao`):

```sql
INSTALL pdf FROM community;
LOAD pdf;
```

#### PDF function inventory

| Area | Functions |
|------|-----------|
| **Read** | `read_pdf`, `read_pdf_lines`, `read_pdf_meta`, `read_pdf_words`, `read_pdf_tables`, `read_pdf_elements`, `pdf_chunks` |
| **Inspect** | `pdf_info`, `pdf_outline`, `pdf_attachments`, `pdf_form_fields`, `pdf_annotations`, `pdf_revisions`, `pdf_signatures`, `pdf_images` |
| **Render / export** | `pdf_to_text`, `pdf_to_markdown`, `pdf_to_html`, `pdf_to_xml`, `pdf_to_svg`, `pdf_to_png` |
| **Write** | `write_pdf`, `COPY … TO … (FORMAT pdf)`, `to_pdf` (LibreOffice) |
| **Transform (qpdf)** | `pdf_merge`, `pdf_split`, `pdf_split_blank`, `pdf_rotate`, `pdf_pages`, `pdf_compress`, `pdf_encrypt`, `pdf_decrypt`, `pdf_watermark`, `pdf_bates` |
| **Redact / sign** | `pdf_redact` (table), `pdf_sign` (table) — listed on extension page function table |

Shared named params on readers: `first_page`, `last_page`, `password`, `layout`, OCR knobs (`ocr`, `auto_ocr`, `ocr_language`, …), `ignore_errors`.

**Platforms (from page):** Linux x86_64/arm64, macOS x86_64/arm64, Windows x64; not wasm. **License:** GPL-2.0-or-later (Poppler).

### 5. Everything else that helps “DuckDB IS the backend”

| Concern | Extension(s) | Notes |
|---------|--------------|-------|
| Sample / demo data | **fakeit** | Perfect for `generate_series` demos |
| Outbound API / self-dispatch | **http_client**, **erpl_web**, **shellfs**+curl, core **httpfs** | Classic CTE fan-out patterns |
| Cache / sessions store | **redis** | External Redis still required |
| Token crypto | **crypto** | HMAC/hash/random; assemble your own tokens |
| Realtime messaging | **radio** | WS/Redis **client** |
| Scheduled work | **cronjob** | In-process SQL cron |
| Auth for multi-user DuckDB protocol | **quack_oauth** + core Quack | Not httpserver |
| Agent-facing server | **duckdb_mcp** | MCP, not browsers |
| Offline site content | **zim** | Query packaged websites |
| URL parsing | **netquack** | Path/query validation |
| Scraping ingest | **crawler** + **webbed** | Fill tables that the API serves |
| Remote macros | **webmacro** | Ops convenience |
| Secrets multi-tenant | **boilstream** | Ducklake + OPAQUE |

**Not found in catalog:** dedicated **SSE server**, **cookie session** extension, **JWT mint/verify** as first-class product (crypto only), **static file server**, **named route registry** (except private/local tools).

---

## Suggested “maximum community” architecture (honest)

```text
Browser / curl
    │
    ▼
httpserver  ──►  SQL queries  ──►  tables / views
    │                 │
    │                 ├── tera_render / webbed  (HTML strings as columns)
    │                 ├── pdf_*                 (documents)
    │                 ├── quickjs / jsonata     (logic / reshape)
    │                 ├── redis / crypto        (state / tokens)
    │                 ├── http_client           (call others)
    │                 └── cronjob               (background SQL)
    │
    └── play UI or duckdbi/dash for humans

Optional: radio ↔ Redis/WS bus (async events)
Optional: quack + quack_oauth for multi-user analytics protocol (separate path)
```

**Vs conventional Node/Python:**

| Dimension | DuckDB extension stack | Node/Python |
|-----------|------------------------|-------------|
| Deploy | One binary + `INSTALL` | Runtime + packages + process manager |
| OLAP queries | Native, excellent | Needs a DB |
| REST resource design | Weak (raw SQL API) | First-class routers |
| AuthN/Z | Shared key / Quack OAuth | Mature middleware |
| HTML product UI | DIY or BI embeds | Native |
| Concurrency model | DuckDB MVCC / single writer reality | Async workers, multi-process |
| Production hardening | Many extensions **experimental** | Battle-tested frameworks |

**When this stack wins:** internal tools, OLAP APIs, agent tool hosts (MCP), document/PDF pipelines, SQL-first prototypes, single-box demos.

**When to stay conventional:** multi-route public webapps, OAuth cookie sessions, websockets-as-product, horizontal HTTP scale, non-SQL business logic volume.

---

## Signed builds — osx_arm64 probe results

Probed: `https://community-extensions.duckdb.org/{ver}/osx_arm64/<ext>.duckdb_extension.gz`

| Extension | v1.5.3 | v1.5.4 |
|-----------|--------|--------|
| httpserver | 404 | **200** |
| pdf | 404 | **200** |
| tera, quickjs, fakeit, shellfs, hostfs, webbed, cronjob, crypto, redis, jsonata, duckdbi, dash, duckdb_mcp, crawler, boilstream, zim, netquack, cloudfront, webmacro, radio, http_client, erpl_web, quack_oauth | **200** | **200** |
| http_request, httpd_log | 404 | 404 (all platforms) |

**Practical guidance:** Prefer DuckDB **≥ 1.5.4** for full httpserver + pdf coverage on Apple Silicon. Catalog itself documents the list as **v1.5.4**. Install still uses:

```sql
INSTALL httpserver FROM community;
```

which resolves version/platform for the running binary.

---

## Sources

- Catalog: https://duckdb.org/community_extensions/list_of_extensions.html  
- Per-extension pages under https://duckdb.org/community_extensions/extensions/<name>.html (linked in table)  
- httpserver README: https://github.com/Query-farm/httpserver  
- shellfs docs: https://github.com/query-farm/shellfs (docs/README.md)  
- Community signing model: https://duckdb.org/2024/07/05/community-extensions.html  
- CDN: `https://community-extensions.duckdb.org/`

---

*Generated as a read-only research artifact. No repository code was modified except this file.*
