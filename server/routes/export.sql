-- routes/export.sql — case export: the plan is a VIEW, the act is one route.
--
-- pdf_redact and query() are TABLE functions — their args must fold at bind,
-- so a sentence built from live data can't be assembled inside the executing
-- call. Construction therefore lives in v_export_plans (the sentence is a
-- COLUMN), and the fail-closed gate lives IN the construction: a case with
-- flagged-pending suggestions gets the no-op sentence — nothing a client
-- sends can unblock it.
--
-- The act: GET export_plan hands the sentence out, POST export hands it back
-- as the foldable $sql param. The response is the redaction RELATION itself
-- (document_id, pages per doc) — callers count rows, no server-side tallies.

CREATE OR REPLACE VIEW v_export_plans AS
WITH boxes AS (
    -- accepted boxes as a typed STRUCT[], geometry converted once
    -- (words are top-left, pdf_redact is bottom-left: y = height_pt - y1)
    SELECT s.document_id,
           list(struct_pack(
                    page := s.page_no::INTEGER,
                    x    := s.x0::DOUBLE,
                    y    := (p.height_pt - s.y1)::DOUBLE,
                    w    := (s.x1 - s.x0)::DOUBLE,
                    h    := (s.y1 - s.y0)::DOUBLE)
                ORDER BY s.page_no, s.id) AS boxes
    FROM v_suggestions s
    JOIN pages p ON cast(p.document_id AS VARCHAR) = s.document_id
                AND p.page_no = s.page_no
    WHERE s.status = 'accepted'
    GROUP BY s.document_id
),
doc_sentences AS (
    SELECT d.case_id,
           format(
               'SELECT ''{}'' AS document_id, count(*)::INTEGER AS pages FROM pdf_redact(''{}'', ''exports/{}_redacted.pdf'', {}::STRUCT(page INTEGER, x DOUBLE, y DOUBLE, w DOUBLE, h DOUBLE)[])',
               d.id, d.source_path, d.filename,
               cast(coalesce(b.boxes, []) AS VARCHAR)
           ) AS sentence
    FROM documents d
    LEFT JOIN boxes b ON b.document_id = cast(d.id AS VARCHAR)
),
gates AS (
    SELECT d.case_id,
           bool_or(s.band = 'flagged' AND s.status = 'pending') AS blocked
    FROM documents d
    LEFT JOIN v_suggestions s ON s.document_id = cast(d.id AS VARCHAR)
    GROUP BY d.case_id
)
SELECT g.case_id,
       g.blocked,
       CASE WHEN g.blocked
            THEN 'SELECT NULL AS document_id, NULL::INTEGER AS pages LIMIT 0'
            ELSE string_agg(ds.sentence, ' UNION ALL ')
       END AS export_sql
FROM gates g
JOIN doc_sentences ds USING (case_id)
GROUP BY g.case_id, g.blocked;

CREATE OR REPLACE ROUTE api_case_export_plan GET '/api/cases/:id/export_plan' AS
SELECT blocked, export_sql
FROM v_export_plans
WHERE cast(case_id AS VARCHAR) = $id;

-- POST body: sql=<export_plan.export_sql>. Returns one row per redacted
-- document; a blocked plan's sentence returns zero rows. The guard only
-- keeps $sql to a single SELECT shape.
CREATE OR REPLACE ROUTE api_case_export POST '/api/cases/:id/export'
  PARAM sql VARCHAR DEFAULT 'SELECT NULL AS document_id, NULL::INTEGER AS pages LIMIT 0'
AS
SELECT document_id, pages
FROM query(CASE WHEN starts_with($sql, 'SELECT ') AND position(';' IN $sql) = 0
                THEN $sql
                ELSE 'SELECT NULL AS document_id, NULL::INTEGER AS pages LIMIT 0'
           END);
