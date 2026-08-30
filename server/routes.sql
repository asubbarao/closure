-- routes.sql — GET = SELECT * product. POST = insert decision rows. No reason laundry.

CREATE OR REPLACE VIEW v_route_get AS
SELECT * FROM (VALUES
    ('page_home', 'GET', '/',
     $$SELECT html FROM v_pages WHERE path = '/cases/' || (SELECT min(id) FROM cases)$$),
    ('page_case', 'GET', '/cases/:id',
     $$SELECT html FROM v_pages WHERE path = '/cases/' || $id$$),
    ('page_stream', 'GET', '/cases/:id/stream',
     $$SELECT html FROM v_pages WHERE path = '/cases/' || $id || '/stream'$$),
    ('page_flagged', 'GET', '/cases/:id/flagged',
     $$SELECT html FROM v_pages WHERE path = '/cases/' || $id || '/flagged'$$),
    ('page_remainder', 'GET', '/cases/:id/remainder',
     $$SELECT html FROM v_pages WHERE path = '/cases/' || $id || '/remainder'$$),
    ('page_audit', 'GET', '/cases/:id/audit',
     $$SELECT html FROM v_pages WHERE path = '/cases/' || $id || '/audit'$$),
    ('page_document', 'GET', '/documents/:id',
     $$SELECT html FROM v_review_page WHERE document_id = $id AND page_no = 1$$),
    ('page_document_page', 'GET', '/documents/:id/pages/:page',
     $$SELECT html FROM v_review_page WHERE document_id = $id
       AND page_no = least(greatest(try_cast($page AS INTEGER), 1),
                           (SELECT page_count FROM documents WHERE id = $id))$$),
    ('case_nav', 'GET', '/api/cases/:id/nav',
     $$SELECT href, text FROM v_nav WHERE case_id = $id ORDER BY href$$),
    ('case_suggestions', 'GET', '/api/cases/:id/suggestions',
     $$SELECT * FROM v_suggestions WHERE case_id = $id
       ORDER BY document_id, page_no, id$$),
    ('case_entities', 'GET', '/api/cases/:id/entities',
     $$SELECT * FROM entities WHERE case_id = $id ORDER BY kind, canonical_text$$),
    ('suggestion_context', 'GET', '/api/suggestions/:id/context',
     $$SELECT * FROM v_suggestion_line_context WHERE suggestion_id = $id ORDER BY line_number$$),
    ('suggestion_judges', 'GET', '/api/suggestions/:id/judges',
     $$SELECT * FROM v_suggestion_judge_votes WHERE suggestion_id = $id ORDER BY judge$$),
    ('case_audit_api', 'GET', '/api/cases/:id/audit',
     $$SELECT * FROM v_audit WHERE case_id = $id ORDER BY ts DESC$$),
    ('case_flagged', 'GET', '/api/cases/:id/flagged',
     $$SELECT * FROM v_flagged_pending WHERE case_id = $id ORDER BY filename, page_no, id$$),
    ('case_remainder', 'GET', '/api/cases/:id/remainder',
     $$SELECT * FROM v_remainder_pending WHERE case_id = $id ORDER BY filename, page_no, id$$),
    ('case_batches', 'GET', '/api/cases/:id/batches',
     $$SELECT * FROM v_decision_batches WHERE case_id = $id ORDER BY ts DESC$$),
    ('catalog_list', 'GET', '/api/catalog',
     $$SELECT * FROM v_cols ORDER BY relation$$),
    ('catalog_one', 'GET', '/api/catalog/:relation',
     $$SELECT * FROM v_cols WHERE relation = $relation$$),
    ('catalog_rows', 'GET', '/api/catalog/:relation/rows',
     $$SELECT rows.* FROM query(format('SELECT * FROM {}', $relation)) rows
       JOIN v_cols allow ON allow.relation = $relation$$),
    ('catalog_summary', 'GET', '/api/catalog/:relation/summary',
     $$SELECT rows.* FROM query(format('FROM (SUMMARIZE {})', $relation)) rows
       JOIN v_cols allow ON allow.relation = $relation$$),
    ('ops_hostfs', 'GET', '/api/ops/hostfs',
     $$SELECT * FROM v_hostfs ORDER BY root, path$$),
    ('ops_zips', 'GET', '/api/ops/zips',
     $$SELECT * FROM v_zips ORDER BY root, zip_path$$),
    ('ops_shell', 'GET', '/api/ops/shell',
     $$SELECT * FROM v_shell_patterns ORDER BY kind$$),
    ('ops_cache', 'GET', '/api/ops/cache', $$SELECT * FROM v_http_cache$$),
    ('ops_cache_status', 'GET', '/api/ops/cache/status',
     $$SELECT * FROM v_http_cache_status ORDER BY original_remote_path, start_offset$$),
    ('ops_cache_access', 'GET', '/api/ops/cache/access',
     $$SELECT * FROM v_http_cache_access$$),
    ('ops_hosts', 'GET', '/api/ops/hosts',
     $$SELECT * FROM v_url_hosts ORDER BY hostname$$),
    ('ops_templates', 'GET', '/api/ops/templates',
     $$SELECT * FROM v_src_template_links ORDER BY template, line_number$$),
    ('ops_semantic', 'GET', '/api/ops/semantic',
     $$SELECT * FROM v_src_semantic_yaml$$)
) AS t(name, method, path, body);

