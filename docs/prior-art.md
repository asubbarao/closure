# Prior art: “backend collapsed into an embedded OLAP process”

**Date:** 2026-07-19  
**Claim under review (do not assume true):**

> Collapsing the entire web backend into a single **embedded OLAP** database process — where the HTTP server, PDF engine, HTML template renderer, and data generation all run as **in-process loadable database extensions**, and HTTP routes are declared as **SQL DDL (`CREATE ROUTE`)** — is novel; there is no prior art for this exact instantiation.

**Project under study:** Closure / quackapi — browser → one DuckDB process loading `quackapi` (HTTP + `CREATE ROUTE`), `pdf`, `tera` (and related extensions); handlers are SQL; `pdf_redact` / `tera_render` are in-process function calls.

**Method:** Web survey of historical “app in the DB,” modern “DB as API,” DuckDB/SQLite server patterns, and closest structural analogues. Skeptical posture: if the claim is weaker than “no prior art,” say so.

**Verdict in one line:** The *idea* of serving the web from inside a database is decades old and well documented; the *exact composition* (embedded columnar OLAP + multi-route FastAPI-shaped SQL-DDL app framework + PDF + HTML templating as co-loaded extensions) appears **without a matching public product** — but claiming unqualified novelty for “DB is the backend” is **false and puncturable**.

---

## 1. Comparison axes (what the claim actually asserts)

| Axis | This project’s instantiation |
|------|------------------------------|
| Process model | **Single process**: HTTP listener lives *inside* the DB process (extension thread / serve loop) |
| Engine class | **Embedded OLAP** (DuckDB), not heavyweight multi-process OLTP |
| Route declaration | **SQL DDL** (`CREATE ROUTE … METHOD path AS <select>`) with typed params; query *is* the handler |
| Companion capabilities | PDF, HTML templates, fake data, etc. as **loadable extensions in the same address space** |
| Handler style | Set-oriented SQL (plus extension UDFs), not a separate imperative language runtime as the primary app tier |

Prior art is evaluated against these axes, not against vague “SQL on the web.”

---

## 2. App-in-the-database precedents

### 2.1 Oracle: PL/SQL Web Toolkit, mod_plsql, Embedded PL/SQL Gateway, APEX

**What it does**

