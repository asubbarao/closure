-- routes.sql — HTTP surface (single contract).
--
-- Layers:
--   pages     HTML SSR          /  /cases/…  /documents/…
--   product   FOIA resources    /api/cases|documents|suggestions|entities/…
--   catalog   allowlisted data  /api/catalog/…
--   ops       machine/debug     /api/ops/…
--
-- Flow: views own data/html → v_route_get (GETs) → install DDL
--       POSTs stay explicit (PARAM + INSERT).
-- OpenAPI: /docs · /openapi.json · /redoc

-- ═══════════════════════════════════════════════════════════════════════════
-- GET catalog (only place GET paths are defined)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW v_route_get AS
SELECT * FROM (VALUES
    -- ── pages (html column) ──────────────────────────────────────────────
    ('page_home',     'GET', '/',
     $$SELECT html FROM v_case_html WHERE case_id = (SELECT min(case_id) FROM v_case_html)$$),
    ('page_case',     'GET', '/cases/:id',
     $$SELECT html FROM v_case_html WHERE case_id = $id$$),
    ('page_stream',   'GET', '/cases/:id/stream',
     $$SELECT html FROM v_stream_page WHERE case_id = $id$$),
    ('page_audit',    'GET', '/cases/:id/audit',
     $$SELECT html FROM v_audit_page WHERE case_id = $id$$),
    ('page_document', 'GET', '/documents/:id',
     $$SELECT html FROM v_review_page WHERE document_id = $id AND page_no = 1$$),
    ('page_document_page', 'GET', '/documents/:id/pages/:page',
     $$SELECT html FROM v_review_page
       WHERE document_id = $id
         AND page_no = least(greatest(try_cast($page AS INTEGER), 1),
                             (SELECT page_count FROM documents WHERE id = $id))$$),

    -- ── product reads ────────────────────────────────────────────────────
    ('case_nav',      'GET', '/api/cases/:id/nav',
     $$SELECT href, text FROM v_nav WHERE case_id = $id ORDER BY href$$),
    -- Grain rows for the case (product). Profiles: /api/catalog/…/summary.
    -- Semantic slice (dims only): FROM semantic_view('closure', dimensions := […]).
    ('case_suggestions', 'GET', '/api/cases/:id/suggestions',
     $$SELECT sug.*
       FROM v_suggestions sug
       JOIN documents doc ON doc.id = sug.document_id
       WHERE doc.case_id = $id
       ORDER BY sug.document_id, sug.page_no, sug.id$$),
    ('case_entities', 'GET', '/api/cases/:id/entities',
     $$SELECT id, case_id, canonical_text, kind, kind_label, mono
       FROM entities WHERE case_id = $id
       ORDER BY kind, canonical_text$$),
    ('suggestion_context', 'GET', '/api/suggestions/:id/context',
     $$SELECT suggestion_id, document_id, page_no, hit_line, line_number, line_text, dist
       FROM v_suggestion_line_context
       WHERE suggestion_id = $id ORDER BY line_number$$),
    ('suggestion_judges', 'GET', '/api/suggestions/:id/judges',
     $$SELECT jdg.suggestion_id, jdg.vote_pattern, jdg.vote_context, jdg.vote_prior, jdg.panel, jdg.judge_reason,
              sug.band, sug.status, sug.text, sug.kind
       FROM suggestion_judges jdg
       JOIN v_suggestions sug ON sug.id = jdg.suggestion_id
       WHERE jdg.suggestion_id = $id$$),
    ('case_audit_api', 'GET', '/api/cases/:id/audit',
     $$SELECT ts, actor, action, status, target, reason, band, batch_id, batch_label, undoes_batch_id
       FROM v_audit WHERE case_id = $id ORDER BY ts DESC$$),
    ('case_flagged', 'GET', '/api/cases/:id/flagged',
     $$SELECT sug.id, sug.document_id, sug.page_no, sug.text, sug.band, sug.status,
              sug.judge_panel, sug.judge_reason, sug.reason
       FROM v_suggestions sug
       JOIN documents doc ON doc.id = sug.document_id
       WHERE doc.case_id = $id AND sug.band = 'flagged' AND sug.status = 'pending'
       ORDER BY sug.document_id, sug.page_no, sug.id$$),

    -- ── catalog (allowlisted relations via v_cols) ───────────────────────
    ('catalog_list',  'GET', '/api/catalog',
     $$SELECT * FROM v_cols ORDER BY relation$$),
    ('catalog_one',   'GET', '/api/catalog/:relation',
     $$SELECT * FROM v_cols WHERE relation = $relation$$),
    -- $relation is the route literal (query TVF rejects lateral column args).
    -- JOIN v_cols is the allowlist (empty join → no rows if unknown relation).
    ('catalog_rows',  'GET', '/api/catalog/:relation/rows',
     $$SELECT rows.*
       FROM query(format('SELECT * FROM {}', $relation)) rows
       JOIN v_cols allow ON allow.relation = $relation$$),
    ('catalog_summary','GET', '/api/catalog/:relation/summary',
     $$SELECT rows.*
       FROM query(format('FROM (SUMMARIZE {})', $relation)) rows
       JOIN v_cols allow ON allow.relation = $relation$$),

    -- ── ops (debug / machine; not the FOIA product loop) ─────────────────
    ('ops_hostfs',    'GET', '/api/ops/hostfs',
     $$SELECT * FROM v_hostfs ORDER BY root, path$$),
    ('ops_zips',      'GET', '/api/ops/zips',
     $$SELECT * FROM v_zips ORDER BY root, zip_path$$),
    ('ops_shell',     'GET', '/api/ops/shell',
     $$SELECT * FROM v_shell_patterns ORDER BY kind$$),
    ('ops_cache',     'GET', '/api/ops/cache',
     $$SELECT * FROM v_http_cache$$),
    ('ops_cache_status','GET', '/api/ops/cache/status',
     $$SELECT * FROM v_http_cache_status ORDER BY original_remote_path, start_offset$$),
    ('ops_cache_access','GET', '/api/ops/cache/access',
     $$SELECT * FROM v_http_cache_access$$),
    ('ops_hosts',     'GET', '/api/ops/hosts',
     $$SELECT * FROM v_url_hosts ORDER BY hostname$$),
    ('ops_templates', 'GET', '/api/ops/templates',
     $$SELECT * FROM v_src_template_links ORDER BY template, line_number$$),
    ('ops_semantic',  'GET', '/api/ops/semantic',
     $$SELECT * FROM v_src_semantic_yaml$$)
) AS t(name, method, path, body);

