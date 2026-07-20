-- routes/pages.sql — HTML page routes (no render mega-macros).
-- Contract: case.html {case,stats,documents,entities,audit};
--   audit.html {case,events};
--   review.html {case,doc,page,words,marks,docs,page_map,suggestions,stats} (no proof).
-- Stats: v_document_stats. Ids VARCHAR. Shells = raw app_templates.

-- Per-doc library/rail row over v_document_stats + scan badges.
CREATE OR REPLACE VIEW v_doc_ui AS
SELECT
    ds.document_id AS id, ds.case_id, ds.filename, ds.page_count, ds.word_count,
    ds.width_pt, ds.height_pt, ds.file_size, d.source_path,
    sc.scan_badge, sc.scan_badge_class, sc.scan_detail,
    coalesce(sc.is_scanned, false) AS is_scanned,
    coalesce(sc.ocr_ingested, false) AS ocr_ingested,
    coalesce(sc.scan_gap, false) AS scan_gap,
    ds.suggestion_count, ds.pending_count, ds.accepted_count, ds.rejected_count,
    ds.flagged_count, ds.high_count, ds.review_count,
    CASE WHEN ds.suggestion_count = 0 THEN 0
         ELSE round(100.0 * (ds.accepted_count + ds.rejected_count)
                    / ds.suggestion_count, 0)::INTEGER END AS progress_pct,
    CASE WHEN ds.flagged_count > 0 THEN 'flagged'
         WHEN ds.suggestion_count = 0 THEN 'empty'
         WHEN ds.pending_count = 0 THEN 'done' ELSE 'review' END AS status,
    CASE WHEN ds.file_size IS NULL THEN '—'
         WHEN ds.file_size >= 1048576 THEN round(ds.file_size / 1048576.0, 1)::VARCHAR || ' MB'
         WHEN ds.file_size >= 1024 THEN round(ds.file_size / 1024.0, 0)::VARCHAR || ' KB'
         ELSE ds.file_size::VARCHAR || ' B' END AS size_label
FROM v_document_stats ds
JOIN documents d ON cast(d.id AS VARCHAR) = ds.document_id
LEFT JOIN document_scan_status sc ON cast(sc.document_id AS VARCHAR) = ds.document_id;

-- Audit strip rows: the append-only decision log IS the audit trail; this is
-- its one display projection (case_id backfilled by JOIN, never a subselect).
-- Fallbacks: legacy log shards may lack ts/actor/kind; target is display text
-- only ('' = nothing to show), never a join/group key.
CREATE OR REPLACE VIEW v_audit AS
SELECT
    coalesce(try_cast(l.ts AS TIMESTAMP), now()) AS ts,
    coalesce(l.actor, 'reviewer') AS actor,
    coalesce(l.kind, 'decision') AS action,
    cast(l.suggestion_id AS VARCHAR) AS suggestion_id,
    coalesce(cast(l.case_id AS VARCHAR), d.case_id) AS case_id,
    coalesce(l.text, cast(l.suggestion_id AS VARCHAR), '') AS target,
    l.reason
FROM v_src_decisions l
LEFT JOIN documents d ON cast(d.id AS VARCHAR) = cast(l.document_id AS VARCHAR)
WHERE l.kind IN ('decision', 'added');

CREATE OR REPLACE VIEW v_page_geom AS
SELECT cast(p.document_id AS VARCHAR) AS document_id, p.page_no,
       p.width_pt, p.height_pt, 680.0 / p.width_pt AS scale,
       680.0 AS display_w, round(p.height_pt * (680.0 / p.width_pt), 1) AS display_h
FROM pages p;

CREATE OR REPLACE VIEW v_page_words AS
SELECT cast(w.document_id AS VARCHAR) AS document_id, w.page_no, w.word,
       w.x0, w.y0, w.x1, w.y1,
       round(w.x0 * g.scale, 2) AS left_px, round(w.y0 * g.scale, 2) AS top_px,
       round((w.x1 - w.x0) * g.scale, 2) AS width_px,
       round(greatest(w.y1 - w.y0, 4) * g.scale, 2) AS height_px,
       round(coalesce(w.font_size, 9) * g.scale * 0.95, 1) AS font_px, false AS is_hit
FROM words w
JOIN v_page_geom g ON g.document_id = cast(w.document_id AS VARCHAR) AND g.page_no = w.page_no;

CREATE OR REPLACE VIEW v_page_marks AS
SELECT cast(s.document_id AS VARCHAR) AS document_id, s.page_no,
       s.id, s.text, s.confidence, s.status, s.band, coalesce(s.kind, '') AS kind,
       round(s.x0 * g.scale, 2) AS left_px, round(s.y0 * g.scale, 2) AS top_px,
       round((s.x1 - s.x0) * g.scale, 2) AS width_px,
       round((s.y1 - s.y0) * g.scale, 2) AS height_px, false AS is_current
