-- routes/decisions.sql — POST decision writes + batch fold (history/undo).
-- Contract §2 file columns; routes keep frozen paths. Ids are VARCHAR/uuid.
-- CREATE ROUTE rebinds without SET VARIABLE → fold-safe getenv paths only.
-- COPY TO rejects path expressions; use FILENAME_PATTERN '{uuid}' per shard.

-- Auto-schema log + shard path as _file (no cast soup).
CREATE OR REPLACE VIEW v_decision_log AS
SELECT * RENAME (filename AS _file)
FROM read_json_auto(
    CASE WHEN getenv('CLOSURE_EXPORTS_DIR') IS NOT NULL
          AND length(getenv('CLOSURE_EXPORTS_DIR')) > 0
         THEN getenv('CLOSURE_EXPORTS_DIR') || '/decisions/*.json'
         ELSE 'exports/decisions/*.json' END,
    union_by_name := true, ignore_errors := true, filename := true)
WHERE kind IS DISTINCT FROM 'sentinel';

-- Latest status (route-bind safe; mirrors detect's v_latest_decision).
CREATE OR REPLACE VIEW v_route_latest_status AS
SELECT cast(suggestion_id AS VARCHAR) AS suggestion_id,
       arg_max(cast(status AS VARCHAR),
               coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01')) AS status
FROM v_decision_log
WHERE kind = 'decision' AND suggestion_id IS NOT NULL
GROUP BY cast(suggestion_id AS VARCHAR);

-- One GROUP BY; label = simple CASE over pre-agg facts (not COALESCE(CASE agg())).
CREATE OR REPLACE VIEW v_decision_batches AS
WITH raw AS (
    SELECT CASE WHEN batch_id IS NOT NULL AND length(cast(batch_id AS VARCHAR)) > 0
                THEN cast(batch_id AS VARCHAR) ELSE _file END AS batch_id,
           cast(batch_label AS VARCHAR) AS batch_label,
           cast(undoes_batch_id AS VARCHAR) AS undoes_batch_id,
           cast(kind AS VARCHAR) AS kind, cast(status AS VARCHAR) AS status,
           cast(actor AS VARCHAR) AS actor, try_cast(ts AS TIMESTAMP) AS ts,
           cast(text AS VARCHAR) AS text,
           coalesce(cast(d.case_id AS VARCHAR), doc.case_id) AS case_id
    FROM v_decision_log d
    LEFT JOIN documents doc ON cast(doc.id AS VARCHAR) = cast(d.document_id AS VARCHAR)
    WHERE d.kind IN ('decision', 'added')
),
agg AS (
    SELECT batch_id, min(ts) AS ts, max(ts) AS ts_end, any_value(actor) AS actor,
           nullif(any_value(batch_label), '') AS stored_label,
           count(*)::INTEGER AS decision_count,
           count(*) FILTER (WHERE status = 'accepted')::INTEGER AS accepted_count,
           count(*) FILTER (WHERE status = 'rejected')::INTEGER AS rejected_count,
           count(*) FILTER (WHERE status = 'pending')::INTEGER AS pending_count,
           count(*) FILTER (WHERE kind = 'added')::INTEGER AS added_count,
           bool_or(nullif(undoes_batch_id, '') IS NOT NULL) AS is_undo,
           max(undoes_batch_id) FILTER (WHERE nullif(undoes_batch_id, '') IS NOT NULL) AS undoes_batch_id,
           max(case_id) AS case_id, max(status) AS max_status, max(text) AS sample_text,
           max(text) FILTER (WHERE kind = 'added') AS added_text,
           bool_or(kind = 'added') AS has_added
    FROM raw GROUP BY batch_id
)
SELECT batch_id, ts, ts_end, actor,
       CASE
           WHEN stored_label IS NOT NULL THEN stored_label
           WHEN is_undo THEN 'Undid batch'
           WHEN has_added THEN 'Added missed — ' || coalesce(added_text, 'manual')
           WHEN decision_count = 1 THEN
               CASE max_status
                   WHEN 'accepted' THEN 'Accepted — ' || coalesce(sample_text, '')
                   WHEN 'rejected' THEN 'Rejected — ' || coalesce(sample_text, '')
                   WHEN 'pending'  THEN 'Restored to pending — ' || coalesce(sample_text, '')
                   ELSE 'Updated — ' || coalesce(sample_text, '') END
           WHEN max_status = 'accepted'
               THEN 'Accepted ' || cast(decision_count AS VARCHAR) || ' — ' || coalesce(sample_text, '')
           WHEN max_status = 'rejected'
               THEN 'Rejected ' || cast(decision_count AS VARCHAR) || ' — ' || coalesce(sample_text, '')
           ELSE 'Updated ' || cast(decision_count AS VARCHAR)
       END AS label,
       decision_count, accepted_count, rejected_count, pending_count, added_count,
       is_undo, undoes_batch_id, case_id,
       EXISTS (SELECT 1 FROM v_decision_log d
               WHERE nullif(cast(d.undoes_batch_id AS VARCHAR), '') = a.batch_id) AS undone
FROM agg a;

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
        FROM v_decision_log
        WHERE kind = 'added' AND cast(suggestion_id AS VARCHAR) = cast($id AS VARCHAR)
          AND NOT EXISTS (SELECT 1 FROM suggestions WHERE cast(id AS VARCHAR) = cast($id AS VARCHAR))
        LIMIT 1
    ) t
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_entity_decision POST '/api/entities/:id/decision'
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS COPY (
    SELECT 'decision' AS kind, cast(s.id AS VARCHAR) AS suggestion_id, $status AS status,
           coalesce($actor, 'reviewer') AS actor, coalesce($reason, '') AS reason,
           (SELECT now()) AS ts, cast(s.document_id AS VARCHAR) AS document_id, d.case_id, s.text,
           (SELECT cast(uuid() AS VARCHAR)) AS batch_id,
           CASE lower($status)
               WHEN 'accepted' THEN 'Accepted ' || cast(count(*) OVER () AS VARCHAR) || ' — ' ||
                   coalesce(max(e.canonical_text) OVER (), max(s.text) OVER (), '')
               WHEN 'rejected' THEN 'Rejected all ''' ||
                   coalesce(max(e.canonical_text) OVER (), max(s.text) OVER (), '') ||
                   ''' ×' || cast(count(*) OVER () AS VARCHAR)
               ELSE 'Updated ' || cast(count(*) OVER () AS VARCHAR) || ' — ' ||
                   coalesce(max(e.canonical_text) OVER (), max(s.text) OVER (), '')
           END AS batch_label, cast(NULL AS VARCHAR) AS undoes_batch_id
    FROM suggestions s
    JOIN documents d ON d.id = s.document_id
    JOIN entities e ON e.id = s.entity_id
    LEFT JOIN v_route_latest_status ld ON ld.suggestion_id = cast(s.id AS VARCHAR)
    WHERE cast(s.entity_id AS VARCHAR) = cast($id AS VARCHAR)
      AND s.confidence >= 60 AND coalesce(ld.status, 'pending') = 'pending'
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_doc_band_decision POST '/api/documents/:id/band/:band/decision'
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS COPY (
    SELECT 'decision' AS kind, cast(s.id AS VARCHAR) AS suggestion_id, $status AS status,
           coalesce($actor, 'reviewer') AS actor,
           coalesce($reason, 'bulk band ' || $band) AS reason,
           (SELECT now()) AS ts, cast(s.document_id AS VARCHAR) AS document_id, d.case_id, s.text,
           (SELECT cast(uuid() AS VARCHAR)) AS batch_id,
           CASE lower($status)
               WHEN 'accepted' THEN 'Accepted all ''' || $band || ''' ×' || cast(count(*) OVER () AS VARCHAR)
               WHEN 'rejected' THEN 'Rejected all ''' || $band || ''' ×' || cast(count(*) OVER () AS VARCHAR)
               ELSE 'Updated all ''' || $band || ''' ×' || cast(count(*) OVER () AS VARCHAR)
           END AS batch_label, cast(NULL AS VARCHAR) AS undoes_batch_id
    FROM suggestions s
    JOIN documents d ON d.id = s.document_id
    LEFT JOIN v_route_latest_status ld ON ld.suggestion_id = cast(s.id AS VARCHAR)
    WHERE cast(s.document_id AS VARCHAR) = cast($id AS VARCHAR)
      AND CASE WHEN s.confidence >= 90 THEN 'high'
               WHEN s.confidence >= 60 THEN 'review' ELSE 'flagged' END = $band
      AND $band <> 'flagged' AND coalesce(ld.status, 'pending') = 'pending'
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_suggestions_batch_decision POST '/api/suggestions/batch/decision'
  PARAM status VARCHAR PARAM ids VARCHAR
  PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS COPY (
    SELECT 'decision' AS kind, cast(s.id AS VARCHAR) AS suggestion_id, $status AS status,
           coalesce($actor, 'reviewer') AS actor, coalesce($reason, '') AS reason,
           (SELECT now()) AS ts, cast(s.document_id AS VARCHAR) AS document_id, d.case_id, s.text,
           (SELECT cast(uuid() AS VARCHAR)) AS batch_id,
           CASE lower($status)
               WHEN 'accepted' THEN CASE WHEN count(*) OVER () = 1
                   THEN 'Accepted — ' || coalesce(max(s.text) OVER (), '')
                   ELSE 'Accepted ' || cast(count(*) OVER () AS VARCHAR) || ' — ' || coalesce(max(s.text) OVER (), '') END
               WHEN 'rejected' THEN CASE WHEN count(*) OVER () = 1
                   THEN 'Rejected — ' || coalesce(max(s.text) OVER (), '')
                   ELSE 'Rejected ' || cast(count(*) OVER () AS VARCHAR) || ' — ' || coalesce(max(s.text) OVER (), '') END
               WHEN 'pending' THEN CASE WHEN count(*) OVER () = 1
                   THEN 'Restored to pending — ' || coalesce(max(s.text) OVER (), '')
                   ELSE 'Restored ' || cast(count(*) OVER () AS VARCHAR) || ' to pending' END
               ELSE 'Updated ' || cast(count(*) OVER () AS VARCHAR)
           END AS batch_label, cast(NULL AS VARCHAR) AS undoes_batch_id
    FROM suggestions s
    JOIN documents d ON d.id = s.document_id
    JOIN (SELECT DISTINCT trim(u) AS suggestion_id
          FROM unnest(string_split(coalesce($ids, ''), ',')) AS t(u)
          WHERE length(trim(u)) > 0) ids ON ids.suggestion_id = cast(s.id AS VARCHAR)
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
