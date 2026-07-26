-- views.sql — live folds + product surfaces + thin tera edge.
--
-- Naming: verbose CTEs/views; aliases 2–3 letters (sug, doc, pag, cas);
--         lambdas only use 1-letter (list_transform(xs, x -> …)).
-- Surfaces name the join once. Ctx only maps typed columns → template keys.
-- Geometry is first-class on the mark grain (bbox / screen). No count boards.

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
      'v_export_blocked', 'v_case_flagged_pending', 'v_export_plans', 'v_audit',
      'v_decision_batches',
      'v_history_events', 'v_hostfs', 'v_zips', 'v_shell_patterns',
      'v_url_hosts', 'v_suggestion_line_context', 'v_cols', 'v_page_marks',
      'v_case_surface', 'v_document_page_surface',
      'v_http_cache', 'v_http_cache_config', 'v_http_cache_status',
      'v_http_cache_access', 'v_http_cache_filesystems',
      'v_route_get', 'v_pages', 'v_review_page',
      'v_flagged_pending', 'v_remainder_pending', 'v_entity_work', 'v_decision_batches'
  )
GROUP BY table_name;

-- ── live folds ─────────────────────────────────────────────────────────────

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
       -- prefer text; fall back to id (NULL stays NULL — templates render empty)
       coalesce(log.text, log.suggestion_id) AS target,
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

-- Export gate: store the id list; len(list) is free (not bool_or / count*).
CREATE OR REPLACE VIEW v_case_flagged_pending AS
SELECT doc.case_id,
       list(sug.id ORDER BY sug.id) AS flagged_pending_ids
FROM documents doc
JOIN v_suggestions sug ON sug.document_id = doc.id
WHERE sug.band = 'flagged' AND sug.status = 'pending'
GROUP BY doc.case_id;

CREATE OR REPLACE VIEW v_export_blocked AS
SELECT cas.id AS case_id,
       coalesce(fp.flagged_pending_ids, []) AS flagged_pending_ids,
       len(coalesce(fp.flagged_pending_ids, [])) > 0 AS export_blocked
FROM cases cas
LEFT JOIN v_case_flagged_pending fp ON fp.case_id = cas.id;

CREATE OR REPLACE VIEW v_nav AS
SELECT case_id, '/documents/' || id AS href, filename AS text
FROM documents
UNION ALL BY NAME
SELECT id AS case_id, '/cases/' || id AS href, 'Library' AS text FROM cases
UNION ALL BY NAME
SELECT id AS case_id, '/cases/' || id || '/stream' AS href, 'Entity stream' AS text FROM cases
UNION ALL BY NAME
SELECT id AS case_id, '/cases/' || id || '/flagged' AS href, 'Flagged triage' AS text FROM cases
UNION ALL BY NAME
SELECT id AS case_id, '/cases/' || id || '/remainder' AS href, 'FN remainder' AS text FROM cases
UNION ALL BY NAME
SELECT id AS case_id, '/cases/' || id || '/audit' AS href, 'Audit' AS text FROM cases;

CREATE OR REPLACE VIEW v_history_events AS
SELECT kind, suggestion_id, status, actor, reason, ts AS event_ts,
       document_id, case_id, text, batch_id, batch_label, undoes_batch_id
FROM v_src_decisions
WHERE batch_id IS NOT NULL;

-- Batches: array_agg everything that matters; ts / is_undo / counts = list ops free.
CREATE OR REPLACE VIEW v_decision_batches AS
WITH batches_from_history_events AS (
    SELECT batch_id,
           list(suggestion_id ORDER BY event_ts) AS suggestion_ids,
           list(event_ts ORDER BY event_ts) AS event_timestamps,
           list(actor ORDER BY event_ts) AS actors,
           list(batch_label ORDER BY event_ts) AS labels,
           list(undoes_batch_id ORDER BY event_ts) AS undoes_batch_ids,
           list(case_id ORDER BY event_ts) AS case_ids
    FROM v_history_events
    GROUP BY batch_id
),
batches_with_list_ops AS (
    SELECT batch_id,
           suggestion_ids,
           event_timestamps,
           actors,
           labels,
           undoes_batch_ids,
           case_ids,
           event_timestamps[1] AS ts,
           event_timestamps[len(event_timestamps)] AS ts_end,
           actors[1] AS actor,
           labels[1] AS label,
           case_ids[1] AS case_id,
           list_filter(undoes_batch_ids, x -> x IS NOT NULL) AS undoes_nonnull
    FROM batches_from_history_events
)
SELECT bat.batch_id,
       bat.suggestion_ids,
       bat.event_timestamps,
       bat.ts,
       bat.ts_end,
       strftime(bat.ts, '%Y-%m-%d %H:%M') AS ts_short,  -- display pins here → list(row) rollup
       bat.actor,
       bat.label,
       array_to_string(bat.suggestion_ids, ', ') AS members,
       len(bat.suggestion_ids) AS n_members,
       bat.case_id,
       bat.undoes_nonnull[1] AS undoes_batch_id,
       len(bat.undoes_nonnull) > 0 AS is_undo,
       und.batch_id IS NOT NULL AS undone
