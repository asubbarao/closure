# Closure as quackapi exemplar

Not a product roadmap. **What the next project should copy** — and what to push upstream.

## Copy this shape

```text
path pins (scalarfs / hostfs)
  → reader tables (pdf_words, pdf_lines)     -- cost pins only
  → few detect pins + unmat product views
  → CREATE ROUTE AS SELECT * FROM v_…
  → tera_render views for HTML
  → append-only decisions
quackapi_serve
```

| Do | Don’t |
|----|--------|
| Unmat sources over files | Agent `.tmp` dumps of relational grain |
| Extension grain (`read_pdf_*`) | DIY cluster/string_agg lines from words |
| GET = thin `SELECT *` | Fat DTO packs / KPI boards |
| Tables for Poppler + durable truth | 29 intermediate detect tables |
| Friction → extension issue | Permanent app workaround |

## LOC target (core)

| Bucket | Today ~LOC | Target |
|--------|------------|--------|
| unmat sources | 32 | keep ~25 |
| pdf/cases/pages pins | 63 | ~30 (collapse geom into docs/pages) |
| words + watchlist | 69 | ~40 |
| **detect scorer stack** | **189** | **~0–20** as named tables; rest CTE or drop theater |
| suggestions/entities | 90 | ~40 |
| judge + manual | 75 | optional / separate file |
| product views | 39 | keep ~30 |
| **core total** | **564** | **~70–90** (+ judge optional) |

Detect theater to delete or fold: bloom prefilter tables, full scorer unpivot stacks if only max score ships, multi-hop name_* tables that only feed one consumer.

## Closure → quackapi (gap mining)

Build friction is a **quackapi ticket**, not “use FastAPI.”

| Observed in Closure | Class | Action |
|---------------------|-------|--------|
| GET routes as `SELECT *` + live OpenAPI | **win** | document as exemplar |
| POST decision clones (N similar inserts) | gap / pattern | route macros? shared insert view? or keep thin SQL |
| Auth optional for local review | OK | product choice |
| Static + tera in one process | **win** | keep |
| Long boot = model build in-process | ops | optional build DB then serve attach — quackapi doc |
| Need durable QueryLog off for hot path | already known | bench discipline |

**Do not invent:** WebSockets/OIDC/HTTP2 as Closure gaps — community stack first (`radio`, `quack_oauth`, `curl_httpfs`). See `quackapi/docs/SUPERIORITY_ORDER.md`.

## Closure → pdf extension (upstream)

| App pain | Extension move |
|----------|----------------|
| Dual open words+lines on same pack | single multi-grain reader or shared document handle (perf) |
| Page geom from max bbox | optional page size from `pdf_info` / media box on words path |
| Raster previews via shell pdftoppm | prefer `pdf_write_page_images` / `pdf_page_images` (shipped) — app should not shell |
| Word↔line association for marks | optional `line` on `read_pdf_words` or lateral join helper |
| True content-stream redact | ROADMAP — forensics-grade |

App stays thin; **pdf** grows the grain.

## Lookdown next

Same skeleton: quackapi routes = product tables/views; hatch only for Roboflow; no second ASGI product server. Point at this repo’s `server/{routes,views,store,extensions}.sql` layout after densify.
