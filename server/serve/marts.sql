-- server/serve/marts.sql — UI aggregates + HTML page payloads (not HTTP).

CREATE OR REPLACE VIEW v_suggestion_cube AS
SELECT document_id, page_no, status, band, count(*)::BIGINT AS n
FROM v_suggestions GROUP BY ALL;

CREATE OR REPLACE VIEW document_scan_status AS
SELECT d.id AS document_id, d.case_id, d.filename, d.source_path, d.page_count,
       coalesce(w.n, 0)::BIGINT AS native_word_count,
       coalesce(w.n, 0)::BIGINT AS total_word_count,
       false AS is_scanned, false AS ocr_ingested, false AS scan_gap,
       NULL::VARCHAR AS scan_badge, 'b-gray' AS scan_badge_class,
       NULL::VARCHAR AS scan_detail, 'native text' AS ocr_status_note
FROM documents d
LEFT JOIN (SELECT document_id, count(*)::BIGINT AS n FROM words GROUP BY 1) w
  ON w.document_id = d.id;

CREATE OR REPLACE VIEW v_doc_ui AS
SELECT
    d.id, d.case_id, d.filename, d.page_count, d.width_pt, d.height_pt,
    d.file_size, d.source_path,
    CASE WHEN d.file_size >= 1048576
         THEN round(d.file_size / 1048576.0, 1)::VARCHAR || ' MB'
         WHEN d.file_size >= 1024
         THEN round(d.file_size / 1024.0, 0)::VARCHAR || ' KB'
         ELSE d.file_size::VARCHAR || ' B' END AS size_label,
    coalesce(w.wc, 0)::BIGINT AS word_count,
    coalesce(sum(c.n), 0)::BIGINT AS suggestion_count,
    coalesce(sum(CASE WHEN c.status = 'pending' THEN c.n END), 0)::BIGINT AS pending_count,
    coalesce(sum(CASE WHEN c.status = 'accepted' THEN c.n END), 0)::BIGINT AS accepted_count,
    coalesce(sum(CASE WHEN c.status = 'rejected' THEN c.n END), 0)::BIGINT AS rejected_count,
    coalesce(sum(CASE WHEN c.status = 'pending' AND c.band = 'flagged' THEN c.n END), 0)::BIGINT AS flagged_count,
    coalesce(sum(CASE WHEN c.band = 'high' THEN c.n END), 0)::BIGINT AS high_count,
    coalesce(sum(CASE WHEN c.band = 'review' THEN c.n END), 0)::BIGINT AS review_count,
    CASE WHEN coalesce(sum(c.n), 0) = 0 THEN 0
         ELSE round(100.0 * coalesce(sum(CASE WHEN c.status IN ('accepted','rejected') THEN c.n END), 0)
              / sum(c.n), 0)::INTEGER END AS progress_pct,
    CASE WHEN coalesce(sum(CASE WHEN c.status = 'pending' AND c.band = 'flagged' THEN c.n END), 0) > 0
         THEN 'flagged'
         WHEN coalesce(sum(c.n), 0) = 0 THEN 'empty'
         WHEN coalesce(sum(CASE WHEN c.status = 'pending' THEN c.n END), 0) = 0 THEN 'done'
         ELSE 'review' END AS status,
    sc.scan_badge, sc.scan_badge_class, sc.scan_detail,
    sc.is_scanned, sc.ocr_ingested, sc.scan_gap
FROM documents d
LEFT JOIN v_suggestion_cube c ON c.document_id = d.id
LEFT JOIN (SELECT document_id, count(*)::BIGINT AS wc FROM words GROUP BY 1) w
  ON w.document_id = d.id
LEFT JOIN document_scan_status sc ON sc.document_id = d.id
GROUP BY ALL;

CREATE OR REPLACE VIEW v_page_geom AS
SELECT document_id, page_no, width_pt, height_pt,
       680.0 / width_pt AS scale, 680.0 AS display_w,
       round(height_pt * 680.0 / width_pt, 1) AS display_h
FROM pages;

