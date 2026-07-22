# Closure e2e (Playwright)

Thin SSR stack: tera pages + `static/app.js` (POST + reload).

Asserts **product state** (nav, suggestion fold via `/api/catalog/v_suggestions/rows`, bulk counts, keyboard) — not “page returned 200”.

## Specs

| Spec | Covers |
|------|--------|
| `01-smoke-nav` | Library, stream, review, audit, nav API |
| `02-foia-loop` | Decide → undo → entity reject → export gate (serial) |
| `03-bulk-multidoc-keyboard` | Multi-doc, accept-HIGH, band, entity, flagged refuse, keyboard, export |

## Paths (must match `server/routes.sql`)

| Use | Path |
|-----|------|
| Catalog rows | `GET /api/catalog/:relation/rows` |
| Decide | `POST /api/suggestions/:id/decision` |
| Entity bulk | `POST /api/entities/:id/decision` |
| Band bulk | `POST /api/documents/:id/bands/:band/decision` |
| Accept high | `POST /api/cases/:id/accept-high` |
| Undo | `POST /api/cases/:id/undo` |
| Export | `POST /api/cases/:id/export` |

Helpers: `tests/e2e/helpers/app.ts` (`api.*`).

## Run

```sh
# DuckDB ≥ 1.5.4
export DUCKDB_BIN=/opt/homebrew/bin/duckdb

make test    # fresh DB + boot + all specs

# or manual:
make run
cd tests/e2e && npm i && npx playwright install chromium
CLOSURE_BASE_URL=http://127.0.0.1:8117 npx playwright test
```

## Rules

1. **One worker** — shared DB.  
2. **Serial** mutation specs.  
3. **Count deltas** for bulk — not “button exists”.  
4. **Real controls** — `data-action`, document links.  
5. **No SPA helpers**.
