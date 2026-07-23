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
    -- Case rollup: GROUP BY ALL on dims; measures are count()/avg on the group
    -- (not a metrics catalog). Prefer /api/catalog/v_suggestions/summary for profiles.
    ('case_metrics',  'GET', '/api/cases/:id/metrics',
     $$FROM v_suggestions s
       JOIN documents d ON d.id = s.document_id
       WHERE d.case_id = $id
       SELECT status, band, count(), avg(confidence)
       GROUP BY ALL
       ORDER BY ALL$$),
    ('suggestion_context', 'GET', '/api/suggestions/:id/context',
     $$SELECT suggestion_id, document_id, page_no, hit_line, line_number, line_text, dist
       FROM v_suggestion_line_context
       WHERE suggestion_id = $id ORDER BY line_number$$),
    ('suggestion_judges', 'GET', '/api/suggestions/:id/judges',
     $$SELECT j.suggestion_id, j.vote_pattern, j.vote_context, j.vote_prior, j.panel, j.judge_reason,
              s.band, s.status, s.text, s.kind
       FROM suggestion_judges j
       JOIN v_suggestions s ON s.id = j.suggestion_id
       WHERE j.suggestion_id = $id$$),
    ('case_audit_api', 'GET', '/api/cases/:id/audit',
     $$SELECT ts, actor, action, status, target, reason, band, batch_id, batch_label, undoes_batch_id
       FROM v_audit WHERE case_id = $id ORDER BY ts DESC$$),
    ('case_flagged', 'GET', '/api/cases/:id/flagged',
     $$SELECT s.id, s.document_id, s.page_no, s.text, s.band, s.status, s.judge_panel, s.judge_reason, s.reason
       FROM v_suggestions s
       JOIN documents d ON d.id = s.document_id
       WHERE d.case_id = $id AND s.band = 'flagged' AND s.status = 'pending'
       ORDER BY s.document_id, s.page_no, s.id$$),

    -- ── catalog (allowlisted relations via v_cols) ───────────────────────
    ('catalog_list',  'GET', '/api/catalog',
     $$SELECT * FROM v_cols ORDER BY relation$$),
    ('catalog_one',   'GET', '/api/catalog/:relation',
     $$SELECT * FROM v_cols WHERE relation = $relation$$),
    ('catalog_rows',  'GET', '/api/catalog/:relation/rows',
     $$SELECT * FROM query(format('SELECT * FROM {}', $relation))
       WHERE $relation IN (SELECT relation FROM v_cols)$$),
    ('catalog_summary','GET', '/api/catalog/:relation/summary',
     $$SELECT * FROM query(format('FROM (SUMMARIZE {})', $relation))
       WHERE $relation IN (SELECT relation FROM v_cols)$$),

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
     $$SELECT * FROM v_url_hosts ORDER BY token_n DESC, hostname$$),
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
WITH b AS (SELECT uuid()::VARCHAR AS batch_id)
SELECT 'decision' AS kind, t.suggestion_id, $status AS status, $actor AS actor, $reason AS reason,
       now() AS ts, t.document_id, t.case_id, t.text, (SELECT batch_id FROM b) AS batch_id,
       $status || ' — ' || coalesce(t.text, '') AS batch_label, NULL::VARCHAR AS undoes_batch_id
FROM v_decide_targets t
WHERE t.suggestion_id = $id
RETURNING suggestion_id, status;

-- Entity bulk (case-wide; skips flagged)
CREATE OR REPLACE ROUTE entity_decide POST '/api/entities/:id/decision'
  STATUS 201
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS INSERT INTO decisions BY NAME
WITH b AS (SELECT uuid()::VARCHAR AS batch_id)
SELECT 'decision' AS kind, t.suggestion_id, $status AS status, $actor AS actor, $reason AS reason,
       now() AS ts, t.document_id, t.case_id, t.text, (SELECT batch_id FROM b) AS batch_id,
       $status || ' entity — ' || coalesce(t.entity_text, t.text, '') AS batch_label,
       NULL::VARCHAR AS undoes_batch_id
FROM v_decide_targets t
WHERE t.entity_id = $id AND t.status = 'pending' AND t.band <> 'flagged'
RETURNING suggestion_id, status;

-- Band bulk on one document (never flagged)
CREATE OR REPLACE ROUTE document_band_decide POST '/api/documents/:id/bands/:band/decision'
  STATUS 201
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS INSERT INTO decisions BY NAME
WITH b AS (SELECT uuid()::VARCHAR AS batch_id)
SELECT 'decision' AS kind, t.suggestion_id, $status AS status, $actor AS actor,
       coalesce(nullif($reason, ''), 'bulk band ' || $band) AS reason,
       now() AS ts, t.document_id, t.case_id, t.text, (SELECT batch_id FROM b) AS batch_id,
       $status || ' band ' || $band AS batch_label, NULL::VARCHAR AS undoes_batch_id
