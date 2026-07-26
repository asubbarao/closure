-- judge.sql — the LLM judge panel, run live from core.sql once suggestions exist.
-- The ONLY file that calls out. Provider = server/config/judges.json: an endpoint,
-- a token, and the models. Ollama by default; any OpenAI-compatible URL + key works.

LOAD shellfs;

CREATE OR REPLACE TABLE judge_config AS SELECT * FROM read_json_auto('pathvariable:judges_path');
CREATE OR REPLACE TABLE judges AS SELECT unnest(judges, recursive := true) FROM judge_config;

-- Judge unit = the distinct decision, not the 17k occurrences: "John Smith" is
-- judged once and the verdict joins back down to every mark.
CREATE OR REPLACE TABLE judge_spans AS
SELECT kind, text, any_value(context) AS context
FROM suggestions WHERE text IS NOT NULL GROUP BY kind, text;

SELECT content AS judge_workdir FROM read_text('mkdir -p .tmp/judge && rm -f .tmp/judge/*.json |');
COPY judge_spans TO '.tmp/judge/spans.json' (FORMAT json, ARRAY true);

-- Self-dispatch. open_prompt's model is session-global — model_name := is accepted
-- then ignored (a bogus model still answers) — so a judge cannot be a column, and
-- an in-process httpserver shares the session. It becomes a built command instead:
-- DuckDB prints one env-carrying command per judge, the shell runs them together,
-- DuckDB reads the votes back off the same pipe. One literal, one relation.
CREATE OR REPLACE TABLE judge_votes AS
SELECT vote.judge, vote.kind, vote.text, vote.response, jdg.model_name
FROM read_json($$"$(scripts/duckdb-bin.sh)" -no-init -noheader -list -c "
        COPY (
            SELECT printf('OPEN_PROMPT_API_URL=%s OPEN_PROMPT_API_TOKEN=%s OPEN_PROMPT_API_TIMEOUT=120 '
                       || 'OPEN_PROMPT_MODEL_NAME=%s CLOSURE_JUDGE=%s '
                       || 'CLOSURE_JUDGE_SPANS=.tmp/judge/spans.json '
                       || '\"\$DUCKDB\" -no-init -c \".read server/judge_worker.sql\" > .tmp/judge/votes_%s.json &',
                          cfg.api_url, cfg.api_token, judge.model_name, judge.judge, judge.judge) AS command
            FROM read_json_auto('server/config/judges.json') cfg, unnest(cfg.judges) AS panel(judge)
            UNION ALL SELECT 'wait; cat .tmp/judge/votes_*.json'
        ) TO '/dev/stdout' (FORMAT csv, HEADER false, QUOTE '')" \
    | DUCKDB="$(scripts/duckdb-bin.sh)" bash |$$) vote
JOIN judges jdg ON jdg.judge = vote.judge;

-- Raw-first capture: one llm_calls row per vote, request + response verbatim.
INSERT INTO llm_calls BY NAME
SELECT uuid()::VARCHAR AS id, now() AS ts,
       (SELECT run_id FROM detect_run) AS run_id,
       'judge:' || judge AS model_key,
       json_object('kind', kind, 'text', text, 'model', model_name) AS request,
       json_object('response', response) AS raw
FROM judge_votes;

-- One row per judge per span: verdict, reason, and the reply they came out of. A
-- reply naming none of the three words is 'unparsed', NOT a review vote — a refusal
-- must never impersonate a judge agreeing with two others.
CREATE OR REPLACE TABLE judge_verdicts AS
SELECT kind, text, judge, model_name,
       CASE
           WHEN contains(lower(response), 'redact') THEN 'redact'
           WHEN contains(lower(response), 'keep')   THEN 'keep'
           WHEN contains(lower(response), 'review') THEN 'review'
           ELSE 'unparsed'
       END AS verdict,
       trim(ltrim(substr(response, position('-' IN response) + 1), '- ')) AS reason,
       response AS reply
FROM judge_votes;

SELECT 'judge panel refreshed' AS phase,
       count(*) AS votes,
       count(DISTINCT judge) AS judges_reporting,
       count(*) FILTER (WHERE verdict = 'unparsed') AS unparsed_votes,
       array_to_string(list(DISTINCT verdict ORDER BY verdict), ', ') AS verdicts_seen
FROM judge_verdicts;