CREATE OR REPLACE VIEW v_page_map AS
SELECT p.document_id, p.page_no,
       coalesce(sum(c.n), 0)::BIGINT AS total,
       coalesce(sum(CASE WHEN c.status = 'pending' THEN c.n END), 0)::BIGINT AS pending,
       coalesce(sum(CASE WHEN c.status = 'accepted' THEN c.n END), 0)::BIGINT AS accepted,
       coalesce(sum(CASE WHEN c.status = 'rejected' THEN c.n END), 0)::BIGINT AS rejected,
       coalesce(sum(CASE WHEN c.status = 'pending' AND c.band = 'flagged' THEN c.n END), 0)::BIGINT AS flagged
FROM pages p
LEFT JOIN v_suggestion_cube c
  ON c.document_id = p.document_id AND c.page_no = p.page_no
GROUP BY ALL;

CREATE OR REPLACE VIEW v_page_words AS
SELECT w.document_id, w.page_no, w.word, w.bbox, w.font_size,
       w.bbox.x0 AS x0, w.bbox.y0 AS y0, w.bbox.x1 AS x1, w.bbox.y1 AS y1,
       round(w.bbox.x0 * g.scale, 2) AS left_px,
       round(w.bbox.y0 * g.scale, 2) AS top_px,
       round((w.bbox.x1 - w.bbox.x0) * g.scale, 2) AS width,
       round(greatest(w.bbox.y1 - w.bbox.y0, 4) * g.scale, 2) AS height,
       round(coalesce(w.font_size, 9) * g.scale * 0.95, 1) AS font_px,
       false AS is_hit
FROM words w
JOIN v_page_geom g ON g.document_id = w.document_id AND g.page_no = w.page_no;

CREATE OR REPLACE VIEW v_page_marks AS
SELECT s.id, s.document_id, s.page_no, s.line_no, s.bbox, s.x0, s.y0, s.x1, s.y1,
       s.text, s.confidence, s.status, s.band, s.kind,
       round(s.x0 * g.scale, 2) AS left_px,
       round(s.y0 * g.scale, 2) AS top_px,
       round((s.x1 - s.x0) * g.scale, 2) AS width,
       round((s.y1 - s.y0) * g.scale, 2) AS height,
       false AS current
FROM v_suggestions s
JOIN v_page_geom g ON g.document_id = s.document_id AND g.page_no = s.page_no;

CREATE OR REPLACE VIEW v_audit AS
SELECT coalesce(l.ts, now()) AS ts,
       coalesce(l.actor, 'reviewer') AS actor,
       coalesce(l.kind, 'decision') AS action,
       l.suggestion_id, coalesce(l.case_id, d.case_id) AS case_id,
       coalesce(l.text, l.suggestion_id, '') AS target, l.reason
FROM v_src_decisions l
LEFT JOIN documents d ON d.id = l.document_id
WHERE l.kind IN ('decision', 'added');

CREATE OR REPLACE TABLE app_templates AS
SELECT replace(parse_filename(filename, true), '.html', '') AS name, content
FROM read_text('server/templates/*.html');

CREATE OR REPLACE VIEW v_case_stats AS
SELECT
    u.case_id,
    count(*)::BIGINT AS doc_count,
    coalesce(sum(u.page_count), 0)::BIGINT AS page_count,
    (SELECT count(*)::BIGINT FROM entities e WHERE e.case_id = u.case_id) AS entity_count,
    coalesce(sum(u.suggestion_count), 0)::BIGINT AS suggestion_count,
    coalesce(sum(u.pending_count), 0)::BIGINT AS pending_count,
    coalesce(sum(u.accepted_count), 0)::BIGINT AS accepted_count,
    coalesce(sum(u.rejected_count), 0)::BIGINT AS rejected_count,
    coalesce(sum(u.flagged_count), 0)::BIGINT AS flagged_count,
    coalesce(sum(u.accepted_count + u.rejected_count), 0)::BIGINT AS resolved,
    coalesce(sum(u.high_count), 0)::BIGINT AS high_count,
    coalesce(sum(u.review_count), 0)::BIGINT AS review_count,
    CASE WHEN coalesce(sum(u.suggestion_count), 0) = 0 THEN 0
         ELSE round(100.0 * sum(u.accepted_count + u.rejected_count)
              / sum(u.suggestion_count), 0)::INTEGER END AS progress_pct,
    CASE WHEN coalesce(sum(u.suggestion_count), 0) = 0 THEN 0
         ELSE round(100.0 * sum(u.accepted_count) / sum(u.suggestion_count), 0)::INTEGER
    END AS accepted_pct,
    CASE WHEN coalesce(sum(u.suggestion_count), 0) = 0 THEN 0
         ELSE round(100.0 * sum(u.pending_count) / sum(u.suggestion_count), 0)::INTEGER
    END AS pending_pct
