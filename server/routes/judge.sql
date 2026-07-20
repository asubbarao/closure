-- routes/judge.sql — judge-ensemble confidence breakdown API.
--
-- Purpose: on-demand 2–3 judge votes for a suggestion (verdict/score/reason).
-- Dependencies: v_judge_votes, v_judge_panel (from server/judge.sql).
-- No mutations.

-- GET /api/suggestions/:id/judges
-- One row per judge vote, with panel summary columns repeated for convenience.
-- Column names become JSON keys for the review UI.
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
JOIN v_judge_panel p ON p.suggestion_id = j.suggestion_id
WHERE j.suggestion_id = $id::INTEGER
ORDER BY j.judge_id;
