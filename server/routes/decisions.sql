-- routes/decisions.sql — POST mutations (decision log + manual add).
--
-- Purpose: append-only decision events under exports/decisions/*.json.
-- Every user action stamps one batch_id (+ derived human label) shared by all
-- rows written for that action. Runtime writes only (COPY). No pdf_* calls.
-- Dependencies: suggestions, v_suggestions, documents, entities.
--
-- Also extends v_decision_log with batch columns (seed's view lacks them).

-- ── Live decision log: batch_id / batch_label / undoes_batch_id ───────────
-- Replaces seed's view so history/undo can fold batches. Extra columns are
-- NULL on pre-versioning shards; batch_key(batch_id, _file) is the effective id.

-- Effective batch key: built-pipeline batch_id over legacy shards that predate
-- batch stamping (those rows carry a NULL or blank batch_id — fall back to the
-- shard file path, which is unique per pre-batch write). NULL-preserving CASE;
-- shared by v_decision_batches and routes/history.sql.
CREATE OR REPLACE MACRO batch_key(bid, shard_file) AS
    CASE WHEN bid IS NOT NULL AND length(bid) > 0 THEN bid ELSE shard_file END;

CREATE OR REPLACE VIEW v_decision_log AS
SELECT
    -- read_json(filename := true) virtual column — never NULL, no '' collapse.
    filename AS _file,
    cast(kind AS VARCHAR) AS kind,
    try_cast(suggestion_id AS BIGINT)::INTEGER AS suggestion_id,
    cast(status AS VARCHAR) AS status,
    cast(actor AS VARCHAR) AS actor,
    cast(reason AS VARCHAR) AS reason,
    try_cast(ts AS TIMESTAMP) AS ts,
    try_cast(document_id AS BIGINT)::INTEGER AS document_id,
    try_cast(page_no AS BIGINT)::INTEGER AS page_no,
    try_cast(x0 AS DOUBLE) AS x0,
    try_cast(y0 AS DOUBLE) AS y0,
    try_cast(x1 AS DOUBLE) AS x1,
    try_cast(y1 AS DOUBLE) AS y1,
    cast(text AS VARCHAR) AS text,
    cast(context AS VARCHAR) AS context,
    try_cast(confidence AS BIGINT)::INTEGER AS confidence,
    cast(flag_tag AS VARCHAR) AS flag_tag,
    cast(source AS VARCHAR) AS source,
    try_cast(entity_id AS BIGINT)::INTEGER AS entity_id,
    try_cast(case_id AS BIGINT)::INTEGER AS case_id,
    cast(batch_id AS VARCHAR) AS batch_id,
    cast(batch_label AS VARCHAR) AS batch_label,
    cast(undoes_batch_id AS VARCHAR) AS undoes_batch_id,
    cast(scope AS VARCHAR) AS scope
FROM read_json(
    -- app_config decisions_glob (fold-only position — macro, not subquery).
    cfg_decisions_glob(),
    format := 'auto',
    ignore_errors := true,
    union_by_name := true,
    filename := true,
    columns := {
        'kind': 'VARCHAR',
        'suggestion_id': 'BIGINT',
        'status': 'VARCHAR',
        'actor': 'VARCHAR',
        'reason': 'VARCHAR',
        'ts': 'VARCHAR',
        'document_id': 'BIGINT',
        'page_no': 'BIGINT',
        'x0': 'DOUBLE',
        'y0': 'DOUBLE',
        'x1': 'DOUBLE',
        'y1': 'DOUBLE',
        'text': 'VARCHAR',
        'context': 'VARCHAR',
        'confidence': 'BIGINT',
        'flag_tag': 'VARCHAR',
        'source': 'VARCHAR',
        'entity_id': 'BIGINT',
        'case_id': 'BIGINT',
        'batch_id': 'VARCHAR',
        'batch_label': 'VARCHAR',
        'undoes_batch_id': 'VARCHAR',
        'scope': 'VARCHAR'
    }
)
WHERE kind IS NULL OR kind <> 'sentinel';

-- Effective batch key (legacy shards use the file path — see batch_key above).
CREATE OR REPLACE VIEW v_decision_batches AS
WITH raw AS (
    SELECT
        batch_key(d.batch_id, d._file) AS batch_id,
        d.batch_label,
        d.undoes_batch_id,
        d.kind,
        d.status,
        d.actor,
        d.ts,
        d.suggestion_id,
        d.text,
        coalesce(d.case_id, doc.case_id) AS case_id,
        d.document_id
    FROM v_decision_log d
    LEFT JOIN documents doc ON doc.id = d.document_id
    WHERE d.kind IN ('decision', 'added')
),
agg AS (
    SELECT
        batch_id,
        min(ts) AS ts,
        max(ts) AS ts_end,
        any_value(actor) AS actor,
        -- Prefer an explicit label; else synthesize from contents. The nullif
        -- lets a blank stored label (legacy shards) yield the synthesized one;
        -- the coalesce('') tails below are display text only, never keys.
        coalesce(
            nullif(any_value(batch_label), ''),
            CASE
                WHEN bool_or(undoes_batch_id IS NOT NULL AND undoes_batch_id <> '')
                    THEN 'Undid batch'
                WHEN bool_or(kind = 'added')
                    THEN 'Added missed — ' || coalesce(
                        max(CASE WHEN kind = 'added' THEN text END),
                        'manual'
                    )
                WHEN count(*) = 1 AND max(status) = 'accepted'
                    THEN 'Accepted — ' || coalesce(max(text), '')
                WHEN count(*) = 1 AND max(status) = 'rejected'
                    THEN 'Rejected — ' || coalesce(max(text), '')
                WHEN count(*) = 1 AND max(status) = 'pending'
                    THEN 'Restored to pending — ' || coalesce(max(text), '')
                WHEN max(status) = 'accepted'
                    THEN 'Accepted ' || cast(count(*) AS VARCHAR) || ' — ' || coalesce(max(text), '')
                WHEN max(status) = 'rejected'
                    THEN 'Rejected ' || cast(count(*) AS VARCHAR) || ' — ' || coalesce(max(text), '')
                ELSE 'Updated ' || cast(count(*) AS VARCHAR)
            END
        ) AS label,
        count(*)::INTEGER AS decision_count,
        count(*) FILTER (WHERE status = 'accepted')::INTEGER AS accepted_count,
        count(*) FILTER (WHERE status = 'rejected')::INTEGER AS rejected_count,
        count(*) FILTER (WHERE status = 'pending')::INTEGER AS pending_count,
        count(*) FILTER (WHERE kind = 'added')::INTEGER AS added_count,
        bool_or(undoes_batch_id IS NOT NULL AND undoes_batch_id <> '') AS is_undo,
        max(undoes_batch_id) FILTER (
            WHERE undoes_batch_id IS NOT NULL AND undoes_batch_id <> ''
        ) AS undoes_batch_id,
        max(case_id) AS case_id
    FROM raw
    GROUP BY batch_id
)
SELECT
    a.batch_id,
    a.ts,
    a.ts_end,
    a.actor,
    a.label,
    a.decision_count,
    a.accepted_count,
    a.rejected_count,
    a.pending_count,
    a.added_count,
    a.is_undo,
    a.undoes_batch_id,
    a.case_id,
    -- A batch is undone when any later row references it via undoes_batch_id.
    EXISTS (
        SELECT 1
        FROM v_decision_log d
        WHERE d.undoes_batch_id IS NOT NULL
          AND d.undoes_batch_id <> ''
          AND d.undoes_batch_id = a.batch_id
    ) AS undone
FROM agg a;

-- ── Single suggestion decision ────────────────────────────────────────────
-- $param coalesce fallbacks throughout: quackapi binds an explicit JSON null
-- as NULL even when the PARAM has a DEFAULT — the coalesce restores it.
CREATE OR REPLACE ROUTE api_suggestion_decision POST '/api/suggestions/:id/decision'
  PARAM status VARCHAR
  PARAM actor VARCHAR DEFAULT 'reviewer'
  PARAM reason VARCHAR DEFAULT ''
AS
COPY (
    WITH meta AS (
        SELECT
            cast(uuid() AS VARCHAR) AS batch_id,
            now() AS ts,
            s.id AS suggestion_id,
            s.document_id,
            d.case_id,
            s.text,
            $status::VARCHAR AS status,
            coalesce($actor::VARCHAR, 'reviewer') AS actor,
            coalesce($reason::VARCHAR, '') AS reason,
            CASE lower($status::VARCHAR)
                WHEN 'accepted' THEN 'Accepted — ' || coalesce(s.text, '')
                WHEN 'rejected' THEN 'Rejected — ' || coalesce(s.text, '')
                WHEN 'pending'  THEN 'Restored to pending — ' || coalesce(s.text, '')
                ELSE 'Updated — ' || coalesce(s.text, '')
            END AS batch_label
        FROM suggestions s
        JOIN documents d ON d.id = s.document_id
        WHERE s.id = $id::INTEGER
        UNION ALL BY NAME
        -- Manual adds live only in the log; allow re-decide by id.
        SELECT
            cast(uuid() AS VARCHAR) AS batch_id,
            now() AS ts,
            s.id AS suggestion_id,
            s.document_id,
            d.case_id,
            s.text,
            $status::VARCHAR AS status,
            coalesce($actor::VARCHAR, 'reviewer') AS actor,
            coalesce($reason::VARCHAR, '') AS reason,
            CASE lower($status::VARCHAR)
                WHEN 'accepted' THEN 'Accepted — ' || coalesce(s.text, '')
                WHEN 'rejected' THEN 'Rejected — ' || coalesce(s.text, '')
                WHEN 'pending'  THEN 'Restored to pending — ' || coalesce(s.text, '')
                ELSE 'Updated — ' || coalesce(s.text, '')
            END AS batch_label
        FROM v_suggestions s
        JOIN documents d ON d.id = s.document_id
        WHERE s.id = $id::INTEGER
          AND s.source = 'manual'
          AND NOT EXISTS (SELECT 1 FROM suggestions x WHERE x.id = $id::INTEGER)
        LIMIT 1
    )
    SELECT
        'decision' AS kind,
        suggestion_id,
        status,
        actor,
        reason,
        ts,
        document_id,
        case_id,
        text,
        batch_id,
        batch_label,
        NULL::VARCHAR AS undoes_batch_id
    FROM meta
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

-- ── Entity fan-out (one batch, N rows; excludes flagged) ──────────────────
CREATE OR REPLACE ROUTE api_entity_decision POST '/api/entities/:id/decision'
  PARAM status VARCHAR
  PARAM actor VARCHAR DEFAULT 'reviewer'
  PARAM reason VARCHAR DEFAULT ''
AS
COPY (
    WITH targets AS (
        SELECT
            s.id AS suggestion_id,
            s.document_id,
            d.case_id,
            s.text,
            e.canonical_text AS entity_text
        FROM v_suggestions s
        JOIN documents d ON d.id = s.document_id
        JOIN entities e ON e.id = s.entity_id
        WHERE s.entity_id = $id::INTEGER
          AND s.band <> 'flagged'
          AND s.status = 'pending'
    ),
    meta AS (
        SELECT
            cast(uuid() AS VARCHAR) AS batch_id,
            now() AS ts,
            coalesce($actor::VARCHAR, 'reviewer') AS actor,
            coalesce($reason::VARCHAR, '') AS reason,
            $status::VARCHAR AS status,
            (SELECT count(*) FROM targets) AS n,
            (SELECT max(entity_text) FROM targets) AS entity_text,
            (SELECT max(text) FROM targets) AS sample_text
    )
    SELECT
        'decision' AS kind,
        t.suggestion_id,
        m.status,
        m.actor,
        m.reason,
        m.ts,
        t.document_id,
        t.case_id,
        t.text,
        m.batch_id,
        CASE lower(m.status)
            WHEN 'accepted' THEN
                'Accepted ' || cast(m.n AS VARCHAR) || ' — ' ||
                coalesce(m.entity_text, m.sample_text, '')
            WHEN 'rejected' THEN
                'Rejected all ''' || coalesce(m.entity_text, m.sample_text, '') ||
                ''' ×' || cast(m.n AS VARCHAR)
            ELSE
                'Updated ' || cast(m.n AS VARCHAR) || ' — ' ||
                coalesce(m.entity_text, m.sample_text, '')
        END AS batch_label,
        NULL::VARCHAR AS undoes_batch_id
    FROM targets t
    CROSS JOIN meta m
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

-- ── Bulk accept/reject a band within a document (flagged always excluded) ─
CREATE OR REPLACE ROUTE api_doc_band_decision POST '/api/documents/:id/band/:band/decision'
  PARAM status VARCHAR
  PARAM actor VARCHAR DEFAULT 'reviewer'
  PARAM reason VARCHAR DEFAULT ''
AS
COPY (
    WITH targets AS (
        SELECT
            s.id AS suggestion_id,
            s.document_id,
            d.case_id,
            s.text,
            s.band
        FROM v_suggestions s
        JOIN documents d ON d.id = s.document_id
        WHERE s.document_id = $id::INTEGER
          AND s.band = $band::VARCHAR
          AND s.band <> 'flagged'
          AND s.status = 'pending'
    ),
    meta AS (
        SELECT
            cast(uuid() AS VARCHAR) AS batch_id,
            now() AS ts,
            coalesce($actor::VARCHAR, 'reviewer') AS actor,
            coalesce($reason::VARCHAR, 'bulk band ' || $band::VARCHAR) AS reason,
            $status::VARCHAR AS status,
            $band::VARCHAR AS band,
            (SELECT count(*) FROM targets) AS n,
            (SELECT max(text) FROM targets) AS sample_text
    )
    SELECT
        'decision' AS kind,
        t.suggestion_id,
        m.status,
        m.actor,
        m.reason,
        m.ts,
        t.document_id,
        t.case_id,
        t.text,
        m.batch_id,
        CASE lower(m.status)
            WHEN 'accepted' THEN
                'Accepted all ''' || m.band || ''' ×' || cast(m.n AS VARCHAR)
            WHEN 'rejected' THEN
                'Rejected all ''' || m.band || ''' ×' || cast(m.n AS VARCHAR)
            ELSE
                'Updated all ''' || m.band || ''' ×' || cast(m.n AS VARCHAR)
        END AS batch_label,
        NULL::VARCHAR AS undoes_batch_id
    FROM targets t
    CROSS JOIN meta m
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

-- ── Multi-id batch (one user action → one batch; comma-separated ids) ─────
CREATE OR REPLACE ROUTE api_suggestions_batch_decision POST '/api/suggestions/batch/decision'
  PARAM status VARCHAR
  PARAM ids VARCHAR
  PARAM actor VARCHAR DEFAULT 'reviewer'
  PARAM reason VARCHAR DEFAULT ''
AS
COPY (
    WITH id_list AS (
        SELECT DISTINCT try_cast(trim(u) AS INTEGER) AS suggestion_id
        FROM unnest(string_split(coalesce($ids::VARCHAR, ''), ',')) AS t(u)
        WHERE try_cast(trim(u) AS INTEGER) IS NOT NULL
    ),
    targets AS (
        SELECT
            s.id AS suggestion_id,
            s.document_id,
            d.case_id,
            s.text
        FROM v_suggestions s
        JOIN documents d ON d.id = s.document_id
        JOIN id_list i ON i.suggestion_id = s.id
    ),
    meta AS (
        SELECT
            cast(uuid() AS VARCHAR) AS batch_id,
            now() AS ts,
            coalesce($actor::VARCHAR, 'reviewer') AS actor,
            coalesce($reason::VARCHAR, '') AS reason,
            $status::VARCHAR AS status,
            (SELECT count(*) FROM targets) AS n,
            (SELECT max(text) FROM targets) AS sample_text
    )
    SELECT
        'decision' AS kind,
        t.suggestion_id,
        m.status,
        m.actor,
        m.reason,
        m.ts,
        t.document_id,
        t.case_id,
        t.text,
        m.batch_id,
        CASE lower(m.status)
            WHEN 'accepted' THEN
                CASE WHEN m.n = 1 THEN 'Accepted — ' || coalesce(m.sample_text, '')
                     ELSE 'Accepted ' || cast(m.n AS VARCHAR) || ' — ' || coalesce(m.sample_text, '')
                END
            WHEN 'rejected' THEN
                CASE WHEN m.n = 1 THEN 'Rejected — ' || coalesce(m.sample_text, '')
                     ELSE 'Rejected ' || cast(m.n AS VARCHAR) || ' — ' || coalesce(m.sample_text, '')
                END
            WHEN 'pending' THEN
                CASE WHEN m.n = 1 THEN 'Restored to pending — ' || coalesce(m.sample_text, '')
                     ELSE 'Restored ' || cast(m.n AS VARCHAR) || ' to pending'
                END
            ELSE 'Updated ' || cast(m.n AS VARCHAR)
        END AS batch_label,
        NULL::VARCHAR AS undoes_batch_id
    FROM targets t
    CROSS JOIN meta m
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

-- ── Manual add (born accepted; one batch) ────────────────────────────────
-- P0-4: accept DOUBLE coords (drag posts floats; integer PARAM caused 422).
CREATE OR REPLACE ROUTE api_document_add POST '/api/documents/:id/add'
  PARAM page INTEGER
  PARAM x0 DOUBLE
  PARAM y0 DOUBLE
  PARAM x1 DOUBLE
  PARAM y1 DOUBLE
  PARAM text VARCHAR
  PARAM kind VARCHAR DEFAULT 'MANUAL'
  PARAM scope VARCHAR DEFAULT 'one'
  PARAM actor VARCHAR DEFAULT 'reviewer'
  PARAM reason VARCHAR DEFAULT 'missed by AI'
AS
COPY (
    WITH meta AS (
        SELECT
            cast(uuid() AS VARCHAR) AS batch_id,
            now() AS ts,
            (1000000 + abs(hash(
                cast($id AS VARCHAR) || ':' || cast($page AS VARCHAR) || ':' ||
                cast($x0 AS VARCHAR) || ':' || cast($y0 AS VARCHAR) || ':' ||
                cast($x1 AS VARCHAR) || ':' || cast($y1 AS VARCHAR) || ':' ||
                cast($text AS VARCHAR) || ':' || cast(uuid() AS VARCHAR)
            )) % 1000000000)::INTEGER AS suggestion_id,
            $id::INTEGER AS document_id,
            $page::INTEGER AS page_no,
            $x0::DOUBLE AS x0,
            $y0::DOUBLE AS y0,
            $x1::DOUBLE AS x1,
            $y1::DOUBLE AS y1,
            $text::VARCHAR AS text,
            coalesce($kind::VARCHAR, 'MANUAL') AS flag_tag,
            coalesce($reason::VARCHAR, 'manual add') AS reason,
            coalesce($actor::VARCHAR, 'reviewer') AS actor,
            (SELECT case_id FROM documents WHERE id = $id::INTEGER) AS case_id,
            coalesce($scope::VARCHAR, 'one') AS scope,
            'Added missed — ' || coalesce($text::VARCHAR, '') AS batch_label
    )
    SELECT
        'added' AS kind,
        suggestion_id,
        document_id,
        page_no,
        x0, y0, x1, y1,
        text,
        coalesce(text, '') AS context,
        99 AS confidence,
        flag_tag,
        reason,
        NULL::INTEGER AS entity_id,
        'manual' AS source,
        'accepted' AS status,
        actor,
        ts,
        case_id,
        scope,
        batch_id,
        batch_label,
        NULL::VARCHAR AS undoes_batch_id
    FROM meta
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'add_{uuid}', OVERWRITE_OR_IGNORE true);
