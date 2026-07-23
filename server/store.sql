-- Durable state. DuckDB is the app (quackapi HTTP); files stay files.
-- shellfs / hostfs / scalarfs / zipfs / curl_httpfs / cache_httpfs live in-process.
-- Optional peer: ATTACH Postgres (server/postgres.sql). No MATERIALIZED VIEW.
-- AI telemetry raw-first (pipeline_runs / llm_calls).

CREATE OR REPLACE TYPE bbox AS STRUCT(x0 DOUBLE, y0 DOUBLE, x1 DOUBLE, y1 DOUBLE);

-- The type carries its own operations. Every consumer asks the model for the
-- shape it needs — nobody re-spells min/max/scale/flip arithmetic downstream.
-- A bbox is packed once at the edge (pdf words, route params) and unpacked once
-- per destination (screen px, PDF points, identity key).
CREATE OR REPLACE MACRO bbox_of(x0, y0, x1, y1) AS (x0, y0, x1, y1)::bbox;

CREATE OR REPLACE MACRO bbox_union(a, b) AS
    (least(a.x0, b.x0), least(a.y0, b.y0),
     greatest(a.x1, b.x1), greatest(a.y1, b.y1))::bbox;

-- Hull of a list of boxes (matched words → one mark).
CREATE OR REPLACE MACRO bbox_hull(boxes) AS
    list_reduce(boxes, (a, b) -> bbox_union(a, b));

-- Screen: top-left origin, scaled. min_h floors thin word boxes so they stay
-- clickable; marks pass 0 to keep their true height.
CREATE OR REPLACE MACRO bbox_px(b, scale, min_h) AS struct_pack(
    left_px := round(b.x0 * scale, 2),
    top_px  := round(b.y0 * scale, 2),
    width   := round((b.x1 - b.x0) * scale, 2),
    height  := round(greatest(b.y1 - b.y0, min_h) * scale, 2));

-- PDF points: bottom-left origin, so y flips against page height.
CREATE OR REPLACE MACRO bbox_pdf(b, page_height) AS struct_pack(
    x := b.x0, y := page_height - b.y1,
    w := b.x1 - b.x0, h := b.y1 - b.y0);

-- Identity: rounded coords, unit-separated. Feeds the suggestion id hash.
CREATE OR REPLACE MACRO bbox_key(b) AS
    concat_ws(chr(31), round(b.x0, 0), round(b.y0, 0), round(b.x1, 0), round(b.y1, 0));

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
SELECT * FROM (VALUES
    ('detector:corpus', '{"provider":"deterministic","surface":"token_kind+kind_rules"}'::JSON, now(), now()),
    ('detector:rapidfuzz-watchlist', '{"provider":"deterministic","ext":"rapidfuzz"}'::JSON, now(), now()),
    ('detector:remainder', '{"provider":"deterministic","surface":"residual_pii_tokens"}'::JSON, now(), now()),
    ('judge:pattern-context-prior', '{"provider":"deterministic","panel":"majority|conflict→flagged"}'::JSON, now(), now())
) AS t(model_key, raw, first_seen_at, last_seen_at)
WHERE model_key NOT IN (SELECT model_key FROM llm_models);

UPDATE llm_models SET last_seen_at = now()
WHERE starts_with(model_key, 'detector:');
