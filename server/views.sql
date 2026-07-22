-- views.sql — thin projections over a robust table model + live folds.
--
-- Layer rule (extend by layer, not by stuffing page bags):
--   1. TABLES (core.sql)  stable facts + display pins (display_name, scale, kind_label, …)
--   2. LIVE VIEWS         decision fold, marks px, export gate (change every POST)
--   3. PAGE VIEWS         tera → parse_html only (list-pack at the edge)
--
-- Prefer: add a column to a table/grain → join it.
-- Avoid: re-deriving labels/geometry in every page view.
--
-- Catalog:  SELECT * FROM v_cols
-- Metrics:  semantic_view('closure', …)  — edit server/config/closure_semantic.yaml
-- Open:     GET /api/catalog/:relation/rows (allowlisted via v_cols)

DROP SEMANTIC VIEW IF EXISTS suggestion_metrics;
DROP SEMANTIC VIEW IF EXISTS closure;
CREATE SEMANTIC VIEW closure FROM YAML FILE 'server/config/closure_semantic.yaml';

-- Allowlist for GET /api/rel + /api/summarize (not every internal extract table).
CREATE OR REPLACE VIEW v_cols AS
SELECT table_name AS relation,
       array_agg([column_name, data_type] ORDER BY ordinal_position) AS cols
FROM information_schema.columns
WHERE table_schema = 'main'
  AND table_name IN (
      'cases', 'documents', 'pages', 'words', 'entities', 'suggestions', 'decisions',
      'v_suggestions', 'v_decide_targets', 'v_entity_stream', 'v_nav',
      'v_export_blocked', 'v_export_plans', 'v_audit', 'v_decision_batches',
      'v_history_events', 'v_hostfs', 'v_zips', 'v_shell_patterns',
      'v_url_hosts', 'v_suggestion_line_context', 'v_cols', 'v_page_marks',
      'v_http_cache', 'v_http_cache_config', 'v_http_cache_status',
      'v_http_cache_access', 'v_http_cache_filesystems',
      'v_route_get', 'v_case_html', 'v_stream_page', 'v_audit_page', 'v_review_page'
  )
GROUP BY table_name;

-- ── live grains (thin; join tables, do not re-pin display) ─────────────────

CREATE OR REPLACE VIEW v_doc_ui AS
SELECT id, case_id, filename, page_count, width_pt, height_pt,
       file_size, source_path, display_name, size_label
FROM documents;

CREATE OR REPLACE VIEW v_page_marks AS
SELECT s.id, s.document_id, s.page_no, s.line_no, s.bbox,
       s.text, s.confidence, s.status, s.band, s.kind, s.entity_id, s.flag_tag,
       round(s.bbox.x0 * p.scale, 2) AS left_px,
       round(s.bbox.y0 * p.scale, 2) AS top_px,
       round((s.bbox.x1 - s.bbox.x0) * p.scale, 2) AS width,
       round((s.bbox.y1 - s.bbox.y0) * p.scale, 2) AS height
FROM v_suggestions s
JOIN pages p ON p.document_id = s.document_id AND p.page_no = s.page_no;

CREATE OR REPLACE VIEW v_page_words AS
SELECT w.document_id, w.page_no, w.word, w.bbox, w.font_size,
       round(w.bbox.x0 * p.scale, 2) AS left_px,
       round(w.bbox.y0 * p.scale, 2) AS top_px,
       round((w.bbox.x1 - w.bbox.x0) * p.scale, 2) AS width,
       round(greatest(w.bbox.y1 - w.bbox.y0, 4) * p.scale, 2) AS height,
       round(coalesce(w.font_size, 9) * p.scale * 0.95, 1) AS font_px
FROM words w
JOIN pages p ON p.document_id = w.document_id AND p.page_no = w.page_no;

CREATE OR REPLACE VIEW v_audit AS
SELECT l.ts, coalesce(l.actor, 'reviewer') AS actor, coalesce(l.kind, 'decision') AS action,
       l.suggestion_id, coalesce(l.case_id, d.case_id) AS case_id,
       coalesce(l.text, l.suggestion_id, '') AS target, l.reason
FROM v_src_decisions l LEFT JOIN documents d ON d.id = l.document_id;

CREATE OR REPLACE VIEW v_export_blocked AS
SELECT d.case_id,
       bool_or(s.band = 'flagged' AND s.status = 'pending') AS export_blocked
FROM documents d
LEFT JOIN v_suggestions s ON s.document_id = d.id
GROUP BY d.case_id;

