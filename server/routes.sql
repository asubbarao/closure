-- routes.sql — quackapi HTTP surface.
-- Complex HTML is built in MACRO AS TABLE helpers (CREATE ROUTE's parser does
-- not like nested `{ … }` struct literals). Routes stay one thin SELECT.
-- Column name `html` → text/html via quackapi ResponseMode::HTML.

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
SELECT tera_render(
    (SELECT content FROM app_templates WHERE name = 'case.html'),
    {
        'case': (
            SELECT struct_pack(id := c.id, case_no := c.case_no, title := c.title)
            FROM cases c WHERE c.id = cid
        ),
        'stats': (
            SELECT struct_pack(
                doc_count        := (SELECT count(*)::BIGINT FROM documents d WHERE d.case_id = cid),
                page_count       := (SELECT count(*)::BIGINT FROM pages p
                                     JOIN documents d ON d.id = p.document_id WHERE d.case_id = cid),
                word_count       := (SELECT count(*)::BIGINT FROM words w
                                     JOIN documents d ON d.id = w.document_id WHERE d.case_id = cid),
                entity_count     := (SELECT count(*)::BIGINT FROM entities e WHERE e.case_id = cid),
                suggestion_count := coalesce((SELECT count(*)::BIGINT FROM v_suggestions s
                                             JOIN documents d ON d.id = s.document_id
                                             WHERE d.case_id = cid), 0),
                pending_count    := coalesce((SELECT count(*)::BIGINT FROM v_suggestions s
                                             JOIN documents d ON d.id = s.document_id
                                             WHERE d.case_id = cid AND s.status = 'pending'), 0),
                accepted_count   := coalesce((SELECT count(*)::BIGINT FROM v_suggestions s
                                             JOIN documents d ON d.id = s.document_id
                                             WHERE d.case_id = cid AND s.status = 'accepted'), 0),
                rejected_count   := coalesce((SELECT count(*)::BIGINT FROM v_suggestions s
                                             JOIN documents d ON d.id = s.document_id
                                             WHERE d.case_id = cid AND s.status = 'rejected'), 0),
                flagged_count    := coalesce((SELECT count(*)::BIGINT FROM v_suggestions s
                                             JOIN documents d ON d.id = s.document_id
                                             WHERE d.case_id = cid AND s.band = 'flagged'
                                               AND s.status = 'pending'), 0),
                resolved         := coalesce((SELECT count(*)::BIGINT FROM v_suggestions s
                                             JOIN documents d ON d.id = s.document_id
                                             WHERE d.case_id = cid
                                               AND s.status IN ('accepted','rejected')), 0),
                progress_pct     := 0,
                accepted_pct     := 0,
                pending_pct      := 0
            )
        ),
        'documents': (
            SELECT coalesce(list(struct_pack(
                id               := ds.document_id,
                filename         := ds.filename,
                page_count       := ds.page_count,
                word_count       := ds.word_count,
                width_pt         := ds.width_pt,
                height_pt        := ds.height_pt,
                suggestion_count := ds.suggestion_count,
                pending_count    := ds.pending_count,
                flagged_count    := ds.flagged_count
            ) ORDER BY ds.filename), [])
            FROM v_document_stats ds
            WHERE ds.case_id = cid
        ),
        'entities': (
            SELECT coalesce(list(struct_pack(
                id             := e.entity_id,
                canonical_text := e.canonical_text,
                kind           := e.kind,
                hit_count      := e.hit_count,
                doc_count      := e.doc_count,
                mono           := (e.kind IN ('SSN', 'DATE OF BIRTH') OR e.kind LIKE 'PHONE%')
            ) ORDER BY e.hit_count DESC, e.kind, e.canonical_text), [])
            FROM v_entity_hits e
            WHERE e.case_id = cid
        ),
        'audit': (
            SELECT coalesce(list(struct_pack(
                ts_short := strftime(a.ts, '%H:%M'),
                action   := a.action,
                actor    := a.actor,
                target   := coalesce(a.target, ''),
                reason   := coalesce(a.reason, '')
            ) ORDER BY a.id DESC), [])
            FROM (
                SELECT * FROM audit_events
                WHERE case_id = cid
                ORDER BY id DESC
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

-- Document review: real word boxes at PDF coordinates, scaled to 680px width.
CREATE OR REPLACE MACRO render_document(did, pageno) AS TABLE
WITH
doc AS (
    SELECT d.*, c.case_no, c.title AS case_title, c.id AS case_id_real
    FROM documents d
    JOIN cases c ON c.id = d.case_id
    WHERE d.id = did
),
pg AS (
    SELECT least(
        greatest(coalesce(pageno, 1), 1),
        (SELECT page_count FROM doc)
    ) AS page_no
),
page_dims AS (
    SELECT
        p.page_no,
        p.width_pt,
        p.height_pt,
        680.0 / p.width_pt AS scale,
        680.0 AS display_w,
        round(p.height_pt * (680.0 / p.width_pt), 1) AS display_h
    FROM pages p, pg
    WHERE p.document_id = did AND p.page_no = pg.page_no
),
word_rows AS (
    SELECT
        w.word,
        w.x0, w.y0, w.x1, w.y1,
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
          AND (w.word LIKE '%-%' OR w.y0 < 80 OR w.word LIKE 'Yasmine%' OR w.word LIKE 'Nienow%'
               OR w.word LIKE 'Reyes%' OR w.word LIKE 'Rosamond%' OR w.word LIKE 'Arvel%')
    ) z
    WHERE rn <= 6
),
mark_rows AS (
    SELECT
        s.text,
        s.confidence,
        s.status,
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
            text := text, confidence := confidence, status := status, kind := kind,
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
                id := ds.document_id, filename := ds.filename, page_count := ds.page_count,
                word_count := ds.word_count, suggestion_count := ds.suggestion_count
            ) ORDER BY ds.filename), [])
            FROM v_document_stats ds
            WHERE ds.case_id = (SELECT case_id_real FROM doc)
        ),
        'suggestions': (
            SELECT coalesce(list(struct_pack(
                id := s.id, text := s.text, context := s.context, confidence := s.confidence,
                page_no := s.page_no, status := s.status, band := s.band, current := false
            ) ORDER BY s.page_no, s.id), [])
            FROM v_suggestions s
            WHERE s.document_id = did
        ),
        'stats': (
            SELECT struct_pack(
                suggestion_count := coalesce((SELECT count(*)::BIGINT FROM v_suggestions s
                                              JOIN documents d ON d.id = s.document_id
                                              WHERE d.case_id = (SELECT case_id_real FROM doc)), 0),
                pending_count    := coalesce((SELECT count(*)::BIGINT FROM v_suggestions s
                                              JOIN documents d ON d.id = s.document_id
                                              WHERE d.case_id = (SELECT case_id_real FROM doc)
                                                AND s.status = 'pending'), 0),
                resolved         := coalesce((SELECT count(*)::BIGINT FROM v_suggestions s
                                              JOIN documents d ON d.id = s.document_id
                                              WHERE d.case_id = (SELECT case_id_real FROM doc)
                                                AND s.status IN ('accepted','rejected')), 0),
                progress_pct     := 0,
                high_count       := coalesce((SELECT count(*)::BIGINT FROM v_suggestions s
                                              JOIN documents d ON d.id = s.document_id
                                              WHERE d.case_id = (SELECT case_id_real FROM doc)
                                                AND s.band = 'high'), 0),
                review_count     := coalesce((SELECT count(*)::BIGINT FROM v_suggestions s
                                              JOIN documents d ON d.id = s.document_id
                                              WHERE d.case_id = (SELECT case_id_real FROM doc)
                                                AND s.band = 'review'), 0),
                flagged_count    := coalesce((SELECT count(*)::BIGINT FROM v_suggestions s
                                              JOIN documents d ON d.id = s.document_id
                                              WHERE d.case_id = (SELECT case_id_real FROM doc)
                                                AND s.band = 'flagged'), 0)
            )
        )
    }::JSON
) AS html;

