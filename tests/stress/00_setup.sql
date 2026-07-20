-- 00_setup.sql — extensions, budgets, metrics sink, helpers.
-- Requires DuckDB ≥ 1.5.4 (community pdf: pdf_info, pdf_encrypt, pdf_redact, …).
-- Run from repo root with:
--   mkdir -p samples/stress samples/stress/fail samples/stress/glob .tmp/spill
--   duckdb154 -unsigned -c ".read tests/stress/run.sql"
--
-- Constraint: pure DuckDB SQL + community `pdf` only (no Python).

INSTALL pdf FROM community;
LOAD pdf;

-- Default tight budget for extraction / break probes.
-- Generators raise this temporarily then re-apply.
SET memory_limit = '512MB';
SET temp_directory = '.tmp/spill';
SET preserve_insertion_order = false;
SET threads = 4;

CREATE OR REPLACE TABLE stress_metrics (
    step        VARCHAR,
    status      VARCHAR,          -- ok | fail | skipped | expected_fail | partial
    wall_ms     DOUBLE,
    n           BIGINT,           -- rows / pages / bytes depending on step
    n2          BIGINT,           -- secondary (e.g. pages alongside words)
    mem_mb      DOUBLE,
    spill_mb    DOUBLE,
    detail      VARCHAR,
    error_msg   VARCHAR,
    recorded_at TIMESTAMP DEFAULT now()
);

CREATE OR REPLACE MACRO stress_mem_mb() AS (
    SELECT coalesce(sum(memory_usage_bytes), 0) / 1024.0 / 1024.0
    FROM duckdb_memory()
);

CREATE OR REPLACE MACRO stress_spill_mb() AS (
    SELECT coalesce(sum(temporary_storage_bytes), 0) / 1024.0 / 1024.0
    FROM duckdb_memory()
);

CREATE OR REPLACE MACRO stress_now_ms() AS (
    SELECT epoch_ms(now())
);

SELECT 'setup' AS phase,
       version() AS duckdb_version,
       current_setting('memory_limit') AS memory_limit,
       current_setting('temp_directory') AS temp_directory,
       current_setting('threads') AS threads;
