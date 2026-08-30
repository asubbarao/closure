-- judge_worker.sql — ONE judge, its own process (see judge.sql for why). Config
-- arrives as environment: OPEN_PROMPT_* is read by the extension itself,
-- CLOSURE_JUDGE / _SPANS / _CONFIG are ours. Votes go to stdout; the dispatching
-- command redirects each judge's stdout to its own vote file.

INSTALL open_prompt FROM community; LOAD open_prompt;

-- The prompt is assembled from judges.json, not written here: role, one line per
-- rubric verdict, then the answer format. Adding or renaming a verdict is a row
-- in that file — judge.sql reads the same rubric to parse the replies back.
-- Role in system_prompt, data only in the user message: asked inline whether to
-- redact an SSN, small models refuse outright ("I can't fulfill this request").
COPY (
    WITH cfg AS (SELECT * FROM read_json_auto(getenv('CLOSURE_JUDGE_CONFIG'))),
    system AS (
        SELECT cfg.role || ' ' || string_agg(printf('%s if %s.', rule.verdict, rule.rule), ' ')
               || ' ' || cfg.instruction AS prompt
        FROM cfg, unnest(cfg.rubric) AS panel(rule)
        GROUP BY cfg.role, cfg.instruction
    )
    SELECT getenv('CLOSURE_JUDGE') AS judge, getenv('OPEN_PROMPT_MODEL_NAME') AS model_name,
           spn.kind, spn.text, spn.context, now()::TIMESTAMP AS ts,
           open_prompt(
             printf('Span: "%s"' || chr(10) || 'Detected type: %s' || chr(10) || 'Context: "%s"',
                    spn.text, spn.kind, spn.context),
             system_prompt := system.prompt
           ) AS response
    FROM read_json_auto(getenv('CLOSURE_JUDGE_SPANS')) spn, system
    WHERE spn.judge = getenv('CLOSURE_JUDGE')
) TO '/dev/stdout' (FORMAT json);