FROM batches_with_list_ops bat
LEFT JOIN (
    SELECT undoes_batch_id AS batch_id
    FROM v_history_events
    WHERE undoes_batch_id IS NOT NULL
    GROUP BY undoes_batch_id
) und ON und.batch_id = bat.batch_id;

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
SELECT blk.case_id,
       blk.flagged_pending_ids,
       len(blk.flagged_pending_ids) > 0 AS blocked,
       doc.id AS document_id, doc.filename, doc.source_path,
       'exports/' || replace(replace(doc.filename, '/', '_'), chr(92), '_') || '_redacted.pdf' AS out_path,
       coalesce(box.boxes, []) AS boxes
FROM v_export_blocked blk
JOIN documents doc ON doc.case_id = blk.case_id
LEFT JOIN redaction_boxes_from_accepted box ON box.document_id = doc.id;

-- ── list packs (multi-consumer → surface) ──────────────────────────────────

CREATE OR REPLACE VIEW v_case_documents AS
SELECT case_id, list(doc ORDER BY filename) AS documents
FROM documents doc
GROUP BY case_id;

-- Entity work: one pending scan; n_* = len(list) on packed lists (no re-list).
CREATE OR REPLACE VIEW v_entity_work AS
WITH work AS (
    SELECT sug.entity_id, sug.id, sug.document_id, sug.page_no, doc.filename,
           sug.band = 'flagged' AS is_flagged
    FROM v_suggestions sug
    JOIN documents doc ON doc.id = sug.document_id
    WHERE sug.entity_id IS NOT NULL AND sug.status = 'pending'
),
packed AS (
    SELECT ent.id, ent.id AS entity_id, ent.case_id, ent.canonical_text,
           ent.kind, ent.kind_label, ent.mono,
           coalesce(list(w.id ORDER BY w.document_id, w.page_no) FILTER (NOT w.is_flagged), []) AS pending_ids,
           coalesce(list(DISTINCT w.document_id) FILTER (NOT w.is_flagged), []) AS pending_doc_ids,
           coalesce(list(DISTINCT w.filename) FILTER (NOT w.is_flagged), []) AS pending_filenames,
           coalesce(list(w.id ORDER BY w.id) FILTER (w.is_flagged), []) AS flagged_ids
    FROM entities ent
    LEFT JOIN work w ON w.entity_id = ent.id
    GROUP BY ent.id, ent.case_id, ent.canonical_text, ent.kind, ent.kind_label, ent.mono
)
SELECT *, len(pending_ids) AS n_pending, len(pending_doc_ids) AS n_docs,
       len(flagged_ids) AS n_flagged
FROM packed;

-- Rollup = list(row); the row already carries id / n_* the template reads.
CREATE OR REPLACE VIEW v_case_entities AS
SELECT case_id, list(ew ORDER BY ew.kind, ew.canonical_text) AS entities
FROM v_entity_work ew
GROUP BY case_id;

CREATE OR REPLACE VIEW v_case_audit_recent AS
SELECT case_id,
       list(struct_pack(
           ts_short := strftime(ts, '%H:%M'), action := action, actor := actor,
           target := target, reason := reason
       ) ORDER BY ts DESC) AS audit
FROM v_audit
GROUP BY case_id;

CREATE OR REPLACE VIEW v_case_batches AS
SELECT case_id, list(db ORDER BY db.ts DESC) AS batches
FROM v_decision_batches db
GROUP BY case_id;

CREATE OR REPLACE VIEW v_case_events AS
SELECT case_id,
       list(struct_pack(
           ts_short := strftime(ts, '%Y-%m-%d %H:%M:%S'),
           action := action,
           status := status,
           actor := actor,
           target := target,
           reason := reason,
           band := band,
           batch_label := batch_label,
           is_undo := undoes_batch_id IS NOT NULL
       ) ORDER BY ts DESC) AS events
FROM v_audit
GROUP BY case_id;

CREATE OR REPLACE VIEW v_page_mark_lists AS
SELECT document_id, page_no, list(mrk) AS marks
FROM v_page_marks mrk
GROUP BY document_id, page_no;