FROM v_decide_targets t
WHERE t.document_id = $id AND t.status = 'pending' AND t.band = $band AND $band <> 'flagged'
RETURNING suggestion_id, status;

-- Accept HIGH case-wide
CREATE OR REPLACE ROUTE case_accept_high POST '/api/cases/:id/accept-high'
  STATUS 201
  PARAM threshold INTEGER DEFAULT 90 GE 0 LE 100
  PARAM actor VARCHAR DEFAULT 'reviewer'
AS INSERT INTO decisions BY NAME
WITH b AS (SELECT uuid()::VARCHAR AS batch_id)
SELECT 'decision' AS kind, t.suggestion_id, 'accepted' AS status, $actor AS actor,
       'accept high ≥' || $threshold::VARCHAR AS reason,
       now() AS ts, t.document_id, t.case_id, t.text, (SELECT batch_id FROM b) AS batch_id,
       'Accepted high' AS batch_label, NULL::VARCHAR AS undoes_batch_id
FROM v_decide_targets t
WHERE t.case_id = $id AND t.status = 'pending' AND t.confidence >= $threshold
  AND t.band <> 'flagged' AND t.flag_tag <> 'false_positive'
RETURNING suggestion_id, status;

-- Manual mark (add missed)
CREATE OR REPLACE ROUTE document_mark_add POST '/api/documents/:id/marks'
  STATUS 201
  PARAM page INTEGER PARAM x0 DOUBLE PARAM y0 DOUBLE PARAM x1 DOUBLE PARAM y1 DOUBLE
  PARAM text VARCHAR PARAM kind VARCHAR DEFAULT 'MANUAL'
  PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT 'missed by AI'
AS INSERT INTO decisions BY NAME
WITH b AS (SELECT uuid()::VARCHAR AS batch_id, uuid()::VARCHAR AS suggestion_id)
SELECT 'added' AS kind, b.suggestion_id, $id AS document_id, $page::INTEGER AS page_no,
       ($x0, $y0, $x1, $y1)::bbox AS bbox, $text AS text, coalesce($text, '') AS context,
       99 AS confidence, $kind AS flag_tag, coalesce($reason, 'manual add') AS reason,
       NULL::VARCHAR AS entity_id, 'manual' AS source, 'accepted' AS status,
       $actor AS actor, now() AS ts,
       (SELECT case_id FROM documents WHERE id = $id) AS case_id,
       'one' AS scope, b.batch_id,
       'Added missed — ' || coalesce($text, '') AS batch_label, NULL::VARCHAR AS undoes_batch_id
FROM b
RETURNING suggestion_id, status;

-- Undo last batch for case
CREATE OR REPLACE ROUTE case_undo POST '/api/cases/:id/undo'
  STATUS 201
  PARAM actor VARCHAR DEFAULT 'reviewer'
AS INSERT INTO decisions BY NAME
WITH target AS (
    SELECT arg_max(batch_id, ts) AS batch_id, arg_max(label, ts) AS label
    FROM v_decision_batches
    WHERE undoes_batch_id IS NULL AND case_id = $id
),
b AS (SELECT uuid()::VARCHAR AS batch_id)
SELECT 'decision' AS kind, h.suggestion_id,
       coalesce(lag(h.status) OVER (PARTITION BY h.suggestion_id ORDER BY h.event_ts), 'pending') AS status,
       $actor AS actor, 'undo' AS reason, now() AS ts,
       h.document_id, h.case_id, h.text, (SELECT batch_id FROM b) AS batch_id,
       'Undo — ' || coalesce(t.label, t.batch_id) AS batch_label,
       t.batch_id AS undoes_batch_id
FROM v_history_events h
JOIN target t ON h.batch_id = t.batch_id
WHERE h.kind = 'decision'
RETURNING suggestion_id, status;

-- Export redacted PDFs (blocked while flagged pending)
CREATE OR REPLACE ROUTE case_export POST '/api/cases/:id/export' AS
SELECT p.document_id, p.out_path,
       (SELECT count(*)::INTEGER
        FROM pdf_redact(p.source_path, p.out_path, p.boxes)) AS pages
FROM v_export_plans p
WHERE p.case_id = $id AND NOT p.blocked AND len(p.boxes) > 0;