COPY (
    SELECT format('CREATE OR REPLACE ROUTE {} {} ''{}'' AS {};',
        name, method, path,
        replace(replace(replace(body, chr(10), ' '), chr(13), ' '), '  ', ' '))
    FROM v_route_get ORDER BY name
) TO '.tmp/routes_get.sql' (FORMAT CSV, HEADER false, QUOTE '', ESCAPE '');
.read .tmp/routes_get.sql

-- POSTs: grain = v_decide_targets. reason = $reason (DEFAULT ''). label = status + scope.

CREATE OR REPLACE ROUTE suggestion_decide POST '/api/suggestions/:id/decision'
  STATUS 201
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS INSERT INTO decisions BY NAME
SELECT 'decision' AS kind, tgt.suggestion_id, $status AS status, $actor AS actor, $reason AS reason,
       now() AS ts, tgt.document_id, tgt.case_id, tgt.text,
       (SELECT uuid()::VARCHAR) AS batch_id, $status AS batch_label,
       NULL::VARCHAR AS undoes_batch_id,
       tgt.page_no, tgt.bbox, tgt.context, tgt.confidence, tgt.flag_tag, tgt.entity_id,
       tgt.source, 'one' AS scope
FROM v_decide_targets tgt WHERE tgt.suggestion_id = $id
RETURNING suggestion_id, status;

CREATE OR REPLACE ROUTE entity_decide POST '/api/entities/:id/decision'
  STATUS 201
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS INSERT INTO decisions BY NAME
SELECT 'decision' AS kind, tgt.suggestion_id, $status AS status, $actor AS actor, $reason AS reason,
       now() AS ts, tgt.document_id, tgt.case_id, tgt.text,
       (SELECT uuid()::VARCHAR) AS batch_id, $status || ' entity' AS batch_label,
       NULL::VARCHAR AS undoes_batch_id,
       tgt.page_no, tgt.bbox, tgt.context, tgt.confidence, tgt.flag_tag, tgt.entity_id,
       tgt.source, 'entity' AS scope
FROM v_decide_targets tgt
WHERE tgt.entity_id = $id AND tgt.status = 'pending' AND tgt.band <> 'flagged'
RETURNING suggestion_id, status;

CREATE OR REPLACE ROUTE document_band_decide POST '/api/documents/:id/bands/:band/decision'
  STATUS 201
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS INSERT INTO decisions BY NAME
SELECT 'decision' AS kind, tgt.suggestion_id, $status AS status, $actor AS actor, $reason AS reason,
       now() AS ts, tgt.document_id, tgt.case_id, tgt.text,
       (SELECT uuid()::VARCHAR) AS batch_id, $status || ' band ' || $band AS batch_label,
       NULL::VARCHAR AS undoes_batch_id,
       tgt.page_no, tgt.bbox, tgt.context, tgt.confidence, tgt.flag_tag, tgt.entity_id,
       tgt.source, 'band' AS scope
