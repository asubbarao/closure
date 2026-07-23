-- views.sql — live folds + page edge over a table model.
--
-- Naming (clarity first):
--   tables / views / CTEs  verbose snake_case  (data_from_pdf_words, batches_from_events)
--   view prefix            v_* is fine
--   relation aliases       2–3 letters (sug, doc, pag, cas, ent, …)
--   lambdas only           1-letter ok  list_transform(col, x -> …)
--
-- Table rule: create a TABLE only when multi-consumer re-run work makes
-- everything downstream simpler/robust. Prefer JOINs of named relations.
-- Lossy count* boards are not product. Semantic graph: closure_semantic.yaml.

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
      'v_case_surface', 'v_document_page_surface',
      'v_http_cache', 'v_http_cache_config', 'v_http_cache_status',
      'v_http_cache_access', 'v_http_cache_filesystems',
      'v_route_get', 'v_case_html', 'v_stream_page', 'v_audit_page', 'v_review_page'
  )
GROUP BY table_name;

-- ── live folds (change every decision POST) ────────────────────────────────

-- Marks = suggestion grain + live status/band.
-- Geometry is first-class: bbox (PDF), screen (canvas). UNNEST only if a consumer
-- needs flat CSS fields; the table/view keep typed STRUCTs.
CREATE OR REPLACE VIEW v_page_marks AS
SELECT sug.id, sug.document_id, sug.page_no, sug.line_no,
       sug.bbox, sug.screen,
       sug.text, sug.confidence, sug.status, sug.band, sug.kind, sug.entity_id, sug.flag_tag
FROM v_suggestions sug;

CREATE OR REPLACE VIEW v_audit AS
SELECT log.ts,
       coalesce(log.actor, 'reviewer') AS actor,
       coalesce(log.kind, 'decision') AS action,
       log.status,
       log.suggestion_id,
       coalesce(log.case_id, doc.case_id) AS case_id,
       log.document_id,
       coalesce(log.text, log.suggestion_id, '') AS target,
       log.reason,
       log.batch_id,
       log.batch_label,
       log.undoes_batch_id,
       sug.band,
       sug.kind AS pii_kind,
       sug.judge_panel
FROM v_src_decisions log
LEFT JOIN documents doc ON doc.id = log.document_id
LEFT JOIN v_suggestions sug ON sug.id = log.suggestion_id;

CREATE OR REPLACE VIEW v_export_blocked AS
SELECT doc.case_id,
       bool_or(sug.band = 'flagged' AND sug.status = 'pending') AS export_blocked
FROM documents doc
LEFT JOIN v_suggestions sug ON sug.document_id = doc.id
GROUP BY doc.case_id;

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
FROM v_src_decisions
WHERE nullif(batch_id, '') IS NOT NULL;

CREATE OR REPLACE VIEW v_undone_batches AS
SELECT undoes_batch_id AS batch_id
FROM v_history_events
WHERE undoes_batch_id IS NOT NULL
GROUP BY undoes_batch_id;

CREATE OR REPLACE VIEW v_decision_batches AS
SELECT bat.batch_id, bat.ts, bat.ts_end, bat.actor, bat.label, bat.suggestion_ids,
       bat.is_undo, bat.undoes_batch_id, bat.case_id,
       und.batch_id IS NOT NULL AS undone
FROM (
    SELECT batch_id,
           min(event_ts) AS ts,
           max(event_ts) AS ts_end,
           any_value(actor) AS actor,
           any_value(batch_label) AS label,
           list(suggestion_id ORDER BY event_ts) AS suggestion_ids,
           bool_or(undoes_batch_id IS NOT NULL) AS is_undo,
           max(undoes_batch_id) AS undoes_batch_id,
           max(case_id) AS case_id
    FROM v_history_events
    GROUP BY batch_id
) bat
LEFT JOIN v_undone_batches und ON und.batch_id = bat.batch_id;

CREATE OR REPLACE VIEW v_export_plans AS
WITH redaction_boxes_from_accepted AS (
    SELECT sug.document_id,
           list(struct_insert(bbox_to_redact(sug.bbox, pag.height_pt), page := sug.page_no::INTEGER)
                ORDER BY sug.page_no, sug.id) AS boxes
    FROM v_suggestions sug
    JOIN pages pag
      ON pag.document_id = sug.document_id AND pag.page_no = sug.page_no
    WHERE sug.status = 'accepted'
    GROUP BY sug.document_id
)
SELECT blk.case_id, blk.export_blocked AS blocked,
       doc.id AS document_id, doc.filename, doc.source_path,
       'exports/' || replace(replace(doc.filename, '/', '_'), chr(92), '_') || '_redacted.pdf' AS out_path,
       coalesce(box.boxes, []) AS boxes
FROM v_export_blocked blk
JOIN documents doc ON doc.case_id = blk.case_id
LEFT JOIN redaction_boxes_from_accepted box ON box.document_id = doc.id;