COPY (
    SELECT format(
        'CREATE OR REPLACE ROUTE {} {} ''{}'' AS {};',
        name, method, path,
        replace(replace(replace(body, chr(10), ' '), chr(13), ' '), '  ', ' ')
    )
    FROM v_route_get
    ORDER BY name
) TO '.tmp/routes_get.sql' (FORMAT CSV, HEADER false, QUOTE '', ESCAPE '');

.read .tmp/routes_get.sql

FROM (SUMMARIZE v_route_get);

-- ═══════════════════════════════════════════════════════════════════════════
-- POST product writes (resource-nested; STATUS 201 on decision creates)
-- ═══════════════════════════════════════════════════════════════════════════

-- Decide one suggestion
CREATE OR REPLACE ROUTE suggestion_decide POST '/api/suggestions/:id/decision'
  STATUS 201
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS INSERT INTO decisions BY NAME
WITH new_batch AS (SELECT uuid()::VARCHAR AS batch_id)
SELECT 'decision' AS kind, tgt.suggestion_id, $status AS status, $actor AS actor, $reason AS reason,
       now() AS ts, tgt.document_id, tgt.case_id, tgt.text, (SELECT batch_id FROM new_batch) AS batch_id,
       CASE WHEN tgt.text IS NOT NULL THEN $status || ' — ' || tgt.text ELSE $status END AS batch_label,
       NULL::VARCHAR AS undoes_batch_id
FROM v_decide_targets tgt
WHERE tgt.suggestion_id = $id
RETURNING suggestion_id, status;

-- Entity bulk (case-wide; skips flagged)
CREATE OR REPLACE ROUTE entity_decide POST '/api/entities/:id/decision'
  STATUS 201
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS INSERT INTO decisions BY NAME
WITH new_batch AS (SELECT uuid()::VARCHAR AS batch_id)
SELECT 'decision' AS kind, tgt.suggestion_id, $status AS status, $actor AS actor, $reason AS reason,
       now() AS ts, tgt.document_id, tgt.case_id, tgt.text, (SELECT batch_id FROM new_batch) AS batch_id,
       CASE
           WHEN tgt.entity_text IS NOT NULL THEN $status || ' entity — ' || tgt.entity_text
           WHEN tgt.text IS NOT NULL THEN $status || ' entity — ' || tgt.text
           ELSE $status || ' entity'
       END AS batch_label,
       NULL::VARCHAR AS undoes_batch_id
FROM v_decide_targets tgt
WHERE tgt.entity_id = $id AND tgt.status = 'pending' AND tgt.band <> 'flagged'
RETURNING suggestion_id, status;

-- Band bulk on one document (never flagged)
CREATE OR REPLACE ROUTE document_band_decide POST '/api/documents/:id/bands/:band/decision'
  STATUS 201
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS INSERT INTO decisions BY NAME
WITH new_batch AS (SELECT uuid()::VARCHAR AS batch_id)
SELECT 'decision' AS kind, tgt.suggestion_id, $status AS status, $actor AS actor,
       CASE WHEN $reason IS NULL OR $reason = '' THEN 'bulk band ' || $band ELSE $reason END AS reason,
       now() AS ts, tgt.document_id, tgt.case_id, tgt.text, (SELECT batch_id FROM new_batch) AS batch_id,
       $status || ' band ' || $band AS batch_label, NULL::VARCHAR AS undoes_batch_id
