-- views.sql — live folds + page edge over a table model.
--
-- Table rule (adversarial): create a TABLE only when many consumers re-run the
-- same work, and "it makes everything downstream simpler/robust" is true.
-- Prefer JOINs of named relations over correlated scalar subqueries.
--
-- Lossy count* boards are not product. Grain rows + SUMMARIZE/semantic dims.
-- Semantic graph: server/config/closure_semantic.yaml (joins + dimensions).
-- Catalog:  SELECT * FROM v_cols · GET /api/catalog/:relation/rows|summary

DROP SEMANTIC VIEW IF EXISTS suggestion_metrics;
DROP SEMANTIC VIEW IF EXISTS closure;
CREATE SEMANTIC VIEW closure FROM YAML FILE 'server/config/closure_semantic.yaml';

CREATE OR REPLACE VIEW v_cols AS
SELECT table_name AS relation,
       array_agg([column_name, data_type] ORDER BY ordinal_position) AS cols
FROM information_schema.columns
WHERE table_schema = 'main'
  AND table_name IN (
      'cases', 'documents', 'pages', 'words', 'entities', 'suggestions', 'decisions',
      'suggestion_judges', 'v_suggestions', 'v_decide_targets', 'v_nav',
      'v_export_blocked', 'v_export_plans', 'v_audit', 'v_decision_batches',
      'v_history_events', 'v_hostfs', 'v_zips', 'v_shell_patterns',
      'v_url_hosts', 'v_suggestion_line_context', 'v_cols', 'v_page_marks',
      'v_http_cache', 'v_http_cache_config', 'v_http_cache_status',
      'v_http_cache_access', 'v_http_cache_filesystems',
      'v_route_get', 'v_case_html', 'v_stream_page', 'v_audit_page', 'v_review_page'
  )
GROUP BY table_name;

-- ── live folds (change every decision POST) ────────────────────────────────

CREATE OR REPLACE VIEW v_page_marks AS
SELECT s.id, s.document_id, s.page_no, s.line_no, s.bbox,
       s.text, s.confidence, s.status, s.band, s.kind, s.entity_id, s.flag_tag,
       UNNEST(bbox_px(s.bbox, p.scale, 0))
FROM v_suggestions s
JOIN pages p ON p.document_id = s.document_id AND p.page_no = s.page_no;

CREATE OR REPLACE VIEW v_audit AS
SELECT l.ts,
       coalesce(l.actor, 'reviewer') AS actor,
       coalesce(l.kind, 'decision') AS action,
       l.status,
       l.suggestion_id,
       coalesce(l.case_id, d.case_id) AS case_id,
       l.document_id,
       coalesce(l.text, l.suggestion_id, '') AS target,
       l.reason,
       l.batch_id,
       l.batch_label,
       l.undoes_batch_id,
       s.band,
       s.kind AS pii_kind,
       s.judge_panel
FROM v_src_decisions l
LEFT JOIN documents d ON d.id = l.document_id
LEFT JOIN v_suggestions s ON s.id = l.suggestion_id;

CREATE OR REPLACE VIEW v_export_blocked AS
SELECT d.case_id,
       bool_or(s.band = 'flagged' AND s.status = 'pending') AS export_blocked
FROM documents d
LEFT JOIN v_suggestions s ON s.document_id = d.id
GROUP BY d.case_id;

CREATE OR REPLACE VIEW v_nav AS
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

CREATE OR REPLACE VIEW v_undone_batches AS
SELECT undoes_batch_id AS batch_id
FROM v_history_events
WHERE undoes_batch_id IS NOT NULL
GROUP BY undoes_batch_id;

CREATE OR REPLACE VIEW v_decision_batches AS
SELECT e.batch_id, e.ts, e.ts_end, e.actor, e.label, e.suggestion_ids,
       e.is_undo, e.undoes_batch_id, e.case_id,
       u.batch_id IS NOT NULL AS undone
FROM (
    SELECT batch_id, min(event_ts) AS ts, max(event_ts) AS ts_end,
           any_value(actor) AS actor, any_value(batch_label) AS label,
           list(suggestion_id ORDER BY event_ts) AS suggestion_ids,
           bool_or(undoes_batch_id IS NOT NULL) AS is_undo,
           max(undoes_batch_id) AS undoes_batch_id, max(case_id) AS case_id
    FROM v_history_events
    GROUP BY batch_id
) e
LEFT JOIN v_undone_batches u ON u.batch_id = e.batch_id;

