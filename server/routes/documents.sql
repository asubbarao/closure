-- routes/documents.sql — document resource JSON (lists + page map).
--
-- Purpose: document-centric read APIs for review rail / library.
-- Dependencies: documents, pages, v_suggestions.
-- Suggestion lists: routes/suggestions.sql.

CREATE OR REPLACE ROUTE api_doc_page_map GET '/api/documents/:id/page_map' AS
SELECT
    p.page_no,
    coalesce(c.n, 0)::BIGINT AS total,
    coalesce(c.pending, 0)::BIGINT AS pending,
    coalesce(c.accepted, 0)::BIGINT AS accepted,
    coalesce(c.rejected, 0)::BIGINT AS rejected,
    coalesce(c.flagged, 0)::BIGINT AS flagged
FROM pages p
LEFT JOIN (
    SELECT
        s.page_no,
        count(*)::BIGINT AS n,
        count(*) FILTER (WHERE s.status = 'pending')::BIGINT AS pending,
        count(*) FILTER (WHERE s.status = 'accepted')::BIGINT AS accepted,
        count(*) FILTER (WHERE s.status = 'rejected')::BIGINT AS rejected,
        count(*) FILTER (WHERE s.band = 'flagged' AND s.status = 'pending')::BIGINT AS flagged
    FROM v_suggestions s
    WHERE s.document_id = $id::INTEGER
    GROUP BY s.page_no
) c ON c.page_no = p.page_no
WHERE p.document_id = $id::INTEGER
ORDER BY p.page_no;

CREATE OR REPLACE ROUTE api_case_documents GET '/api/cases/:id/documents' AS
SELECT
    d.id,
    d.filename,
    d.page_count,
    d.file_size,
    d.source_path,
    d.width_pt,
    d.height_pt,
    coalesce(sc.total_word_count, 0)::BIGINT AS word_count,
    sc.scan_badge,
    sc.scan_badge_class,
    sc.scan_detail,
    coalesce(sc.is_scanned, false) AS is_scanned,
    coalesce(sc.ocr_ingested, false) AS ocr_ingested,
    coalesce(sc.scan_gap, false) AS scan_gap,
    coalesce(sa.suggestion_count, 0)::BIGINT AS suggestion_count,
    coalesce(sa.pending_count, 0)::BIGINT AS pending_count,
    coalesce(sa.accepted_count, 0)::BIGINT AS accepted_count,
    coalesce(sa.rejected_count, 0)::BIGINT AS rejected_count,
    coalesce(sa.flagged_count, 0)::BIGINT AS flagged_count,
    coalesce(sa.high_count, 0)::BIGINT AS high_count,
    coalesce(sa.review_count, 0)::BIGINT AS review_count,
    CASE WHEN coalesce(sa.suggestion_count, 0) = 0 THEN 0
         ELSE round(100.0 * (coalesce(sa.accepted_count, 0) + coalesce(sa.rejected_count, 0))
                    / sa.suggestion_count, 0)::INTEGER
    END AS progress_pct
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
WHERE d.case_id = $id::INTEGER
ORDER BY d.filename;
