-- routes.sql — HTTP over model relations.
-- Target: a TS controller count, not a REST cosmogony.
-- Reads = SELECT * FROM view. Writes = COPY into the decision log.

-- ── pages (HTML) ──────────────────────────────────────────────────────────

CREATE OR REPLACE ROUTE home GET '/' AS
SELECT tera_render((SELECT content FROM app_templates WHERE name = 'case'),
    {'case': case_obj, 'stats': stats, 'documents': documents,
     'entities': entities, 'audit': audit}::JSON) AS html
FROM v_case_page WHERE case_id = (SELECT min(case_id) FROM v_case_page);

CREATE OR REPLACE ROUTE case_dash GET '/cases/:id' AS
SELECT tera_render((SELECT content FROM app_templates WHERE name = 'case'),
    {'case': case_obj, 'stats': stats, 'documents': documents,
     'entities': entities, 'audit': audit}::JSON) AS html
FROM v_case_page WHERE case_id = $id;

CREATE OR REPLACE ROUTE case_audit_html GET '/cases/:id/audit' AS
SELECT tera_render((SELECT content FROM app_templates WHERE name = 'audit'), {
    'case': (SELECT struct_pack(id := id, case_no := case_no, title := title)
             FROM cases WHERE id = $id),
    'events': (SELECT coalesce(list(struct_pack(
        ts_short := strftime(a.ts, '%Y-%m-%d %H:%M:%S'),
        action := a.action, actor := a.actor,
        target := coalesce(a.target, ''), reason := coalesce(a.reason, '')
    ) ORDER BY a.ts DESC), []) FROM v_audit a WHERE a.case_id = $id)
}::JSON) AS html;

CREATE OR REPLACE ROUTE document_review GET '/documents/:id' AS
SELECT html FROM v_review_page WHERE document_id = $id AND page_no = 1;

CREATE OR REPLACE ROUTE document_page GET '/documents/:id/pages/:page' AS
SELECT html FROM v_review_page
WHERE document_id = $id
  AND page_no = least(greatest(try_cast($page AS INTEGER), 1),
                      (SELECT page_count FROM documents WHERE id = $id));

-- Static shells (one template each)
CREATE OR REPLACE ROUTE reject_shell GET '/ui/reject' AS
SELECT content AS html FROM app_templates WHERE name = 'reject';
CREATE OR REPLACE ROUTE add_shell GET '/ui/add-missed' AS
SELECT content AS html FROM app_templates WHERE name = 'add_missed';
CREATE OR REPLACE ROUTE bulk_shell GET '/ui/bulk' AS
SELECT content AS html FROM app_templates WHERE name = 'bulk';
CREATE OR REPLACE ROUTE ui_missed_panel GET '/ui/missed'
  PARAM doc VARCHAR DEFAULT '' PARAM case_id VARCHAR DEFAULT '' PARAM page INTEGER DEFAULT 1
AS
SELECT tera_render((SELECT content FROM app_templates WHERE name = 'remainder_panel'),
    {'doc_id': coalesce($doc, ''), 'case_id': coalesce($case_id, ''),
     'page_no': coalesce($page, 1), 'standalone': true}::JSON) AS html;
CREATE OR REPLACE ROUTE ui_geo_panel GET '/ui/geo' AS
SELECT content AS html FROM app_templates WHERE name = 'geo_panel';

-- ── reads ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE ROUTE api_case_documents GET '/api/cases/:id/documents' AS
SELECT * FROM v_doc_ui WHERE case_id = $id ORDER BY filename;

CREATE OR REPLACE ROUTE api_doc_suggestions GET '/api/documents/:id/suggestions' AS
SELECT * FROM v_suggestions WHERE document_id = $id
ORDER BY page_no, line_no, id;

CREATE OR REPLACE ROUTE api_case_suggestions GET '/api/cases/:id/suggestions' AS
SELECT s.*, d.filename
FROM v_suggestions s JOIN documents d ON d.id = s.document_id
WHERE d.case_id = $id
ORDER BY s.document_id, s.page_no, s.line_no, s.id;

