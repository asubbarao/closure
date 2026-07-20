-- routes/documents.sql — document resource JSON (lists + page map).
-- Spine: pages, documents, v_suggestions, v_document_stats. No inline count soup.

-- page_no + status/band tallies for the review rail page strip.
CREATE OR REPLACE ROUTE api_doc_page_map GET '/api/documents/:id/page_map' AS
SELECT
    p.page_no,
    coalesce(c.total, 0)::BIGINT    AS total,
    coalesce(c.pending, 0)::BIGINT  AS pending,
    coalesce(c.accepted, 0)::BIGINT AS accepted,
    coalesce(c.rejected, 0)::BIGINT AS rejected,
    coalesce(c.flagged, 0)::BIGINT  AS flagged
FROM pages p
LEFT JOIN (
    SELECT page_no,
           count(*)::BIGINT AS total,
           count(*) FILTER (WHERE status = 'pending')::BIGINT AS pending,
           count(*) FILTER (WHERE status = 'accepted')::BIGINT AS accepted,
           count(*) FILTER (WHERE status = 'rejected')::BIGINT AS rejected,
           count(*) FILTER (WHERE band = 'flagged' AND status = 'pending')::BIGINT AS flagged
    FROM v_suggestions
    WHERE document_id = $id
    GROUP BY page_no
) c ON c.page_no = p.page_no
WHERE cast(p.document_id AS VARCHAR) = $id
ORDER BY p.page_no;

-- Case library rows: stats view owns counts; documents owns source_path.
CREATE OR REPLACE ROUTE api_case_documents GET '/api/cases/:id/documents' AS
SELECT
    st.document_id AS id,
    st.filename,
    st.page_count,
    st.file_size,
    d.source_path,
    st.width_pt,
    st.height_pt,
    st.word_count,
    cast(NULL AS VARCHAR) AS scan_badge,
    cast(NULL AS VARCHAR) AS scan_badge_class,
    cast(NULL AS VARCHAR) AS scan_detail,
    false AS is_scanned,
    false AS ocr_ingested,
    false AS scan_gap,
    st.suggestion_count,
    st.pending_count,
    st.accepted_count,
    st.rejected_count,
    st.flagged_count,
    st.high_count,
    st.review_count,
    CASE WHEN st.suggestion_count = 0 THEN 0
         ELSE round(100.0 * (st.accepted_count + st.rejected_count)
                    / st.suggestion_count, 0)::INTEGER
    END AS progress_pct
FROM v_document_stats st
JOIN documents d ON cast(d.id AS VARCHAR) = st.document_id
WHERE st.case_id = $id
ORDER BY st.filename;
