# Closure e2e (Playwright)

Playwright tests for the **core redaction-review workflow**, driving the real
DuckDB + quackapi app at `http://127.0.0.1:8117/`.

This directory is **standalone dev tooling** — its own `package.json`,
`node_modules/`, and Playwright config. It does not touch `server/`,
`templates/`, or `static/`.

## Prerequisites

- Node 18+ (Node 20/24 fine)
- App binary: the quackapi-built duckdb (`$QUACKAPI_ROOT/build/release/duckdb`;
  default layout is `../quackapi` next to this repo — see `run.sh`)

## Boot the app (fresh)

From the **closure repo root**:

```sh
# free the port
lsof -ti :8117 | xargs kill -9 2>/dev/null || true

# clean DB (and decision log so statuses start pending)
rm -f closure.db closure.db.wal
# optional but recommended for a clean queue:
find exports/decisions -type f -name '*.json' ! -name '_sentinel.json' -delete 2>/dev/null || true
mkdir -p exports/decisions
printf '%s\n' '{"kind":"sentinel"}' > exports/decisions/_sentinel.json

# boot (blocks — leave this terminal open)
"${DUCKDB_BIN:-../quackapi/build/release/duckdb}" -unsigned closure.db -c ".read server/app.sql"
```

Wait until the home route is healthy:

```sh
until curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:8117/ | grep -q 200; do sleep 1; done
echo ready
```

Ingest + seed can take 1–3 minutes on a cold boot.

## Install & run tests

```sh
cd tests/e2e
npm install
npx playwright install chromium   # first time only
npx playwright test
```

Useful variants:

```sh
npx playwright test --reporter=list
npx playwright test specs/01-review-interface.spec.ts
npx playwright test --headed
```

Override base URL if needed:

```sh
CLOSURE_BASE_URL=http://127.0.0.1:8117 npx playwright test
```

## Specs (core flows)

| Spec | Flow |
|------|------|
| `01-review-interface.spec.ts` | Open doc, queue + marks, `j`/`k`, accept (`a`) |
| `02-reject-false-positive.spec.ts` | Reject street FP; reject-all-matching |
| `03-add-missed.spec.ts` | Add missed redaction (born accepted) |
| `04-bulk-accept-reject.spec.ts` | Bulk HIGH / entity accept |
| `05-multi-document.spec.ts` | Library multi-doc; entity fan-out (data-driven doc ids) |
| `06-confidence-display.spec.ts` | Confidence bands + filters |
| `07-export-audit.spec.ts` | Export blocked on flagged; audit trail |

## Specs (wave-2 — skip cleanly on 404)

| Spec | Flow |
|------|------|
| `08-judge-panel.spec.ts` | `GET /api/suggestions/:id/judges` + UI on flagged |
| `09-missed-queue.spec.ts` | `GET /api/documents/:id/missed` + one-tap add |
| `10-fuzzy-add-missed-search.spec.ts` | Search `exact_count` / `fuzzy_count` + add-missed chip |
| `11-provenance.spec.ts` | `GET /api/cases/:id/provenance` + chain-of-custody panel |

Wave-2 helpers probe routes first; if a route returns **404**, the test
`test.skip`s with a clear reason. When live, API + UI are exercised fully.
All fixtures (filenames, tokens, doc ids) come from `/api` responses — nothing
is hardcoded to a corpus regeneration.

Tests use `workers: 1` and share the live server (mutations are intentional).

## HTML report

```sh
npx playwright show-report
```
