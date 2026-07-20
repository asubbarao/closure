-- routes/pages.sql — HTML page routes + tera render macros.
--
-- Purpose: server-rendered review UI (dashboard, case, document, shells).
-- Dependencies: app_templates, cases/documents/pages/words/entities/v_suggestions/v_audit.
-- Does not call pdf_info / read_pdf_words / pdf_redact (page PNGs are static files).

-- ═══════════════════════════════════════════════════════════════════════════
-- Render macros
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE MACRO render_home() AS TABLE
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
) AS html;

CREATE OR REPLACE MACRO render_case(cid) AS TABLE
WITH
-- One scan of v_suggestions for case-level status/band counts.
sugg_agg AS (
    SELECT
        count(*)::BIGINT AS suggestion_count,
        count(*) FILTER (WHERE s.status = 'pending')::BIGINT AS pending_count,
        count(*) FILTER (WHERE s.status = 'accepted')::BIGINT AS accepted_count,
        count(*) FILTER (WHERE s.status = 'rejected')::BIGINT AS rejected_count,
        count(*) FILTER (WHERE s.band = 'flagged' AND s.status = 'pending')::BIGINT AS flagged_count
    FROM v_suggestions s
    JOIN documents d ON d.id = s.document_id
    WHERE d.case_id = cid
),
st AS (
    SELECT
        (SELECT count(*)::BIGINT FROM documents d WHERE d.case_id = cid) AS doc_count,
        (SELECT count(*)::BIGINT FROM pages p JOIN documents d ON d.id = p.document_id WHERE d.case_id = cid) AS page_count,
        (SELECT count(*)::BIGINT FROM words w JOIN documents d ON d.id = w.document_id WHERE d.case_id = cid) AS word_count,
        (SELECT count(*)::BIGINT FROM entities e WHERE e.case_id = cid) AS entity_count,
        coalesce((SELECT suggestion_count FROM sugg_agg), 0) AS suggestion_count,
        coalesce((SELECT pending_count FROM sugg_agg), 0) AS pending_count,
        coalesce((SELECT accepted_count FROM sugg_agg), 0) AS accepted_count,
        coalesce((SELECT rejected_count FROM sugg_agg), 0) AS rejected_count,
        coalesce((SELECT flagged_count FROM sugg_agg), 0) AS flagged_count
),
st2 AS (
    SELECT st.*,
           (st.accepted_count + st.rejected_count) AS resolved,
           CASE WHEN st.suggestion_count = 0 THEN 0
                ELSE round(100.0 * (st.accepted_count + st.rejected_count) / st.suggestion_count, 0)::INTEGER
           END AS progress_pct,
           CASE WHEN st.suggestion_count = 0 THEN 0
                ELSE round(100.0 * st.accepted_count / st.suggestion_count, 0)::INTEGER
           END AS accepted_pct,
           CASE WHEN st.suggestion_count = 0 THEN 0
                ELSE round(100.0 * st.pending_count / st.suggestion_count, 0)::INTEGER
           END AS pending_pct
    FROM st
),
-- Per-doc library stats (progress, bands, size) — one scan of v_suggestions.
doc_rows AS (
    SELECT
        d.id AS document_id,
        d.filename,
        d.page_count,
        d.width_pt,
        d.height_pt,
        d.file_size,
        d.source_path,
        (SELECT count(*)::BIGINT FROM words w WHERE w.document_id = d.id) AS word_count,
        sc.scan_badge,
        sc.scan_badge_class,
        sc.scan_detail,
        coalesce(sc.is_scanned, false) AS is_scanned,
        coalesce(sc.ocr_ingested, false) AS ocr_ingested,
        coalesce(sc.scan_gap, false) AS scan_gap,
        coalesce(sa.suggestion_count, 0) AS suggestion_count,
        coalesce(sa.pending_count, 0) AS pending_count,
        coalesce(sa.accepted_count, 0) AS accepted_count,
        coalesce(sa.rejected_count, 0) AS rejected_count,
        coalesce(sa.flagged_count, 0) AS flagged_count,
        coalesce(sa.high_count, 0) AS high_count,
        coalesce(sa.review_count, 0) AS review_count,
        CASE WHEN coalesce(sa.suggestion_count, 0) = 0 THEN 0
             ELSE round(100.0 * (coalesce(sa.accepted_count, 0) + coalesce(sa.rejected_count, 0))
                        / sa.suggestion_count, 0)::INTEGER
        END AS progress_pct,
        CASE
            WHEN coalesce(sa.flagged_count, 0) > 0 THEN 'flagged'
            WHEN coalesce(sa.suggestion_count, 0) = 0 THEN 'empty'
            WHEN coalesce(sa.pending_count, 0) = 0 THEN 'done'
            ELSE 'review'
        END AS status
    FROM documents d
    LEFT JOIN document_scan_status sc ON sc.document_id = d.id
    LEFT JOIN (
        SELECT
            s.document_id,
            count(*)::BIGINT AS suggestion_count,
            count(*) FILTER (WHERE s.status = 'pending')::BIGINT AS pending_count,
            count(*) FILTER (WHERE s.status = 'accepted')::BIGINT AS accepted_count,
            count(*) FILTER (WHERE s.status = 'rejected')::BIGINT AS rejected_count,
            count(*) FILTER (WHERE s.band = 'flagged' AND s.status = 'pending')::BIGINT AS flagged_count,
            count(*) FILTER (WHERE s.band = 'high')::BIGINT AS high_count,
            count(*) FILTER (WHERE s.band = 'review')::BIGINT AS review_count
        FROM v_suggestions s
        GROUP BY s.document_id
    ) sa ON sa.document_id = d.id
    WHERE d.case_id = cid
),
-- Entity list: roster entities + suggestion hit counts (no v_grams join).
entity_rows AS (
    SELECT
        e.id AS entity_id,
        e.canonical_text,
        e.kind,
        coalesce(h.hit_count, 0)::BIGINT AS hit_count,
        coalesce(h.doc_count, 0)::BIGINT AS doc_count
    FROM entities e
    LEFT JOIN (
        SELECT
            s.entity_id,
            count(*)::BIGINT AS hit_count,
            count(DISTINCT s.document_id)::BIGINT AS doc_count
        FROM v_suggestions s
        WHERE s.entity_id IS NOT NULL
        GROUP BY s.entity_id
    ) h ON h.entity_id = e.id
    WHERE e.case_id = cid
)
SELECT tera_render(
    (SELECT content FROM app_templates WHERE name = 'case.html'),
    {
        'case': (
            SELECT struct_pack(id := c.id, case_no := c.case_no, title := c.title)
            FROM cases c WHERE c.id = cid
        ),
        'stats': (SELECT struct_pack(
            doc_count := doc_count, page_count := page_count, word_count := word_count,
            entity_count := entity_count, suggestion_count := suggestion_count,
            pending_count := pending_count, accepted_count := accepted_count,
            rejected_count := rejected_count, flagged_count := flagged_count,
            resolved := resolved, progress_pct := progress_pct,
            accepted_pct := accepted_pct, pending_pct := pending_pct
        ) FROM st2),
        'documents': (
            SELECT coalesce(list(struct_pack(
                id               := document_id,
                filename         := filename,
                page_count       := page_count,
                word_count       := word_count,
                width_pt         := width_pt,
                height_pt        := height_pt,
                file_size        := file_size,
                source_path      := source_path,
                scan_badge       := scan_badge,
                scan_badge_class := scan_badge_class,
                scan_detail      := scan_detail,
                is_scanned       := is_scanned,
                ocr_ingested     := ocr_ingested,
                scan_gap         := scan_gap,
                suggestion_count := suggestion_count,
                pending_count    := pending_count,
                accepted_count   := accepted_count,
                rejected_count   := rejected_count,
                flagged_count    := flagged_count,
                high_count       := high_count,
                review_count     := review_count,
                progress_pct     := progress_pct,
                status           := status,
                size_label       := CASE
                    WHEN file_size IS NULL THEN '—'
                    WHEN file_size >= 1048576 THEN round(file_size / 1048576.0, 1)::VARCHAR || ' MB'
                    WHEN file_size >= 1024 THEN round(file_size / 1024.0, 0)::VARCHAR || ' KB'
                    ELSE file_size::VARCHAR || ' B'
                END
            ) ORDER BY filename), [])
            FROM doc_rows
        ),
        'entities': (
            SELECT coalesce(list(struct_pack(
                id             := entity_id,
                canonical_text := canonical_text,
                kind           := kind,
                hit_count      := hit_count,
                doc_count      := doc_count,
                mono           := (kind IN ('SSN', 'DATE OF BIRTH') OR starts_with(kind, 'PHONE'))
            ) ORDER BY hit_count DESC, kind, canonical_text), [])
            FROM entity_rows
        ),
        'audit': (
            SELECT coalesce(list(struct_pack(
                ts_short := strftime(a.ts, '%H:%M'),
                action   := a.action,
                actor    := a.actor,
                target   := coalesce(a.target, ''),
                reason   := coalesce(a.reason, '')
            ) ORDER BY a.ts DESC), [])
            FROM (
                SELECT * FROM v_audit
                WHERE case_id = cid
                ORDER BY coalesce(ts, TIMESTAMP '1970-01-01') DESC
                LIMIT 12
            ) a
        )
    }::JSON
) AS html;

