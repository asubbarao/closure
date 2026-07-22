-- Durable state. DuckDB is the app (quackapi HTTP); files stay files.
-- shellfs / hostfs / scalarfs / zipfs / curl_httpfs live in-process.
-- Optional peer: ATTACH Postgres (server/postgres.sql). No MATERIALIZED VIEW.
-- AI telemetry raw-first (pipeline_runs / llm_calls).

CREATE OR REPLACE TYPE bbox AS STRUCT(x0 DOUBLE, y0 DOUBLE, x1 DOUBLE, y1 DOUBLE);

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
    ('detector:remainder-rapidfuzz', '{"provider":"deterministic","ext":"rapidfuzz"}'::JSON, now(), now())
) AS t(model_key, raw, first_seen_at, last_seen_at)
WHERE model_key NOT IN (SELECT model_key FROM llm_models);

UPDATE llm_models SET last_seen_at = now()
WHERE starts_with(model_key, 'detector:');
