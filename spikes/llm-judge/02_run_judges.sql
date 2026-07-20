-- 02_run_judges.sql — local-LLM judges on real flagged / review / control items.
-- From repo root (Ollama up; models llama3.2:3b + qwen2.5:7b):
--   rm -f spikes/llm-judge/out/run.duckdb
--   duckdb -unsigned spikes/llm-judge/out/run.duckdb < spikes/llm-judge/02_run_judges.sql
--
-- Outputs under spikes/llm-judge/out/:
--   llm_votes.csv, comparison.csv, latency_summary.csv
--
-- Integration note: `ai_classify(..., model := col)` fails — model must be a
-- constant expression. So production-shaped path uses http_client.http_post
-- with model as a row value. Separate constant-model ai_classify batches are
-- kept as a control (path_A).

INSTALL ai FROM community;
LOAD ai;
INSTALL http_client FROM community;
LOAD http_client;

SET duckdb_ai_provider = 'ollama';
SET duckdb_ai_base_url = 'http://127.0.0.1:11434';
SET duckdb_ai_timeout_seconds = 180;
SET duckdb_ai_allowed_hosts = '127.0.0.1,localhost';
SET duckdb_ai_cache = false;
SET duckdb_ai_max_concurrent_requests = 1;
SET duckdb_ai_min_request_interval_ms = 0;
SET duckdb_ai_on_error = 'null';

CREATE OR REPLACE TABLE items AS
SELECT
    suggestion_id::INTEGER AS suggestion_id,
    pick::VARCHAR AS pick,
    text::VARCHAR AS text,
    kind::VARCHAR AS kind,
    context::VARCHAR AS context,
    seed_confidence::INTEGER AS seed_confidence,
    flag_tag::VARCHAR AS flag_tag,
    seed_reason::VARCHAR AS seed_reason,
    band::VARCHAR AS band,
    panel_signal::VARCHAR AS panel_signal,
    panel_confidence::INTEGER AS panel_confidence,
    judge_band::VARCHAR AS judge_band,
    det_majority::VARCHAR AS det_majority
FROM read_json_auto('spikes/llm-judge/fixture.json');

-- Two independent judges (requirement): different model × different prompt.
-- Both use http_post so model can vary per row. Extra ai_classify control below.
CREATE OR REPLACE TABLE judge_specs AS
SELECT * FROM (
    SELECT
        'llama32_foia' AS judge_key,
        'llama3.2:3b' AS model,
        'foia_strict' AS prompt_style
    UNION ALL
    SELECT
        'qwen25_brief',
        'qwen2.5:7b',
        'brief'
);

CREATE OR REPLACE TABLE prompts AS
SELECT
    i.suggestion_id,
    s.judge_key,
    s.model,
    s.prompt_style,
    CASE s.prompt_style
        WHEN 'foia_strict' THEN
            concat(
                'You are a FOIA redaction judge for law-enforcement PDFs. ',
                'Decide whether the CANDIDATE span should be REDACTED (protectable subject/witness PII) or KEPT (false positive: citation, street label, officer of record). ',
                'Rules: (1) SSN/phone/DOB/subject name/home address → redact. ',
                '(2) Case citations (X v. Y, U.S. reports) → keep. ',
                '(3) Street names that share a surname (e.g. "Feeney Street") with no house number in the candidate → keep. ',
                '(4) Reporting officers (Det./Ofc./Sgt. + badge) → keep. ',
                'Reply with ONLY a JSON object with keys verdict (redact|keep), score (0-100 integer), reason (one short line). ',
                'CANDIDATE: "', coalesce(i.text, ''), '". ',
                'KIND: ', coalesce(i.kind, 'unknown'), '. ',
                'CONTEXT: "', coalesce(i.context, ''), '".'
            )
        WHEN 'brief' THEN
            concat(
                'PII triage JSON only {"verdict":"redact"|"keep","score":0-100,"reason":"one line"}. ',
                'redact=subject/witness PII; keep=citation, street-only, officer. ',
                'text="', coalesce(i.text, ''),
                '" kind=', coalesce(i.kind, '?'),
                ' ctx="', coalesce(i.context, ''), '".'
            )
    END AS prompt_text