CREATE OR REPLACE MACRO render_audit(cid) AS TABLE
SELECT tera_render(
    (SELECT content FROM app_templates WHERE name = 'audit.html'),
    {
        'case': (
            SELECT struct_pack(id := id, case_no := case_no, title := title)
            FROM cases WHERE id = cid
        ),
        'events': (
            SELECT coalesce(list(struct_pack(
                ts_short := strftime(a.ts, '%Y-%m-%d %H:%M:%S'),
                action   := a.action,
                actor    := a.actor,
                target   := coalesce(a.target, ''),
                reason   := coalesce(a.reason, '')
            ) ORDER BY a.ts DESC), [])
            FROM v_audit a
            WHERE a.case_id = cid
        )
    }::JSON
) AS html;

-- Review page: words + marks are CURRENT PAGE only.
-- Suggestion queue is capped (page-first, then pending) so a 110-page doc
-- never builds a ~1MB tera context of every suggestion.
CREATE OR REPLACE MACRO render_document(did, pageno) AS TABLE
WITH
doc AS (
    SELECT d.*, c.case_no, c.title AS case_title, c.id AS case_id_real
    FROM documents d
    JOIN cases c ON c.id = d.case_id
    WHERE d.id = did
),
pg AS (
    SELECT least(greatest(coalesce(pageno, 1), 1), (SELECT page_count FROM doc)) AS page_no
),
page_dims AS (
    SELECT
        p.page_no, p.width_pt, p.height_pt,
        680.0 / p.width_pt AS scale,
        680.0 AS display_w,
        round(p.height_pt * (680.0 / p.width_pt), 1) AS display_h
    FROM pages p, pg
    WHERE p.document_id = did AND p.page_no = pg.page_no
),
-- CURRENT PAGE words only (never whole-document word lists).
word_rows AS (
    SELECT
        w.word, w.x0, w.y0, w.x1, w.y1,
        round(w.x0 * pd.scale, 2) AS left_px,
        round(w.y0 * pd.scale, 2) AS top_px,
        round((w.x1 - w.x0) * pd.scale, 2) AS width_px,
        round(greatest(w.y1 - w.y0, 4) * pd.scale, 2) AS height_px,
        round(coalesce(w.font_size, 9) * pd.scale * 0.95, 1) AS font_px,
        false AS is_hit
    FROM words w
    CROSS JOIN page_dims pd
    CROSS JOIN pg
    WHERE w.document_id = did AND w.page_no = pg.page_no
),
proof AS (
    SELECT word, page_no, x0, y0, x1, y1, left_px, top_px
    FROM (
        SELECT w.word, w.page_no,
               round(w.x0, 2) AS x0, round(w.y0, 2) AS y0,
               round(w.x1, 2) AS x1, round(w.y1, 2) AS y1,
               round(w.x0 * pd.scale, 2) AS left_px,
               round(w.y0 * pd.scale, 2) AS top_px,
               row_number() OVER (ORDER BY w.y0, w.x0) AS rn
        FROM words w
        CROSS JOIN page_dims pd
        CROSS JOIN pg
        WHERE w.document_id = did AND w.page_no = pg.page_no
          AND length(w.word) >= 4
          AND (position('-' IN w.word) > 0 OR w.y0 < 80
               -- Roster-derived name tokens (was a literal generated-cast list,
               -- which drifted every time the sample corpus was regenerated).
               OR EXISTS (
                   SELECT 1 FROM entities e
                   WHERE e.case_id = (SELECT case_id_real FROM doc)
                     AND position(w.word IN e.canonical_text) > 0
               ))
    ) z
    WHERE rn <= 6
),
-- Overlay marks: current page only.
mark_rows AS (
    SELECT
        s.id, s.text, s.confidence, s.status, s.band,
        coalesce(s.kind, '') AS kind,
        round(s.x0 * pd.scale, 2) AS left_px,
        round(s.y0 * pd.scale, 2) AS top_px,
        round((s.x1 - s.x0) * pd.scale, 2) AS width_px,
        round((s.y1 - s.y0) * pd.scale, 2) AS height_px,
        false AS is_current
    FROM v_suggestions s
    CROSS JOIN page_dims pd
    CROSS JOIN pg
    WHERE s.document_id = did AND s.page_no = pg.page_no
),
-- Queue: current-page suggestions first, then other pending, hard-capped.
queue_rows AS (
    SELECT *
    FROM (
        SELECT
            s.id, s.text, s.context, s.confidence, s.page_no, s.status, s.band,
            coalesce(s.kind, '') AS kind, s.entity_id,
            CASE WHEN s.page_no = (SELECT page_no FROM pg) THEN 0 ELSE 1 END AS page_rank,
            CASE WHEN s.status = 'pending' THEN 0 ELSE 1 END AS status_rank,
            row_number() OVER (
                ORDER BY
                    CASE WHEN s.page_no = (SELECT page_no FROM pg) THEN 0 ELSE 1 END,
                    CASE WHEN s.status = 'pending' THEN 0 ELSE 1 END,
                    s.page_no,
                    s.id
            ) AS rn
        FROM v_suggestions s
        WHERE s.document_id = did
          AND (
                s.page_no = (SELECT page_no FROM pg)
             OR s.status = 'pending'
          )
    ) z
    WHERE rn <= 80
),
-- Single pass for case-level band stats (avoids 6× rescans of v_suggestions).
case_stats AS (
    SELECT
        count(*)::BIGINT AS suggestion_count,
        count(*) FILTER (WHERE s.status = 'pending')::BIGINT AS pending_count,
        count(*) FILTER (WHERE s.status IN ('accepted', 'rejected'))::BIGINT AS resolved,
        count(*) FILTER (WHERE s.band = 'high')::BIGINT AS high_count,
        count(*) FILTER (WHERE s.band = 'review')::BIGINT AS review_count,
        count(*) FILTER (WHERE s.band = 'flagged')::BIGINT AS flagged_count
    FROM v_suggestions s
    JOIN documents d ON d.id = s.document_id
    WHERE d.case_id = (SELECT case_id_real FROM doc)
),
-- Lean doc rail with pending + progress for multi-doc rollup.
doc_rail AS (
    SELECT
        d.id AS document_id,
        d.filename,
        d.page_count,
        (SELECT count(*)::BIGINT FROM words w WHERE w.document_id = d.id) AS word_count,
        coalesce(sa.suggestion_count, 0) AS suggestion_count,
        coalesce(sa.pending_count, 0) AS pending_count,
        coalesce(sa.flagged_count, 0) AS flagged_count,
        CASE WHEN coalesce(sa.suggestion_count, 0) = 0 THEN 0
             ELSE round(100.0 * (coalesce(sa.accepted_count, 0) + coalesce(sa.rejected_count, 0))
                        / sa.suggestion_count, 0)::INTEGER
        END AS progress_pct
    FROM documents d
    LEFT JOIN (
        SELECT
            s.document_id,
            count(*)::BIGINT AS suggestion_count,
            count(*) FILTER (WHERE s.status = 'pending')::BIGINT AS pending_count,
            count(*) FILTER (WHERE s.status = 'accepted')::BIGINT AS accepted_count,
            count(*) FILTER (WHERE s.status = 'rejected')::BIGINT AS rejected_count,
            count(*) FILTER (WHERE s.band = 'flagged' AND s.status = 'pending')::BIGINT AS flagged_count
        FROM v_suggestions s
        GROUP BY s.document_id
    ) sa ON sa.document_id = d.id
    WHERE d.case_id = (SELECT case_id_real FROM doc)
),
-- Page minimap: pending/total per page (never loads page content).
page_map AS (
    SELECT
        p.page_no,
        coalesce(c.n, 0)::BIGINT AS total,
        coalesce(c.pending, 0)::BIGINT AS pending,
        coalesce(c.flagged, 0)::BIGINT AS flagged
    FROM pages p
    LEFT JOIN (
        SELECT
            s.page_no,
            count(*)::BIGINT AS n,
            count(*) FILTER (WHERE s.status = 'pending')::BIGINT AS pending,
            count(*) FILTER (WHERE s.band = 'flagged' AND s.status = 'pending')::BIGINT AS flagged
        FROM v_suggestions s
        WHERE s.document_id = did
        GROUP BY s.page_no
    ) c ON c.page_no = p.page_no
    WHERE p.document_id = did
)
SELECT tera_render(
    (SELECT content FROM app_templates WHERE name = 'review.html'),
    {
        'case': (SELECT struct_pack(id := case_id_real, case_no := case_no, title := case_title) FROM doc),
        'doc':  (SELECT struct_pack(id := id, filename := filename, page_count := page_count) FROM doc),
        'page': (
            SELECT struct_pack(
                page_no    := pd.page_no,
                prev       := greatest(pd.page_no - 1, 1),
                next       := least(pd.page_no + 1, (SELECT page_count FROM doc)),
                width_pt   := pd.width_pt,
                height_pt  := pd.height_pt,
                scale      := round(pd.scale, 4),
                display_w  := pd.display_w,
                display_h  := pd.display_h,
                word_count := (SELECT count(*)::BIGINT FROM word_rows),
                mark_count := (SELECT count(*)::BIGINT FROM mark_rows),
                png_href   := '/pages/' || (SELECT filename FROM doc) || '/p' || pd.page_no || '.png'
            )
            FROM page_dims pd
        ),
        'words': (SELECT coalesce(list(struct_pack(
            word := word,
            x0 := round(x0,2), y0 := round(y0,2), x1 := round(x1,2), y1 := round(y1,2),
            left_px := left_px, top_px := top_px, width := width_px, height := height_px,
            font_px := font_px, is_hit := is_hit
        )), []) FROM word_rows),
        'marks': (SELECT coalesce(list(struct_pack(
            id := id, text := text, confidence := confidence, status := status, band := band, kind := kind,
            left_px := left_px, top_px := top_px, width := width_px, height := height_px,
            current := is_current
        )), []) FROM mark_rows),
        'proof': (SELECT coalesce(list(struct_pack(
            word := word, page_no := page_no,
            x0 := x0, y0 := y0, x1 := x1, y1 := y1,
            left_px := left_px, top_px := top_px
        )), []) FROM proof),
        'docs': (
            SELECT coalesce(list(struct_pack(
                id := document_id, filename := filename, page_count := page_count,
                word_count := word_count, suggestion_count := suggestion_count,
                pending_count := pending_count, flagged_count := flagged_count,
                progress_pct := progress_pct
            ) ORDER BY filename), [])
            FROM doc_rail
        ),
        'page_map': (
            SELECT coalesce(list(struct_pack(
                page_no := page_no, total := total, pending := pending, flagged := flagged
            ) ORDER BY page_no), [])
            FROM page_map
        ),
        'suggestions': (
            SELECT coalesce(list(struct_pack(
                id := id, text := text, context := context, confidence := confidence,
                page_no := page_no, status := status, band := band, current := false,
                kind := kind, entity_id := entity_id
            ) ORDER BY page_rank, status_rank, page_no, id), [])
            FROM queue_rows
        ),
        'stats': (
            SELECT struct_pack(
                suggestion_count := suggestion_count,
                pending_count    := pending_count,
                resolved         := resolved,
                progress_pct     := CASE WHEN suggestion_count = 0 THEN 0
                    ELSE round(100.0 * resolved / suggestion_count, 0)::INTEGER END,
                high_count       := high_count,
                review_count     := review_count,
                flagged_count    := flagged_count
            )
            FROM case_stats
        )
    }::JSON
) AS html;

