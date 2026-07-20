# CLOSURE SQL REBUILD — shared preamble (every task reads this first)

Repo: /Users/aloksubbarao/personal/closure. Already submitted (public); `main` is free to refactor.
The owner reviewed all SQL in DataGrip and the model was built bottom-up and WRONG. Your job:
rewrite ONE file clean, cutting it dramatically, using extensions instead of hand-rolled SQL.

## Boot / run
`/Users/aloksubbarao/personal/quackapi/build/release/duckdb -unsigned closure.db -c ".read server/app.sql"` (serves :8117).
The `-unsigned` is only for the local quackapi build; all other extensions are signed community installs.

## Extension call shapes — USE THESE, don't hand-roll
Read /private/tmp/.../scratchpad/EXT_REFERENCE.md (full path given in your task). Summary:
- rapidfuzz: `rapidfuzz_ratio(a,b)` 0..100, `rapidfuzz_token_sort_ratio`, `rapidfuzz_jaro_winkler_similarity`.
- splink_udfs: **`ngrams(list, n)`** (replaces hand-rolled n-gram window-UNION), `unaccent`/`strip_diacritics` (replaces `qnorm`), `soundex`/`double_metaphone`/`levenshtein` (variant grouping).
- us_address_standardizer: `addrust_parse(addr) → STRUCT` (canonical US addresses).
- finetype: `finetype(val)` / `finetype_detail(val)` (PII type taxonomy + confidence).
- scalarfs: `read_csv('variable:x')` / `COPY (...) TO 'variable:x' (FORMAT variable)` (replaces NULL::CAST + temp-file soup).

## ARCHITECTURE RULINGS (tonight's corrections — these override everything, get them right)
A. **Layered unmaterialized views over raw sources.** Bottom = `read_*` wrapped as views (scalecontrol pattern). Compose upward. Only expensive extraction (read_pdf_words over the corpus) is pinned to a table. No rigid denormalized "keystone."
B. **The schema must be GENERIC / real-app-shaped — NEVER built for the fake fixture.** Do NOT unpivot / reshape identities.json's specific nested struct inside the app. PII is found by GENERIC DETECTION over the document words: `finetype` types tokens (SSN/phone/date/email), `addrust_parse` finds addresses, patterns for the rest. Names come from a generic **watchlist(term, kind)** (a case's known parties — realistic) matched with `rapidfuzz` for variants. Any fixture reshaping belongs at the SOURCE (the generator emits clean flat rows); the app reads clean data. `identities.json`/`manifest.json` are TEST ground-truth only (score detection) — NOT app input.
C. **Identity like a real app: issue once at load, save it.** No `row_number()` re-deriving ids on read. At load (the "record created" event) assign `uuid()` into the materialized table and persist it, OR use a natural key (`case_no`, `filename`). Routes use whatever id the data carries — string routes `/cases/:id` are clean; drop `::INTEGER` coupling. Don't mix routing with keying.
D. **Near-zero macros; extensions over hand-rolled** (rapidfuzz/splink_udfs/finetype/us_address_standardizer/scalarfs). Delete qnorm, v_grams, n-gram UNIONs, bespoke variant tables.

## Hard style rules (from the owner's --# review — violating these fails the task)
1. **CTAS / CREATE OR REPLACE** for anything derivable. Fresh clone every run — NO `CREATE ... IF NOT EXISTS`, NO sequences ceremony, NO idempotency guards. Tables ONLY for genuinely mutable state (the append-only decision log).
2. **NO correlated subselect stat views.** Counts come from clean `GROUP BY` (or `SUMMARIZE`/`DESCRIBE` exposed as a view). The old `v_document_stats` (12 inner `SELECT count(*)` subselects) is the banned antipattern.
3. **NO `CROSS JOIN`** except `CROSS JOIN UNNEST(...)`. **NO `AND`/`OR` chains for branching** → `CASE WHEN`. **NO `COALESCE(..., CASE WHEN agg())`** — aggregate once upstream, then one clean `CASE`.
4. **NO hand-rolled string/NLP/geometry** the extensions cover. Delete `qnorm`, `v_grams`, n-gram UNIONs, `_name_variant_*`/`entity_groups` hand tables. Use rapidfuzz/splink/finetype/addrust. Regex ONLY inside the user-facing bulk-change tool.
5. **NEAR-ZERO macros.** Default: delete. Render macros (`render_home/case/document/audit`) become the route body (`CREATE ROUTE x AS <select>`). `cfg_*` path macros → plain literals or `SET`. Keep a macro ONLY if parameterized AND reused >1 place AND clearly clearer — and justify it in a comment.
6. **Coords as a `box` STRUCT** internally (verbose field names), not 4 loose `x0/y0/x1/y1` doubles — BUT routes that already emit `x0/y0/x1/y1` (or `left_px/top_px`) JSON keys must keep emitting those exact keys (unpack the struct at the edge). Internal representation changes; public JSON keys DO NOT.
7. **No `row_number()`** unless a stable id is genuinely needed and nothing else provides it.
8. **Verbose, readable names.** No `p`/`q`/`b` single letters. Comments explain intent, not mechanics.

## FROZEN PUBLIC CONTRACT (do not change these — the frontend + e2e depend on them)
Read /private/tmp/.../scratchpad/SCHEMA_CONTRACT.md (path in your task) for: exact table names, each
view's column set, the `box` struct shape, and the route inventory (every route path + its JSON output
keys / tera context var names). Your rewrite must keep every route path, every JSON key, and every
tera template variable identical. Refactor the SQL that PRODUCES them, never the outputs.

## Placeholder rule
If the correct/clean approach for something genuinely needs the owner's design input (esp. the
phrase→word-box matching that seeds suggestions), DO NOT ship a smelly version — leave a short
view/CTE placeholder with a comment stating exactly what it must produce (columns + intent), so the
owner can sketch the query. A clean placeholder beats a working mess.

## Deliverable
Rewrite ONLY your assigned file. Verify it: boot the app (or `.read server/schema.sql` then your file)
and confirm no error + the routes/views it owns still return the same shape. Report: old line count →
new line count, what you deleted, which extensions you used, and any placeholder you left.
