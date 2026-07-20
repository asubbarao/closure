-- routes/decisions.sql — POST decision writes + batch fold (history/undo).
-- Contract §2 file columns; routes keep frozen paths. Ids are VARCHAR/uuid.
-- COPY TO rejects path expressions; use FILENAME_PATTERN '{uuid}' per shard.
--
-- The decision log has ONE reader: v_src_decisions (sources.sql, getenv fold —
-- bind-safe inside CREATE ROUTE). Latest-status is detect's v_latest_decision.
-- v_decision_batches lives in routes/history.sql only (history/undo/restore
-- are the consumers; this file only WRITES decisions and must not redefine it).

CREATE OR REPLACE ROUTE api_suggestion_decision POST '/api/suggestions/:id/decision'
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS COPY (
    SELECT 'decision' AS kind, t.suggestion_id, $status AS status,
           coalesce($actor, 'reviewer') AS actor, coalesce($reason, '') AS reason,
           now() AS ts, t.document_id, t.case_id, t.text,
           cast(uuid() AS VARCHAR) AS batch_id,
           CASE lower($status)
               WHEN 'accepted' THEN 'Accepted — ' || coalesce(t.text, '')
               WHEN 'rejected' THEN 'Rejected — ' || coalesce(t.text, '')
               WHEN 'pending'  THEN 'Restored to pending — ' || coalesce(t.text, '')
               ELSE 'Updated — ' || coalesce(t.text, '') END AS batch_label,
           cast(NULL AS VARCHAR) AS undoes_batch_id
    FROM (
        SELECT cast(s.id AS VARCHAR) AS suggestion_id, cast(s.document_id AS VARCHAR) AS document_id,
               d.case_id, s.text
        FROM suggestions s JOIN documents d ON d.id = s.document_id
        WHERE cast(s.id AS VARCHAR) = cast($id AS VARCHAR)
        UNION ALL BY NAME
        SELECT cast(suggestion_id AS VARCHAR), cast(document_id AS VARCHAR),
               coalesce(cast(case_id AS VARCHAR),
                   (SELECT case_id FROM documents WHERE cast(id AS VARCHAR) = cast(document_id AS VARCHAR))),
               cast(text AS VARCHAR)
        FROM v_src_decisions
        WHERE kind = 'added' AND cast(suggestion_id AS VARCHAR) = cast($id AS VARCHAR)
          AND NOT EXISTS (SELECT 1 FROM suggestions WHERE cast(id AS VARCHAR) = cast($id AS VARCHAR))
        LIMIT 1
    ) t
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_entity_decision POST '/api/entities/:id/decision'
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS COPY (
    WITH targets AS (
        SELECT cast(s.id AS VARCHAR) AS suggestion_id,
               cast(s.document_id AS VARCHAR) AS document_id,
               d.case_id, s.text,
               e.canonical_text
        FROM suggestions s
        JOIN documents d ON d.id = s.document_id
        JOIN entities e ON e.id = s.entity_id
        LEFT JOIN v_latest_decision ld ON ld.suggestion_id = cast(s.id AS VARCHAR)
        WHERE cast(s.entity_id AS VARCHAR) = cast($id AS VARCHAR)
          AND s.confidence >= 60 AND coalesce(ld.status, 'pending') = 'pending'
    ),
    meta AS (
        SELECT cast(uuid() AS VARCHAR) AS batch_id, now() AS ts,
               (SELECT count(*) FROM targets) AS n,
               (SELECT coalesce(max(canonical_text), max(text)) FROM targets) AS sample_text
    )
    SELECT 'decision' AS kind, t.suggestion_id, $status AS status,
           coalesce($actor, 'reviewer') AS actor, coalesce($reason, '') AS reason,
           m.ts, t.document_id, t.case_id, t.text, m.batch_id,
           CASE lower($status)
               WHEN 'accepted' THEN 'Accepted ' || cast(m.n AS VARCHAR) || ' — ' ||
                   coalesce(m.sample_text, '')
               WHEN 'rejected' THEN 'Rejected all ''' ||
                   coalesce(m.sample_text, '') ||
                   ''' ×' || cast(m.n AS VARCHAR)
               ELSE 'Updated ' || cast(m.n AS VARCHAR) || ' — ' ||
                   coalesce(m.sample_text, '')
           END AS batch_label, cast(NULL AS VARCHAR) AS undoes_batch_id
    FROM targets t JOIN meta m ON true
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_doc_band_decision POST '/api/documents/:id/band/:band/decision'
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS COPY (
    WITH targets AS (
        SELECT cast(s.id AS VARCHAR) AS suggestion_id,
               cast(s.document_id AS VARCHAR) AS document_id,
               d.case_id, s.text
        FROM suggestions s
        JOIN documents d ON d.id = s.document_id
        LEFT JOIN v_latest_decision ld ON ld.suggestion_id = cast(s.id AS VARCHAR)
        WHERE cast(s.document_id AS VARCHAR) = cast($id AS VARCHAR)
          AND CASE WHEN s.confidence >= 90 THEN 'high'
                   WHEN s.confidence >= 60 THEN 'review' ELSE 'flagged' END = $band
          AND $band <> 'flagged' AND coalesce(ld.status, 'pending') = 'pending'
    ),
    meta AS (
        SELECT cast(uuid() AS VARCHAR) AS batch_id, now() AS ts,
               (SELECT count(*) FROM targets) AS n
    )
    SELECT 'decision' AS kind, t.suggestion_id, $status AS status,
           coalesce($actor, 'reviewer') AS actor,
           coalesce($reason, 'bulk band ' || $band) AS reason,
           m.ts, t.document_id, t.case_id, t.text, m.batch_id,
           CASE lower($status)
               WHEN 'accepted' THEN 'Accepted all ''' || $band || ''' ×' || cast(m.n AS VARCHAR)
               WHEN 'rejected' THEN 'Rejected all ''' || $band || ''' ×' || cast(m.n AS VARCHAR)
               ELSE 'Updated all ''' || $band || ''' ×' || cast(m.n AS VARCHAR)
           END AS batch_label, cast(NULL AS VARCHAR) AS undoes_batch_id
    FROM targets t JOIN meta m ON true
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_suggestions_batch_decision POST '/api/suggestions/batch/decision'
  PARAM status VARCHAR PARAM ids VARCHAR
  PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS COPY (
    WITH targets AS (
        SELECT cast(s.id AS VARCHAR) AS suggestion_id,
               cast(s.document_id AS VARCHAR) AS document_id,
               d.case_id, s.text
        FROM suggestions s
        JOIN documents d ON d.id = s.document_id
        JOIN (SELECT DISTINCT trim(u) AS suggestion_id
              FROM unnest(string_split(coalesce($ids, ''), ',')) AS t(u)
              WHERE length(trim(u)) > 0) ids ON ids.suggestion_id = cast(s.id AS VARCHAR)
    ),
    meta AS (
        SELECT cast(uuid() AS VARCHAR) AS batch_id, now() AS ts,
               (SELECT count(*) FROM targets) AS n,
               (SELECT max(text) FROM targets) AS sample_text
    )
    SELECT 'decision' AS kind, t.suggestion_id, $status AS status,
           coalesce($actor, 'reviewer') AS actor, coalesce($reason, '') AS reason,
           m.ts, t.document_id, t.case_id, t.text, m.batch_id,
           CASE lower($status)
               WHEN 'accepted' THEN CASE WHEN m.n = 1
                   THEN 'Accepted — ' || coalesce(m.sample_text, '')
                   ELSE 'Accepted ' || cast(m.n AS VARCHAR) || ' — ' || coalesce(m.sample_text, '') END
               WHEN 'rejected' THEN CASE WHEN m.n = 1
                   THEN 'Rejected — ' || coalesce(m.sample_text, '')
                   ELSE 'Rejected ' || cast(m.n AS VARCHAR) || ' — ' || coalesce(m.sample_text, '') END
               WHEN 'pending' THEN CASE WHEN m.n = 1
                   THEN 'Restored to pending — ' || coalesce(m.sample_text, '')
                   ELSE 'Restored ' || cast(m.n AS VARCHAR) || ' to pending' END
               ELSE 'Updated ' || cast(m.n AS VARCHAR)
           END AS batch_label, cast(NULL AS VARCHAR) AS undoes_batch_id
    FROM targets t JOIN meta m ON true
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_document_add POST '/api/documents/:id/add'
  PARAM page INTEGER PARAM x0 DOUBLE PARAM y0 DOUBLE PARAM x1 DOUBLE PARAM y1 DOUBLE
  PARAM text VARCHAR PARAM kind VARCHAR DEFAULT 'MANUAL' PARAM scope VARCHAR DEFAULT 'one'
  PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT 'missed by AI'
AS COPY (
    SELECT 'added' AS kind, cast(uuid() AS VARCHAR) AS suggestion_id,
           cast($id AS VARCHAR) AS document_id, $page::INTEGER AS page_no,
           $x0::DOUBLE AS x0, $y0::DOUBLE AS y0, $x1::DOUBLE AS x1, $y1::DOUBLE AS y1,
           $text AS text, coalesce($text, '') AS context, 99 AS confidence,
           coalesce($kind, 'MANUAL') AS flag_tag, coalesce($reason, 'manual add') AS reason,
           cast(NULL AS VARCHAR) AS entity_id, 'manual' AS source, 'accepted' AS status,
           coalesce($actor, 'reviewer') AS actor, now() AS ts,
           (SELECT case_id FROM documents WHERE cast(id AS VARCHAR) = cast($id AS VARCHAR)) AS case_id,
           coalesce($scope, 'one') AS scope, cast(uuid() AS VARCHAR) AS batch_id,
           'Added missed — ' || coalesce($text, '') AS batch_label,
           cast(NULL AS VARCHAR) AS undoes_batch_id
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'add_{uuid}', OVERWRITE_OR_IGNORE true);
