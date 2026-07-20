-- routes/history.sql — version timeline + Google-Docs-style undo/restore.
--
-- GET  /api/cases/:id/history          ordered batch list
-- POST /api/undo                       revert latest non-undone forward batch
-- POST /api/cases/:id/restore           restore to a batch (undo everything after)
-- GET  /api/undo/status                peek latest undoable batch (toasts)
--
-- All reverts APPEND inverse decision rows (audit trail never deletes).
-- Dependencies: v_decision_log, v_decision_batches, batch_key (decisions.sql), documents.
-- $actor coalesce fallbacks: explicit JSON null binds NULL past the PARAM DEFAULT.

-- ── Timeline: ordered batches for a case ──────────────────────────────────
CREATE OR REPLACE ROUTE api_case_history GET '/api/cases/:id/history' AS
SELECT
    batch_id,
    label,
    actor,
    ts,
    ts_end,
    decision_count,
    accepted_count,
    rejected_count,
    pending_count,
    added_count,
    is_undo,
    undoes_batch_id,
    undone,
    case_id
FROM v_decision_batches
WHERE case_id = $id::INTEGER
ORDER BY coalesce(ts, TIMESTAMP '1970-01-01') DESC, batch_id DESC;

-- ── Undo latest batch (walks back one forward action) ─────────────────────
CREATE OR REPLACE ROUTE api_undo POST '/api/undo'
  PARAM actor VARCHAR DEFAULT 'reviewer'
  PARAM case_id INTEGER DEFAULT 0
