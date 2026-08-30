-- views.sql — product WHERE + render. Lists from children only (null = empty). No ifnull/struct_pack laundry.

DROP SEMANTIC VIEW IF EXISTS suggestion_metrics;
DROP SEMANTIC VIEW IF EXISTS closure;
CREATE SEMANTIC VIEW closure FROM YAML FILE 'server/config/closure_semantic.yaml';

-- Product projections (lived in core; exemplar keeps core as pins + detect).
CREATE OR REPLACE VIEW v_latest_decision AS
SELECT suggestion_id, status, actor, reason, ts
FROM v_src_decisions
WHERE kind = 'decision' AND suggestion_id IS NOT NULL
QUALIFY row_number() OVER (PARTITION BY suggestion_id ORDER BY ts DESC) = 1;

CREATE OR REPLACE VIEW v_suggestions AS
SELECT mark.*,
       CASE
           WHEN dec.status IS NOT NULL THEN dec.status
           WHEN mark.source = 'manual' THEN 'accepted'
           ELSE 'pending'
       END AS status
FROM suggestions mark
LEFT JOIN v_latest_decision dec ON dec.suggestion_id = mark.id;

CREATE OR REPLACE VIEW v_decide_targets AS
SELECT * RENAME (id AS suggestion_id) FROM v_suggestions;

CREATE OR REPLACE VIEW v_suggestion_line_context AS
SELECT sug.id AS suggestion_id, sug.document_id, sug.page_no, sug.line_no AS hit_line,
       lin.line_no AS line_number, lin.line_text,
       abs(lin.line_no - sug.line_no)::INTEGER AS dist
FROM suggestions sug
JOIN document_lines lin
  ON lin.document_id = sug.document_id AND lin.page_no = sug.page_no
 AND abs(lin.line_no - sug.line_no) <= 3
WHERE sug.line_no IS NOT NULL;

CREATE OR REPLACE VIEW v_suggestion_judge_votes AS
SELECT sug.id AS suggestion_id, sug.kind, sug.text,
       ver.judge, ver.model_name, ver.verdict, ver.reason, ver.reply
FROM suggestions sug
JOIN judge_verdicts ver ON ver.kind = sug.kind AND ver.text = sug.text;

CREATE OR REPLACE VIEW v_url_hosts AS
SELECT hostname, dns_lookup(hostname) AS a_record, dns_lookup_all(hostname) AS a_records
FROM words WHERE nullif(hostname, '') IS NOT NULL
GROUP BY hostname;

CREATE OR REPLACE VIEW v_cols AS
SELECT table_name AS relation,
       array_agg([column_name, data_type] ORDER BY ordinal_position) AS cols
FROM information_schema.columns
WHERE table_schema = 'main'
  AND table_name IN (
      'cases', 'documents', 'pages', 'words', 'entities', 'suggestions', 'decisions',
      'v_suggestions', 'v_decide_targets', 'v_nav', 'v_export_plans',
      'v_audit', 'v_decision_batches', 'v_history_events', 'v_hostfs', 'v_zips',
      'v_shell_patterns', 'v_url_hosts', 'v_suggestion_line_context', 'v_cols',
      'v_http_cache', 'v_http_cache_status', 'v_http_cache_access',
      'v_route_get', 'v_pages', 'v_review_page', 'v_flagged_pending',
      'v_remainder_pending', 'v_flagged_by_doc', 'v_case_shell', 'v_page_nav'
  )
GROUP BY table_name;

CREATE OR REPLACE VIEW v_flagged_pending AS
SELECT * FROM v_suggestions
WHERE band = 'flagged' AND status = 'pending';

CREATE OR REPLACE VIEW v_remainder_pending AS
SELECT * FROM v_suggestions
WHERE status = 'pending' AND detector_key = 'detector:remainder';

CREATE OR REPLACE VIEW v_audit AS
SELECT log.ts, log.actor, log.kind AS action, log.status, log.suggestion_id,
       log.case_id, log.document_id, log.text AS target, log.reason,
       log.batch_id, log.batch_label, log.undoes_batch_id,
       strftime(log.ts, '%H:%M') AS ts_short,
       strftime(log.ts, '%Y-%m-%d %H:%M:%S') AS ts_full,
       sug.band, sug.kind AS pii_kind, sug.judge_panel