FROM v_doc_ui u
GROUP BY u.case_id;

CREATE OR REPLACE VIEW v_case_page AS
SELECT c.id AS case_id,
       struct_pack(id := c.id, case_no := c.case_no, title := c.title) AS case_obj,
       st AS stats,
       (SELECT coalesce(list(u ORDER BY u.filename), [])
        FROM v_doc_ui u WHERE u.case_id = c.id) AS documents,
       (SELECT coalesce(list(struct_pack(
            id := e.id, canonical_text := e.canonical_text, kind := e.kind,
            hit_count := coalesce(h.n, 0)::BIGINT,
            doc_count := coalesce(h.d, 0)::BIGINT,
            mono := (e.kind IN ('SSN', 'DATE OF BIRTH') OR starts_with(e.kind, 'PHONE'))
        ) ORDER BY coalesce(h.n, 0) DESC, e.kind, e.canonical_text), [])
        FROM entities e
        LEFT JOIN (
            SELECT entity_id, count(*)::BIGINT AS n, count(DISTINCT document_id)::BIGINT AS d
            FROM v_suggestions WHERE entity_id IS NOT NULL GROUP BY 1
        ) h ON h.entity_id = e.id
        WHERE e.case_id = c.id) AS entities,
       (SELECT coalesce(list(struct_pack(
            ts_short := strftime(a.ts, '%H:%M'), action := a.action, actor := a.actor,
            target := coalesce(a.target, ''), reason := coalesce(a.reason, '')
        ) ORDER BY a.ts DESC), [])
        FROM v_audit a WHERE a.case_id = c.id) AS audit
FROM cases c
LEFT JOIN v_case_stats st ON st.case_id = c.id;

CREATE OR REPLACE VIEW v_review_page AS
SELECT d.id AS document_id, g.page_no,
    tera_render(
        (SELECT content FROM app_templates WHERE name = 'review'),
        {
            'case': struct_pack(id := d.case_id, case_no := c.case_no, title := c.title),
            'doc':  struct_pack(id := d.id, filename := d.filename, page_count := d.page_count),
            'page': struct_pack(
                page_no := g.page_no,
                prev := greatest(g.page_no - 1, 1),
                next := least(g.page_no + 1, d.page_count),
                width_pt := g.width_pt, height_pt := g.height_pt,
                scale := round(g.scale, 4), display_w := g.display_w, display_h := g.display_h,
                word_count := (SELECT count(*) FROM words w
                               WHERE w.document_id = d.id AND w.page_no = g.page_no),
                mark_count := (SELECT count(*) FROM v_suggestions s
                               WHERE s.document_id = d.id AND s.page_no = g.page_no),
                png_href := '/pages/' || d.filename || '/p' || g.page_no || '.png'
            ),
            'words': (SELECT coalesce(list(w), []) FROM v_page_words w
                      WHERE w.document_id = d.id AND w.page_no = g.page_no),
            'marks': (SELECT coalesce(list(m), []) FROM v_page_marks m
                      WHERE m.document_id = d.id AND m.page_no = g.page_no),
            'docs': (SELECT coalesce(list(u ORDER BY u.filename), [])
                     FROM v_doc_ui u WHERE u.case_id = d.case_id),
            'page_map': (SELECT coalesce(list(pm ORDER BY pm.page_no), [])
                         FROM v_page_map pm WHERE pm.document_id = d.id),
            'suggestions': (SELECT coalesce(list(struct_pack(
                id := s.id, text := s.text, context := s.context, confidence := s.confidence,
                page_no := s.page_no, line_no := s.line_no, status := s.status, band := s.band,
                current := false, kind := coalesce(s.kind, ''), entity_id := s.entity_id
            ) ORDER BY (s.page_no = g.page_no) DESC, (s.status = 'pending') DESC, s.page_no, s.id), [])
                FROM v_suggestions s
                WHERE s.document_id = d.id AND (s.page_no = g.page_no OR s.status = 'pending')),
            'stats': st
        }::JSON
    ) AS html
FROM documents d
JOIN cases c ON c.id = d.case_id
JOIN v_page_geom g ON g.document_id = d.id
LEFT JOIN v_case_stats st ON st.case_id = d.case_id;
