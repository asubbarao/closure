-- server/domain/fold.sql — decision log + AI → v_suggestions / v_lines.
-- The log is append-only, so "current" means the latest row per suggestion:
-- max_by(d, d.ts) takes that whole row at once, no column-by-column arg_max.

CREATE OR REPLACE VIEW v_latest_decision AS
SELECT suggestion_id, r.status, r.actor, r.reason, r.ts
FROM (
    SELECT suggestion_id, max_by(d, d.ts) AS r
    FROM v_src_decisions d
    WHERE kind = 'decision' AND suggestion_id IS NOT NULL
    GROUP BY suggestion_id
);

CREATE OR REPLACE VIEW v_manual_suggestions AS
SELECT m.suggestion_id AS id,
       m.r.document_id, m.r.page_no, m.r.bbox,
       m.r.text, coalesce(m.r.context, m.r.text) AS context,
       coalesce(m.r.confidence, 99) AS confidence,
       m.r.flag_tag, m.r.reason, m.r.entity_id,
       NULL::VARCHAR AS kind, 'manual' AS source,
       m.r.ts AS created_at, dl.line_no
FROM (
    SELECT suggestion_id, max_by(d, d.ts) AS r
    FROM v_src_decisions d
    WHERE kind = 'added' AND suggestion_id IS NOT NULL
    GROUP BY suggestion_id
) m
LEFT JOIN document_lines dl
  ON dl.document_id = m.r.document_id AND dl.page_no = m.r.page_no
 AND dl.y_key = round(m.r.bbox.y0, 0);

CREATE OR REPLACE VIEW v_suggestions AS
WITH base AS (
    SELECT id, document_id, page_no, bbox, text, context, confidence,
           flag_tag, reason, entity_id, source, created_at,
           kind AS kind_stored, line_no
    FROM suggestions
    UNION ALL BY NAME
    SELECT id, document_id, page_no, bbox, text, context, confidence,
           flag_tag, reason, entity_id, source, created_at, kind, line_no
    FROM v_manual_suggestions
)
SELECT b.id, b.document_id, b.page_no, b.line_no, b.bbox,
       b.bbox.x0 AS x0, b.bbox.y0 AS y0, b.bbox.x1 AS x1, b.bbox.y1 AS y1,
       b.text, b.context, b.confidence, b.flag_tag, b.reason,
       b.entity_id, b.source, b.created_at,
       coalesce(e.kind, b.kind_stored) AS kind,
       e.canonical_text AS entity_text,
       coalesce(ld.status,
                CASE b.source WHEN 'manual' THEN 'accepted' ELSE 'pending' END) AS status,
       CASE WHEN b.flag_tag = 'false_positive' THEN 'flagged'
            WHEN b.confidence >= 90 THEN 'high'
            WHEN b.confidence >= 60 THEN 'review'
            ELSE 'flagged' END AS band,
       CASE WHEN b.entity_id IS NOT NULL THEN 'e:' || b.entity_id
            ELSE 't:' || lower(b.text) || '|' || coalesce(e.kind, b.kind_stored)
       END AS group_key
FROM base b
LEFT JOIN entities e ON e.id = b.entity_id
LEFT JOIN v_latest_decision ld ON ld.suggestion_id = b.id;

CREATE OR REPLACE VIEW v_lines AS
SELECT document_id, page_no, line_no, y_key, line_text, line_norm, word_list, bbox,
       bbox.x0 AS x0, bbox.y0 AS y0, bbox.x1 AS x1, bbox.y1 AS y1, case_id
FROM document_lines;