FROM v_suggestions s
JOIN v_page_geom g ON g.document_id = cast(s.document_id AS VARCHAR) AND g.page_no = s.page_no;

CREATE OR REPLACE VIEW v_page_map AS
SELECT cast(p.document_id AS VARCHAR) AS document_id, p.page_no,
       coalesce(c.n, 0)::BIGINT AS total,
       coalesce(c.pending, 0)::BIGINT AS pending,
       coalesce(c.flagged, 0)::BIGINT AS flagged
FROM pages p
LEFT JOIN (
    SELECT document_id, page_no, count(*)::BIGINT AS n,
           count(*) FILTER (WHERE status = 'pending')::BIGINT AS pending,
           count(*) FILTER (WHERE band = 'flagged' AND status = 'pending')::BIGINT AS flagged
    FROM v_suggestions GROUP BY document_id, page_no
) c ON cast(c.document_id AS VARCHAR) = cast(p.document_id AS VARCHAR) AND c.page_no = p.page_no;

-- case.html context (one row / case). Routes filter; no render_* macro.
CREATE OR REPLACE VIEW v_case_page AS
SELECT
    cast(c.id AS VARCHAR) AS case_id,
    struct_pack(id := c.id, case_no := c.case_no, title := c.title) AS case_obj,
    (SELECT struct_pack(
         doc_count := s.doc_count, page_count := s.page_count, word_count := s.word_count,
         entity_count := s.entity_count, suggestion_count := s.suggestion_count,
         pending_count := s.pending_count, accepted_count := s.accepted_count,
         rejected_count := s.rejected_count, flagged_count := s.flagged_count,
         resolved := s.accepted_count + s.rejected_count,
         progress_pct := CASE WHEN s.suggestion_count = 0 THEN 0
             ELSE round(100.0 * (s.accepted_count + s.rejected_count)
                        / s.suggestion_count, 0)::INTEGER END,
         accepted_pct := CASE WHEN s.suggestion_count = 0 THEN 0
             ELSE round(100.0 * s.accepted_count / s.suggestion_count, 0)::INTEGER END,
         pending_pct := CASE WHEN s.suggestion_count = 0 THEN 0
             ELSE round(100.0 * s.pending_count / s.suggestion_count, 0)::INTEGER END
     )
     FROM (
         SELECT count(*)::BIGINT AS doc_count,
                coalesce(sum(u.page_count), 0)::BIGINT AS page_count,
                coalesce(sum(u.word_count), 0)::BIGINT AS word_count,
                (SELECT count(*)::BIGINT FROM entities e
                 WHERE cast(e.case_id AS VARCHAR) = cast(c.id AS VARCHAR)) AS entity_count,
                coalesce(sum(u.suggestion_count), 0)::BIGINT AS suggestion_count,
                coalesce(sum(u.pending_count), 0)::BIGINT AS pending_count,
                coalesce(sum(u.accepted_count), 0)::BIGINT AS accepted_count,
                coalesce(sum(u.rejected_count), 0)::BIGINT AS rejected_count,
                coalesce(sum(u.flagged_count), 0)::BIGINT AS flagged_count
         FROM v_doc_ui u WHERE cast(u.case_id AS VARCHAR) = cast(c.id AS VARCHAR)
     ) s) AS stats,
    (SELECT coalesce(list(struct_pack(
         id := u.id, filename := u.filename, page_count := u.page_count,
         word_count := u.word_count, width_pt := u.width_pt, height_pt := u.height_pt,
         file_size := u.file_size, source_path := u.source_path,
         scan_badge := u.scan_badge, scan_badge_class := u.scan_badge_class,
         scan_detail := u.scan_detail, is_scanned := u.is_scanned,
         ocr_ingested := u.ocr_ingested, scan_gap := u.scan_gap,
         suggestion_count := u.suggestion_count, pending_count := u.pending_count,
         accepted_count := u.accepted_count, rejected_count := u.rejected_count,
         flagged_count := u.flagged_count, high_count := u.high_count,
         review_count := u.review_count, progress_pct := u.progress_pct,
         status := u.status, size_label := u.size_label
     ) ORDER BY u.filename), [])
     FROM v_doc_ui u WHERE cast(u.case_id AS VARCHAR) = cast(c.id AS VARCHAR)) AS documents,
    (SELECT coalesce(list(struct_pack(
         id := e.id, canonical_text := e.canonical_text, kind := e.kind,
         hit_count := coalesce(h.hit_count, 0)::BIGINT,
         doc_count := coalesce(h.doc_count, 0)::BIGINT,
         mono := (e.kind IN ('SSN', 'DATE OF BIRTH') OR starts_with(e.kind, 'PHONE'))
     ) ORDER BY coalesce(h.hit_count, 0) DESC, e.kind, e.canonical_text), [])
     FROM entities e
     LEFT JOIN (
         SELECT entity_id, count(*)::BIGINT AS hit_count,
                count(DISTINCT document_id)::BIGINT AS doc_count
         FROM v_suggestions WHERE entity_id IS NOT NULL GROUP BY entity_id
     ) h ON cast(h.entity_id AS VARCHAR) = cast(e.id AS VARCHAR)
     WHERE cast(e.case_id AS VARCHAR) = cast(c.id AS VARCHAR)) AS entities,
    (SELECT coalesce(list(struct_pack(
         ts_short := strftime(a.ts, '%H:%M'), action := a.action, actor := a.actor,
         target := coalesce(a.target, ''), reason := coalesce(a.reason, '')
     ) ORDER BY a.ts DESC), [])
     FROM (
         SELECT * FROM v_audit WHERE cast(case_id AS VARCHAR) = cast(c.id AS VARCHAR)
         ORDER BY coalesce(ts, TIMESTAMP '1970-01-01') DESC LIMIT 12
     ) a) AS audit