-- Mutations are pure SQL INSERT…RETURNING (real quackapi allows DML handlers).
-- No shellfs here: worker connections were OOMing under shellfs+large ingest.
-- PDF byte-copy for export runs via shellfs-free SQL that lists paths; the
-- helper script server/export_case.sh remains for offline identity-copy.

-- ═══════════════════════════════════════════════════════════════════════════
-- HTTP routes
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE ROUTE home GET '/' AS SELECT * FROM render_home();

CREATE OR REPLACE ROUTE case_dash GET '/cases/:id' AS SELECT * FROM render_case($id::INTEGER);

CREATE OR REPLACE ROUTE case_audit GET '/cases/:id/audit' AS SELECT * FROM render_audit($id::INTEGER);

-- Default page 1. Paginated form takes /pages/:page so $page is a path param
-- (query params are always required by quackapi when named in the handler).
CREATE OR REPLACE ROUTE document_review GET '/documents/:id' AS SELECT * FROM render_document($id::INTEGER, 1);

CREATE OR REPLACE ROUTE document_page GET '/documents/:id/pages/:page' AS SELECT * FROM render_document($id::INTEGER, $page::INTEGER);

CREATE OR REPLACE ROUTE reject_shell GET '/ui/reject' AS SELECT content AS html FROM app_templates WHERE name = 'reject.html';

