-- sources.sql — SOURCE OF TRUTH surfaces (files), not an "orthogonal data model."
--
-- Doctrine (data-model-assault / Kleppmann):
--   * The decision log on disk is the changelog for status (and manual adds).
--   * PDF samples + watchlist + manifest are inputs to batch detect at boot.
--   * Serving tables (suggestions, entities, words) are DERIVED — rebuildable —
--     but MUST use durable keys (see ids.sql / ingest.sql / detect.sql).
--   * UI marts (v_doc_ui, triage counts, …) are projections, not the model.
--
-- This file only wraps read_* over source files. No uuid(). No metrics.

-- Real documents: dimensions + on-disk path, keyed by filename (natural key).
CREATE OR REPLACE VIEW v_src_pdf_info AS
SELECT parse_filename(file, true) AS filename,   -- built-in basename
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

-- Append-only decision log. ONE reader. Typed columns so empty/sentinel boots
-- do not infer JSON and break coalesce(status, 'pending').
-- ignore_errors OFF: corrupt shards must fail loud (audit log, not best-effort).
CREATE OR REPLACE VIEW v_src_decisions AS
SELECT
    cast(kind AS VARCHAR) AS kind,
    cast(suggestion_id AS VARCHAR) AS suggestion_id,
    cast(status AS VARCHAR) AS status,
    cast(actor AS VARCHAR) AS actor,
    cast(reason AS VARCHAR) AS reason,
    cast(ts AS VARCHAR) AS ts,
    cast(document_id AS VARCHAR) AS document_id,
    try_cast(page_no AS INTEGER) AS page_no,
    try_cast(x0 AS DOUBLE) AS x0,
    try_cast(y0 AS DOUBLE) AS y0,
    try_cast(x1 AS DOUBLE) AS x1,
    try_cast(y1 AS DOUBLE) AS y1,
    cast(text AS VARCHAR) AS text,
    cast(context AS VARCHAR) AS context,
    try_cast(confidence AS INTEGER) AS confidence,
    cast(flag_tag AS VARCHAR) AS flag_tag,
    cast(source AS VARCHAR) AS source,
    cast(entity_id AS VARCHAR) AS entity_id,
    cast(case_id AS VARCHAR) AS case_id,
    cast(batch_id AS VARCHAR) AS batch_id,
    cast(batch_label AS VARCHAR) AS batch_label,
    cast(undoes_batch_id AS VARCHAR) AS undoes_batch_id,
    filename
FROM read_json_auto(
    CASE WHEN getenv('CLOSURE_EXPORTS_DIR') IS NOT NULL
          AND length(getenv('CLOSURE_EXPORTS_DIR')) > 0
         THEN getenv('CLOSURE_EXPORTS_DIR')
         ELSE 'exports' END || '/decisions/*.json',
    union_by_name := true,
    ignore_errors := false,
    filename := true
)
WHERE kind IS DISTINCT FROM 'sentinel';