CREATE OR REPLACE VIEW v_entity_stream AS
SELECT e.case_id, e.id AS entity_id, e.canonical_text, e.kind,
       e.kind_label, e.mono, m.n AS hit_count
FROM entities e
LEFT JOIN semantic_view('closure', dimensions := ['entity_id'], metrics := ['n']) m
  ON m.entity_id = e.id;

CREATE OR REPLACE VIEW v_nav AS
-- AS case_id/href/text on every arm — UNION ALL BY NAME matches names.
SELECT case_id,
       '/documents/' || id AS href,
       filename AS text
FROM documents
UNION ALL BY NAME
SELECT id AS case_id, '/cases/' || id AS href, 'Library' AS text FROM cases
UNION ALL BY NAME
SELECT id AS case_id, '/cases/' || id || '/stream' AS href, 'Entity stream' AS text FROM cases
UNION ALL BY NAME
SELECT id AS case_id, '/cases/' || id || '/audit' AS href, 'Audit' AS text FROM cases;

CREATE OR REPLACE VIEW v_history_events AS
SELECT kind, suggestion_id, status, actor, reason, ts AS event_ts,
       document_id, case_id, text, batch_id, batch_label, undoes_batch_id
FROM v_src_decisions WHERE nullif(batch_id, '') IS NOT NULL;

CREATE OR REPLACE VIEW v_decision_batches AS
SELECT e.batch_id, min(e.event_ts) AS ts, max(e.event_ts) AS ts_end,
       any_value(e.actor) AS actor, any_value(e.batch_label) AS label,
       count(*)::INTEGER AS decision_count,
       bool_or(e.undoes_batch_id IS NOT NULL) AS is_undo,
       max(e.undoes_batch_id) AS undoes_batch_id, max(e.case_id) AS case_id,
       exists (SELECT 1 FROM v_history_events u WHERE u.undoes_batch_id = e.batch_id) AS undone
FROM v_history_events e GROUP BY e.batch_id;

CREATE OR REPLACE VIEW v_export_plans AS
WITH boxes AS (
    SELECT s.document_id,
           list(struct_pack(
               page := s.page_no::INTEGER,
               x := s.bbox.x0, y := (p.height_pt - s.bbox.y1),
               w := (s.bbox.x1 - s.bbox.x0), h := (s.bbox.y1 - s.bbox.y0)
           ) ORDER BY s.page_no, s.id) AS boxes
    FROM v_suggestions s
    JOIN pages p ON p.document_id = s.document_id AND p.page_no = s.page_no
    WHERE s.status = 'accepted' GROUP BY s.document_id
)
SELECT b.case_id, b.export_blocked AS blocked,
       d.id AS document_id, d.filename, d.source_path,
       'exports/' || replace(replace(d.filename, '/', '_'), chr(92), '_') || '_redacted.pdf' AS out_path,
       coalesce(x.boxes, []) AS boxes
FROM v_export_blocked b
JOIN documents d ON d.case_id = b.case_id
LEFT JOIN boxes x ON x.document_id = d.id;

-- ── page HTML ──────────────────────────────────────────────────────────────
-- Separation: SQL builds ctx (bags) · tera pages/fragments render · static CSS/JS.
-- VARCHAR html only — never parse_html on pages (voids <script src> → app.js dead).
-- template_path glob loads fragments/ for {% include %}.

CREATE OR REPLACE VIEW v_tpl_entities AS
SELECT case_id,
       list(struct_pack(
           id := entity_id, canonical_text := canonical_text, kind := kind,
           kind_label := kind_label, n := hit_count, mono := mono
       ) ORDER BY hit_count DESC NULLS LAST, kind, canonical_text) AS entities
FROM v_entity_stream
GROUP BY case_id;

CREATE OR REPLACE VIEW v_tpl_case AS
SELECT c.id AS case_id,
       struct_pack(id := c.id, case_no := c.case_no, title := c.title) AS case_row,
       coalesce(e.entities, []) AS entities,
       coalesce(b.export_blocked, false) AS export_blocked
FROM cases c
LEFT JOIN v_tpl_entities e ON e.case_id = c.id
LEFT JOIN v_export_blocked b ON b.case_id = c.id;

-- Context views (JSON) then thin tera_render.

