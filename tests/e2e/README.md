# Closure e2e (Playwright)

Tests for the **thin SSR stack** (tera pages + `static/app.js` POST+reload).

Not the old SPA suite. Specs assert **product state** (nav graph, suggestion
fold via `/api/rel/v_suggestions`, UI after reload) — not “page returned 200”.

## Surface under test

| Area | Spec |
|------|------|
| Library / stream / audit / review / nav API | `specs/01-smoke-nav.spec.ts` |
| Decide → undo → entity reject → export gate | `specs/02-foia-loop.spec.ts` (serial) |

## Boot

From repo root (DuckDB ≥ 1.5.4 with community quackapi):

```sh
# optional: pin built quackapi binary
# export DUCKDB_BIN=/path/to/duckdb

rm -f closure.db closure.db.wal
make run   # or PORT=8117 ./run.sh
```

Wait for home:

```sh
until curl -sf -o /dev/null http://127.0.0.1:8117/; do sleep 1; done
```

## Run

```sh
cd tests/e2e
npm install
npx playwright install chromium
CLOSURE_BASE_URL=http://127.0.0.1:8117 npx playwright test
```

Or from root (fresh DB + boot + test):

```sh
make test
```

## Design rules

1. **One worker** — mutations share one DB (`playwright.config.ts`).
2. **Serial FOIA loop** — order is the product loop, not parallel greenwash.
3. **Prefer real controls** — `data-entity-decision`, `#export-btn`, document links.
4. **Verify fold** — after POST, re-read `v_suggestions` status (allowlisted `api/rel`).
5. **No SPA helpers** — no bulk.js / panel locators.