FROM items i
CROSS JOIN judge_specs s;

-- Sequential-ish http_post fan-out (DuckDB may still parallelise internally;
-- Ollama serialises model inference per loaded model).
CREATE OR REPLACE TABLE votes_http AS
WITH posted AS (
    SELECT
        p.suggestion_id,
        p.judge_key,
        p.model,
        p.prompt_style,
        http_post(
            'http://127.0.0.1:11434/api/generate',
            map {'Content-Type': 'application/json'},
            {
                'model': p.model,
                'prompt': p.prompt_text,
                'stream': false,
                'format': 'json',
                'options': {
                    'temperature': 0,
                    'num_predict': 100
                }
            }::JSON
        ) AS resp
    FROM prompts p
)
SELECT
    suggestion_id,
    judge_key,
    model,
    prompt_style,
    'http_generate' AS call_path,
    (resp ->> 'body')::JSON ->> 'response' AS raw_json,
    try_cast(
        ((resp ->> 'body')::JSON ->> 'total_duration') AS BIGINT
    ) / 1000000 AS ollama_total_ms,
    try_cast(resp ->> 'status' AS INTEGER) AS http_status
FROM posted;

-- Control path: ai_classify with CONSTANT model (llama3.2 only).
SET duckdb_ai_model = 'llama3.2:3b';
CREATE OR REPLACE TABLE votes_ai_llama AS
SELECT
    i.suggestion_id,
    'llama32_ai_classify' AS judge_key,
    'llama3.2:3b' AS model,
    'classify_short' AS prompt_style,
    'ai_classify' AS call_path,
    lower(trim(ai_classify(
        concat(
            'PII redaction triage. Candidate="', coalesce(i.text, ''),
            '" Kind=', coalesce(i.kind, 'unknown'),
            ' Context="', coalesce(i.context, ''),
            '". Choose redact if protectable subject/witness PII; keep if citation, street-only label, or officer of record; unsure if ambiguous.'
        ),
        ['redact', 'keep', 'unsure']
    ))) AS raw_label,
    NULL::VARCHAR AS raw_json,
    NULL::BIGINT AS ollama_total_ms,
    NULL::INTEGER AS http_status
FROM items i;

CREATE OR REPLACE TABLE llm_votes AS
WITH unioned AS (
    SELECT
        suggestion_id, judge_key, model, prompt_style, call_path,
        NULL::VARCHAR AS raw_label, raw_json, ollama_total_ms, http_status
    FROM votes_http
    UNION ALL BY NAME
    SELECT
        suggestion_id, judge_key, model, prompt_style, call_path,
        raw_label, raw_json, ollama_total_ms, http_status
    FROM votes_ai_llama
),
parsed AS (
    SELECT
        u.*,
        CASE
            WHEN u.raw_json IS NOT NULL
                 AND json_valid(u.raw_json)
                 AND json_type(u.raw_json::JSON) = 'OBJECT'
                THEN lower(trim(coalesce(
                    json_extract_string(u.raw_json::JSON, '$.verdict'),
                    json_extract_string(u.raw_json::JSON, '$.label')
                )))
            WHEN u.raw_label IS NOT NULL THEN u.raw_label
            WHEN u.raw_json IS NOT NULL
                 AND regexp_matches(u.raw_json, '(?i)"verdict"\s*:\s*"(redact|keep|unsure)"')
                THEN lower(regexp_extract(
                    u.raw_json,
                    '(?i)"verdict"\s*:\s*"(redact|keep|unsure)"',
                    1
                ))
            ELSE 'unsure'
        END AS verdict_raw,
        CASE
            WHEN u.raw_json IS NOT NULL AND json_valid(u.raw_json)
                THEN try_cast(json_extract(u.raw_json::JSON, '$.score') AS INTEGER)
            WHEN u.raw_label = 'redact' THEN 80
            WHEN u.raw_label = 'keep' THEN 80
            WHEN u.raw_label = 'unsure' THEN 50
            ELSE 50
        END AS score,
        CASE
            WHEN u.raw_json IS NOT NULL AND json_valid(u.raw_json)
                THEN left(coalesce(json_extract_string(u.raw_json::JSON, '$.reason'), ''), 160)
            WHEN u.call_path = 'ai_classify'
                THEN concat('ai_classify label=', coalesce(u.raw_label, '?'))
            ELSE left(coalesce(u.raw_json, ''), 160)
        END AS reason
    FROM unioned u
)
SELECT
    suggestion_id,
    judge_key,
    model,
    prompt_style,
    call_path,
    CASE
        WHEN verdict_raw IN ('redact', 'keep', 'unsure') THEN verdict_raw
        WHEN position('redact' IN coalesce(verdict_raw, '')) > 0 THEN 'redact'
        WHEN position('keep' IN coalesce(verdict_raw, '')) > 0 THEN 'keep'
        ELSE 'unsure'
    END AS verdict,
    least(100, greatest(0, coalesce(score, 50)))::INTEGER AS score,
    reason,
    ollama_total_ms,
    http_status,
    raw_label,
    raw_json
