-- judge.sql — the LLM judge panel, run live from core.sql once suggestions exist.
-- The ONLY file that calls out. Provider = server/config/judges.json: an endpoint,
-- a token, and the models. Ollama by default; any OpenAI-compatible URL + key works.

LOAD shellfs;

CREATE OR REPLACE TABLE judges AS
SELECT cfg.api_url, cfg.api_token, unnest(cfg.judges, recursive := true)
FROM read_json_auto('pathvariable:judges_path') cfg;

-- The verdict vocabulary, same rows the worker builds its prompt from: one place
-- names REDACT/KEEP/REVIEW and what each means. Nothing here hardcodes them.
CREATE OR REPLACE TABLE judge_rubric AS
SELECT unnest(rubric, recursive := true) FROM read_json_auto('pathvariable:judges_path');

-- Judge unit = the distinct decision, not the 17k occurrences: "John Smith" is
-- judged once and the verdict joins back down to every mark.
CREATE OR REPLACE TABLE judge_spans AS
SELECT kind, text, any_value(context) AS context
FROM suggestions WHERE text IS NOT NULL GROUP BY kind, text;

SELECT content AS judge_workdir
FROM read_text('mkdir -p .tmp/judge/votes && touch .tmp/judge/votes/_seed.json |');

-- The votes are an append-only file log: every round writes new files, nothing is
-- rewritten. That log is what makes the panel incremental — a rebuild judges only
-- what no judge has seen, so adding a document costs its own spans and nothing
-- else, and a second build costs nothing. Explicit columns so an empty log reads.
CREATE OR REPLACE TABLE judge_log AS
SELECT * FROM read_json('.tmp/judge/votes/*.json',
    columns := {judge: 'VARCHAR', model_name: 'VARCHAR', kind: 'VARCHAR',
                text: 'VARCHAR', context: 'VARCHAR', response: 'VARCHAR', ts: 'TIMESTAMP'});

-- Pending = every (span, judge) pair with no usable vote. A call that errored or
-- was refused names none of the three verdicts and so never counts as judged — it
-- comes back next round. CLOSURE_JUDGE_RERUN makes the anti-join match nothing:
-- the whole panel votes again (new model, new prompt, new corpus) and the fresh
-- votes win by ts. That is the rerun; `make rejudge` is just this flag set.
CREATE OR REPLACE TABLE judge_pending AS
SELECT jdg.judge, spn.kind, spn.text, spn.context
FROM judge_spans spn CROSS JOIN judges jdg
ANTI JOIN judge_log log
   ON log.judge = jdg.judge AND log.kind = spn.kind AND log.text = spn.text
  AND EXISTS (SELECT 1 FROM judge_rubric rub WHERE contains(lower(log.response), lower(rub.verdict)))
  AND getenv('CLOSURE_JUDGE_RERUN') = '';

COPY judge_pending TO '.tmp/judge/pending.json' (FORMAT json, ARRAY true);

-- The round to run, as data: only judges that actually have spans waiting.
COPY (
    SELECT jdg.judge, jdg.model_name, jdg.api_url, jdg.api_token,
           getvariable('judges_path') AS config, uuid()::VARCHAR AS round, count(*) AS n_spans
    FROM judge_pending pnd JOIN judges jdg USING (judge) GROUP BY ALL
) TO '.tmp/judge/work.json' (FORMAT json, ARRAY true);

