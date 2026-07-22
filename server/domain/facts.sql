-- server/domain/facts.sql — durable tables from typed sources.

CREATE OR REPLACE TABLE cases AS
SELECT DISTINCT case_no AS id, case_no, 'Case ' || case_no AS title
FROM v_src_manifest;

CREATE OR REPLACE TABLE documents AS
SELECT md5(m.case_no || chr(31) || p.filename) AS id,
       m.case_no AS case_id, p.filename, p.source_path,
       p.page_count, p.width_pt, p.height_pt, p.file_size
FROM v_src_pdf_info p
JOIN v_src_manifest m ON m.filename = p.filename;

CREATE OR REPLACE TABLE pages AS
SELECT d.id AS document_id, p.page_no, p.width_pt, p.height_pt
FROM v_src_pdf_pages p
JOIN documents d ON d.filename = p.doc_filename;

CREATE OR REPLACE TABLE words AS
SELECT d.id AS document_id, w.page_no, w.word, w.bbox, w.font_size
FROM v_src_pdf_words w
JOIN documents d ON d.filename = w.doc_filename;

CREATE OR REPLACE TABLE watchlist AS
SELECT term, kind, case_no FROM v_src_watchlist;

-- Visual lines: one bbox per y-bag.
CREATE OR REPLACE TABLE document_lines AS
SELECT w.document_id, w.page_no, d.case_id,
       round(w.bbox.y0, 0) AS y_key,
       dense_rank() OVER (
           PARTITION BY w.document_id, w.page_no
           ORDER BY round(w.bbox.y0, 0)
       )::INTEGER AS line_no,
       string_agg(w.word, ' ' ORDER BY w.bbox.x0) AS line_text,
       lower(trim(unaccent(string_agg(w.word, ' ' ORDER BY w.bbox.x0)))) AS line_norm,
       list(w.word ORDER BY w.bbox.x0) AS word_list,
       list(struct_pack(word := w.word, bbox := w.bbox) ORDER BY w.bbox.x0) AS word_meta,
       struct_pack(
           x0 := min(w.bbox.x0), y0 := min(w.bbox.y0),
           x1 := max(w.bbox.x1), y1 := max(w.bbox.y1)
       ) AS bbox
FROM words w
JOIN documents d ON d.id = w.document_id
GROUP BY w.document_id, w.page_no, d.case_id, round(w.bbox.y0, 0);