FROM cases c;

-- review.html for every (document, page). Routes filter; no proof key.
CREATE OR REPLACE VIEW v_review_page AS
SELECT
    cast(d.id AS VARCHAR) AS document_id,
    g.page_no,
    tera_render(
        (SELECT content FROM app_templates WHERE name = 'review.html'),
        {
            'case': struct_pack(id := d.case_id, case_no := c.case_no, title := c.title),
            'doc':  struct_pack(id := d.id, filename := d.filename, page_count := d.page_count),
            'page': struct_pack(
                page_no := g.page_no,
                prev := greatest(g.page_no - 1, 1),
                next := least(g.page_no + 1, d.page_count),
                width_pt := g.width_pt, height_pt := g.height_pt,
                scale := round(g.scale, 4), display_w := g.display_w, display_h := g.display_h,
                word_count := (SELECT count(*)::BIGINT FROM v_page_words w
                               WHERE w.document_id = cast(d.id AS VARCHAR)
                                 AND w.page_no = g.page_no),
                mark_count := (SELECT count(*)::BIGINT FROM v_page_marks m
                               WHERE m.document_id = cast(d.id AS VARCHAR)
                                 AND m.page_no = g.page_no),
                png_href := '/pages/' || d.filename || '/p' || g.page_no || '.png'
            ),
            'words': (SELECT coalesce(list(struct_pack(
                word := w.word, x0 := round(w.x0, 2), y0 := round(w.y0, 2),
                x1 := round(w.x1, 2), y1 := round(w.y1, 2),
                left_px := w.left_px, top_px := w.top_px,
                width := w.width_px, height := w.height_px,
                font_px := w.font_px, is_hit := w.is_hit
            )), []) FROM v_page_words w
                WHERE w.document_id = cast(d.id AS VARCHAR) AND w.page_no = g.page_no),
            'marks': (SELECT coalesce(list(struct_pack(
                id := m.id, text := m.text, confidence := m.confidence, status := m.status,
                band := m.band, kind := m.kind, left_px := m.left_px, top_px := m.top_px,
                width := m.width_px, height := m.height_px, current := m.is_current
            )), []) FROM v_page_marks m
                WHERE m.document_id = cast(d.id AS VARCHAR) AND m.page_no = g.page_no),
            'docs': (SELECT coalesce(list(struct_pack(
                id := u.id, filename := u.filename, page_count := u.page_count,
                word_count := u.word_count, suggestion_count := u.suggestion_count,
                pending_count := u.pending_count, flagged_count := u.flagged_count,
                progress_pct := u.progress_pct
            ) ORDER BY u.filename), [])
                FROM v_doc_ui u WHERE cast(u.case_id AS VARCHAR) = cast(d.case_id AS VARCHAR)),
            'page_map': (SELECT coalesce(list(struct_pack(
                page_no := pm.page_no, total := pm.total, pending := pm.pending,
                flagged := pm.flagged
            ) ORDER BY pm.page_no), [])
                FROM v_page_map pm WHERE pm.document_id = cast(d.id AS VARCHAR)),
            'suggestions': (SELECT coalesce(list(struct_pack(
                id := q.id, text := q.text, context := q.context, confidence := q.confidence,
                page_no := q.page_no, status := q.status, band := q.band, current := false,
                kind := q.kind, entity_id := q.entity_id
            ) ORDER BY q.page_rank, q.status_rank, q.page_no, q.id), [])
                FROM (
                    SELECT s.id, s.text, s.context, s.confidence, s.page_no, s.status, s.band,
                           coalesce(s.kind, '') AS kind, s.entity_id,
                           CASE WHEN s.page_no = g.page_no THEN 0 ELSE 1 END AS page_rank,
                           CASE WHEN s.status = 'pending' THEN 0 ELSE 1 END AS status_rank
                    FROM v_suggestions s
                    WHERE cast(s.document_id AS VARCHAR) = cast(d.id AS VARCHAR)
                      AND (s.page_no = g.page_no OR s.status = 'pending')
                    ORDER BY page_rank, status_rank, s.page_no, s.id
                    LIMIT 80
                ) q),
            'stats': (SELECT struct_pack(
                suggestion_count := cs.suggestion_count, pending_count := cs.pending_count,
                resolved := cs.resolved,
                progress_pct := CASE WHEN cs.suggestion_count = 0 THEN 0
                    ELSE round(100.0 * cs.resolved / cs.suggestion_count, 0)::INTEGER END,
                high_count := cs.high_count, review_count := cs.review_count,
                flagged_count := cs.flagged_count
            ) FROM (
                SELECT coalesce(sum(suggestion_count), 0)::BIGINT AS suggestion_count,
                       coalesce(sum(pending_count), 0)::BIGINT AS pending_count,
                       coalesce(sum(accepted_count + rejected_count), 0)::BIGINT AS resolved,
                       coalesce(sum(high_count), 0)::BIGINT AS high_count,
                       coalesce(sum(review_count), 0)::BIGINT AS review_count,
                       coalesce(sum(flagged_count), 0)::BIGINT AS flagged_count
                FROM v_document_stats
                WHERE cast(case_id AS VARCHAR) = cast(d.case_id AS VARCHAR)
            ) cs)
        }::JSON
    ) AS html
