-- routes/documents.sql — document resource JSON (lists + page map).
-- Thin projections over v_page_map / v_doc_ui (defined in pages.sql, loaded first).

-- page_no + status/band tallies for the review rail page strip.
CREATE OR REPLACE ROUTE api_doc_page_map GET '/api/documents/:id/page_map' AS
SELECT page_no, total, pending, accepted, rejected, flagged
FROM v_page_map
WHERE document_id = $id
ORDER BY page_no;

-- Case library rows: one GROUP BY over v_suggestions + scan badges.
CREATE OR REPLACE ROUTE api_case_documents GET '/api/cases/:id/documents' AS
SELECT
    id, filename, page_count, file_size, source_path, width_pt, height_pt,
    word_count, scan_badge, scan_badge_class, scan_detail,
    is_scanned, ocr_ingested, scan_gap,
    suggestion_count, pending_count, accepted_count, rejected_count,
    flagged_count, high_count, review_count, progress_pct
FROM v_doc_ui
WHERE case_id = $id
ORDER BY filename;