-- ── product surfaces (named spines) ────────────────────────────────────────

CREATE OR REPLACE VIEW v_case_surface AS
SELECT cas.id AS case_id,
       cas.case_no,
       cas.title,
       struct_pack(id := cas.id, case_no := cas.case_no, title := cas.title) AS case_row,
       coalesce(docs.documents, []) AS documents,
       coalesce(ents.entities, []) AS entities,
       coalesce(blk.flagged_pending_ids, []) AS flagged_pending_ids,
       len(coalesce(blk.flagged_pending_ids, [])) AS n_flagged_pending,
       len(coalesce(blk.flagged_pending_ids, [])) > 0 AS export_blocked
FROM cases cas
LEFT JOIN v_case_documents docs ON docs.case_id = cas.id
LEFT JOIN v_case_entities ents ON ents.case_id = cas.id
LEFT JOIN v_export_blocked blk ON blk.case_id = cas.id;

-- Flagged triage grain: judge votes as workflow help (not ML scores).
CREATE OR REPLACE VIEW v_flagged_pending AS
SELECT sug.id, sug.document_id, doc.filename, doc.case_id, sug.page_no,
       sug.text, sug.kind, sug.confidence, sug.status, sug.band,
       sug.entity_id, sug.entity_text, sug.detector_key,
       sug.judge_panel, sug.judge_reason, sug.reason,
       sug.judge_agreement, sug.judge_votes,
       sug.flag_tag
FROM v_suggestions sug
JOIN documents doc ON doc.id = sug.document_id
WHERE sug.band = 'flagged' AND sug.status = 'pending';

-- Flat list (API) + document-grouped list (triage UI multi-doc).
CREATE OR REPLACE VIEW v_case_flagged_rows AS
SELECT case_id, list(fp ORDER BY fp.filename, fp.page_no, fp.id) AS flagged
FROM v_flagged_pending fp
GROUP BY case_id;

CREATE OR REPLACE VIEW v_case_flagged_by_doc AS
SELECT case_id, list(bd ORDER BY bd.filename) AS by_doc
FROM (
    SELECT case_id, document_id, filename,
           list(fp.id ORDER BY fp.page_no, fp.id) AS ids,
           len(list(fp.id)) AS n,  -- template reads .n; carry it as a column
           list(fp ORDER BY fp.page_no, fp.id) AS rows
    FROM v_flagged_pending fp
    GROUP BY case_id, document_id, filename
) bd
GROUP BY case_id;

-- FN remainder queue: detector said miss; human accepts (redact) or rejects (noise).
CREATE OR REPLACE VIEW v_remainder_pending AS
SELECT sug.id, sug.document_id, doc.filename, doc.case_id, sug.page_no,
       sug.text, sug.kind, sug.confidence, sug.status, sug.band,
       sug.detector_key, sug.reason, sug.judge_panel, sug.judge_reason
FROM v_suggestions sug
JOIN documents doc ON doc.id = sug.document_id
WHERE sug.status = 'pending'
  AND sug.detector_key = 'detector:remainder';

CREATE OR REPLACE VIEW v_case_remainder_rows AS
SELECT case_id, list(rp ORDER BY rp.filename, rp.page_no, rp.id) AS remainder
FROM v_remainder_pending rp
GROUP BY case_id;

-- Doc-scoped id lists for review header (len free; no correlated re-scan).
CREATE OR REPLACE VIEW v_document_flagged_ids AS
SELECT document_id, list(id ORDER BY id) AS flagged_pending_ids
FROM v_flagged_pending
GROUP BY document_id;

CREATE OR REPLACE VIEW v_document_remainder_ids AS
SELECT document_id, list(id ORDER BY id) AS remainder_ids
FROM v_remainder_pending
GROUP BY document_id;

CREATE OR REPLACE VIEW v_document_page_surface AS
SELECT doc.id AS document_id,
       doc.case_id,
       doc.filename,
       doc.page_count,
       pag.page_no,
       pag.scale,
       pag.display_w,
       pag.display_h,
       pag.width_pt,
       pag.height_pt,
       cas.case_no,
       cas.title AS case_title,
       struct_pack(id := cas.id, case_no := cas.case_no, title := cas.title) AS case_row,
       struct_pack(id := doc.id, filename := doc.filename, page_count := doc.page_count) AS doc_row,
       struct_pack(
           page_no := pag.page_no,
           prev := greatest(pag.page_no - 1, 1),
           next := least(pag.page_no + 1, doc.page_count),
           width_pt := pag.width_pt,
           height_pt := pag.height_pt,
           scale := round(pag.scale, 4),
           display_w := pag.display_w,
           display_h := pag.display_h,
           png_href := '/pages/' || doc.filename || '/p' || pag.page_no || '.png'
       ) AS page_row,
       coalesce(ml.marks, []) AS marks,
       coalesce(sl.suggestions, []) AS suggestions