CREATE OR REPLACE ROUTE api_doc_lines GET '/api/documents/:id/lines'
  PARAM page INTEGER DEFAULT 0
AS
SELECT l.line_no, l.page_no, l.line_text AS text, l.x0, l.y0, l.x1, l.y1,
       count(s.id)::INTEGER AS hit_count,
       count(CASE WHEN s.status = 'pending' THEN 1 END)::INTEGER AS pending_count
FROM v_lines l
LEFT JOIN v_suggestions s
  ON s.document_id = l.document_id AND s.page_no = l.page_no AND s.line_no = l.line_no
WHERE l.document_id = $id AND ($page = 0 OR l.page_no = $page)
GROUP BY ALL
ORDER BY l.page_no, l.line_no;

CREATE OR REPLACE ROUTE api_case_audit GET '/api/cases/:id/audit' AS
SELECT * FROM v_audit WHERE case_id = $id ORDER BY ts DESC;

CREATE OR REPLACE ROUTE api_case_history GET '/api/cases/:id/history' AS
SELECT * FROM v_decision_batches WHERE case_id = $id ORDER BY ts DESC;

CREATE OR REPLACE ROUTE api_doc_missed GET '/api/documents/:id/missed' AS
SELECT r.*, d.filename
FROM residual_pii_hits r JOIN documents d ON d.id = r.document_id
WHERE r.document_id = $id ORDER BY r.page, r.id;

CREATE OR REPLACE ROUTE api_case_missed GET '/api/cases/:id/missed' AS
SELECT r.*, d.filename
FROM residual_pii_hits r JOIN documents d ON d.id = r.document_id
WHERE d.case_id = $id ORDER BY d.filename, r.page, r.id;

CREATE OR REPLACE ROUTE api_suggestion_judges GET '/api/suggestions/:id/judges' AS
SELECT * FROM v_judge_panel WHERE suggestion_id = $id;

CREATE OR REPLACE ROUTE api_case_provenance GET '/api/cases/:id/provenance' AS
SELECT * FROM v_case_provenance WHERE case_id = $id;

CREATE OR REPLACE ROUTE api_case_addresses GET '/api/cases/:id/addresses' AS
SELECT * FROM entity_address_canon WHERE case_id = $id;

CREATE OR REPLACE ROUTE api_case_export_plan GET '/api/cases/:id/export_plan' AS
SELECT blocked, export_sql FROM v_export_plans WHERE case_id = $id;

CREATE OR REPLACE ROUTE api_stats GET '/api/stats' AS
SELECT table_name, estimated_size AS n
FROM duckdb_tables()
WHERE NOT internal AND schema_name = 'main'
  AND table_name IN ('cases', 'documents', 'pages', 'words', 'entities', 'suggestions')
ORDER BY table_name;

CREATE OR REPLACE ROUTE api_search GET '/api/search' AS
WITH q AS (
    SELECT lower(trim(unaccent($q))) AS qn, $case AS case_id
),
hits AS (
    SELECT l.document_id, d.filename, l.page_no, l.line_no, l.line_text AS text,
           l.x0, l.y0, l.x1, l.y1,
           -- partial_ratio, not ratio: the query is a name/number inside a long
           -- line, so whole-string similarity would score every hit near zero.
           rapidfuzz_partial_ratio(l.line_norm, q.qn) AS score
    FROM v_lines l
    JOIN documents d ON d.id = l.document_id
    JOIN q ON d.case_id = q.case_id
    WHERE q.qn <> '' AND len(l.word_list) > 0
)
SELECT coalesce(list(h ORDER BY score DESC), []) AS matches,
       count(*)::INTEGER AS count,
       count(*) FILTER (WHERE score = 100)::INTEGER AS exact_count,
       count(*) FILTER (WHERE score < 100 AND score >= 90)::INTEGER AS fuzzy_count
FROM hits h WHERE score >= 90;

-- ── triage ────────────────────────────────────────────────────────────────