CREATE OR REPLACE VIEW v_case_ctx AS
SELECT t.case_id,
       json_object(
           'case', t.case_row,
           'documents', coalesce((
               SELECT list(u ORDER BY u.filename) FROM v_doc_ui u WHERE u.case_id = t.case_id
           ), []),
           'by_status', coalesce((
               SELECT list(m ORDER BY status)
               FROM semantic_view('closure', dimensions := ['case_id', 'status'],
                    metrics := ['n', 'avg_confidence']) m
               WHERE m.case_id = t.case_id
           ), []),
           'by_band', coalesce((
               SELECT list(m ORDER BY band)
               FROM semantic_view('closure', dimensions := ['case_id', 'band'],
                    metrics := ['n', 'avg_confidence']) m
               WHERE m.case_id = t.case_id
           ), []),
           'entities', t.entities,
           'audit', coalesce((
               SELECT list(struct_pack(
                   ts_short := strftime(a.ts, '%H:%M'), action := a.action, actor := a.actor,
                   target := coalesce(a.target, ''), reason := coalesce(a.reason, '')
               ) ORDER BY a.ts DESC)
               FROM v_audit a WHERE a.case_id = t.case_id
           ), []),
           'export_blocked', t.export_blocked
       ) AS ctx
FROM v_tpl_case t;

CREATE OR REPLACE VIEW v_stream_ctx AS
SELECT case_id,
       json_object(
           'case', case_row,
           'entities', entities,
           'export_blocked', export_blocked
       ) AS ctx
FROM v_tpl_case;

CREATE OR REPLACE VIEW v_audit_ctx AS
SELECT c.id AS case_id,
       json_object(
           'case', struct_pack(id := c.id, case_no := c.case_no, title := c.title),
           'events', coalesce((
               SELECT list(struct_pack(
                   ts_short := strftime(a.ts, '%Y-%m-%d %H:%M:%S'),
                   action := a.action, actor := a.actor,
                   target := coalesce(a.target, ''), reason := coalesce(a.reason, '')
               ) ORDER BY a.ts DESC)
               FROM v_audit a WHERE a.case_id = c.id
           ), [])
       ) AS ctx
FROM cases c;

CREATE OR REPLACE VIEW v_review_ctx AS
SELECT d.id AS document_id, p.page_no,
       json_object(
           'case', struct_pack(id := c.id, case_no := c.case_no, title := c.title),
           'doc',  struct_pack(id := d.id, filename := d.filename, page_count := d.page_count),
           'page', struct_pack(
               page_no := p.page_no,
               prev := greatest(p.page_no - 1, 1),
               next := least(p.page_no + 1, d.page_count),
               width_pt := p.width_pt, height_pt := p.height_pt,
               scale := round(p.scale, 4),
               display_w := p.display_w, display_h := p.display_h,
               png_href := '/pages/' || d.filename || '/p' || p.page_no || '.png'
           ),
           'marks', coalesce((
               SELECT list(m) FROM v_page_marks m
               WHERE m.document_id = d.id AND m.page_no = p.page_no
           ), []),
           'by_status', coalesce((
               SELECT list(m ORDER BY status)
               FROM semantic_view('closure', dimensions := ['document_id', 'status'],
                    metrics := ['n']) m
               WHERE m.document_id = d.id
           ), []),
           'suggestions', coalesce((
               SELECT list(s ORDER BY (page_no = p.page_no) DESC,
                                   (status = 'pending') DESC, page_no, id)
               FROM v_suggestions s
               WHERE s.document_id = d.id
                 AND (s.page_no = p.page_no OR s.status = 'pending')
           ), [])
       ) AS ctx
FROM documents d
JOIN cases c ON c.id = d.case_id
JOIN pages p ON p.document_id = d.id;

-- Page views: html + path (path is product URL; GET routes bind it via v_route_get).
CREATE OR REPLACE VIEW v_case_html AS
SELECT case_id,
       '/cases/' || case_id AS path,
       tera_render('case.html', ctx, template_path := 'server/templates/**/*.html') AS html
FROM v_case_ctx;

CREATE OR REPLACE VIEW v_stream_page AS
SELECT case_id,
       '/cases/' || case_id || '/stream' AS path,
       tera_render('stream.html', ctx, template_path := 'server/templates/**/*.html') AS html
FROM v_stream_ctx;

CREATE OR REPLACE VIEW v_audit_page AS
SELECT case_id,
       '/cases/' || case_id || '/audit' AS path,
       tera_render('audit.html', ctx, template_path := 'server/templates/**/*.html') AS html
FROM v_audit_ctx;

CREATE OR REPLACE VIEW v_review_page AS
SELECT document_id, page_no,
       CASE WHEN page_no = 1 THEN '/documents/' || document_id
            ELSE '/documents/' || document_id || '/pages/' || page_no::VARCHAR
       END AS path,
       tera_render('review.html', ctx, template_path := 'server/templates/**/*.html') AS html
FROM v_review_ctx;
