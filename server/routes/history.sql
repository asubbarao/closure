-- routes/history.sql — timeline + undo/restore (append-only inverses).
-- GET  /api/cases/:id/history | POST /api/undo | POST /api/cases/:id/restore | GET /api/undo/status
-- Model: v_prior_states = lag(status) per suggestion over batches. Undo/restore JOIN it and APPEND.
-- undo_role tri-state: NULL=active forward, 'undo'=inverse batch, 'undone'=already inverted.
-- Params VARCHAR. Spine: documents; decision log via exports/decisions/*.json.

-- Single upstream: event_ts alias reused by every view/route below.
-- Composes v_src_decisions (sources.sql, the ONE decision-log reader; its
-- getenv fold is bind-safe inside CREATE ROUTE handlers).
CREATE OR REPLACE VIEW v_history_events AS
SELECT cast(d.suggestion_id AS VARCHAR) AS suggestion_id,
       cast(d.document_id AS VARCHAR) AS document_id,
       coalesce(cast(d.case_id AS VARCHAR), cast(doc.case_id AS VARCHAR)) AS case_id,
       cast(d.text AS VARCHAR) AS text,
       cast(d.status AS VARCHAR) AS status,
       cast(d.kind AS VARCHAR) AS kind,
       cast(d.actor AS VARCHAR) AS actor,
       cast(d.batch_label AS VARCHAR) AS batch_label,
       nullif(cast(d.undoes_batch_id AS VARCHAR), '') AS undoes_batch_id,
       cast(d.batch_id AS VARCHAR) AS batch_id,
       coalesce(try_cast(d.ts AS TIMESTAMP), TIMESTAMP '1970-01-01') AS event_ts
FROM v_src_decisions d
LEFT JOIN documents doc ON cast(doc.id AS VARCHAR) = cast(d.document_id AS VARCHAR)
WHERE d.kind IN ('decision', 'added')
  AND d.suggestion_id IS NOT NULL
  AND nullif(cast(d.batch_id AS VARCHAR), '') IS NOT NULL;

-- Prior state ledger: one row per (suggestion, batch); prior_status via lag.
CREATE OR REPLACE VIEW v_prior_states AS
SELECT suggestion_id, document_id, case_id, text, batch_id, event_ts, status,
       coalesce(lag(status) OVER (PARTITION BY suggestion_id ORDER BY event_ts, batch_id),
                'pending') AS prior_status
FROM (
    SELECT suggestion_id, any_value(document_id) AS document_id, any_value(case_id) AS case_id,
           any_value(text) AS text, batch_id, max(event_ts) AS event_ts,
           arg_max(status, event_ts) AS status
    FROM v_history_events GROUP BY suggestion_id, batch_id
);

-- Sole owner of v_decision_batches (removed duplicate from routes/decisions.sql).
-- Consumers: /api/cases/:id/history, /api/undo, /api/cases/:id/restore, /api/undo/status.
-- Purpose: one set-based GROUP BY over history events + undo graph join.
CREATE OR REPLACE VIEW v_decision_batches AS
WITH agg AS (
    SELECT batch_id, min(event_ts) AS ts, max(event_ts) AS ts_end,
           any_value(actor) AS actor, any_value(batch_label) AS label,
           count(*)::INTEGER AS decision_count,
           count(*) FILTER (WHERE status = 'accepted')::INTEGER AS accepted_count,
           count(*) FILTER (WHERE status = 'rejected')::INTEGER AS rejected_count,
           count(*) FILTER (WHERE status = 'pending')::INTEGER AS pending_count,
           count(*) FILTER (WHERE kind = 'added')::INTEGER AS added_count,
           max(undoes_batch_id) AS undoes_batch_id, max(case_id) AS case_id
    FROM v_history_events GROUP BY batch_id
),
undone_ids AS (
    SELECT DISTINCT undoes_batch_id AS batch_id FROM v_history_events
    WHERE undoes_batch_id IS NOT NULL
)
SELECT a.batch_id, a.ts, a.ts_end, a.actor, coalesce(nullif(a.label, ''), 'Batch') AS label,
       a.decision_count, a.accepted_count, a.rejected_count, a.pending_count, a.added_count,
       CASE WHEN a.undoes_batch_id IS NOT NULL THEN 'undo'
            WHEN u.batch_id IS NOT NULL THEN 'undone' END AS undo_role,
       a.undoes_batch_id IS NOT NULL AS is_undo, a.undoes_batch_id, a.case_id,
       u.batch_id IS NOT NULL AS undone
FROM agg a LEFT JOIN undone_ids u ON u.batch_id = a.batch_id;

CREATE OR REPLACE ROUTE api_case_history GET '/api/cases/:id/history' AS
SELECT batch_id, label, actor, ts, ts_end, decision_count, accepted_count, rejected_count,
       pending_count, added_count, is_undo, undoes_batch_id, undone, case_id
FROM v_decision_batches WHERE case_id = cast($id AS VARCHAR)
ORDER BY ts DESC, batch_id DESC;

CREATE OR REPLACE ROUTE api_undo POST '/api/undo'
  PARAM actor VARCHAR DEFAULT 'reviewer'
  PARAM case_id VARCHAR DEFAULT ''
AS
COPY (
    WITH target AS (
        SELECT batch_id, label FROM v_decision_batches
        WHERE undo_role IS NULL
          AND CASE WHEN nullif(nullif(cast($case_id AS VARCHAR), ''), '0') IS NULL THEN true
                   ELSE case_id = cast($case_id AS VARCHAR) END
        ORDER BY ts DESC, batch_id DESC LIMIT 1
    )
    SELECT 'decision' AS kind, p.suggestion_id, p.prior_status AS status,
           coalesce(cast($actor AS VARCHAR), 'reviewer') AS actor, 'undo' AS reason,
           (SELECT now()) AS ts, p.document_id, p.case_id, p.text,
           (SELECT cast(uuid() AS VARCHAR)) AS batch_id,
           'Undid: ' || coalesce(t.label, 'batch') AS batch_label,
           t.batch_id AS undoes_batch_id
    FROM v_prior_states p JOIN target t ON p.batch_id = t.batch_id
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

-- Restore: target_status = prior_status of earliest after-batch event per suggestion.
CREATE OR REPLACE ROUTE api_case_restore POST '/api/cases/:id/restore'
  PARAM batch_id VARCHAR
  PARAM actor VARCHAR DEFAULT 'reviewer'
AS
COPY (
    WITH checkpoint AS (
        SELECT batch_id, label, ts FROM v_decision_batches
        WHERE batch_id = cast($batch_id AS VARCHAR) AND case_id = cast($id AS VARCHAR) LIMIT 1
    ),
    after_batches AS (
        SELECT b.batch_id FROM v_decision_batches b
        JOIN checkpoint ck ON b.case_id = cast($id AS VARCHAR)
        WHERE b.undo_role IS NULL AND b.batch_id <> ck.batch_id
          AND CASE WHEN b.ts > ck.ts THEN true
                   WHEN b.ts = ck.ts AND b.batch_id > ck.batch_id THEN true
                   ELSE false END
    ),
    restored AS (
        SELECT suggestion_id,
               arg_min(document_id, (event_ts, batch_id)) AS document_id,
               arg_min(case_id, (event_ts, batch_id)) AS case_id,
               arg_min(text, (event_ts, batch_id)) AS text,
               arg_min(prior_status, (event_ts, batch_id)) AS target_status
        FROM v_prior_states WHERE batch_id IN (SELECT batch_id FROM after_batches)
        GROUP BY suggestion_id
    ),
    write_rows AS (
        SELECT suggestion_id, document_id, case_id, text, target_status,
               cast(NULL AS VARCHAR) AS undoes_batch_id FROM restored
        UNION ALL BY NAME
        SELECT r.suggestion_id, r.document_id, r.case_id, r.text, r.target_status, ab.batch_id
        FROM after_batches ab
        JOIN restored r ON r.suggestion_id = (SELECT min(suggestion_id) FROM restored)
    )
    SELECT 'decision' AS kind, w.suggestion_id, w.target_status AS status,
           coalesce(cast($actor AS VARCHAR), 'reviewer') AS actor, 'restore' AS reason,
           (SELECT now()) AS ts, w.document_id,
           coalesce(w.case_id, cast($id AS VARCHAR)) AS case_id, w.text,
           (SELECT cast(uuid() AS VARCHAR)) AS batch_id,
           'Restored to: ' || coalesce((SELECT label FROM checkpoint), 'checkpoint') AS batch_label,
           w.undoes_batch_id
    FROM write_rows w
    WHERE EXISTS (SELECT 1 FROM checkpoint) AND EXISTS (SELECT 1 FROM after_batches)
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_undo_status GET '/api/undo/status'
  PARAM case_id VARCHAR DEFAULT ''
AS
SELECT batch_id AS latest_batch_id, label AS latest_label, actor, ts,
       decision_count, undone, is_undo
FROM v_decision_batches
WHERE undo_role IS NULL
  AND CASE WHEN nullif(nullif(cast($case_id AS VARCHAR), ''), '0') IS NULL THEN true
           ELSE case_id = cast($case_id AS VARCHAR) END
ORDER BY ts DESC, batch_id DESC LIMIT 1;