CREATE OR REPLACE ROUTE api_case_triage GET '/api/cases/:id/triage'
  PARAM threshold INTEGER DEFAULT 90 GE 0 LE 100
AS
SELECT
    CASE WHEN s.status = 'pending' AND s.confidence >= $threshold
              AND s.band <> 'flagged' AND coalesce(s.flag_tag, '') <> 'false_positive'
         THEN 'auto'
         WHEN s.status = 'pending' THEN 'residual' ELSE 'done' END AS funnel,
    s.status, s.band, count(*)::BIGINT AS n
FROM v_suggestions s JOIN documents d ON d.id = s.document_id
WHERE d.case_id = $id
GROUP BY ALL ORDER BY funnel, status, band;

CREATE OR REPLACE ROUTE api_case_triage_groups GET '/api/cases/:id/triage/groups'
  PARAM threshold INTEGER DEFAULT 90 GE 0 LE 100
  PARAM scope VARCHAR DEFAULT 'case' PARAM doc_id VARCHAR DEFAULT ''
AS
SELECT s.group_key,
       any_value(coalesce(nullif(s.entity_text, ''), s.text, '(unknown)')) AS group_label,
       any_value(s.kind) AS kind, any_value(s.entity_id) AS entity_id,
       count(*)::BIGINT AS n,
       count(DISTINCT s.document_id)::BIGINT AS doc_count,
       count(DISTINCT s.page_no)::BIGINT AS page_count,
       min(s.confidence)::INTEGER AS min_conf, max(s.confidence)::INTEGER AS max_conf,
       bool_or(s.band = 'flagged') AS has_flagged,
       bool_or(coalesce(s.flag_tag, '') = 'false_positive') AS has_fp,
       any_value(s.reason) AS sample_reason,
       string_agg(s.id, ',' ORDER BY s.document_id, s.page_no, s.id) AS ids,
       list(struct_pack(
           id := s.id, document_id := s.document_id, filename := d.filename,
           page_no := s.page_no, line_no := s.line_no, text := s.text, context := s.context,
           confidence := s.confidence, band := s.band
       ) ORDER BY s.document_id, s.page_no, s.id) AS instances,
       CASE WHEN bool_or(s.band = 'flagged') THEN 'flagged'
            WHEN bool_or(s.band = 'review') THEN 'review' ELSE 'high' END AS group_band
FROM v_suggestions s JOIN documents d ON d.id = s.document_id
WHERE d.case_id = $id AND s.status = 'pending'
  AND NOT (s.confidence >= $threshold AND s.band <> 'flagged'
           AND coalesce(s.flag_tag, '') <> 'false_positive')
  AND (lower($scope) <> 'doc' OR $doc_id IN ('', '0') OR s.document_id = $doc_id)
GROUP BY s.group_key
ORDER BY group_band DESC, n DESC, group_label;

-- ── writes (append-only decision log) ─────────────────────────────────────

