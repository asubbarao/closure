# Closure — AI-assisted redaction review

A prototype redaction-review tool for law enforcement: AI suggests, a human
decides, the export is provably clean. Built on an unusual thesis — **one DuckDB
process is the entire backend**: the database, the HTTP server, the PDF engine,
and the audit log.

## Layout

```
server/     DuckDB backend — schema, detection, named HTTP routes (quackapi),
            boot script. SQL is the application code.
web/        The frontend webapp (Vite + React + TS). Talks only to named
            JSON endpoints; has no knowledge of the backend's implementation.
design/     Part 1 — high-fidelity mockups (self-contained HTML/CSS).
samples/    Generated sample corpus: one 110-page consolidated case file +
            ten ~10-page related police reports across 4 cases.
  gen/      The corpus generator: fakeit (DuckDB ext) fabricates identities →
            identities.json (frozen fixture) → typst renders the PDFs.
            manifest.json is the ground-truth PII answer key used by tests.
docs/       Design rationale (Part 3).
```

## Stack

| Concern            | Implementation                                           |
|--------------------|----------------------------------------------------------|
| Database           | DuckDB v1.5.4                                            |
| PDF read/render/redact | `pdf` community extension (`read_pdf_words`, `pdf_to_png`, `pdf_redact`) |
| HTTP API           | quackapi (`CREATE ROUTE` DDL + `serve_brain`)            |
| Fake identities    | `fakeit` community extension                             |
| Corpus rendering   | typst (embedded fonts, so pages raster everywhere)       |
| Frontend           | Vite + React + TypeScript                                |

All extensions install signed from the community repo — no `-unsigned` anywhere.

## Regenerating the sample corpus

```sh
duckdb -c ".read samples/gen/identities.sql"   # fakeit → samples/identities.json
python3 samples/gen/generate.py                # typst → samples/*.pdf + manifest.json
```

`identities.json` is a frozen fixture (fakeit is not seedable); the committed
PDFs and manifest derive from it, so tests have a stable answer key.

## Status

Work in progress. Done: corpus pipeline, mockups (round 1), architecture spikes
(word-box coordinates, true raster redaction round-trip, quackapi route → pdf
extension integration). Next: `server/` schema + detection + routes, then the
webapp.