FROM parsed;

COPY (SELECT * FROM llm_votes ORDER BY suggestion_id, judge_key)
TO 'spikes/llm-judge/out/llm_votes.csv' (HEADER, DELIMITER ',');

CREATE OR REPLACE TABLE comparison AS
SELECT
    i.suggestion_id,
    i.pick,
    i.text,
    i.kind,
    i.band,
    i.det_majority,
    i.panel_signal,
    i.panel_confidence,
    i.judge_band,
    v.judge_key,
    v.model,
    v.prompt_style,
    v.call_path,
    v.verdict AS llm_verdict,
    v.score AS llm_score,
    v.reason AS llm_reason,
    v.ollama_total_ms,
    (v.verdict = i.det_majority) AS agrees_det_majority,
    CASE
        WHEN i.flag_tag = 'false_positive' THEN 'keep'
        WHEN starts_with(i.pick, 'true_') THEN 'redact'
        ELSE i.det_majority
    END AS expected,
    (v.verdict = CASE
        WHEN i.flag_tag = 'false_positive' THEN 'keep'
        WHEN starts_with(i.pick, 'true_') THEN 'redact'
        ELSE i.det_majority
    END) AS agrees_expected
FROM items i
JOIN llm_votes v ON v.suggestion_id = i.suggestion_id
ORDER BY i.suggestion_id, v.judge_key;

COPY (SELECT * FROM comparison)
TO 'spikes/llm-judge/out/comparison.csv' (HEADER, DELIMITER ',');

CREATE OR REPLACE TABLE latency_summary AS
SELECT
    judge_key,
    model,
    call_path,
    count(*) AS n,
    round(avg(ollama_total_ms), 1) AS avg_ms,
    min(ollama_total_ms) AS min_ms,
    max(ollama_total_ms) AS max_ms,
    sum(CASE WHEN agrees_expected THEN 1 ELSE 0 END) AS n_agree_expected,
    sum(CASE WHEN agrees_det_majority THEN 1 ELSE 0 END) AS n_agree_det,
    round(100.0 * avg(agrees_expected::INTEGER), 1) AS pct_agree_expected,
    round(100.0 * avg(agrees_det_majority::INTEGER), 1) AS pct_agree_det
FROM comparison
GROUP BY 1, 2, 3
ORDER BY 1;

COPY (SELECT * FROM latency_summary)
TO 'spikes/llm-judge/out/latency_summary.csv' (HEADER, DELIMITER ',');

SELECT '=== comparison ===' AS section;
SELECT
    suggestion_id,
    pick,
    left(text, 28) AS text,
    det_majority,
    expected,
    judge_key,
    llm_verdict,
    llm_score,
    agrees_expected,
    ollama_total_ms
FROM comparison
ORDER BY suggestion_id, judge_key;

SELECT '=== latency / accuracy ===' AS section;
SELECT * FROM latency_summary;

SELECT '=== agreement rates ===' AS section;
SELECT
    judge_key,
    round(100.0 * avg(agrees_expected::INTEGER), 1) AS pct_agree_expected,
    round(100.0 * avg(agrees_det_majority::INTEGER), 1) AS pct_agree_det,
    count(*) AS n
FROM comparison
GROUP BY 1
ORDER BY 1;