-- ── product surfaces (named spines — not denormalized fact tables) ─────────
-- Grain truth stays in cases / documents / entities / suggestions / decisions.
-- Re-spelling the same multi-join in every page handler is the smell; one
-- unmat surface view is the fix. A TABLE would go stale on every decision POST
-- (export_blocked, marks) — that fails the adversarial table test.

CREATE OR REPLACE VIEW v_case_documents AS
SELECT case_id, list(doc ORDER BY filename) AS documents
FROM documents doc
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

-- Case spine: join packs once. Library / stream / audit / API all read this.
CREATE OR REPLACE VIEW v_case_surface AS
SELECT cas.id AS case_id,
       cas.case_no,
       cas.title,
       coalesce(docs.documents, []) AS documents,
       coalesce(ents.entities, []) AS entities,
       coalesce(blk.export_blocked, false) AS export_blocked
FROM cases cas
LEFT JOIN v_case_documents docs ON docs.case_id = cas.id
LEFT JOIN v_case_entities ents ON ents.case_id = cas.id
LEFT JOIN v_export_blocked blk ON blk.case_id = cas.id;

CREATE OR REPLACE VIEW v_page_mark_lists AS
SELECT document_id, page_no, list(mrk) AS marks
FROM v_page_marks mrk
GROUP BY document_id, page_no;

-- Document×page spine: case + doc + page pins + marks + queue suggestions.
-- All product fields typed here; tera only maps columns → template keys (JSON).
CREATE OR REPLACE VIEW v_document_page_surface AS
SELECT doc.id AS document_id,
       doc.case_id,
       doc.filename,
       doc.page_count,
       pag.page_no,
       pag.width_pt,
       pag.height_pt,
       pag.scale,
       pag.display_w,
       pag.display_h,
       greatest(pag.page_no - 1, 1) AS page_prev,
       least(pag.page_no + 1, doc.page_count) AS page_next,
       '/pages/' || doc.filename || '/p' || pag.page_no || '.png' AS png_href,
       cas.case_no,
       cas.title AS case_title,
       coalesce(ml.marks, []) AS marks,
       coalesce(sl.suggestions, []) AS suggestions
FROM documents doc
JOIN cases cas ON cas.id = doc.case_id
JOIN pages pag ON pag.document_id = doc.id
LEFT JOIN v_page_mark_lists ml
  ON ml.document_id = doc.id AND ml.page_no = pag.page_no
LEFT JOIN LATERAL (
    SELECT list(sug ORDER BY (sug.page_no = pag.page_no) DESC,
                         (sug.status = 'pending') DESC, sug.page_no, sug.id) AS suggestions
    FROM v_suggestions sug
    WHERE sug.document_id = doc.id
      AND (sug.page_no = pag.page_no OR sug.status = 'pending')
) sl ON true;

-- ── tera edge only: surface columns → JSON keys the templates already use ──
-- tera_render(template, JSON) requires a bag; logic stays upstream of here.

CREATE OR REPLACE VIEW v_case_ctx AS
SELECT sfc.case_id,
       json_object(
           'case', struct_pack(id := sfc.case_id, case_no := sfc.case_no, title := sfc.title),
           'documents', sfc.documents,
           'entities', sfc.entities,
           'audit', coalesce(aud.audit, []),
           'export_blocked', sfc.export_blocked
       ) AS ctx
FROM v_case_surface sfc
LEFT JOIN v_case_audit_recent aud ON aud.case_id = sfc.case_id;

CREATE OR REPLACE VIEW v_stream_ctx AS
SELECT sfc.case_id,
       json_object(
           'case', struct_pack(id := sfc.case_id, case_no := sfc.case_no, title := sfc.title),
           'entities', sfc.entities,
           'export_blocked', sfc.export_blocked
       ) AS ctx
FROM v_case_surface sfc;

CREATE OR REPLACE VIEW v_audit_ctx AS
SELECT sfc.case_id,
       json_object(
           'case', struct_pack(id := sfc.case_id, case_no := sfc.case_no, title := sfc.title),
           'export_blocked', sfc.export_blocked,
           'batches', coalesce(bat.batches, []),
           'events', coalesce(evt.events, [])
       ) AS ctx
FROM v_case_surface sfc
LEFT JOIN v_case_batches bat ON bat.case_id = sfc.case_id
LEFT JOIN v_case_events evt ON evt.case_id = sfc.case_id;

CREATE OR REPLACE VIEW v_review_ctx AS
SELECT sfc.document_id, sfc.page_no,
       json_object(
           'case', struct_pack(id := sfc.case_id, case_no := sfc.case_no, title := sfc.case_title),
           'doc',  struct_pack(id := sfc.document_id, filename := sfc.filename, page_count := sfc.page_count),
           'page', struct_pack(
               page_no := sfc.page_no,
               prev := sfc.page_prev,
               next := sfc.page_next,
               width_pt := sfc.width_pt, height_pt := sfc.height_pt,
               scale := round(sfc.scale, 4),
               display_w := sfc.display_w, display_h := sfc.display_h,
               png_href := sfc.png_href
           ),
           'marks', sfc.marks,
           'suggestions', sfc.suggestions
       ) AS ctx
FROM v_document_page_surface sfc;

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