FROM v_src_decisions log
LEFT JOIN v_suggestions sug ON sug.id = log.suggestion_id;

CREATE OR REPLACE VIEW v_nav AS
SELECT case_id, '/documents/' || id AS href, filename AS text FROM documents
UNION ALL BY NAME
SELECT DISTINCT cas.id AS case_id,
       replace(lnk.href, '{{ case.id }}', cas.id) AS href,
       trim(lnk.link_text, '← ') AS text
FROM template_links lnk
JOIN cases cas ON contains(lnk.href, '{{ case.id }}');

CREATE OR REPLACE VIEW v_history_events AS
SELECT kind, suggestion_id, status, actor, reason, ts AS event_ts,
       document_id, case_id, text, batch_id, batch_label, undoes_batch_id
FROM v_src_decisions WHERE batch_id IS NOT NULL;

CREATE OR REPLACE VIEW v_decision_batches AS
WITH g AS (
    SELECT batch_id,
           arg_min(case_id, event_ts) AS case_id,
           min(event_ts) AS ts,
           max(event_ts) AS ts_end,
           strftime(min(event_ts), '%Y-%m-%d %H:%M') AS ts_short,
           arg_min(actor, event_ts) AS actor,
           arg_min(batch_label, event_ts) AS label,
           list(suggestion_id ORDER BY event_ts) AS suggestion_ids,
           array_to_string(list(suggestion_id ORDER BY event_ts), ', ') AS members,
           max(undoes_batch_id) AS undoes_batch_id
    FROM v_history_events
    GROUP BY batch_id
),
undone AS (
    SELECT undoes_batch_id AS batch_id
    FROM v_history_events
    WHERE undoes_batch_id IS NOT NULL
    GROUP BY undoes_batch_id
)
SELECT g.*,
       g.undoes_batch_id IS NOT NULL AS is_undo,
       u.batch_id IS NOT NULL AS undone
FROM g
LEFT JOIN undone u ON u.batch_id = g.batch_id;

CREATE OR REPLACE VIEW v_export_plans AS
WITH boxes AS (
    SELECT sug.document_id,
           list(struct_insert(
               (sug.bbox.x0, pag.height_pt - sug.bbox.y1,
                sug.bbox.x1 - sug.bbox.x0, sug.bbox.y1 - sug.bbox.y0)::redact_box,
               page := sug.page_no::INTEGER) ORDER BY sug.page_no, sug.id) AS boxes
    FROM v_suggestions sug
    JOIN pages pag ON pag.document_id = sug.document_id AND pag.page_no = sug.page_no
    WHERE sug.status = 'accepted'
    GROUP BY sug.document_id
),
blocked AS (
    SELECT DISTINCT case_id FROM v_flagged_pending
)
SELECT doc.case_id, doc.id AS document_id, doc.filename, doc.source_path,
       'exports/' || doc.filename || '_redacted.pdf' AS out_path,
       boxes.boxes,
       blk.case_id IS NOT NULL AS blocked
FROM documents doc
LEFT JOIN boxes ON boxes.document_id = doc.id
LEFT JOIN blocked blk ON blk.case_id = doc.case_id;

CREATE OR REPLACE VIEW v_flagged_by_doc AS
SELECT case_id, document_id, filename,
       list(fp ORDER BY page_no, id) AS rows
FROM v_flagged_pending fp
GROUP BY case_id, document_id, filename;

CREATE OR REPLACE VIEW v_case_shell AS
SELECT cas.*,
       blk.case_id IS NOT NULL AS export_blocked
FROM cases cas
LEFT JOIN (SELECT DISTINCT case_id FROM v_flagged_pending) blk ON blk.case_id = cas.id;

-- Page row + nav fields (product shape for review).
CREATE OR REPLACE VIEW v_page_nav AS
SELECT pag.document_id, pag.page_no, pag.width_pt, pag.height_pt, pag.scale,
       pag.display_w, pag.display_h,
       greatest(pag.page_no - 1, 1) AS prev,
       least(pag.page_no + 1, doc.page_count) AS next,
       -- setup_pages writes pages/<stem>/pN.png (stem = parse_filename without .pdf)
       '/pages/' || parse_filename(doc.filename, true) || '/p' || pag.page_no || '.png' AS png_href
