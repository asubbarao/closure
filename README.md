# Closure

AI-assisted **PDF redaction review** for FOIA / public-records release.

**One process:** DuckDB + community extensions. HTTP is `CREATE ROUTE`. HTML is tera file-mode. Mutations are append-only SQL. Browser is ~300 lines of progressive enhancement (`static/app.js` → POST + reload).

## Product loop

| Step | Surface |
|------|---------|
| Library | `GET /` · `GET /cases/:id` |
| Entity stream | `GET /cases/:id/stream` — decide once, case-wide |
| Page peek | `GET /documents/:id` · `/pages/:n` — PNG + marks |
| Decide | POST suggestion / entity / band / accept-high / undo / add |
| Export | POST export (blocked while flagged pending) |
| Audit | `GET /cases/:id/audit` |

Details: [`docs/HOW_IT_WORKS.md`](docs/HOW_IT_WORKS.md) · data layers: [`docs/DATA_MODEL.md`](docs/DATA_MODEL.md) · design mocks: [`design/`](design/) · assignment write-up: [`docs/rationale.md`](docs/rationale.md).

## Stack

| Concern | How |
|---------|-----|
| Process | DuckDB ≥ **1.5.4** + `INSTALL … FROM community` |
| HTTP | **quackapi** — routes, OpenAPI `/docs`, optional API key |
| PDF | **pdf** — words, pages, `pdf_redact` |
| HTML | **tera** → **webbed** `parse_html` (`HTML` type) |
| Paths | **hostfs** → **scalarfs** pins (`pathvariable:`) |
| Config | **json** / **yaml** by file type; semantic model YAML |
| Metrics | **semantic_views** (`server/config/closure_semantic.yaml`) |
| Client | `static/app.js` only (no SPA) |

**Not product:** Airflow-style orchestrators (e.g. [duck-orch](https://github.com/nkwork9999/duck-orch) — asset/DAG tooling for warehouses, not interactive FOIA review). **Not product:** `events` hooks to external processes.

## Quick start

```sh
# DuckDB ≥ 1.5.4 on PATH (or DUCKDB_BIN=…)
make install   # probe INSTALL quackapi FROM community
make setup     # samples + page PNGs (pdf extension, no host poppler)
make run       # → http://127.0.0.1:8117/
```

Optional: `CLOSURE_API_KEY=…` (register quackapi API key), `CLOSURE_POSTGRES=…` (ATTACH peer Postgres), `CLOSURE_SAMPLE_ZIP=…` (zip case pack).

## Tests

```sh
make test      # fresh DB + boot + Playwright (thin SSR suite)
# or boot yourself, then:
cd tests/e2e && CLOSURE_BASE_URL=http://127.0.0.1:8117 npx playwright test
```

SQL smoke (after a boot that left `closure.db`):

```sh
make smoke
```

## Layout

```
server/          SQL app (config → extensions → model → routes → serve)
  templates/     tera pages (base, case, stream, review, audit)
static/app.js    progressive enhancement only
samples/         corpus inputs (generated/fetched — see .gitignore)
pages/           PNG previews (setup output)
tests/e2e/       Playwright for this stack
docs/            canon docs only; older notes under docs/archive/
design/          high-fidelity mocks (assignment)
```

## License

See `LICENSE`.