CREATE OR REPLACE VIEW v_export_plans AS
WITH boxes AS (
    SELECT s.document_id,
           list(struct_insert(bbox_pdf(s.bbox, p.height_pt), page := s.page_no::INTEGER)
                ORDER BY s.page_no, s.id) AS boxes
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

-- ── case-grain packs (multi-consumer: case / stream / audit ctx) ────────────
-- Earned as named views so page edges JOIN instead of correlated SELECTs.

CREATE OR REPLACE VIEW v_case_documents AS
SELECT case_id, list(d ORDER BY filename) AS documents
FROM documents d
GROUP BY case_id;

CREATE OR REPLACE VIEW v_case_entities AS
SELECT case_id,
       list(struct_pack(
           id := id, canonical_text := canonical_text, kind := kind,
           kind_label := kind_label, mono := mono
       ) ORDER BY kind, canonical_text) AS entities
FROM entities
GROUP BY case_id;

CREATE OR REPLACE VIEW v_case_audit_recent AS
SELECT case_id,
       list(struct_pack(
           ts_short := strftime(ts, '%H:%M'), action := action, actor := actor,
           target := coalesce(target, ''), reason := coalesce(reason, '')
       ) ORDER BY ts DESC) AS audit
FROM v_audit
GROUP BY case_id;

CREATE OR REPLACE VIEW v_case_batches AS
SELECT case_id,
       list(struct_pack(
           batch_id := batch_id,
           ts_short := strftime(ts, '%Y-%m-%d %H:%M'),
           actor := actor,
           label := label,
           members := array_to_string(suggestion_ids, ', '),
           is_undo := is_undo,
           undone := undone
       ) ORDER BY ts DESC) AS batches
FROM v_decision_batches
GROUP BY case_id;

CREATE OR REPLACE VIEW v_case_events AS
SELECT case_id,
       list(struct_pack(
           ts_short := strftime(ts, '%Y-%m-%d %H:%M:%S'),
           action := action,
           status := coalesce(status, ''),
           actor := actor,
           target := coalesce(target, ''),
           reason := coalesce(reason, ''),
           band := coalesce(band, ''),
           batch_label := coalesce(batch_label, ''),
           is_undo := undoes_batch_id IS NOT NULL
       ) ORDER BY ts DESC) AS events
FROM v_audit
GROUP BY case_id;

CREATE OR REPLACE VIEW v_page_mark_lists AS
SELECT document_id, page_no, list(m) AS marks
FROM v_page_marks m
GROUP BY document_id, page_no;

-- ── page edge: JOIN packs → json_object → tera ─────────────────────────────

CREATE OR REPLACE VIEW v_case_ctx AS
SELECT c.id AS case_id,
       json_object(
           'case', struct_pack(id := c.id, case_no := c.case_no, title := c.title),
           'documents', coalesce(docs.documents, []),
           'entities', coalesce(ents.entities, []),
           'audit', coalesce(aud.audit, []),
           'export_blocked', coalesce(blk.export_blocked, false)
       ) AS ctx
FROM cases c
LEFT JOIN v_case_documents docs ON docs.case_id = c.id
LEFT JOIN v_case_entities ents ON ents.case_id = c.id
LEFT JOIN v_case_audit_recent aud ON aud.case_id = c.id
LEFT JOIN v_export_blocked blk ON blk.case_id = c.id;

CREATE OR REPLACE VIEW v_stream_ctx AS
SELECT c.id AS case_id,
       json_object(
           'case', struct_pack(id := c.id, case_no := c.case_no, title := c.title),
           'entities', coalesce(ents.entities, []),
           'export_blocked', coalesce(blk.export_blocked, false)
       ) AS ctx
FROM cases c
LEFT JOIN v_case_entities ents ON ents.case_id = c.id
LEFT JOIN v_export_blocked blk ON blk.case_id = c.id;

CREATE OR REPLACE VIEW v_audit_ctx AS
SELECT c.id AS case_id,
       json_object(
           'case', struct_pack(id := c.id, case_no := c.case_no, title := c.title),
           'export_blocked', coalesce(blk.export_blocked, false),
           'batches', coalesce(bat.batches, []),
           'events', coalesce(ev.events, [])
       ) AS ctx
FROM cases c
LEFT JOIN v_export_blocked blk ON blk.case_id = c.id
LEFT JOIN v_case_batches bat ON bat.case_id = c.id
LEFT JOIN v_case_events ev ON ev.case_id = c.id;

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
           'marks', coalesce(ml.marks, []),
           'suggestions', coalesce(sl.suggestions, [])
       ) AS ctx
FROM documents d
JOIN cases c ON c.id = d.case_id
JOIN pages p ON p.document_id = d.id
LEFT JOIN v_page_mark_lists ml ON ml.document_id = d.id AND ml.page_no = p.page_no
LEFT JOIN LATERAL (
    SELECT list(s ORDER BY (s.page_no = p.page_no) DESC,
                        (s.status = 'pending') DESC, s.page_no, s.id) AS suggestions
    FROM v_suggestions s
    WHERE s.document_id = d.id
      AND (s.page_no = p.page_no OR s.status = 'pending')
) sl ON true;

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
