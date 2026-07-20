-- stress.sql — DuckDB-only stress harness for Closure's "handles 1GB+ / thousands of pages" thesis.
--
-- Proves (and breaks):
--   1. GENERATE a multi-thousand-page PDF via COPY … (FORMAT pdf)
--   2. EXTRACT with read_pdf_words under SET memory_limit='512MB' + temp_directory spill
--   3. RENDER path is O(one page): page-scoped list() is fast; whole-doc list() OOMs
--   4. BREAKING POINTS: document failures with exact error messages
--
-- Constraints: DuckDB + community `pdf` only. No Python, no typst, no shell logic inside.
-- Invoke from repo root (see tests/stress/run.sql for the entrypoint):
--
--   duckdb -unsigned -c ".read tests/stress/run.sql"
--
-- Or piecemeal:
--   .read tests/stress/01_generate.sql
--   .read tests/stress/02_extract.sql
--   .read tests/stress/03_page_vs_all.sql
--   .read tests/stress/04_break.sql
--
-- Artifacts:
--   samples/stress/monster.pdf          — primary stress PDF (≥5k pages)
--   samples/stress/stress_metrics.json  — machine-readable timings/sizes
--   samples/stress/stress_metrics.csv   — same as CSV
--   docs/stress-test.md                 — human report (written by agent after run)
--
-- This file is a thin dispatcher; the real steps live under tests/stress/.

.print '==> Closure PDF stress harness (server/stress.sql)'
.print '    Prefer: .read tests/stress/run.sql'
.read tests/stress/run.sql
