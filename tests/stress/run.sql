-- run.sql — full PDF stress suite entrypoint (primary path).
--
-- From repo root (DuckDB ≥ 1.5.4 required for full pdf API):
--
--   mkdir -p samples/stress samples/stress/fail samples/stress/glob /tmp/closure_spill
--   duckdb154 -unsigned 2>samples/stress/run.err <<'SQL'
--   .read tests/stress/run.sql
--   SQL
--
-- Optional huge (~700MB / 130k pages) — AFTER primary suite or standalone:
--   duckdb154 -unsigned -c ".read tests/stress/00_setup.sql" \
--             -c ".read tests/stress/01b_generate_huge.sql" \
--             -c ".read tests/stress/02b_huge_budget.sql" \
--             -c ".read tests/stress/07_export_metrics.sql"
--
-- Isolated OOM proof (separate process so OOM does not abort metrics export):
--   duckdb154 -unsigned -c ".read tests/stress/break_b1_all_list.sql" \
--       2>samples/stress/break_b1.err || true

.print '========== 00 setup =========='
.read tests/stress/00_setup.sql

.print '========== 01 generate (≥5k pages) =========='
.read tests/stress/01_generate.sql

.print '========== 01c mid100 + glob folder =========='
.read tests/stress/01c_generate_folder.sql

.print '========== 02 extract under 512MB =========='
.read tests/stress/02_extract.sql

.print '========== 03 page vs all =========='
.read tests/stress/03_page_vs_all.sql

.print '========== 04 break probes =========='
.read tests/stress/04_break.sql

.print '========== 05 failure modes =========='
.read tests/stress/05_failure_modes.sql

.print '========== 06 glob scale ingest =========='
.read tests/stress/06_glob_scale.sql

.print '========== 02b huge under 512MB (if present) =========='
.read tests/stress/02b_huge_budget.sql

.print '========== 07 export metrics =========='
.read tests/stress/07_export_metrics.sql

.print '========== stress suite complete =========='
.print 'Next: break_b1_all_list.sql in a FRESH process for OOM capture.'
.print 'Optional: 01b_generate_huge.sql for 100k+/700MB class if missing.'