FROM pages pag
JOIN documents doc ON doc.id = pag.document_id;

-- Child-only lists: missing join → null → template {% if %}. Never ifnull(list, []).
CREATE OR REPLACE VIEW v_pages AS
WITH
docs AS (SELECT case_id, list(d ORDER BY filename) AS documents FROM documents d GROUP BY case_id),
ents AS (SELECT case_id, list(e ORDER BY kind, canonical_text) AS entities FROM entities e GROUP BY case_id),
-- Library "Recent audit" is a short slice; full trail lives on /audit.
aud  AS (SELECT case_id, list_slice(list(a ORDER BY ts DESC), 1, 12) AS audit FROM v_audit a GROUP BY case_id),
evts AS (SELECT case_id, list(a ORDER BY ts DESC) AS events FROM v_audit a GROUP BY case_id),
bats AS (SELECT case_id, list(b ORDER BY ts DESC) AS batches FROM v_decision_batches b GROUP BY case_id),
flags AS (SELECT case_id, list(bd ORDER BY filename) AS by_doc FROM v_flagged_by_doc bd GROUP BY case_id),
rems AS (SELECT case_id, list(r ORDER BY filename, page_no, id) AS remainder FROM v_remainder_pending r GROUP BY case_id)
SELECT path, tera_render(template, ctx, template_path := 'server/templates/**/*.html') AS html
FROM (
    SELECT '/cases/' || s.id AS path, 'case.html' AS template,
           json_object('case', s, 'documents', docs.documents, 'entities', ents.entities,
                       'audit', aud.audit, 'export_blocked', s.export_blocked) AS ctx
    FROM v_case_shell s
    LEFT JOIN docs ON docs.case_id = s.id
    LEFT JOIN ents ON ents.case_id = s.id
    LEFT JOIN aud ON aud.case_id = s.id
    UNION ALL
    SELECT '/cases/' || s.id || '/stream', 'stream.html',
           json_object('case', s, 'entities', ents.entities, 'export_blocked', s.export_blocked)
    FROM v_case_shell s
    LEFT JOIN ents ON ents.case_id = s.id
    UNION ALL
    SELECT '/cases/' || s.id || '/flagged', 'flagged.html',
           json_object('case', s, 'export_blocked', s.export_blocked, 'by_doc', flags.by_doc)
    FROM v_case_shell s
    LEFT JOIN flags ON flags.case_id = s.id
    UNION ALL
    SELECT '/cases/' || s.id || '/remainder', 'remainder.html',
           json_object('case', s, 'export_blocked', s.export_blocked, 'remainder', rems.remainder)
    FROM v_case_shell s
    LEFT JOIN rems ON rems.case_id = s.id
    UNION ALL
    SELECT '/cases/' || s.id || '/audit', 'audit.html',
           json_object('case', s, 'export_blocked', s.export_blocked,
                       'batches', bats.batches, 'events', evts.events)
    FROM v_case_shell s
    LEFT JOIN bats ON bats.case_id = s.id
    LEFT JOIN evts ON evts.case_id = s.id
);

CREATE OR REPLACE VIEW v_review_page AS
WITH page_sugs AS (
    SELECT document_id, page_no,
           list(sug ORDER BY (status = 'pending') DESC, id) AS suggestions
    FROM v_suggestions sug
    GROUP BY document_id, page_no
)
SELECT doc.id AS document_id, nav.page_no,
       CASE WHEN nav.page_no = 1 THEN '/documents/' || doc.id
            ELSE '/documents/' || doc.id || '/pages/' || nav.page_no::VARCHAR END AS path,
       tera_render('review.html',
           json_object('case', cas, 'doc', doc, 'page', nav, 'suggestions', ps.suggestions),
           template_path := 'server/templates/**/*.html') AS html
FROM documents doc
JOIN cases cas ON cas.id = doc.case_id
JOIN v_page_nav nav ON nav.document_id = doc.id
LEFT JOIN page_sugs ps ON ps.document_id = doc.id AND ps.page_no = nav.page_no;