AS
COPY (
    WITH batches AS (
        SELECT *
        FROM v_decision_batches
        WHERE NOT undone
          AND NOT is_undo
          AND (
              $case_id::INTEGER = 0
              OR case_id = $case_id::INTEGER
          )
    ),
    target AS (
        SELECT *
        FROM batches
        ORDER BY coalesce(ts, TIMESTAMP '1970-01-01') DESC, batch_id DESC
        LIMIT 1
    ),
    batch_rows AS (
        SELECT
            d.*,
            batch_key(d.batch_id, d._file) AS bid
        FROM v_decision_log d
        JOIN target t ON batch_key(d.batch_id, d._file) = t.batch_id
        WHERE d.kind IN ('decision', 'added')
          AND d.suggestion_id IS NOT NULL
    ),
    -- One row per suggestion in the batch (latest log line if duplicated).
    batch_sugg AS (
        SELECT
            suggestion_id,
            document_id,
            case_id,
            text,
            kind,
            ts,
            _file,
            bid
        FROM batch_rows
        QUALIFY row_number() OVER (
            PARTITION BY suggestion_id
            ORDER BY coalesce(ts, TIMESTAMP '1970-01-01') DESC, _file DESC
        ) = 1
    ),
    priors AS (
        SELECT
            br.suggestion_id,
            br.document_id,
            br.case_id,
            br.text,
            coalesce(
                (
                    SELECT d.status
                    FROM v_decision_log d
                    WHERE d.kind = 'decision'
                      AND d.suggestion_id = br.suggestion_id
                      AND batch_key(d.batch_id, d._file) <> br.bid
                      AND (
                            coalesce(d.ts, TIMESTAMP '1970-01-01')
                            < coalesce(br.ts, TIMESTAMP '1970-01-01')
                          OR (
                                coalesce(d.ts, TIMESTAMP '1970-01-01')
                                = coalesce(br.ts, TIMESTAMP '1970-01-01')
                            AND d._file < br._file
                          )
                      )
                    ORDER BY
                        coalesce(d.ts, TIMESTAMP '1970-01-01') DESC,
                        d._file DESC
                    LIMIT 1
                ),
                'pending'
            ) AS prior_status
        FROM batch_sugg br
    ),
    meta AS (
        SELECT
            cast(uuid() AS VARCHAR) AS batch_id,
            now() AS ts,
            coalesce($actor::VARCHAR, 'reviewer') AS actor,
            (SELECT label FROM target) AS orig_label,
            (SELECT batch_id FROM target) AS undoes_batch_id
    )
    SELECT
        'decision' AS kind,
        p.suggestion_id,
        p.prior_status AS status,
        m.actor,
        'undo' AS reason,
        m.ts,
        p.document_id,
        coalesce(
            p.case_id,
            (SELECT d.case_id FROM documents d WHERE d.id = p.document_id)
        ) AS case_id,
        p.text,
        m.batch_id,
        'Undid: ' || coalesce(m.orig_label, 'batch') AS batch_label,
        m.undoes_batch_id AS undoes_batch_id
    FROM priors p
    CROSS JOIN meta m
    WHERE m.undoes_batch_id IS NOT NULL
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

-- ── Restore to a point: inverse every forward batch after batch_id ────────
CREATE OR REPLACE ROUTE api_case_restore POST '/api/cases/:id/restore'
  PARAM batch_id VARCHAR
  PARAM actor VARCHAR DEFAULT 'reviewer'
AS
COPY (
    WITH checkpoint AS (
        SELECT *
        FROM v_decision_batches
        WHERE batch_id = $batch_id::VARCHAR
          AND case_id = $id::INTEGER
        LIMIT 1
    ),
    after_batches AS (
        SELECT b.*
        FROM v_decision_batches b
        CROSS JOIN checkpoint ck
        WHERE b.case_id = $id::INTEGER
          AND NOT b.undone
          AND NOT b.is_undo
          AND b.batch_id <> ck.batch_id
          AND (
                coalesce(b.ts, TIMESTAMP '1970-01-01')
                > coalesce(ck.ts, TIMESTAMP '1970-01-01')
              OR (
                    coalesce(b.ts, TIMESTAMP '1970-01-01')
                    = coalesce(ck.ts, TIMESTAMP '1970-01-01')
                AND b.batch_id > ck.batch_id
              )
          )
    ),
    touched AS (
        SELECT
            d.suggestion_id,
            d.document_id,
            coalesce(d.case_id, doc.case_id) AS case_id,
            d.text
        FROM v_decision_log d
        LEFT JOIN documents doc ON doc.id = d.document_id
        JOIN after_batches ab
          ON batch_key(d.batch_id, d._file) = ab.batch_id
        WHERE d.kind IN ('decision', 'added')
          AND d.suggestion_id IS NOT NULL
        QUALIFY row_number() OVER (
            PARTITION BY d.suggestion_id
            ORDER BY coalesce(d.ts, TIMESTAMP '1970-01-01') DESC, d._file DESC
        ) = 1
    ),
    restored AS (
        SELECT
            t.suggestion_id,
            t.document_id,
            t.case_id,
            t.text,
            coalesce(
                (
                    SELECT d.status
                    FROM v_decision_log d
                    CROSS JOIN checkpoint ck
                    WHERE d.kind = 'decision'
                      AND d.suggestion_id = t.suggestion_id
                      AND batch_key(d.batch_id, d._file) NOT IN (
                          SELECT batch_id FROM after_batches
                      )
                      AND coalesce(d.ts, TIMESTAMP '1970-01-01')
                          <= coalesce(ck.ts_end, ck.ts, TIMESTAMP '2099-01-01')
                    ORDER BY
                        coalesce(d.ts, TIMESTAMP '1970-01-01') DESC,
                        d._file DESC
                    LIMIT 1
                ),
                'pending'
            ) AS target_status
        FROM touched t
    ),
    meta AS (
        SELECT
            cast(uuid() AS VARCHAR) AS batch_id,
            now() AS ts,
            coalesce($actor::VARCHAR, 'reviewer') AS actor,
            (SELECT label FROM checkpoint) AS pivot_label
    ),
    -- Status inverses for every touched suggestion.
    status_rows AS (
        SELECT
            r.suggestion_id,
            r.document_id,
            r.case_id,
            r.text,
            r.target_status,
            NULL::VARCHAR AS undoes_batch_id
        FROM restored r
    ),
    -- Marker rows: one per after-batch so history marks each as undone.
    marker_rows AS (
        SELECT
            (SELECT suggestion_id FROM restored LIMIT 1) AS suggestion_id,
            (SELECT document_id FROM restored LIMIT 1) AS document_id,
            (SELECT case_id FROM restored LIMIT 1) AS case_id,
            (SELECT text FROM restored LIMIT 1) AS text,
            (SELECT target_status FROM restored LIMIT 1) AS target_status,
            ab.batch_id AS undoes_batch_id
        FROM after_batches ab
        WHERE EXISTS (SELECT 1 FROM restored)
    ),
    all_rows AS (
        SELECT * FROM status_rows
        UNION ALL BY NAME
        SELECT * FROM marker_rows
    )
    SELECT
        'decision' AS kind,
        a.suggestion_id,
        a.target_status AS status,
        m.actor,
        'restore' AS reason,
        m.ts,
        a.document_id,
        coalesce(a.case_id, $id::INTEGER) AS case_id,
        a.text,
        m.batch_id,
        'Restored to: ' || coalesce(m.pivot_label, 'checkpoint') AS batch_label,
        a.undoes_batch_id
    FROM all_rows a
    CROSS JOIN meta m
    WHERE EXISTS (SELECT 1 FROM checkpoint)
      AND EXISTS (SELECT 1 FROM after_batches)
      AND a.suggestion_id IS NOT NULL
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

-- Peek latest undoable batch (for UI toasts / empty-state).
CREATE OR REPLACE ROUTE api_undo_status GET '/api/undo/status'
  PARAM case_id INTEGER DEFAULT 0
AS
SELECT
    batch_id AS latest_batch_id,
    label AS latest_label,
    actor,
    ts,
    decision_count,
    undone,
    is_undo
FROM v_decision_batches
WHERE NOT undone
  AND NOT is_undo
  AND (
      $case_id::INTEGER = 0
      OR case_id = $case_id::INTEGER
  )
ORDER BY coalesce(ts, TIMESTAMP '1970-01-01') DESC, batch_id DESC
LIMIT 1;
