-- judge_worker.sql — ONE judge, its own process (see judge.sql for why). Config
-- arrives as environment: OPEN_PROMPT_* is read by the extension itself,
-- CLOSURE_JUDGE / CLOSURE_JUDGE_SPANS are ours. Votes go to stdout; the
-- dispatching command redirects each judge's stdout to its own file.

INSTALL open_prompt FROM community; LOAD open_prompt;

-- Role in system_prompt, data only in the user message: asked inline whether to
-- redact an SSN, small models refuse outright ("I can't fulfill this request").
-- The reason is asked for and kept — a verdict with no reasoning isn't reviewable.
COPY (
    SELECT getenv('CLOSURE_JUDGE') AS judge, kind, text,
           open_prompt(
             printf('Span: "%s"' || chr(10) || 'Detected type: %s' || chr(10) || 'Context: "%s"',
                    text, kind, context),
             system_prompt := 'You are a redaction reviewer on a court-records team. You classify '
                 || 'already-detected spans so a human reviewer can triage them. Answer with exactly '
                 || 'one word: REDACT if the span is a private individual''s personal information, '
                 || 'KEEP if it is public record (an officer name and badge, a street, a case '
                 || 'citation, a court or agency), REVIEW if genuinely ambiguous. Then a dash '
                 || 'and one short sentence saying why. Format: VERDICT - reason.'
           ) AS response
    FROM read_json_auto(getenv('CLOSURE_JUDGE_SPANS'))
) TO '/dev/stdout' (FORMAT json);