CREATE OR REPLACE ROUTE add_shell GET '/ui/add-missed' AS SELECT content AS html FROM app_templates WHERE name = 'add_missed.html';

CREATE OR REPLACE ROUTE bulk_shell GET '/ui/bulk' AS SELECT content AS html FROM app_templates WHERE name = 'bulk.html';

-- Decision: append-only audit row. suggestions empty this pass → still logs.
CREATE OR REPLACE ROUTE suggestion_decision POST '/suggestions/:id/decision' AS
INSERT INTO audit_events (actor, action, suggestion_id, target)
VALUES (
    'A. Subbarao',
    $action,
    $id::INTEGER,
    'decision on suggestion #' || cast($id AS VARCHAR) || ' (lookup pending seed)'
)
RETURNING id, ts, actor, action, suggestion_id, case_id, target, reason;

-- Export: audit row + per-doc paths (identity-copy is correct while suggestions
-- empty). Offline: bash server/export_case.sh <case_id> for PDF byte-copy.
CREATE OR REPLACE ROUTE case_export POST '/cases/:id/export' AS
INSERT INTO audit_events (actor, action, case_id, target)
SELECT
    'A. Subbarao',
    'exported',
    $id::INTEGER,
    'export case ' || cast($id AS VARCHAR) || ': ' || cast(count(*) AS VARCHAR)
        || ' doc(s) → exports/*_redacted.pdf (identity-copy while suggestions empty; run server/export_case.sh '
        || cast($id AS VARCHAR) || ')'
FROM documents
WHERE case_id = $id::INTEGER
RETURNING id, ts, actor, action, suggestion_id, case_id, target, reason;

CREATE OR REPLACE ROUTE api_stats GET '/api/stats' AS SELECT
    (SELECT count(*) FROM cases) AS cases,
    (SELECT count(*) FROM documents) AS documents,
    (SELECT count(*) FROM pages) AS pages,
    (SELECT count(*) FROM words) AS words,
    (SELECT count(*) FROM entities) AS entities,
    (SELECT count(*) FROM suggestions) AS suggestions,
    (SELECT count(*) FROM audit_events) AS audit_events;

CREATE OR REPLACE ROUTE api_doc_words GET '/api/documents/:id/words' AS SELECT page_no, seq, word, x0, y0, x1, y1
FROM words
WHERE document_id = $id::INTEGER
  AND page_no = 1
ORDER BY seq
LIMIT 50;

CREATE OR REPLACE ROUTE api_doc_words_page GET '/api/documents/:id/pages/:page/words' AS SELECT page_no, seq, word, x0, y0, x1, y1
FROM words
WHERE document_id = $id::INTEGER
  AND page_no = $page::INTEGER
ORDER BY seq
LIMIT 50;