FROM documents doc
JOIN cases cas ON cas.id = doc.case_id
JOIN pages pag ON pag.document_id = doc.id
LEFT JOIN v_page_mark_lists ml
  ON ml.document_id = doc.id AND ml.page_no = pag.page_no
-- Rail = this page only (not every pending on the doc — that blew SSR to 12MB+).
LEFT JOIN LATERAL (
    SELECT list(sug ORDER BY (sug.status = 'pending') DESC, sug.id) AS suggestions
    FROM v_suggestions sug
    WHERE sug.document_id = doc.id AND sug.page_no = pag.page_no
) sl ON true;

-- ── tera edge: ONE render relation, not a ctx+html view per page ────────────
-- Each page is a row (path, template, ctx json); tera_render runs once over the
-- union. ctx = json_object of already-joined surface columns — no logic here.
-- Add a page = one UNION arm. Route bodies match on path.
CREATE OR REPLACE VIEW v_pages AS
SELECT path, tera_render(template, ctx, template_path := 'server/templates/**/*.html') AS html
FROM (
    SELECT '/cases/' || sfc.case_id AS path, 'case.html' AS template,
           json_object('case', sfc.case_row, 'documents', sfc.documents,
               'entities', sfc.entities, 'audit', coalesce(aud.audit, []),
               'export_blocked', sfc.export_blocked, 'n_flagged_pending', sfc.n_flagged_pending) AS ctx
    FROM v_case_surface sfc LEFT JOIN v_case_audit_recent aud ON aud.case_id = sfc.case_id
    UNION ALL
    SELECT '/cases/' || sfc.case_id || '/stream', 'stream.html',
           json_object('case', sfc.case_row, 'entities', sfc.entities,
               'export_blocked', sfc.export_blocked, 'n_flagged_pending', sfc.n_flagged_pending)
    FROM v_case_surface sfc
    UNION ALL
    SELECT '/cases/' || sfc.case_id || '/flagged', 'flagged.html',
           json_object('case', sfc.case_row, 'export_blocked', sfc.export_blocked,
               'n_flagged_pending', sfc.n_flagged_pending,
               'flagged', coalesce(flg.flagged, []), 'by_doc', coalesce(bd.by_doc, []))
    FROM v_case_surface sfc
    LEFT JOIN v_case_flagged_rows flg ON flg.case_id = sfc.case_id
    LEFT JOIN v_case_flagged_by_doc bd ON bd.case_id = sfc.case_id
    UNION ALL
    SELECT '/cases/' || sfc.case_id || '/remainder', 'remainder.html',
           json_object('case', sfc.case_row, 'export_blocked', sfc.export_blocked,
               'remainder', coalesce(rem.remainder, []), 'n_remainder', len(coalesce(rem.remainder, [])))
    FROM v_case_surface sfc LEFT JOIN v_case_remainder_rows rem ON rem.case_id = sfc.case_id
    UNION ALL
    SELECT '/cases/' || sfc.case_id || '/audit', 'audit.html',
           json_object('case', sfc.case_row, 'export_blocked', sfc.export_blocked,
               'n_flagged_pending', sfc.n_flagged_pending,
               'batches', coalesce(bat.batches, []), 'events', coalesce(evt.events, []))
    FROM v_case_surface sfc
    LEFT JOIN v_case_batches bat ON bat.case_id = sfc.case_id
    LEFT JOIN v_case_events evt ON evt.case_id = sfc.case_id
);

-- Review is document/page grain (its own view); same render shape + canvas ctx.
CREATE OR REPLACE VIEW v_review_page AS
SELECT sfc.document_id, sfc.page_no,
       '/documents/' || sfc.document_id
           || if(sfc.page_no = 1, '', '/pages/' || sfc.page_no::VARCHAR) AS path,
       tera_render('review.html',
           json_object('case', sfc.case_row, 'doc', sfc.doc_row, 'page', sfc.page_row,
               'marks', sfc.marks, 'suggestions', sfc.suggestions,
               'n_doc_flagged', len(coalesce(flg.flagged_pending_ids, [])),
               'n_doc_remainder', len(coalesce(rem.remainder_ids, []))),
           template_path := 'server/templates/**/*.html') AS html
FROM v_document_page_surface sfc
LEFT JOIN v_document_flagged_ids flg ON flg.document_id = sfc.document_id
LEFT JOIN v_document_remainder_ids rem ON rem.document_id = sfc.document_id;
