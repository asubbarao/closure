-- routes/suggestions.sql — suggestion list JSON APIs.
--
-- Purpose: per-document and per-case suggestion rows for review/bulk UI.
-- Dependencies: v_suggestions, documents.
-- Mutations live in routes/decisions.sql.

CREATE OR REPLACE ROUTE api_doc_suggestions GET '/api/documents/:id/suggestions' AS
SELECT
    s.id, s.document_id, s.page_no, s.x0, s.y0, s.x1, s.y1,
    s.text, s.context, s.confidence, s.flag_tag, s.reason,
    s.entity_id, s.source, s.status, s.band, s.kind, s.entity_text
FROM v_suggestions s
WHERE s.document_id = $id::INTEGER
ORDER BY s.page_no, s.id;

CREATE OR REPLACE ROUTE api_case_suggestions GET '/api/cases/:id/suggestions' AS
SELECT
    s.id, s.document_id, s.page_no, s.x0, s.y0, s.x1, s.y1,
    s.text, s.context, s.confidence, s.flag_tag, s.reason,
    s.entity_id, s.source, s.status, s.band, s.kind, s.entity_text,
    d.filename
FROM v_suggestions s
JOIN documents d ON d.id = s.document_id
WHERE d.case_id = $id::INTEGER
ORDER BY s.document_id, s.page_no, s.id;