- **PL/SQL Web Toolkit** (`HTP`/`HTF` packages): stored procedures generate HTML (and other content) by writing to a buffer that a gateway returns as an HTTP response. Documented for decades as “web applications from PL/SQL.”  
  - Docs: [Developing PL/SQL Web Applications](https://docs.oracle.com/en/database/oracle/oracle-database/26/adfns/web-applications.html)  
  - Tutorial-era overview: [PL/SQL Web Toolkit (oracle-base)](https://oracle-base.com/articles/9i/plsql-web-toolkit-9i)

- **mod_plsql**: Apache/Oracle HTTP Server module (process **outside** the DB) maps URLs to PL/SQL procedures via Database Access Descriptors (DADs). Classic three-tier: browser → Apache → DB.

- **Embedded PL/SQL Gateway (EPG)** / Oracle XML DB HTTP Listener: an **HTTP listener that runs inside the Oracle database process**, providing the core features of mod_plsql without a separate Apache. Configured via `DBMS_EPG`. Explicit security note: the listener **cannot be separated** from the database.  
  - [Configuring the Embedded PL/SQL Gateway](https://docs.oracle.com/database/apex-18.1/HTMIG/configuring-embedded-PL-SQL-gateway.htm)  
  - [Choosing a Web Listener (APEX)](https://docs.oracle.com/en/database/oracle/application-express/20.1/htmig/choosing-web-listener.html)  
  - [DBMS_EPG package](https://docs.oracle.com/en/database/oracle/oracle-database/21/arpls/DBMS_EPG.html)

- **Oracle APEX**: full low-code web app platform whose application metadata and PL/SQL live *in* the database. Historically fronted by mod_plsql, EPG, or (today) **ORDS**. Beginning APEX 20.2, **only ORDS** is supported as web listener; EPG and mod_plsql are deprecated. ORDS is a **separate** Java process (standalone Jetty, Tomcat, or WebLogic), not “DB = HTTP process.”  
  - [ORDS — only supported web listener for APEX](https://blogs.oracle.com/apex/oracle-rest-data-services-the-only-supported-web-listener-for-oracle-apex)

**How it differs from this project**

| Axis | Oracle (EPG + PL/SQL / APEX) | Closure / quackapi |
|------|------------------------------|--------------------|
| Process | EPG: **in-DB HTTP** (strong precedent). APEX production: **ORDS separate process** | Always single embedded process |
| Engine | Heavyweight multi-process **OLTP** server (Oracle Database) | **Embedded OLAP** (DuckDB) |
| Handlers | Imperative **PL/SQL** packages (`HTP.p`, etc.), not pure SQL SELECT-as-endpoint | SQL query **is** the route body |
| Route DDL | DADs / path mappings / APEX metadata — **not** `CREATE ROUTE … AS SELECT` | First-class route DDL |
| PDF / render / gen | Not a single loadable-extension mesh of PDF+template+HTTP; document tooling is external or PL/SQL-adjacent | `pdf`, `tera`, etc. as **same-process extensions** |

**Prior-art weight:** **High** for “HTTP server inside the database process” and “application logic lives in the database.” **Low** for embedded OLAP, SQL-DDL FastAPI-style routes, and co-loaded PDF/template engines.

---

### 2.2 Microsoft SQL Server: Native XML Web Services / `CREATE ENDPOINT … AS HTTP`

**What it does**

SQL Server 2005–2008 (and remnants into later versions until fully deprecated) allowed **SQL DDL to declare HTTP endpoints** that exposed stored procedures as **SOAP web methods**, using Windows HTTP.sys integration:

```sql
CREATE ENDPOINT Employees_Select_EndPoint
STATE = STARTED
AS HTTP (
  PATH = '/SQL/Employees_Select',
  AUTHENTICATION = (INTEGRATED),
  PORTS = (CLEAR)
)
FOR SOAP (
  WEBMETHOD 'Employees_Select' (
    NAME = 'Northwind.dbo.Employees_Select',
    SCHEMA = STANDARD
  ),
  WSDL = DEFAULT,
  DATABASE = 'Northwind'
);
```

- Walkthrough: [Creating Native Web Services in SQL Server (CodeGuru)](https://www.codeguru.com/csharp/creating-native-web-services-in-sql-server/)  
- Official deprecation: Native XML Web Services / `CREATE ENDPOINT … FOR SOAP` is deprecated; Microsoft directs users to WCF or ASP.NET ([Deprecated Features object](https://learn.microsoft.com/en-us/sql/relational-databases/performance-monitor/sql-server-deprecated-features-object)).

**How it differs**

| Axis | SQL Server Native XML Web Services | Closure / quackapi |
|------|------------------------------------|--------------------|
| Process | HTTP endpoint **hosted by the SQL Server service** (in-server, not a separate Node app) | Same idea: listener in DB process |
| Engine | Heavyweight **OLTP** server product | Embedded **OLAP** |
| Route shape | `CREATE ENDPOINT` + SOAP **WEBMETHOD** → stored procedure | `CREATE ROUTE` + REST methods + path params → **SQL SELECT/INSERT body** |
| Payload | SOAP/XML, WSDL | JSON / HTML (`html` column) / static files |
| PDF / templates | Not part of the endpoint story; app logic in T-SQL/CLR | PDF + Tera in-process |

**Prior-art weight:** **Highest structural precedent for “HTTP routes declared as SQL DDL inside the database engine.”** Anyone claiming “no one has ever declared HTTP endpoints in SQL DDL” is wrong. Differences remain in REST vs SOAP, handler as pure SQL result-set vs procedure, engine class, and document/SSR co-extensions.

*(Note: SQL Server’s separate `CREATE ROUTE` is for **Service Broker** messaging, not HTTP — do not confuse the two.)*

---

### 2.3 PostgreSQL: clients, wiki ideas, separate API layers

**What exists**

- **HTTP client from inside PG**, not a server: [pgsql-http](https://github.com/pramsey/pgsql-http) (`http_get` etc. from SQL). PL/Python HTTP clients are common (outbound only).
- **PostgreSQL wiki “HTTP API”** (2014-era discussion): explores making Postgres listen on HTTP / become an application platform; notes many ideas later realized by **PostgREST** (separate process), and mentions efforts like **PgArachne** (JSON-RPC + SSE over a lightweight web server in front of PG).  
  - [wiki.postgresql.org/wiki/HTTP_API](https://wiki.postgresql.org/wiki/HTTP_API)
- Community experiments with HTTP servers in background workers appear on forums/Reddit; none became a mainstream “CREATE ROUTE + full app stack” product comparable to this claim.

**How it differs**

Postgres has rich **in-process extension** culture, but production “web app from Postgres” almost always means **PostgREST / Hasura / custom app** as a **sibling process**, with handlers as views/functions exposed by that process—not `CREATE ROUTE` DDL as the primary framework, and not embedded OLAP + PDF in one binary.

**Prior-art weight:** Conceptual interest and **outbound** HTTP; **weak** for in-process multi-route app framework.

---

## 3. DB-as-API *in front of* the database

These systems map tables/views/functions to HTTP. They are the modern mainstream of “SQL-shaped backends.” **None** put the HTTP server *inside* the database process as a loadable extension mesh.

| System | What it does | Process model | Routes | Differs from claim |
|--------|--------------|---------------|--------|--------------------|
| **[PostgREST](https://docs.postgrest.org/)** | Standalone server → automatic REST from Postgres schema, RLS, RPC for functions | **Separate** Haskell process; DB via libpq | Schema-derived URL space, not `CREATE ROUTE` DDL | Separate process; OLTP Postgres; no in-engine PDF/SSR; not embedded OLAP |
| **[Supabase](https://supabase.com/docs/guides/getting-started/architecture)** | BaaS: PostgREST + GoTrue + Realtime + Storage + Kong | **Multi-service** platform; Postgres is core, not the HTTP binary | PostgREST + extra services | Many processes; not one embedded OLAP |
| **[Hasura](https://hasura.io/graphql/database/postgresql)** | GraphQL engine compiles GraphQL → SQL | **Separate** engine process | GraphQL schema from DB + metadata | Separate process; GraphQL not SQL-DDL routes; not PDF-in-DB |
| **[Datasette](https://datasette.io/)** | Explore/publish SQLite as website + JSON API; plugins; ASGI | **Python process** hosting SQLite (embedded *library*, separate *app process*) | Framework routes + plugins; not SQL DDL | Closest “SQLite + web” culture; still **Python ASGI**, not DB extension HTTP; no CREATE ROUTE; PDF not core |
| **[pREST](https://github.com/prest/prest)** | Go REST server over Postgres (PostgREST-like) | Separate process | Config/schema-driven | Same class as PostgREST |
| **[Soul](https://github.com/thevahidal/soul)** | Node REST + realtime over a SQLite **file** | Separate Node process | Auto CRUD | SQLite file + Node, not extensions-in-engine |
| **sqlite-rest** variants | PostgREST-for-SQLite | Separate binary | Auto CRUD | Same separation |

**Prior-art weight for the claim’s process model:** **None of these match.**  
**Prior-art weight for “SQL is the API surface”:** **Very high** — must be cited as lineage for “query/handler is SQL,” not as same architecture.

---

## 4. DuckDB-specific landscape

### 4.1 Community `httpserver` (Query.Farm) — closest DuckDB peer

- Catalog: [httpserver community extension](https://duckdb.org/community_extensions/extensions/httpserver.html)  
- Source: [github.com/Query-farm/httpserver](https://github.com/Query-farm/httpserver)

**What it does:** Loadable extension that starts an **HTTP thread inside the DuckDB process** (`httpserve_start(host, port, auth)`). Clients POST SQL to `/` and receive JSON (ClickHouse-flavored formats). Includes an embedded “play” SQL UI. Auth: Basic or shared `X-API-Key`.

**How it differs from quackapi / Closure**

| Capability | `httpserver` | quackapi / Closure |
|------------|--------------|--------------------|
| In-process HTTP on DuckDB | **Yes** | **Yes** |
| Named app routes (`/api/docs/:id`) | **No** — essentially `/` + `/ping` | **Yes** — `CREATE ROUTE` |
| Handler model | Arbitrary SQL in request body (query API) | Declared SQL per route (app framework) |
| HTML SSR / static tree | Play UI only; not multi-page app SSR | `tera_render` + `html` column + `static_dir` |
| PDF / document pipeline | Orthogonal; not part of httpserver | Core product path via `pdf` extension |

**Prior-art weight:** **Destroys** any claim that “no one has put an HTTP server inside DuckDB.” **Does not** implement CREATE ROUTE app framework or PDF/HTML product stack.

### 4.2 Other DuckDB pieces (composable, not a product)

From the community catalog (see also project doc `docs/duckdb-webapp-extensions.md`):

| Extension | Role | Relation to claim |
|-----------|------|-------------------|
| **tera** / **minijinja** | HTML/text templating **from SQL** | Same-class *capability*; does not serve HTTP alone |
| **pdf** | Read/OCR/render/redact/write PDFs in SQL | Same-class *capability*; not a web framework |
| **fakeit** | Synthetic data generators | Data-gen piece of the claim |
| **duckdbi** / **dash** | In-process **BI UI** servers | In-process HTTP + fixed product UI; not general CREATE ROUTE apps |
| **http_client** / **httpfs** | Outbound HTTP / remote files | Opposite direction of serving |
| **duckdb_mcp** | MCP tool host | Agent protocol, not browser app routes |

**Point:** The *building blocks* for “HTTP + template + PDF in DuckDB” are publicly cataloged as **separate extensions**. The claim’s novelty, if any, is **binding them into one app framework with SQL-DDL routes** (quackapi), not inventing each subsystem.

### 4.3 DuckDB-Wasm, Evidence, MotherDuck UI

- [DuckDB-Wasm](https://duckdb.org/2021/10/29/duckdb-wasm.html): OLAP **in the browser**, not a server backend.  
- **Evidence.dev**, lakeFS UI, MotherDuck UI: apps that *embed* DuckDB-Wasm or connect to DuckDB/MotherDuck from a **normal JS/Node web stack**.

**Differs:** Client-side or multi-process analytics UIs — not “server = single DuckDB process with CREATE ROUTE.”

### 4.4 ClickHouse HTTP interface (related OLAP precedent)

[ClickHouse HTTP interface](https://clickhouse.com/docs/interfaces/http) is a first-class **query-over-HTTP** surface built into `clickhouse-server` (ports 8123/8443). Query.Farm’s DuckDB `httpserver` even markets loose ClickHouse HTTP API compatibility.

**Differs:** Distributed/server OLAP product with a **query API**, not embedded single-file OLAP, not multi-route HTML app framework, not SQL-DDL routes + PDF SSR stack.

---

## 5. SQLite-as-server and “database as application server” writings

| Analogue | What it is | Differs |
|----------|------------|---------|
| **Datasette** (+ Datasette Lite / Wasm) | Publish SQLite as site+API; “baked data” pattern | Python/ASGI or browser Wasm; routes not SQL DDL |
| **Soul / sqlite-rest** | Auto CRUD over SQLite file | Separate app process |
| **SQLite embedded in PHP/Node apps** | Classic LAMP-ish embedding | App process owns HTTP; SQLite is a library |
| **H2 / Derby / Firebird** web consoles | Embedded DB + admin UI | Fixed admin UI, not CREATE ROUTE product apps |
| **Oracle EPG / APEX** | True “DB as application server” literature | Covered in §2.1 |

There is a long informal literature of “put the app in the database” (Oracle evangelism, PostgREST essays, Datasette’s baked-data posts). That literature **precedes and frames** this project; it does not describe this exact DuckDB extension composition.

---

## 6. Closest analogues ranked

| Rank | System | Shared with claim | Critical gap |
|------|--------|-------------------|--------------|
| 1 | **SQL Server `CREATE ENDPOINT … AS HTTP`** | HTTP endpoints as **SQL DDL** inside the DB engine | SOAP/stored-proc; heavyweight OLTP; no PDF/tera extension mesh; deprecated |
| 2 | **Oracle Embedded PL/SQL Gateway + PL/SQL Web Toolkit / APEX** | HTTP **in the database process**; full apps living in DB | PL/SQL imperative HTML; Oracle OLTP; not SQL-SELECT-as-route; PDF not co-engine |
| 3 | **DuckDB `httpserver` (Query.Farm)** | **In-process** HTTP on **embedded OLAP** | Query API only; no CREATE ROUTE multi-route app; no product SSR/PDF stack |
| 4 | **ClickHouse HTTP** | OLAP engine exposes HTTP natively | Server product + query API; not embedded app framework |
| 5 | **PostgREST / Hasura / Datasette / Soul** | SQL-shaped API / data website | **Separate process** (or Python hosting SQLite); schema-auto routes ≠ CREATE ROUTE DDL + in-engine PDF |

No surveyed system matches **all** of: embedded OLAP + in-process HTTP **app framework** + SQL-DDL named routes + PDF + HTML templating co-loaded as extensions.

---

## 7. Conclusion: what is precedented vs what is not

### 7.1 Precedented (cite honestly — overclaiming here is puncturable)

1. **HTTP server inside a database process** — Oracle Embedded PL/SQL Gateway / XML DB HTTP Listener ([docs](https://docs.oracle.com/database/apex-18.1/HTMIG/configuring-embedded-PL-SQL-gateway.htm)); SQL Server native HTTP endpoints; DuckDB community `httpserver` ([catalog](https://duckdb.org/community_extensions/extensions/httpserver.html)).
2. **Declaring network endpoints with SQL DDL** — SQL Server `CREATE ENDPOINT … AS HTTP … FOR SOAP` ([CodeGuru walkthrough](https://www.codeguru.com/csharp/creating-native-web-services-in-sql-server/); [deprecation](https://learn.microsoft.com/en-us/sql/relational-databases/performance-monitor/sql-server-deprecated-features-object)).
3. **Application logic and UI generation living in the database** — Oracle APEX + PL/SQL Web Toolkit ([PL/SQL web apps](https://docs.oracle.com/en/database/oracle/oracle-database/26/adfns/web-applications.html)).
4. **SQL as the public API surface without a hand-written controller layer** — PostgREST, Hasura, Supabase, Datasette, pREST, Soul (all **out-of-process** relative to the DB server binary, except SQLite-as-library cases).
5. **In-process DuckDB HTTP and SQL-side HTML/PDF** as *separate* community capabilities — `httpserver`, `tera`/`minijinja`, `pdf`, `duckdbi`/`dash` ([community list](https://duckdb.org/community_extensions/list_of_extensions.html)).

### 7.2 Without matching public prior art (narrow claim only)

What does **not** appear as a single prior product or papered architecture:

- A **general multi-route HTTP application framework** expressed as **`CREATE ROUTE` SQL DDL** (REST methods, path/query/body param binding, result-set → JSON/HTML) where the host is an **embedded OLAP** engine; **and**
- Where **document processing (PDF)** and **HTML templating** are **loadable extensions in the same process**, so a route handler can `SELECT pdf_redact(...)` / `tera_render(...)` without an RPC hop; **and**
- Deployed as the **entire** product backend (not a query console, not a BI shell, not auto-CRUD only).

That **conjunction** is the only defensible novelty boundary. Individual conjuncts are all precedented.

### 7.3 Skeptical assessment of the original claim

| Phrase in the claim | Assessment |
|---------------------|------------|
| “Collapsing the entire web backend into a single … database process” | **Not novel as an idea** — Oracle EPG/APEX and SQL Server native web services did this class of collapse. |
| “embedded OLAP” + “loadable database extensions” | **Stronger** — modern DuckDB extension ecosystem is a different substrate than Oracle/SQL Server; Query.Farm `httpserver` already shows in-process HTTP on DuckDB. |
| “HTTP, PDF, HTML template, data generation all … extensions” | **Composition claim** — pieces exist separately; full product composition is rare/unmatched in survey. |
| “HTTP routes … SQL DDL (`CREATE ROUTE`)” | **Closest hit is SQL Server `CREATE ENDPOINT`** (SOAP). REST FastAPI-shaped `CREATE ROUTE` on embedded OLAP appears unmatched. |
| “no prior art for this **exact** instantiation” | **Technically defensible if “exact” is the full conjunction** — **false** if read as “no prior art for serving apps from a DB process” or “no SQL-declared HTTP endpoints.” |

**Plain English:** The project is a **recomposition** of old “database as application server” ideas onto **DuckDB’s extension model**, with a **modern REST/SQL-DDL route framework** and **document-centric** co-extensions. It is **not** a green-field invention of in-DB web serving. It **is** plausibly first-of-kind as a **published full-stack pattern** on embedded OLAP with that specific extension set and `CREATE ROUTE` semantics — a claim that survives scrutiny only when worded that carefully.

---

## 8. Defensible rationale sentences (copy-ready)

Use these (or close variants). They cite lineage and bound novelty so reviewers cannot sink the thesis with “Oracle already did that.”

1. **Honest lineage:** “Serving applications from inside a database process is established practice—Oracle’s embedded PL/SQL gateway and PL/SQL Web Toolkit/APEX, and SQL Server’s deprecated `CREATE ENDPOINT … AS HTTP` SOAP endpoints, all put HTTP and application logic in the database tier ([Oracle EPG](https://docs.oracle.com/database/apex-18.1/HTMIG/configuring-embedded-PL-SQL-gateway.htm); [SQL Server native web services](https://www.codeguru.com/csharp/creating-native-web-services-in-sql-server/))—while PostgREST, Hasura, Supabase, and Datasette popularized SQL-shaped APIs as **separate** processes in front of the store ([PostgREST architecture](https://docs.postgrest.org/en/latest/explanations/architecture.html); [Supabase architecture](https://supabase.com/docs/guides/getting-started/architecture)).”

2. **What this instantiation actually is:** “This project’s instantiation is different in substrate and surface: an **embedded OLAP** engine (DuckDB) loads the HTTP server, route registry, PDF engine, and HTML templating as **in-process extensions**, and declares REST handlers with **`CREATE ROUTE` SQL DDL** whose bodies are ordinary SQL—rather than PL/SQL HTML packages, SOAP webmethods, or an out-of-process API generator.”

3. **Bounded novelty (non-puncturable):** “On public evidence, no prior system combines that full stack: Query.Farm’s DuckDB [`httpserver`](https://duckdb.org/community_extensions/extensions/httpserver.html) already serves SQL-over-HTTP **in-process** but only as a query API (not multi-route app DDL + SSR/PDF), and SQL-side `tera`/`pdf` extensions exist separately ([community extensions](https://duckdb.org/community_extensions/list_of_extensions.html)); the novel claim is limited to this **composition**—embedded OLAP as the sole backend process with SQL-DDL routes and co-located document/render extensions—not to the general idea of a database-hosted web tier.”

---

## 9. Source index (primary links)

| Topic | URL |
|-------|-----|
| Oracle PL/SQL web applications | https://docs.oracle.com/en/database/oracle/oracle-database/26/adfns/web-applications.html |
| Oracle Embedded PL/SQL Gateway | https://docs.oracle.com/database/apex-18.1/HTMIG/configuring-embedded-PL-SQL-gateway.htm |
| Oracle DBMS_EPG | https://docs.oracle.com/en/database/oracle/oracle-database/21/arpls/DBMS_EPG.html |
| APEX listener deprecation → ORDS | https://blogs.oracle.com/apex/oracle-rest-data-services-the-only-supported-web-listener-for-oracle-apex |
| SQL Server native web services example | https://www.codeguru.com/csharp/creating-native-web-services-in-sql-server/ |
| SQL Server SOAP endpoint deprecation | https://learn.microsoft.com/en-us/sql/relational-databases/performance-monitor/sql-server-deprecated-features-object |
| PostgreSQL HTTP API wiki | https://wiki.postgresql.org/wiki/HTTP_API |
| pgsql-http (client) | https://github.com/pramsey/pgsql-http |
| PostgREST | https://docs.postgrest.org/ |
| Supabase architecture | https://supabase.com/docs/guides/getting-started/architecture |
| Hasura on PostgreSQL | https://hasura.io/graphql/database/postgresql |
| Datasette | https://datasette.io/ / https://github.com/simonw/datasette |
| Soul (SQLite REST) | https://github.com/thevahidal/soul |
| DuckDB httpserver | https://duckdb.org/community_extensions/extensions/httpserver.html |
| Query.Farm httpserver repo | https://github.com/Query-farm/httpserver |
| DuckDB community extensions list | https://duckdb.org/community_extensions/list_of_extensions.html |
| DuckDB-Wasm | https://duckdb.org/2021/10/29/duckdb-wasm.html |
| ClickHouse HTTP interface | https://clickhouse.com/docs/interfaces/http |

---

## 10. Recommended citation policy for author docs

- **Do** say: “We collapse the demo backend into one DuckDB process; this continues a long line of database-hosted application servers (Oracle EPG/APEX, SQL Server native endpoints) and SQL-as-API tools (PostgREST, Datasette), specialized here to embedded OLAP + extension-loaded PDF/HTML + `CREATE ROUTE`.”
- **Do not** say: “No one has ever put a web server in a database” or “SQL-declared HTTP endpoints are unprecedented.”
- **Do** say, if claiming novelty: “We are not aware of a prior **embedded OLAP** system that implements a multi-route REST framework as SQL DDL and co-hosts PDF generation and HTML templating as in-process extensions for a full product UI.”
- **Qualify** “not aware of” rather than absolute “no prior art exists” — absolute negatives are hard to prove; the survey is thorough but finite.

---

*End of prior-art note. Research date: 2026-07-19. Skeptical summary: less novel as a category than the raw claim suggests; still plausibly unique as a DuckDB extension composition with `CREATE ROUTE` app semantics.*
