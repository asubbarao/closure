# quackapi — the backend IS the database

**Sketch / positioning. Groks flesh this out into the quackapi README, a
`description.yml`, and a community-extensions page.**

## The thesis: collapse the backend into the database

A conventional web backend is *several* processes with serialization at every
hop:

```
browser → app server (routes, handlers, ORM) → PDF microservice
                     ↘ scraper/worker           ↘ database
```

Each arrow is a network boundary and a (de)serialization cost. quackapi collapses
the whole thing into **one DuckDB process**:

```
browser → DuckDB [ quackapi(HTTP) · pdf · tera · fakeit · webbed/crawler ]
```

The database, the HTTP server, the PDF engine, the HTML renderer, the data
generator, and the web/crawl layer are all **community extensions loaded into
the same address space**. A request handler is a SQL query that reads tables and
calls `pdf_redact()` / `read_pdf_words()` / `tera_render()` directly — no RPC, no
serialization between tiers, no services to deploy or keep in sync.

> Because DB and backend are the same process, "call the PDF service" is just a
> function call, and "ingest a web document" is just `SELECT html_to_json(...)`.

## CREATE ROUTE — FastAPI, expressed as SQL DDL

A route is a row in a registry, declared with DDL:

```sql
CREATE ROUTE get_doc GET '/api/documents/:id' AS
SELECT * FROM v_suggestions WHERE document_id = $id;

CREATE ROUTE dashboard GET '/cases/:id' AS
SELECT tera_render(template, ctx) AS html FROM ...;   -- column named `html` → text/html

CREATE ROUTE decide POST '/api/suggestions/:id/decision' AS
INSERT INTO decisions BY NAME SELECT $id AS suggestion_id, $status AS status RETURNING *;
```

- **Typed params** (`:id` path, `$q` query/body) bind and validate — a bad type
  returns a FastAPI-shaped 422. No controller boilerplate, no serializer classes.
- **The query IS the endpoint.** JSON by default; HTML when the output column is
  `html`; static files via `static_dir`. The result set serializes itself.
- Handlers run in the same process as the data, so an endpoint that redacts a PDF
  is literally `SELECT pdf_redact(src, out, boxes)`.

## Why it's more than a party trick

- **One process**: one thing to deploy, reason about, and observe; one memory
  space; no cross-service drift.
- **Scale**: DuckDB is columnar, streaming, and spills to disk — it holds a 1GB /
  thousands-of-page PDF under a tight memory budget where a naive in-memory Node
  service OOMs. (See `docs/pdf-stress.md`, `docs/scaling-and-limits.md`.)
- **Proof by existence**: this redaction-review app — DB + API + PDF read/render/
  redact + server-side HTML + fake-data generation + append-only audit — runs as
  a *single* DuckDB process, zero external services.

## Honest limits (say them plainly)

- Write concurrency / OLTP: single-writer semantics — fine for a few reviewers,
  not a high-write multi-tenant system.
- quackapi is currently an unsigned local build (community submission pending).
- Historic memory cap in the serve loop — addressed; documented in the OOM notes.

## Prior art to cite

PostgREST / Supabase (SQL → REST), Datasette (SQL → HTTP), Hasura, Oracle APEX —
apps living *in* the database. The novel part here: one **embedded OLAP** process
as DB + HTTP framework + PDF engine + renderer, driven by `CREATE ROUTE` DDL.