FROM documents d
JOIN cases c ON cast(c.id AS VARCHAR) = cast(d.case_id AS VARCHAR)
JOIN v_page_geom g ON g.document_id = cast(d.id AS VARCHAR);

CREATE OR REPLACE ROUTE case_dash GET '/cases/:id' AS
SELECT tera_render(
    (SELECT content FROM app_templates WHERE name = 'case.html'),
    {'case': case_obj, 'stats': stats, 'documents': documents,
     'entities': entities, 'audit': audit}::JSON
) AS html FROM v_case_page WHERE case_id = $id;

CREATE OR REPLACE ROUTE home GET '/' AS
SELECT tera_render(
    (SELECT content FROM app_templates WHERE name = 'case.html'),
    {'case': case_obj, 'stats': stats, 'documents': documents,
     'entities': entities, 'audit': audit}::JSON
) AS html FROM v_case_page ORDER BY case_id LIMIT 1;

CREATE OR REPLACE ROUTE library_shell GET '/cases/:id/library' AS
SELECT tera_render(
    (SELECT content FROM app_templates WHERE name = 'case.html'),
    {'case': case_obj, 'stats': stats, 'documents': documents,
     'entities': entities, 'audit': audit}::JSON
) AS html FROM v_case_page WHERE case_id = $id;

CREATE OR REPLACE ROUTE case_audit_html GET '/cases/:id/audit' AS
SELECT tera_render(
    (SELECT content FROM app_templates WHERE name = 'audit.html'),
    {
        'case': (SELECT struct_pack(id := id, case_no := case_no, title := title)
                 FROM cases WHERE cast(id AS VARCHAR) = $id),
        'events': (
            SELECT coalesce(list(struct_pack(
                ts_short := strftime(a.ts, '%Y-%m-%d %H:%M:%S'),
                action := a.action, actor := a.actor,
                target := coalesce(a.target, ''), reason := coalesce(a.reason, '')
            ) ORDER BY a.ts DESC), [])
            FROM v_audit a WHERE cast(a.case_id AS VARCHAR) = $id
        )
    }::JSON
) AS html;

CREATE OR REPLACE ROUTE document_page GET '/documents/:id/pages/:page' AS
SELECT html FROM v_review_page
WHERE document_id = $id
  AND page_no = least(
        greatest(coalesce(try_cast($page AS INTEGER), 1), 1),
        (SELECT page_count FROM documents WHERE cast(id AS VARCHAR) = $id)
      );

CREATE OR REPLACE ROUTE document_review GET '/documents/:id' AS
SELECT html FROM v_review_page WHERE document_id = $id AND page_no = 1;

CREATE OR REPLACE ROUTE reject_shell GET '/ui/reject' AS
SELECT content AS html FROM app_templates WHERE name = 'reject.html';
CREATE OR REPLACE ROUTE add_shell GET '/ui/add-missed' AS
SELECT content AS html FROM app_templates WHERE name = 'add_missed.html';
CREATE OR REPLACE ROUTE bulk_shell GET '/ui/bulk' AS
SELECT content AS html FROM app_templates WHERE name = 'bulk.html';
