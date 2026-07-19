-- render_static.sql — write HTML pages to static/ without waiting on the HTTP server.
-- Usage (after schema + ingest):  .read server/render_static.sql

.mode trash

-- Home
COPY (
    SELECT tera_render(
        (SELECT content FROM app_templates WHERE name = 'home.html'),
        {
            'stats': (
                SELECT struct_pack(
                    case_count        := (SELECT count(*)::BIGINT FROM cases),
                    document_count    := (SELECT count(*)::BIGINT FROM documents),
                    page_count        := (SELECT count(*)::BIGINT FROM pages),
                    word_count        := (SELECT count(*)::BIGINT FROM words),
                    entity_count      := (SELECT count(*)::BIGINT FROM entities),
                    suggestion_count  := (SELECT count(*)::BIGINT FROM suggestions)
                )
            ),
            'cases': (
                SELECT coalesce(list(struct_pack(
                    id           := c.id,
                    case_no      := c.case_no,
                    title        := c.title,
                    doc_count    := (SELECT count(*)::BIGINT FROM documents d WHERE d.case_id = c.id),
                    page_count   := (SELECT count(*)::BIGINT FROM pages p
                                     JOIN documents d ON d.id = p.document_id WHERE d.case_id = c.id),
                    word_count   := (SELECT count(*)::BIGINT FROM words w
                                     JOIN documents d ON d.id = w.document_id WHERE d.case_id = c.id),
                    entity_count := (SELECT count(*)::BIGINT FROM entities e WHERE e.case_id = c.id)
                ) ORDER BY c.case_no), [])
                FROM cases c
            )
        }::JSON
    )
) TO 'static/index.html' (FORMAT CSV, HEADER false, QUOTE '', ESCAPE '', DELIMITER E'\x01');

-- Per-case dashboards
COPY (
    SELECT tera_render(
        (SELECT content FROM app_templates WHERE name = 'case.html'),
        {
            'case': struct_pack(id := c.id, case_no := c.case_no, title := c.title),
            'stats': (
                SELECT struct_pack(
                    doc_count        := (SELECT count(*)::BIGINT FROM documents d WHERE d.case_id = c.id),
                    page_count       := (SELECT count(*)::BIGINT FROM pages p
                                         JOIN documents d ON d.id = p.document_id WHERE d.case_id = c.id),
                    word_count       := (SELECT count(*)::BIGINT FROM words w
                                         JOIN documents d ON d.id = w.document_id WHERE d.case_id = c.id),
                    entity_count     := (SELECT count(*)::BIGINT FROM entities e WHERE e.case_id = c.id),
                    suggestion_count := 0::BIGINT,
                    pending_count    := 0::BIGINT,
                    accepted_count   := 0::BIGINT,
                    rejected_count   := 0::BIGINT,
                    flagged_count    := 0::BIGINT,
                    resolved         := 0::BIGINT,
                    progress_pct     := 0,
                    accepted_pct     := 0,
                    pending_pct      := 0
                )
            ),
            'documents': (
                SELECT coalesce(list(struct_pack(
                    id := ds.document_id, filename := ds.filename, page_count := ds.page_count,
                    word_count := ds.word_count, width_pt := ds.width_pt, height_pt := ds.height_pt,
                    suggestion_count := ds.suggestion_count, pending_count := ds.pending_count,
                    flagged_count := ds.flagged_count
                ) ORDER BY ds.filename), [])
                FROM v_document_stats ds WHERE ds.case_id = c.id
            ),
            'entities': (
                SELECT coalesce(list(struct_pack(
                    id := e.entity_id, canonical_text := e.canonical_text, kind := e.kind,
                    hit_count := e.hit_count, doc_count := e.doc_count,
                    mono := (e.kind IN ('SSN', 'DATE OF BIRTH') OR e.kind LIKE 'PHONE%')
                ) ORDER BY e.hit_count DESC, e.kind), [])
                FROM v_entity_hits e WHERE e.case_id = c.id
            ),
            'audit': (
                SELECT coalesce(list(struct_pack(
                    ts_short := strftime(a.ts, '%H:%M'),
                    action := a.action, actor := a.actor,
                    target := coalesce(a.target, ''), reason := coalesce(a.reason, '')
                ) ORDER BY a.id DESC), [])
                FROM (SELECT * FROM audit_events WHERE case_id = c.id ORDER BY id DESC LIMIT 12) a
            )
        }::JSON
    ) AS html
    FROM cases c
    WHERE c.id = 1
) TO 'static/case_1.html' (FORMAT CSV, HEADER false, QUOTE '', ESCAPE '', DELIMITER E'\x01');

