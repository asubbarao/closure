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

-- Append-only decision log. ONE reader.
-- Empty-glob safe: read_json_auto errors on zero matches; read_text returns 0 rows.
-- Writers (routes/* COPY TO exports/decisions) emit NDJSON (one JSON object per
-- line). Split lines, from_json each with the writer contract — no sentinel file,
-- no columns:=, no per-column cast wall.
CREATE OR REPLACE VIEW v_src_decisions AS
WITH raw AS (
    SELECT filename, content
    FROM read_text(
        CASE WHEN getenv('CLOSURE_EXPORTS_DIR') IS NOT NULL
              AND length(getenv('CLOSURE_EXPORTS_DIR')) > 0
             THEN getenv('CLOSURE_EXPORTS_DIR')
             ELSE 'exports' END || '/decisions/*.json'
    )
),
lines AS (
    SELECT filename, trim(line) AS line
    FROM raw, UNNEST(string_split(content, chr(10))) AS _(line)
    WHERE length(trim(line)) > 0
),
parsed AS (
    SELECT
        from_json(
            line,
            '{"kind":"VARCHAR","suggestion_id":"VARCHAR","status":"VARCHAR",'
            '"actor":"VARCHAR","reason":"VARCHAR","ts":"TIMESTAMP",'
            '"document_id":"VARCHAR","page_no":"INTEGER",'
            '"x0":"DOUBLE","y0":"DOUBLE","x1":"DOUBLE","y1":"DOUBLE",'
            '"text":"VARCHAR","context":"VARCHAR","confidence":"INTEGER",'
            '"flag_tag":"VARCHAR","source":"VARCHAR","entity_id":"VARCHAR",'
            '"case_id":"VARCHAR","batch_id":"VARCHAR","batch_label":"VARCHAR",'
            '"undoes_batch_id":"VARCHAR","scope":"VARCHAR"}'
        ) AS j,
        filename
    FROM lines
)
SELECT j.*, filename
FROM parsed;