FROM v_decide_targets tgt
WHERE tgt.document_id = $id AND tgt.status = 'pending' AND tgt.band = $band AND $band <> 'flagged'
RETURNING suggestion_id, status;

CREATE OR REPLACE ROUTE case_accept_high POST '/api/cases/:id/accept-high'
  STATUS 201
  PARAM threshold INTEGER DEFAULT 90 GE 0 LE 100
  PARAM actor VARCHAR DEFAULT 'reviewer'
AS INSERT INTO decisions BY NAME
SELECT 'decision' AS kind, tgt.suggestion_id, 'accepted' AS status, $actor AS actor,
       'accept high ≥' || $threshold::VARCHAR AS reason,
       now() AS ts, tgt.document_id, tgt.case_id, tgt.text,
       (SELECT uuid()::VARCHAR) AS batch_id, 'Accepted high' AS batch_label,
       NULL::VARCHAR AS undoes_batch_id,
       tgt.page_no, tgt.bbox, tgt.context, tgt.confidence, tgt.flag_tag, tgt.entity_id,
       tgt.source, 'case_high' AS scope
FROM v_decide_targets tgt
WHERE tgt.case_id = $id AND tgt.status = 'pending' AND tgt.confidence >= $threshold
  AND tgt.band <> 'flagged' AND tgt.flag_tag IS DISTINCT FROM 'false_positive'
RETURNING suggestion_id, status;

CREATE OR REPLACE ROUTE case_flagged_decide POST '/api/cases/:id/flagged/decision'
  STATUS 201
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS INSERT INTO decisions BY NAME
SELECT 'decision' AS kind, tgt.suggestion_id, $status AS status, $actor AS actor, $reason AS reason,
       now() AS ts, tgt.document_id, tgt.case_id, tgt.text,
       (SELECT uuid()::VARCHAR) AS batch_id, $status || ' case flagged' AS batch_label,
       NULL::VARCHAR AS undoes_batch_id,
       tgt.page_no, tgt.bbox, tgt.context, tgt.confidence, tgt.flag_tag, tgt.entity_id,
       tgt.source, 'case_flagged' AS scope
FROM v_decide_targets tgt
WHERE tgt.case_id = $id AND tgt.status = 'pending' AND tgt.band = 'flagged'
RETURNING suggestion_id, status;

CREATE OR REPLACE ROUTE document_flagged_decide POST '/api/documents/:id/flagged/decision'
  STATUS 201
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS INSERT INTO decisions BY NAME
SELECT 'decision' AS kind, tgt.suggestion_id, $status AS status, $actor AS actor, $reason AS reason,
       now() AS ts, tgt.document_id, tgt.case_id, tgt.text,
       (SELECT uuid()::VARCHAR) AS batch_id, $status || ' doc flagged' AS batch_label,
       NULL::VARCHAR AS undoes_batch_id,
       tgt.page_no, tgt.bbox, tgt.context, tgt.confidence, tgt.flag_tag, tgt.entity_id,
       tgt.source, 'doc_flagged' AS scope
FROM v_decide_targets tgt
WHERE tgt.document_id = $id AND tgt.status = 'pending' AND tgt.band = 'flagged'
RETURNING suggestion_id, status;

CREATE OR REPLACE ROUTE case_remainder_decide POST '/api/cases/:id/remainder/decision'
  STATUS 201
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS INSERT INTO decisions BY NAME
SELECT 'decision' AS kind, tgt.suggestion_id, $status AS status, $actor AS actor, $reason AS reason,
       now() AS ts, tgt.document_id, tgt.case_id, tgt.text,
       (SELECT uuid()::VARCHAR) AS batch_id, $status || ' remainder' AS batch_label,
       NULL::VARCHAR AS undoes_batch_id,
       tgt.page_no, tgt.bbox, tgt.context, tgt.confidence, tgt.flag_tag, tgt.entity_id,
       tgt.source, 'case_remainder' AS scope