CREATE OR REPLACE ROUTE api_suggestion_decision POST '/api/suggestions/:id/decision'
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS COPY (
    SELECT 'decision' AS kind, s.id AS suggestion_id, $status AS status,
           $actor AS actor, $reason AS reason, now() AS ts,
           s.document_id, d.case_id, s.text, uuid()::VARCHAR AS batch_id,
           $status || ' — ' || coalesce(s.text, '') AS batch_label,
           NULL::VARCHAR AS undoes_batch_id
    FROM v_suggestions s JOIN documents d ON d.id = s.document_id WHERE s.id = $id
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_entity_decision POST '/api/entities/:id/decision'
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS COPY (
    SELECT 'decision' AS kind, s.id AS suggestion_id, $status AS status,
           $actor AS actor, $reason AS reason, now() AS ts,
           s.document_id, d.case_id, s.text, uuid()::VARCHAR AS batch_id,
           $status || ' entity — ' || coalesce(s.entity_text, s.text, '') AS batch_label,
           NULL::VARCHAR AS undoes_batch_id
    FROM v_suggestions s JOIN documents d ON d.id = s.document_id
    WHERE s.entity_id = $id AND s.status = 'pending' AND s.band <> 'flagged'
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_doc_band_decision POST '/api/documents/:id/band/:band/decision'
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS COPY (
    SELECT 'decision' AS kind, s.id AS suggestion_id, $status AS status,
           $actor AS actor, coalesce(nullif($reason, ''), 'bulk band ' || $band) AS reason,
           now() AS ts, s.document_id, d.case_id, s.text, uuid()::VARCHAR AS batch_id,
           $status || ' band ' || $band AS batch_label, NULL::VARCHAR AS undoes_batch_id
    FROM v_suggestions s JOIN documents d ON d.id = s.document_id
    WHERE s.document_id = $id AND s.status = 'pending' AND s.band = $band AND $band <> 'flagged'
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_suggestions_batch_decision POST '/api/suggestions/batch/decision'
  PARAM status VARCHAR PARAM ids VARCHAR
  PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS COPY (
    SELECT 'decision' AS kind, s.id AS suggestion_id, $status AS status,
           $actor AS actor, $reason AS reason, now() AS ts,
           s.document_id, d.case_id, s.text, uuid()::VARCHAR AS batch_id,
           $status || ' — ' || coalesce(s.text, '') AS batch_label,
           NULL::VARCHAR AS undoes_batch_id
    FROM v_suggestions s JOIN documents d ON d.id = s.document_id
    WHERE s.id IN (SELECT trim(u) FROM unnest(string_split($ids, ',')) t(u) WHERE trim(u) <> '')
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_case_triage_accept_high POST '/api/cases/:id/triage/accept-high'
  PARAM threshold INTEGER DEFAULT 90 GE 0 LE 100
  PARAM actor VARCHAR DEFAULT 'reviewer'
  PARAM reason VARCHAR DEFAULT 'triage high-confidence auto-pass'
AS COPY (
    SELECT 'decision' AS kind, s.id AS suggestion_id, 'accepted' AS status,
           $actor AS actor, $reason AS reason, now() AS ts,
           s.document_id, d.case_id, s.text, uuid()::VARCHAR AS batch_id,
           'Accepted high ≥' || $threshold::VARCHAR AS batch_label,
           NULL::VARCHAR AS undoes_batch_id
    FROM v_suggestions s JOIN documents d ON d.id = s.document_id
    WHERE d.case_id = $id AND s.status = 'pending' AND s.confidence >= $threshold
      AND s.band <> 'flagged' AND coalesce(s.flag_tag, '') <> 'false_positive'
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_case_triage_group_decision POST '/api/cases/:id/triage/group/decision'
  PARAM group_key VARCHAR PARAM status VARCHAR
  PARAM exclude_ids VARCHAR DEFAULT ''
  PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
  PARAM threshold INTEGER DEFAULT 90 GE 0 LE 100
AS COPY (
    SELECT 'decision' AS kind, s.id AS suggestion_id, lower(trim($status)) AS status,
           $actor AS actor, $reason AS reason, now() AS ts,
           s.document_id, d.case_id, s.text, uuid()::VARCHAR AS batch_id,
           'Group ' || lower(trim($status)) || ' — ' || trim($group_key) AS batch_label,
           NULL::VARCHAR AS undoes_batch_id
    FROM v_suggestions s JOIN documents d ON d.id = s.document_id
    WHERE d.case_id = $id AND s.status = 'pending' AND s.group_key = trim($group_key)
      AND lower(trim($status)) IN ('accepted', 'rejected', 'pending')
      AND NOT (s.confidence >= $threshold AND s.band <> 'flagged'
               AND coalesce(s.flag_tag, '') <> 'false_positive')
      AND ($exclude_ids = '' OR s.id NOT IN (
            SELECT trim(x) FROM unnest(string_split($exclude_ids, ',')) u(x) WHERE trim(x) <> ''))
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

-- Only remaining edge pack: form params → bbox on the audit event.
CREATE OR REPLACE ROUTE api_document_add POST '/api/documents/:id/add'
  PARAM page INTEGER PARAM x0 DOUBLE PARAM y0 DOUBLE PARAM x1 DOUBLE PARAM y1 DOUBLE
  PARAM text VARCHAR PARAM kind VARCHAR DEFAULT 'MANUAL' PARAM scope VARCHAR DEFAULT 'one'
  PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT 'missed by AI'
AS COPY (
    SELECT 'added' AS kind, uuid()::VARCHAR AS suggestion_id, $id AS document_id,
           $page::INTEGER AS page_no,
           struct_pack(x0 := $x0::DOUBLE, y0 := $y0::DOUBLE,
                       x1 := $x1::DOUBLE, y1 := $y1::DOUBLE) AS bbox,
           $text AS text, coalesce($text, '') AS context,
           99 AS confidence, $kind AS flag_tag, coalesce($reason, 'manual add') AS reason,
           NULL::VARCHAR AS entity_id, 'manual' AS source, 'accepted' AS status,
           $actor AS actor, now() AS ts,
           (SELECT case_id FROM documents WHERE id = $id) AS case_id,
           $scope AS scope, uuid()::VARCHAR AS batch_id,
           'Added missed — ' || coalesce($text, '') AS batch_label,
           NULL::VARCHAR AS undoes_batch_id
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'add_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_undo POST '/api/undo'
  PARAM actor VARCHAR DEFAULT 'reviewer' PARAM case_id VARCHAR DEFAULT ''
AS COPY (
    WITH target AS (
        SELECT arg_max(batch_id, ts) AS batch_id, arg_max(label, ts) AS label
        FROM v_decision_batches
        WHERE undoes_batch_id IS NULL
          AND ($case_id IN ('', '0') OR case_id = $case_id)
    )
    SELECT 'decision' AS kind, h.suggestion_id,
           coalesce(lag(h.status) OVER (PARTITION BY h.suggestion_id ORDER BY h.event_ts), 'pending') AS status,
           $actor AS actor, 'undo' AS reason, now() AS ts,
           h.document_id, h.case_id, h.text, uuid()::VARCHAR AS batch_id,
           'Undo — ' || coalesce(t.label, t.batch_id) AS batch_label,
           t.batch_id AS undoes_batch_id
    FROM v_history_events h
    JOIN target t ON h.batch_id = t.batch_id
    WHERE h.kind = 'decision'
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_undo_status GET '/api/undo/status'
  PARAM case_id VARCHAR DEFAULT ''
AS
SELECT arg_max(batch_id, ts) AS latest_batch_id,
       arg_max(label, ts) AS latest_label,
       arg_max(actor, ts) AS actor,
       max(ts) AS ts,
       arg_max(decision_count, ts) AS decision_count,
       arg_max(undone, ts) AS undone,
       arg_max(is_undo, ts) AS is_undo
FROM v_decision_batches
WHERE undoes_batch_id IS NULL
  AND ($case_id IN ('', '0') OR case_id = $case_id);

CREATE OR REPLACE ROUTE api_case_restore POST '/api/cases/:id/restore'
  PARAM batch_id VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer'
AS COPY (
    SELECT 'decision' AS kind, suggestion_id, 'pending' AS status,
           $actor AS actor, 'restore' AS reason, now() AS ts,
           document_id, case_id, text, uuid()::VARCHAR AS batch_id,
           'Restore after ' || $batch_id AS batch_label,
           $batch_id AS undoes_batch_id
    FROM v_history_events
    WHERE case_id = $id AND event_ts > (
        SELECT ts FROM v_decision_batches WHERE batch_id = $batch_id
    ) AND kind = 'decision'
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_case_export POST '/api/cases/:id/export'
  PARAM sql VARCHAR DEFAULT ''
AS
SELECT document_id, pages
FROM query(CASE WHEN starts_with($sql, 'SELECT ') AND position(';' IN $sql) = 0
                THEN $sql
                ELSE error('export requires SELECT from /export_plan') END);