-- Self-dispatch. open_prompt's model is session-global — model_name := is accepted
-- then ignored (a bogus model still answers) — so a judge cannot be a column, and
-- an in-process httpserver shares the session. It becomes a built command instead:
-- DuckDB prints one env-carrying command per judge in the round, the shell runs
-- them together, each writes its own vote file. Nothing pending ⇒ nothing printed
-- ⇒ no calls at all.
SELECT content AS judge_dispatch
FROM read_text($$"$(scripts/duckdb-bin.sh)" -no-init -noheader -list -c "
        COPY (
            SELECT printf('OPEN_PROMPT_API_URL=%s OPEN_PROMPT_API_TOKEN=%s OPEN_PROMPT_API_TIMEOUT=120 '
                       || 'OPEN_PROMPT_MODEL_NAME=%s CLOSURE_JUDGE=%s '
                       || 'CLOSURE_JUDGE_SPANS=.tmp/judge/pending.json CLOSURE_JUDGE_CONFIG=%s '
                       || '\"\$DUCKDB\" -no-init -c \".read server/judge_worker.sql\" > .tmp/judge/votes/%s.json &',
                          api_url, api_token, model_name, judge, config, round) AS command
            FROM read_json('.tmp/judge/work.json',
                 columns := {judge: 'VARCHAR', model_name: 'VARCHAR', api_url: 'VARCHAR', api_token: 'VARCHAR',
                             config: 'VARCHAR', round: 'VARCHAR', n_spans: 'BIGINT'})
            UNION ALL SELECT 'wait'
        ) TO '/dev/stdout' (FORMAT csv, HEADER false, QUOTE '')" \
    | DUCKDB="$(scripts/duckdb-bin.sh)" bash |$$);

CREATE OR REPLACE TABLE judge_votes AS
SELECT * FROM read_json('.tmp/judge/votes/*.json',
    columns := {judge: 'VARCHAR', model_name: 'VARCHAR', kind: 'VARCHAR',
                text: 'VARCHAR', context: 'VARCHAR', response: 'VARCHAR', ts: 'TIMESTAMP'})
QUALIFY row_number() OVER (PARTITION BY judge, kind, text ORDER BY ts DESC) = 1;

-- Raw-first capture: one llm_calls row per vote THIS round made — the rounds
-- already in the log were captured when they ran.
INSERT INTO llm_calls BY NAME
SELECT uuid()::VARCHAR AS id, vote.ts, (SELECT run_id FROM detect_run) AS run_id,
       'judge:' || vote.judge AS model_key,
       json_object('kind', vote.kind, 'text', vote.text, 'model', vote.model_name) AS request,
       json_object('response', vote.response) AS raw
FROM judge_votes vote
ANTI JOIN judge_log log
   ON log.judge = vote.judge AND log.kind = vote.kind
  AND log.text = vote.text AND log.ts = vote.ts;

-- One row per judge per span: verdict, reason, and the reply it came out of. The
-- verdict is a JOIN to the rubric — the first rubric word the reply names wins —
-- so a reply naming none of them matches nothing and is dropped, NOT read as
-- review: a refusal must never impersonate a judge agreeing with two others.
CREATE OR REPLACE TABLE judge_verdicts AS
SELECT vote.kind, vote.text, vote.judge, vote.model_name,
       lower(rub.verdict) AS verdict,
       trim(ltrim(substr(vote.response, position('-' IN vote.response) + 1), '- ')) AS reason,
       vote.response AS reply
FROM judge_votes vote
JOIN judge_rubric rub ON contains(lower(vote.response), lower(rub.verdict))
QUALIFY row_number() OVER (PARTITION BY vote.judge, vote.kind, vote.text
                           ORDER BY position(lower(rub.verdict) IN lower(vote.response))) = 1;

SELECT 'judge panel' AS phase,
       (SELECT count(*) FROM judge_pending) AS spans_judged_this_run,
       count(*) AS votes,
       count(DISTINCT judge) AS judges_reporting,
       (SELECT count(*) FROM judge_votes) - count(*) AS votes_unusable,
       array_to_string(list(DISTINCT verdict ORDER BY verdict), ', ') AS verdicts_seen
FROM judge_verdicts;

-- Panel → suggestions (lives here so core stays detect+product).
CREATE OR REPLACE TABLE span_panel AS
WITH tally AS (
    SELECT kind, text, verdict, count(*) AS n_votes
    FROM judge_verdicts GROUP BY kind, text, verdict
),
agg AS (
    SELECT kind, text, max(n_votes) AS agreement, sum(n_votes) AS n_judges,
           arg_max(verdict, n_votes) AS majority,
           array_to_string(list(verdict || '×' || n_votes::VARCHAR ORDER BY n_votes DESC), ', ') AS votes
    FROM tally GROUP BY kind, text
)
SELECT kind, text, agreement, votes,
       CASE WHEN agreement >= 2 THEN majority ELSE 'conflict' END AS panel,
       printf('%d of %d judges → %s', agreement, n_judges,
              CASE WHEN agreement >= 2 THEN majority ELSE 'conflict' END) AS judge_reason
FROM agg;

UPDATE suggestions sug
SET judge_panel = pan.panel, judge_agreement = pan.agreement,
    judge_votes = pan.votes, judge_reason = pan.judge_reason
FROM span_panel pan
WHERE pan.kind = sug.kind AND pan.text = sug.text;

UPDATE suggestions SET judge_reason = reason WHERE judge_reason IS NULL;

UPDATE suggestions SET band = CASE
    WHEN flag_tag = 'false_positive' THEN 'flagged'
    WHEN judge_panel = 'keep' THEN 'flagged'
    WHEN judge_panel = 'conflict' THEN 'flagged'
    WHEN judge_panel = 'redact' AND judge_agreement >= 3 THEN 'high'
    WHEN judge_panel = 'redact' THEN 'review'
    WHEN judge_panel = 'review' THEN 'review'
    WHEN confidence >= 90 THEN 'high'
    WHEN confidence >= 60 THEN 'review'
    ELSE 'flagged'
END;