FROM v_decide_targets tgt
WHERE tgt.case_id = $id AND tgt.status = 'pending' AND tgt.detector_key = 'detector:remainder'
RETURNING suggestion_id, status;

CREATE OR REPLACE ROUTE document_mark_add POST '/api/documents/:id/marks'
  STATUS 201
  PARAM page INTEGER PARAM x0 DOUBLE PARAM y0 DOUBLE PARAM x1 DOUBLE PARAM y1 DOUBLE
  PARAM text VARCHAR PARAM kind VARCHAR DEFAULT 'MANUAL'
  PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT 'missed by AI'
AS INSERT INTO suggestions BY NAME
WITH new_mark AS (SELECT uuid()::VARCHAR AS id),
     doc AS (SELECT case_id, filename FROM documents WHERE id = $id),
     pag AS (SELECT scale FROM pages WHERE document_id = $id AND page_no = $page::INTEGER)
SELECT new_mark.id AS id, $id AS document_id, doc.case_id, doc.filename,
       $page::INTEGER AS page_no, ($x0, $y0, $x1, $y1)::bbox AS bbox,
       (round($x0 * pag.scale, 2), round($y0 * pag.scale, 2),
        round(($x1 - $x0) * pag.scale, 2),
        round(greatest($y1 - $y0, 0) * pag.scale, 2))::screen_box AS screen,
       $text AS text, lower($text) AS text_lower, $text AS context, lower($text) AS context_lower,
       99 AS confidence, $kind AS flag_tag, $reason AS reason,
       NULL::VARCHAR AS entity_id, NULL::VARCHAR AS entity_text,
       $kind AS kind, lower($kind) AS kind_lower,
       'manual' AS source, now() AS created_at, NULL::INTEGER AS line_no,
       NULL::VARCHAR AS source_run_id, 'manual' AS detector_key,
       format('{:x}', rapidhash(lower($text) || chr(31) || $kind)) AS group_key,
       NULL::VARCHAR AS judge_panel, NULL::INTEGER AS judge_agreement,
       NULL::VARCHAR AS judge_votes, NULL::VARCHAR AS judge_reason, 'high' AS band
FROM new_mark CROSS JOIN doc CROSS JOIN pag
RETURNING id AS suggestion_id, 'accepted' AS status;

CREATE OR REPLACE ROUTE case_undo POST '/api/cases/:id/undo'
  STATUS 201
  PARAM actor VARCHAR DEFAULT 'reviewer'
AS INSERT INTO decisions BY NAME
WITH last_batch AS (
    SELECT arg_max(batch_id, ts) AS batch_id, arg_max(label, ts) AS label
    FROM v_decision_batches WHERE undoes_batch_id IS NULL AND case_id = $id
),
new_batch AS (SELECT uuid()::VARCHAR AS batch_id)
SELECT 'decision' AS kind, evt.suggestion_id,
       lag(evt.status, 1, 'pending') OVER (PARTITION BY evt.suggestion_id ORDER BY evt.event_ts) AS status,
       $actor AS actor, 'undo' AS reason, now() AS ts,
       evt.document_id, evt.case_id, evt.text,
       (SELECT batch_id FROM new_batch) AS batch_id,
       'Undo' AS batch_label,
       bat.batch_id AS undoes_batch_id
FROM v_history_events evt
JOIN last_batch bat ON evt.batch_id = bat.batch_id
WHERE evt.kind = 'decision'
RETURNING suggestion_id, status;

CREATE OR REPLACE ROUTE case_export POST '/api/cases/:id/export' AS
SELECT plan.document_id, plan.out_path, plan.boxes, true AS redacted
FROM v_export_plans plan
WHERE plan.case_id = $id AND NOT plan.blocked AND len(plan.boxes) > 0
  AND exists (FROM pdf_redact(plan.source_path, plan.out_path, plan.boxes));