-- ═══════════════════════════════════════════════════════════════════════════
-- HTML routes
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE ROUTE home GET '/' AS SELECT * FROM render_case(1);
CREATE OR REPLACE ROUTE case_dash GET '/cases/:id' AS SELECT * FROM render_case($id::INTEGER);
CREATE OR REPLACE ROUTE case_audit_html GET '/cases/:id/audit' AS SELECT * FROM render_audit($id::INTEGER);
CREATE OR REPLACE ROUTE document_review GET '/documents/:id' AS SELECT * FROM render_document($id::INTEGER, 1);
CREATE OR REPLACE ROUTE document_page GET '/documents/:id/pages/:page' AS
SELECT * FROM render_document($id::INTEGER, $page::INTEGER);
CREATE OR REPLACE ROUTE reject_shell GET '/ui/reject' AS
SELECT content AS html FROM app_templates WHERE name = 'reject.html';
CREATE OR REPLACE ROUTE add_shell GET '/ui/add-missed' AS
SELECT content AS html FROM app_templates WHERE name = 'add_missed.html';
CREATE OR REPLACE ROUTE bulk_shell GET '/ui/bulk' AS
SELECT content AS html FROM app_templates WHERE name = 'bulk.html';
CREATE OR REPLACE ROUTE library_shell GET '/cases/:id/library' AS
SELECT * FROM render_case($id::INTEGER);