-- First document, page 1 review (vertical-slice proof)
COPY (
    WITH
    doc AS (
        SELECT d.*, c.case_no, c.title AS case_title, c.id AS case_id_real
        FROM documents d JOIN cases c ON c.id = d.case_id
        WHERE d.id = 1
    ),
    page_dims AS (
        SELECT p.page_no, p.width_pt, p.height_pt,
               680.0 / p.width_pt AS scale,
               680.0 AS display_w,
               round(p.height_pt * (680.0 / p.width_pt), 1) AS display_h
        FROM pages p WHERE p.document_id = 1 AND p.page_no = 1
    ),
    word_rows AS (
        SELECT w.word, w.x0, w.y0, w.x1, w.y1,
               round(w.x0 * pd.scale, 2) AS left_px,
               round(w.y0 * pd.scale, 2) AS top_px,
               round((w.x1 - w.x0) * pd.scale, 2) AS width,
               round(greatest(w.y1 - w.y0, 4) * pd.scale, 2) AS height,
               round(coalesce(w.font_size, 9) * pd.scale * 0.95, 1) AS font_px,
               false AS is_hit
        FROM words w CROSS JOIN page_dims pd
        WHERE w.document_id = 1 AND w.page_no = 1
    ),
    proof AS (
        SELECT word, page_no,
               round(x0,2) AS x0, round(y0,2) AS y0, round(x1,2) AS x1, round(y1,2) AS y1,
               round(x0 * (SELECT scale FROM page_dims), 2) AS left_px,
               round(y0 * (SELECT scale FROM page_dims), 2) AS top_px
        FROM words
        WHERE document_id = 1 AND page_no = 1
          AND (word IN ('RIVERTON', 'Yasmine', 'Nienow', '24-000117') OR word LIKE '280%')
        ORDER BY y0, x0
        LIMIT 6
    )
    SELECT tera_render(
        (SELECT content FROM app_templates WHERE name = 'review.html'),
        {
            'case': (SELECT struct_pack(id := case_id_real, case_no := case_no, title := case_title) FROM doc),
            'doc':  (SELECT struct_pack(id := id, filename := filename, page_count := page_count) FROM doc),
            'page': (SELECT struct_pack(
                page_no := page_no, prev := 1, next := 2,
                width_pt := width_pt, height_pt := height_pt, scale := round(scale,4),
                display_w := display_w, display_h := display_h,
                word_count := (SELECT count(*)::BIGINT FROM word_rows),
                mark_count := 0::BIGINT,
                png_href := '../web/pages/' || (SELECT filename FROM doc) || '/p1.png'
            ) FROM page_dims),
            'words': (SELECT coalesce(list(struct_pack(
                word := word, x0 := round(x0,2), y0 := round(y0,2), x1 := round(x1,2), y1 := round(y1,2),
                left_px := left_px, top_px := top_px, width := width, height := height, font_px := font_px, is_hit := is_hit
            )), []) FROM word_rows),
            'marks': [],
            'proof': (SELECT coalesce(list(struct_pack(
                word := word, page_no := page_no, x0 := x0, y0 := y0, x1 := x1, y1 := y1, left_px := left_px, top_px := top_px
            )), []) FROM proof),
            'docs': (SELECT coalesce(list(struct_pack(
                id := ds.document_id, filename := ds.filename, page_count := ds.page_count,
                word_count := ds.word_count, suggestion_count := ds.suggestion_count
            ) ORDER BY ds.filename), []) FROM v_document_stats ds WHERE ds.case_id = (SELECT case_id_real FROM doc)),
            'suggestions': [],
            'stats': struct_pack(
                suggestion_count := 0::BIGINT, pending_count := 0::BIGINT, resolved := 0::BIGINT,
                progress_pct := 0, high_count := 0::BIGINT, review_count := 0::BIGINT, flagged_count := 0::BIGINT
            )
        }::JSON
    )
) TO 'static/document_1_p1.html' (FORMAT CSV, HEADER false, QUOTE '', ESCAPE '', DELIMITER E'\x01');

.mode duckbox
SELECT 'static render complete' AS status,
       'static/index.html' AS home,
       'static/case_1.html' AS case_page,
       'static/document_1_p1.html' AS review_page;
