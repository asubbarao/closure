-- sources.sql — the RAW LAYER: unmaterialized views straight over source files.
--
-- Model (owner's, same as the scale-control dashboards): everything is a layer
-- of views over raw sources. This bottom layer wraps `read_*` table functions as
-- views so the rest of the app composes them; DuckDB re-derives on demand, fast.
--
-- Two rulings this layer enforces:
--   * GENERIC, not fixture-shaped. The app does NOT reshape identities.json's
--     nested struct into an entity catalog — that would build the schema "for"
--     the mock data. PII is found by generic detection over document words
--     (detect.sql: finetype types, addrust parses addresses, patterns +
--     rapidfuzz for the rest); names match a generic watchlist. identities.json
--     / manifest.json are TEST ground-truth only, read by the test harness — not
--     by the app. So they are intentionally NOT read here.
--   * No fabricated ids / row_number on read. Surrogate ids (uuid) are issued
--     once at LOAD in ingest.sql (the "record created" event) and persisted;
--     natural keys (filename) are used where they exist.
--
-- Paths are inline getenv folds (the committed app_config idiom): these views
-- re-bind at REQUEST time inside route handlers, where SET VARIABLEs are not
-- visible (see routes/decisions.sql) — getvariable here would bind NULL paths.

-- Real documents: dimensions + on-disk path, keyed by filename (natural key).
CREATE OR REPLACE VIEW v_src_pdf_info AS
SELECT parse_filename(file, true) AS filename,   -- built-in basename, no regex
       file                       AS source_path,
       page_count,
       width  AS width_pt,
       height AS height_pt,
       file_size
FROM pdf_info(
    CASE WHEN getenv('CLOSURE_SAMPLES_DIR') IS NOT NULL
          AND length(getenv('CLOSURE_SAMPLES_DIR')) > 0
         THEN getenv('CLOSURE_SAMPLES_DIR')
         ELSE 'samples' END || '/*.pdf');

-- The append-only decision log, read straight off disk. Writes append one JSON
-- file per decision; this view always reflects current state with no mutable
-- table. A committed _sentinel.json pins the column set so the glob resolves
-- even before any decision exists. THE one reader of the glob — every decision
-- consumer (v_latest_decision, v_audit, v_history_events, …) composes this view;
-- filename is the shard path.
CREATE OR REPLACE VIEW v_src_decisions AS
SELECT * FROM read_json_auto(
    CASE WHEN getenv('CLOSURE_EXPORTS_DIR') IS NOT NULL
          AND length(getenv('CLOSURE_EXPORTS_DIR')) > 0
         THEN getenv('CLOSURE_EXPORTS_DIR')
         ELSE 'exports' END || '/decisions/*.json',
    union_by_name := true, ignore_errors := true, filename := true)
WHERE kind IS DISTINCT FROM 'sentinel';

-- NOTE: the entity / watchlist catalog is produced by detect.sql from generic
-- detection over the words table (+ an optional operator watchlist), NOT by
-- unpivoting the fixture here. See docs/SCHEMA_CONTRACT.md and detect.sql.
