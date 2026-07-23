-- Durable state. DuckDB is the app (quackapi HTTP); files stay files.
-- shellfs / hostfs / scalarfs / zipfs / curl_httpfs / cache_httpfs live in-process.
-- Optional peer: ATTACH Postgres (server/postgres.sql). No MATERIALIZED VIEW.
-- AI telemetry raw-first (pipeline_runs / llm_calls).

-- ── geometry as first-class types (same idea as a mark interactor elsewhere) ─
-- PDF page space is the source of truth. Screen is a pin for the canvas.
-- Pack once at write; consumers SELECT columns of type bbox / screen_box.
-- UNNEST is fine at a SQL edge when you need flat fields; storage stays typed.

CREATE OR REPLACE TYPE bbox AS STRUCT(
    x0 DOUBLE, y0 DOUBLE, x1 DOUBLE, y1 DOUBLE
);

-- Canvas CSS box (top-left origin, scaled). One value, not four laundry columns.
-- Field names avoid reserved words (left/top): x/y/w/h = CSS left/top/width/height.
CREATE OR REPLACE TYPE screen_box AS STRUCT(
    x DOUBLE, y DOUBLE, w DOUBLE, h DOUBLE
);

-- pdf_redact() wants bottom-left origin + size (page stamped at plan time).
CREATE OR REPLACE TYPE redact_box AS STRUCT(
    x DOUBLE, y DOUBLE, w DOUBLE, h DOUBLE
);

-- Conversions only — these replace repeated arithmetic downstream.
-- Not a macro zoo: construct with (…)::bbox; transform with these two + key.
CREATE OR REPLACE MACRO bbox_to_screen(b, scale, min_h) AS (
    round(b.x0 * scale, 2),
    round(b.y0 * scale, 2),
    round((b.x1 - b.x0) * scale, 2),
    round(greatest(b.y1 - b.y0, min_h) * scale, 2)
)::screen_box;  -- → (x, y, w, h)

CREATE OR REPLACE MACRO bbox_to_redact(b, page_height) AS (
    b.x0,
    page_height - b.y1,
    b.x1 - b.x0,
    b.y1 - b.y0
)::redact_box;

CREATE OR REPLACE MACRO bbox_key(b) AS
    concat_ws(chr(31), round(b.x0, 0), round(b.y0, 0), round(b.x1, 0), round(b.y1, 0));

-- Hull of matched word boxes → one mark bbox (list of bbox → bbox).
CREATE OR REPLACE MACRO bbox_hull(boxes) AS
    list_reduce(boxes, (a, b) -> (
        least(a.x0, b.x0), least(a.y0, b.y0),
        greatest(a.x1, b.x1), greatest(a.y1, b.y1)
    )::bbox);

CREATE TABLE IF NOT EXISTS decisions (
    ts TIMESTAMP DEFAULT now(), kind VARCHAR, suggestion_id VARCHAR,
    status VARCHAR, actor VARCHAR, reason VARCHAR,
    document_id VARCHAR, case_id VARCHAR, text VARCHAR,
    batch_id VARCHAR, batch_label VARCHAR, undoes_batch_id VARCHAR,
    page_no INTEGER, bbox bbox, context VARCHAR, confidence INTEGER,
    flag_tag VARCHAR, entity_id VARCHAR, source VARCHAR, scope VARCHAR
);

-- model_key + raw. Parse capabilities later.
CREATE TABLE IF NOT EXISTS llm_models (
    model_key VARCHAR PRIMARY KEY,
    raw JSON,
    first_seen_at TIMESTAMP DEFAULT now(),
    last_seen_at TIMESTAMP DEFAULT now()
);

-- One row per unit of work. Everything else lives in raw (no column laundry).
CREATE TABLE IF NOT EXISTS pipeline_runs (
    run_id VARCHAR PRIMARY KEY,
    kind VARCHAR,              -- detect | judge | export | smoke
    ts TIMESTAMP DEFAULT now(),
    raw JSON                   -- counts, paths, models, errors — whole bag
);

-- One row per model call. request + raw only; join keys optional in raw too.
CREATE TABLE IF NOT EXISTS llm_calls (
    id VARCHAR PRIMARY KEY,
    ts TIMESTAMP DEFAULT now(),
    run_id VARCHAR,
    model_key VARCHAR,
    request JSON,
    raw JSON
);

CREATE TABLE IF NOT EXISTS run_artifacts (
    run_id VARCHAR,
    path VARCHAR,
    raw JSON,
    ts TIMESTAMP DEFAULT now()
);

INSERT INTO llm_models BY NAME
SELECT t.*
FROM (VALUES
    ('detector:corpus', '{"provider":"deterministic","surface":"token_kind+kind_rules"}'::JSON, now(), now()),
    ('detector:rapidfuzz-watchlist', '{"provider":"deterministic","ext":"rapidfuzz"}'::JSON, now(), now()),
    ('detector:remainder', '{"provider":"deterministic","surface":"residual_pii_tokens"}'::JSON, now(), now()),
    ('judge:pattern-context-prior', '{"provider":"deterministic","panel":"majority|conflict→flagged"}'::JSON, now(), now())
) AS t(model_key, raw, first_seen_at, last_seen_at)
LEFT JOIN llm_models m ON m.model_key = t.model_key
WHERE m.model_key IS NULL;

UPDATE llm_models SET last_seen_at = now()
WHERE starts_with(model_key, 'detector:');