FROM v_decide_targets tgt
WHERE tgt.document_id = $id AND tgt.status = 'pending' AND tgt.band = $band AND $band <> 'flagged'
RETURNING suggestion_id, status;

-- Accept HIGH case-wide
CREATE OR REPLACE ROUTE case_accept_high POST '/api/cases/:id/accept-high'
  STATUS 201
  PARAM threshold INTEGER DEFAULT 90 GE 0 LE 100
  PARAM actor VARCHAR DEFAULT 'reviewer'
AS INSERT INTO decisions BY NAME
WITH new_batch AS (SELECT uuid()::VARCHAR AS batch_id)
SELECT 'decision' AS kind, tgt.suggestion_id, 'accepted' AS status, $actor AS actor,
       'accept high ≥' || $threshold::VARCHAR AS reason,
       now() AS ts, tgt.document_id, tgt.case_id, tgt.text, (SELECT batch_id FROM new_batch) AS batch_id,
       'Accepted high' AS batch_label, NULL::VARCHAR AS undoes_batch_id
FROM v_decide_targets tgt
WHERE tgt.case_id = $id AND tgt.status = 'pending' AND tgt.confidence >= $threshold
  AND tgt.band <> 'flagged'
  AND (tgt.flag_tag IS NULL OR tgt.flag_tag <> 'false_positive')
RETURNING suggestion_id, status;

-- Manual mark (add missed)
CREATE OR REPLACE ROUTE document_mark_add POST '/api/documents/:id/marks'
  STATUS 201
  PARAM page INTEGER PARAM x0 DOUBLE PARAM y0 DOUBLE PARAM x1 DOUBLE PARAM y1 DOUBLE
  PARAM text VARCHAR PARAM kind VARCHAR DEFAULT 'MANUAL'
  PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT 'missed by AI'
AS INSERT INTO decisions BY NAME
WITH new_mark AS (SELECT uuid()::VARCHAR AS batch_id, uuid()::VARCHAR AS suggestion_id)
SELECT 'added' AS kind, new_mark.suggestion_id, $id AS document_id, $page::INTEGER AS page_no,
       ($x0, $y0, $x1, $y1)::bbox AS bbox, $text AS text, $text AS context,
       99 AS confidence, $kind AS flag_tag,
       CASE WHEN $reason IS NULL OR $reason = '' THEN 'manual add' ELSE $reason END AS reason,
       NULL::VARCHAR AS entity_id, 'manual' AS source, 'accepted' AS status,
       $actor AS actor, now() AS ts,
       (SELECT case_id FROM documents WHERE id = $id) AS case_id,
       'one' AS scope, new_mark.batch_id,
       CASE WHEN $text IS NOT NULL THEN 'Added missed — ' || $text ELSE 'Added missed' END AS batch_label,
       NULL::VARCHAR AS undoes_batch_id
FROM new_mark
RETURNING suggestion_id, status;

-- Undo last batch for case
CREATE OR REPLACE ROUTE case_undo POST '/api/cases/:id/undo'
  STATUS 201
  PARAM actor VARCHAR DEFAULT 'reviewer'
AS INSERT INTO decisions BY NAME
WITH last_batch_for_case AS (
    SELECT arg_max(batch_id, ts) AS batch_id, arg_max(label, ts) AS label
    FROM v_decision_batches
    WHERE undoes_batch_id IS NULL AND case_id = $id
),
new_batch AS (SELECT uuid()::VARCHAR AS batch_id)
SELECT 'decision' AS kind, evt.suggestion_id,
       CASE
           WHEN lag(evt.status) OVER (PARTITION BY evt.suggestion_id ORDER BY evt.event_ts) IS NOT NULL
           THEN lag(evt.status) OVER (PARTITION BY evt.suggestion_id ORDER BY evt.event_ts)
           ELSE 'pending'
       END AS status,
       $actor AS actor, 'undo' AS reason, now() AS ts,
       evt.document_id, evt.case_id, evt.text, (SELECT batch_id FROM new_batch) AS batch_id,
       CASE WHEN bat.label IS NOT NULL THEN 'Undo — ' || bat.label ELSE 'Undo — ' || bat.batch_id END AS batch_label,
       bat.batch_id AS undoes_batch_id
FROM v_history_events evt
JOIN last_batch_for_case bat ON evt.batch_id = bat.batch_id
WHERE evt.kind = 'decision'
RETURNING suggestion_id, status;

-- Export redacted PDFs (blocked while flagged pending). Side-effect TVF; return plan grain.
CREATE OR REPLACE ROUTE case_export POST '/api/cases/:id/export' AS
SELECT plan.document_id, plan.out_path, plan.boxes,
       (SELECT bool_or(true) FROM pdf_redact(plan.source_path, plan.out_path, plan.boxes)) AS redacted
FROM v_export_plans plan
WHERE plan.case_id = $id AND NOT plan.blocked AND len(plan.boxes) > 0;
