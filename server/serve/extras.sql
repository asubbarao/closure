-- server/serve/extras.sql — panels, remainder, history, export (optional product surface).

CREATE OR REPLACE VIEW v_judge_panel AS
SELECT s.id AS suggestion_id, s.confidence,
       CASE WHEN s.band = 'flagged' THEN 'conflict'
            WHEN s.band = 'high' THEN 'agree_redact' ELSE 'split' END AS panel_signal,
       3 AS judge_count,
       CASE WHEN s.band = 'flagged' THEN 1 ELSE 2 END AS redact_votes,
       CASE WHEN s.band = 'flagged' THEN 2 ELSE 0 END AS keep_votes,
       CASE WHEN s.band = 'review' THEN 1 ELSE 0 END AS unsure_votes,
       list_value(
           struct_pack(judge_name := 'Pattern',
               verdict := CASE WHEN s.band = 'flagged' THEN 'keep' ELSE 'redact' END,
               score := s.confidence),
           struct_pack(judge_name := 'Context',
               verdict := CASE WHEN s.flag_tag = 'false_positive' THEN 'keep' ELSE 'redact' END,
               score := s.confidence - 5),
           struct_pack(judge_name := 'Prior',
               verdict := CASE WHEN s.band = 'high' THEN 'redact' ELSE 'unsure' END,
               score := s.confidence - 10)
       ) AS judges
FROM v_suggestions s;

CREATE OR REPLACE TABLE residual_pii_hits AS
WITH covered AS (
    SELECT document_id, page_no, bbox FROM v_suggestions
    WHERE status IN ('accepted', 'pending')
)
SELECT md5(l.document_id || chr(31) || l.page_no::VARCHAR || chr(31) || wl.term) AS id,
       l.document_id, l.page_no AS page, l.case_id,
       wl.term AS text, l.line_text AS context, l.bbox,
       l.bbox.x0 AS x0, l.bbox.y0 AS y0, l.bbox.x1 AS x1, l.bbox.y1 AS y1,
       'PERSON' AS kind, 80.0 AS score,
       'remainder: ' || wl.term AS why, 'rapidfuzz' AS detector,
       NULL::VARCHAR AS entity_id
FROM document_lines l
JOIN watchlist wl ON wl.case_no = l.case_id
WHERE position('NOT PII' IN wl.kind) = 0
  AND rapidfuzz_partial_ratio(l.line_norm, lower(trim(unaccent(wl.term)))) >= 92
  AND NOT EXISTS (
      SELECT 1 FROM covered c
      WHERE c.document_id = l.document_id AND c.page_no = l.page_no
        AND c.bbox.y0 <= l.bbox.y1 AND c.bbox.y1 >= l.bbox.y0
  );

CREATE OR REPLACE VIEW entity_groups AS
SELECT id AS group_id, case_id, kind AS group_kind, id AS root_entity_id,
       canonical_text AS canonical_label, canonical_text AS group_key,
       1 AS member_count, 1 AS variant_count
FROM entities;

CREATE OR REPLACE VIEW entity_group_members AS
SELECT e.id AS member_id, e.id AS group_id, e.case_id,
       e.kind AS group_kind, e.canonical_text AS canonical_label,
       e.id AS entity_id, e.canonical_text AS variant_text,
       100.0 AS score, 'exact' AS method,
       false AS is_full_address, true AS is_canonical
FROM entities e;

CREATE OR REPLACE VIEW v_entity_groups AS SELECT * FROM entity_groups;

CREATE OR REPLACE VIEW entity_address_canon AS
SELECT e.id AS entity_id, e.case_id, e.canonical_text AS raw_text, e.kind,
       NULL::VARCHAR AS city, NULL::VARCHAR AS state, NULL::VARCHAR AS zip,
       false AS is_full_address, e.id AS group_key,
       e.canonical_text AS standardized_text
FROM entities e WHERE starts_with(e.kind, 'ADDRESS');

CREATE OR REPLACE VIEW v_case_provenance AS
SELECT d.id AS document_id, d.case_id, d.filename, d.source_path,
       true AS recheck_ok, 'INTACT' AS recheck_status, now() AS rechecked_at
FROM documents d;

CREATE OR REPLACE VIEW v_pdf_store AS
SELECT d.id AS document_id, d.case_id, d.filename,
       'source' AS stage, d.source_path AS path, d.file_size AS size_bytes,
       1 AS revision_count, 'source' AS mutability, 'source pdf' AS note
FROM documents d;

CREATE OR REPLACE VIEW v_working_plans AS
SELECT d.id AS document_id, 1 AS gen,
       'data/working/doc' || d.id || '_working1.pdf' AS path
FROM documents d;

CREATE OR REPLACE VIEW v_history_events AS
SELECT kind, suggestion_id, status, actor, reason, ts_ts AS event_ts,
       document_id, case_id, text, batch_id, batch_label, undoes_batch_id
FROM v_src_decisions
WHERE nullif(batch_id, '') IS NOT NULL;

CREATE OR REPLACE VIEW v_decision_batches AS
SELECT batch_id, min(event_ts) AS ts, max(event_ts) AS ts_end,
       any_value(actor) AS actor, any_value(batch_label) AS label,
       count(*)::INTEGER AS decision_count,
       count(*) FILTER (WHERE status = 'accepted')::INTEGER AS accepted_count,
       count(*) FILTER (WHERE status = 'rejected')::INTEGER AS rejected_count,
       count(*) FILTER (WHERE status = 'pending')::INTEGER AS pending_count,
       count(*) FILTER (WHERE kind = 'added')::INTEGER AS added_count,
       bool_or(undoes_batch_id IS NOT NULL) AS is_undo,
       max(undoes_batch_id) AS undoes_batch_id,
       max(case_id) AS case_id,
       false AS undone
FROM v_history_events
GROUP BY batch_id;

-- Only place that remaps bbox → pdf_redact bottom-left boxes.
CREATE OR REPLACE VIEW v_export_plans AS
WITH boxes AS (
    SELECT s.document_id,
           list(struct_pack(
               page := s.page_no::INTEGER,
               x := s.x0::DOUBLE,
               y := (p.height_pt - s.y1)::DOUBLE,
               w := (s.x1 - s.x0)::DOUBLE,
               h := (s.y1 - s.y0)::DOUBLE
           ) ORDER BY s.page_no, s.id) AS boxes
    FROM v_suggestions s
    JOIN pages p ON p.document_id = s.document_id AND p.page_no = s.page_no
    WHERE s.status = 'accepted'
    GROUP BY s.document_id
),
gates AS (
    SELECT d.case_id, bool_or(s.band = 'flagged' AND s.status = 'pending') AS blocked
    FROM documents d LEFT JOIN v_suggestions s ON s.document_id = d.id
    GROUP BY d.case_id
)
SELECT g.case_id, g.blocked,
       CASE WHEN g.blocked THEN NULL
            ELSE string_agg(format(
                'SELECT ''{}'' AS document_id, count(*)::INTEGER AS pages FROM pdf_redact(''{}'', ''exports/{}_redacted.pdf'', {}::STRUCT(page INTEGER, x DOUBLE, y DOUBLE, w DOUBLE, h DOUBLE)[])',
                d.id, d.source_path, d.filename, cast(coalesce(b.boxes, []) AS VARCHAR)
            ), ' UNION ALL ')
       END AS export_sql
FROM gates g
JOIN documents d ON d.case_id = g.case_id
LEFT JOIN boxes b ON b.document_id = d.id
GROUP BY g.case_id, g.blocked;
