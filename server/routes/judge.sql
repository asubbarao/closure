-- routes/judge.sql — per-suggestion judge votes + panel summary JSON.

CREATE OR REPLACE ROUTE api_suggestion_judges GET '/api/suggestions/:id/judges' AS
SELECT
    j.suggestion_id,
    j.judge_id,
    j.judge_name,
    j.factor,
    j.verdict,
    j.score,
    j.reason,
    p.confidence AS panel_confidence,
    p.panel_signal,
    p.judge_count,
    p.redact_votes,
    p.keep_votes,
    p.unsure_votes,
    CASE
        WHEN p.panel_signal IN ('split', 'conflict') THEN 'flagged'
        WHEN p.confidence >= 90 THEN 'high'
        WHEN p.confidence >= 60 THEN 'review'
        ELSE 'flagged'
    END AS judge_band
FROM v_judge_votes j
JOIN v_judge_panel p ON cast(p.suggestion_id AS VARCHAR) = cast(j.suggestion_id AS VARCHAR)
WHERE cast(j.suggestion_id AS VARCHAR) = $id
ORDER BY j.judge_id;
