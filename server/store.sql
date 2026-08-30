-- Durable state. Types once; geometry math inlined at write (no macro zoo).

CREATE OR REPLACE TYPE bbox AS STRUCT(x0 DOUBLE, y0 DOUBLE, x1 DOUBLE, y1 DOUBLE);
CREATE OR REPLACE TYPE screen_box AS STRUCT(x DOUBLE, y DOUBLE, w DOUBLE, h DOUBLE);
CREATE OR REPLACE TYPE redact_box AS STRUCT(x DOUBLE, y DOUBLE, w DOUBLE, h DOUBLE);

CREATE TABLE IF NOT EXISTS decisions (
    ts TIMESTAMP DEFAULT now(),
    kind VARCHAR DEFAULT 'decision',
    suggestion_id VARCHAR,
    status VARCHAR,
    actor VARCHAR DEFAULT 'reviewer',
    reason VARCHAR,
    document_id VARCHAR,
    case_id VARCHAR,
    text VARCHAR,
    batch_id VARCHAR, batch_label VARCHAR, undoes_batch_id VARCHAR,
    page_no INTEGER, bbox bbox, context VARCHAR, confidence INTEGER,
    flag_tag VARCHAR, entity_id VARCHAR, source VARCHAR, scope VARCHAR
);

CREATE TABLE IF NOT EXISTS llm_models (
    model_key VARCHAR PRIMARY KEY,
    raw JSON,
    first_seen_at TIMESTAMP DEFAULT now(),
    last_seen_at TIMESTAMP DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pipeline_runs (
    run_id VARCHAR PRIMARY KEY,
    kind VARCHAR,
    ts TIMESTAMP DEFAULT now(),
    raw JSON
);

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
SELECT t.* FROM (VALUES
    ('detector:corpus', '{"provider":"deterministic"}'::JSON, now(), now()),
    ('detector:rapidfuzz-watchlist', '{"provider":"deterministic"}'::JSON, now(), now()),
    ('detector:remainder', '{"provider":"deterministic"}'::JSON, now(), now()),
    ('judge:panel', '{"provider":"llm"}'::JSON, now(), now())
) AS t(model_key, raw, first_seen_at, last_seen_at)
LEFT JOIN llm_models m ON m.model_key = t.model_key
WHERE m.model_key IS NULL;
