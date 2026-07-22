-- core.sql — app data model.
--
-- Path IO (who does what):
--   hostfs     discover on the machine: ls/lsr + is_file/file_extension/… (typed path cols)
--   scalarfs   pin those paths as variables; pathvariable:/variable:/to_scalarfs_uri
--   zipfs      when a host path is a .zip (LE case pack): archive_contents + zip://…/member
--              We may have zero zips today; empty v_zips is fine. Product still needs the path.
--   shellfs    host effects as rows: read_text('cmd |') / bash scripts/foo.sh |
--              (see server/shellfs.sql). Not a second ls — hostfs discovers.
-- Unmat views open files. Tables = state. No MATERIALIZED VIEW.

-- ── files (read-only) ──────────────────────────────────────────────────────

CREATE OR REPLACE VIEW v_src_pdf_info AS
SELECT file AS source_path, parse_filename(file, true) AS filename,
       page_count, width AS width_pt, height AS height_pt, file_size
FROM pdf_info('pathvariable:sample_pdfs');

CREATE OR REPLACE VIEW v_src_pdf_pages AS
SELECT filename, parse_filename(filename, true) AS doc_filename,
       page AS page_no, width AS width_pt, height AS height_pt
FROM read_pdf('pathvariable:sample_pdfs');

CREATE OR REPLACE VIEW v_src_pdf_words AS
SELECT filename, parse_filename(filename, true) AS doc_filename,
       page AS page_no, word, (x0, y0, x1, y1)::bbox AS bbox, font_size
FROM read_pdf_words('pathvariable:sample_pdfs');

-- PDF-native lines (pdf extension). Geometry still comes from words → document_lines.
CREATE OR REPLACE VIEW v_src_pdf_lines AS
SELECT parse_filename(filename, true) AS doc_filename,
       page AS page_no, line AS line_number, text AS content
FROM read_pdf_lines('pathvariable:sample_pdfs');

CREATE OR REPLACE VIEW v_src_manifest AS
SELECT parse_filename(f.filename, true) AS filename, f.case_no
FROM (SELECT unnest(files) AS f FROM read_json_auto('pathvariable:manifest_path'))
WHERE f.filename IS NOT NULL;

CREATE OR REPLACE VIEW v_src_watchlist AS
SELECT term, kind, case_no FROM read_json_auto('pathvariable:watchlist_path')
WHERE nullif(trim(term), '') IS NOT NULL;

CREATE OR REPLACE VIEW v_src_decisions AS SELECT * FROM decisions;

-- Templates (webbed HTML type). Params that earn: filename, ignore_errors, max size.
CREATE OR REPLACE VIEW v_src_templates AS
SELECT filename AS path, file_name(filename) AS name, html AS body
FROM read_html_objects(
    'pathvariable:template_files',
    filename := true,
    ignore_errors := true,
    maximum_file_size := 1048576
);

-- Template hrefs as rows (webbed extract — not a second product nav model)
CREATE OR REPLACE VIEW v_src_template_links AS
SELECT t.name AS template, lnk.text AS link_text, lnk.href, lnk.line_number
FROM v_src_templates t, unnest(html_extract_links(t.body)) AS u(lnk);

-- YAML config as columns (same file semantic_views loads as CREATE SEMANTIC VIEW).
CREATE OR REPLACE VIEW v_src_semantic_yaml AS
SELECT * FROM read_yaml('server/config/closure_semantic.yaml', ignore_errors := true);

-- JSON configs stay JSON: pathvariable:manifest_path / watchlist_path / detector_rules_path

-- Host tree: server/hostfs.sql (v_hostfs, v_zips).

-- ── tables ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE TABLE cases AS
SELECT DISTINCT case_no AS id, case_no,
       inflector_to_title_case('case') || ' ' || case_no AS title
FROM v_src_manifest;

CREATE OR REPLACE TABLE documents AS
SELECT format('{:x}', rapidhash(m.case_no || chr(31) || p.filename)) AS id,
       m.case_no AS case_id, p.filename, p.source_path,
       p.page_count, p.width_pt, p.height_pt, p.file_size,
       -- display pins (UI uses these; views do not recompute)
       inflector_to_title_case(replace(p.filename, '_', ' ')) AS display_name,
       hsize(p.file_size) AS size_label
FROM v_src_pdf_info p JOIN v_src_manifest m ON m.filename = p.filename;

-- Geometry + fixed review scale (680px wide). Downstream: SELECT scale, not recompute.
CREATE OR REPLACE TABLE pages AS
SELECT d.id AS document_id, p.page_no, p.width_pt, p.height_pt,
       680.0 / p.width_pt AS scale,
       680.0 AS display_w,
       round(p.height_pt * 680.0 / p.width_pt, 1) AS display_h
FROM v_src_pdf_pages p JOIN documents d ON d.filename = p.doc_filename;

-- Corpus = barcode-sanitizer shape: full intermediate tables, no lossy coalesce.
--   word_raw          occurrence grain (all surface forms kept)
--   token_types       DISTINCT token evidence (finetype + url) — debugable
--   kind_rules        enhanceable JSON (INSERT row = new format)
--   token_rule_hits   EVERY rule that matched (trace table; not collapsed)
--   token_kind        one primary kind per token (priority pick)
--   words             cheap app table: occurrence ⨝ types ⨝ primary kind

CREATE OR REPLACE TABLE word_raw AS
WITH base AS (
    SELECT d.id AS document_id, d.case_id, w.page_no, w.word, w.bbox, w.font_size,
           trim(w.word, '.,;:()"''[]') AS token,
           round(w.bbox.y0, 0) AS y_key
    FROM v_src_pdf_words w
    JOIN documents d ON d.filename = w.doc_filename
    WHERE length(trim(w.word, '.,;:()"''[]')) > 0
),
compacted AS (
    SELECT *,
           replace(replace(replace(replace(token, '-', ''), '(', ''), ')', ''), '.', '') AS token_compact
    FROM base
)
SELECT document_id, case_id, page_no, word, bbox, font_size, token, y_key,
       lower(unaccent(token)) AS token_norm,
       token_compact,
       length(token_compact) AS compact_len,
       try_cast(token_compact AS BIGINT) IS NOT NULL AS compact_is_int
FROM compacted;

CREATE OR REPLACE TABLE token_types AS
SELECT token, token_compact, compact_len, compact_is_int,
       finetype(token) AS type_label,
       finetype(token_compact) AS type_label_compact,
       url_valid(token) AS is_url,
       CASE WHEN url_valid(token) THEN url_hostname(token) END AS hostname,
       CASE WHEN url_valid(token) THEN url_parse(token) END AS url_parts
FROM (
    SELECT DISTINCT token, token_compact, compact_len, compact_is_int
    FROM word_raw
);

-- Edit detector_rules.json to enhance (priority lower = wins). pathvariable: open.
CREATE OR REPLACE TABLE kind_rules AS
SELECT * FROM read_json_auto('pathvariable:detector_rules_path');

-- Full match trace (like barcode classification rows — keep every hit).
CREATE OR REPLACE TABLE token_rule_hits AS
SELECT tt.token, r.rule, r.kind, r.confidence, r.priority,
       'type_label=' || tt.type_label AS evidence
FROM token_types tt
JOIN kind_rules r ON r.rule = 'finetype_prefix'
 AND starts_with(tt.type_label, r.type_prefix)
UNION ALL BY NAME
SELECT tt.token, r.rule, r.kind, r.confidence, r.priority,
       'type_label_compact=' || tt.type_label_compact
FROM token_types tt
JOIN kind_rules r ON r.rule = 'finetype_prefix'
 AND starts_with(tt.type_label_compact, r.type_prefix)
UNION ALL BY NAME
SELECT tt.token, r.rule, r.kind, r.confidence, r.priority,
       'compact_len=' || tt.compact_len::VARCHAR
FROM token_types tt
JOIN kind_rules r ON r.rule = 'shape'
 AND tt.compact_len = r.compact_len AND tt.compact_is_int
UNION ALL BY NAME
SELECT tt.token, r.rule, r.kind, r.confidence, r.priority, 'url_valid'
FROM token_types tt
JOIN kind_rules r ON r.rule = 'url_valid' AND tt.is_url
UNION ALL BY NAME
SELECT tt.token, r.rule, r.kind, r.confidence, r.priority,
       'urlpattern=' || r.url_pattern
FROM token_types tt
JOIN kind_rules r ON r.rule = 'urlpattern' AND r.url_pattern IS NOT NULL
 AND urlpattern_test(r.url_pattern, tt.token);

-- One primary kind per token (priority, then confidence) — not coalesce of NULLs.
CREATE OR REPLACE TABLE token_kind AS
SELECT token, kind AS pii_kind, confidence AS pii_confidence, rule AS pii_rule, evidence
FROM token_rule_hits
QUALIFY row_number() OVER (
    PARTITION BY token ORDER BY priority ASC, confidence DESC, rule
) = 1;

-- App table: everything useful precomputed for cheap filters/joins.
CREATE OR REPLACE TABLE words AS
SELECT r.document_id, r.case_id, r.page_no, r.word, r.bbox, r.font_size,
       r.token, r.token_norm, r.token_compact, r.compact_len, r.compact_is_int, r.y_key,
       length(r.token) AS token_len,
       tt.type_label, tt.type_label_compact, tt.is_url, tt.hostname, tt.url_parts,
       tk.pii_kind, tk.pii_confidence, tk.pii_rule, tk.evidence AS pii_evidence,
       (tk.pii_kind IS NOT NULL) AS is_pii
FROM word_raw r
JOIN token_types tt ON tt.token = r.token
LEFT JOIN token_kind tk ON tk.token = r.token;

CREATE OR REPLACE TABLE watchlist AS
SELECT term, kind, case_no,
       lower(unaccent(trim(term))) AS term_norm,
       string_split(lower(unaccent(trim(term))), ' ') AS term_tokens,
       replace(replace(replace(replace(trim(term), '-', ''), '(', ''), ')', ''), '.', '') AS term_compact,
       (position('NOT PII' IN kind) > 0) AS is_not_pii
FROM v_src_watchlist
WHERE nullif(trim(term), '') IS NOT NULL;

-- Bloom over prepared watchlist tokens (v1.5.1 = bitfilters hash-compat pin).
SET VARIABLE watchlist_bloom = (
    SELECT bitfilters_duckdb_bloom_filter_create('v1.5.1', 64, hv)
    FROM (
        SELECT bitfilters_duckdb_hash('v1.5.1', term_norm) AS hv
        FROM watchlist WHERE NOT is_not_pii
        UNION ALL
        SELECT bitfilters_duckdb_hash('v1.5.1', t) AS hv
        FROM watchlist, unnest(term_tokens) AS u(t)
        WHERE NOT is_not_pii AND length(t) >= 3
    )
);

CREATE OR REPLACE TABLE document_lines AS
SELECT w.document_id, w.page_no, w.case_id, w.y_key,
       dense_rank() OVER (
           PARTITION BY w.document_id, w.page_no ORDER BY w.y_key
       )::INTEGER AS line_no,
       string_agg(w.word, ' ' ORDER BY w.bbox.x0) AS line_text,
       string_agg(w.token_norm, ' ' ORDER BY w.bbox.x0) AS line_norm,
       list(w.token_norm ORDER BY w.bbox.x0) AS token_norms,
       list(struct_pack(token_norm := w.token_norm, bbox := w.bbox)
            ORDER BY w.bbox.x0) AS word_meta,
       (min(w.bbox.x0), min(w.bbox.y0), max(w.bbox.x1), max(w.bbox.y1))::bbox AS bbox
FROM words w
GROUP BY w.document_id, w.page_no, w.case_id, w.y_key;

-- detect: join prepared columns only
SET VARIABLE detect_run_id = (SELECT uuid()::VARCHAR);

CREATE OR REPLACE TABLE _detect_hits AS
WITH type_hits AS (
    SELECT w.document_id, w.page_no, w.case_id,
           w.token AS text, w.token AS context, w.bbox,
           w.pii_kind AS kind,
           w.pii_confidence AS confidence,
           w.pii_rule || ': ' || w.pii_evidence AS reason,
           NULL::VARCHAR AS flag_tag,
           'detector:corpus' AS detector_key
    FROM words w
    WHERE w.is_pii
),
name_hits AS (
    -- No CROSS JOIN / LATERAL: score in an inner SELECT, filter outer.
    SELECT document_id, page_no, case_id, text, context,
           list_reduce(
               list_transform(mw, m -> m.bbox),
               (a, b) -> (least(a.x0, b.x0), least(a.y0, b.y0),
                          greatest(a.x1, b.x1), greatest(a.y1, b.y1))::bbox
           ) AS bbox,
           kind, greatest(1, least(99, round(sc)::INTEGER)) AS confidence,
           'rapidfuzz: ' || text AS reason,
           CASE WHEN is_not_pii THEN 'false_positive' END AS flag_tag,
           'detector:rapidfuzz-watchlist' AS detector_key
    FROM (
        SELECT l.document_id, l.page_no, l.case_id,
               wl.term AS text, l.line_text AS context, wl.kind, wl.is_not_pii,
               greatest(
                   rapidfuzz_token_sort_ratio(l.line_norm, wl.term_norm),
                   rapidfuzz_partial_ratio(l.line_norm, wl.term_norm),
                   100.0 * jaro_winkler_similarity(l.line_norm, wl.term_norm)
               ) AS sc,
               list_filter(l.word_meta, m ->
                   list_bool_or(list_transform(wl.term_tokens, t ->
                       rapidfuzz_ratio(m.token_norm, t) >= 88
                   ))) AS mw
        FROM document_lines l
        JOIN (
            SELECT document_id, page_no, y_key
            FROM words
            WHERE bitfilters_duckdb_bloom_filter_probe(
                'v1.5.1', getvariable('watchlist_bloom'), token_norm)
            GROUP BY 1, 2, 3
        ) cand ON cand.document_id = l.document_id AND cand.page_no = l.page_no
             AND cand.y_key = l.y_key
        JOIN watchlist wl ON wl.case_no = l.case_id
    ) scored
    WHERE sc >= 90 AND len(mw) > 0
)
SELECT * FROM type_hits UNION ALL BY NAME SELECT * FROM name_hits;

CREATE OR REPLACE TABLE entities AS
SELECT format('{:x}', rapidhash(case_id || chr(31) || kind || chr(31) || canonical_text)) AS id,
       case_id, canonical_text, kind,
       inflector_to_title_case(replace(lower(kind), ' · ', ' ')) AS kind_label,
       (kind IN ('SSN', 'DATE OF BIRTH') OR starts_with(kind, 'PHONE')) AS mono
FROM (
    SELECT case_no AS case_id, term AS canonical_text, kind FROM watchlist
    UNION SELECT case_id, text, kind FROM _detect_hits WHERE kind IS NOT NULL AND text IS NOT NULL
) u GROUP BY case_id, canonical_text, kind;

CREATE OR REPLACE TABLE suggestions AS
SELECT format('{:x}', rapidhash(
           h.document_id || chr(31) || h.page_no::VARCHAR || chr(31)
           || round(h.bbox.x0, 0)::VARCHAR || chr(31) || round(h.bbox.y0, 0)::VARCHAR || chr(31)
           || round(h.bbox.x1, 0)::VARCHAR || chr(31) || round(h.bbox.y1, 0)::VARCHAR || chr(31)
           || h.text || chr(31) || h.kind || chr(31) || 'ai')) AS id,
       h.document_id, h.page_no, h.bbox, h.text, coalesce(h.context, h.text) AS context,
       h.confidence, h.flag_tag, h.reason, e.id AS entity_id, h.kind,
       'ai' AS source, TIMESTAMP '1970-01-01' AS created_at, dl.line_no,
       getvariable('detect_run_id') AS source_run_id, h.detector_key
FROM _detect_hits h
LEFT JOIN entities e ON e.case_id = h.case_id AND e.kind = h.kind
 AND (e.canonical_text = h.text OR starts_with(e.canonical_text, h.text) OR starts_with(h.text, e.canonical_text))
LEFT JOIN document_lines dl ON dl.document_id = h.document_id AND dl.page_no = h.page_no
 AND dl.y_key = round(h.bbox.y0, 0);

DROP TABLE IF EXISTS _detect_hits;

-- Session profile pins (scalarfs native lists — not JSON laundry).
-- Re-read: SELECT * FROM unnest(getvariable('profile_words')) AS u(r); etc.
COPY (FROM (SUMMARIZE words)) TO 'variable:profile_words' (FORMAT variable, LIST rows);
COPY (FROM (SUMMARIZE v_suggestions)) TO 'variable:profile_suggestions' (FORMAT variable, LIST rows);

INSERT INTO pipeline_runs BY NAME
SELECT getvariable('detect_run_id') AS run_id,
       'detect' AS kind,
       now() AS ts,
       NULL::JSON AS raw;

-- ── projections (unmat views only) ─────────────────────────────────────────

CREATE OR REPLACE VIEW v_latest_decision AS
SELECT suggestion_id, r.status, r.actor, r.reason, r.ts
FROM (SELECT suggestion_id, max_by(d, d.ts) AS r FROM v_src_decisions d
      WHERE kind = 'decision' AND suggestion_id IS NOT NULL GROUP BY suggestion_id);

CREATE OR REPLACE VIEW v_manual_suggestions AS
SELECT m.suggestion_id AS id, m.r.document_id, m.r.page_no, m.r.bbox,
       m.r.text, coalesce(m.r.context, m.r.text) AS context,
       coalesce(m.r.confidence, 99) AS confidence, m.r.flag_tag, m.r.reason, m.r.entity_id,
       NULL::VARCHAR AS kind, 'manual' AS source, m.r.ts AS created_at, dl.line_no,
       NULL::VARCHAR AS source_run_id, 'manual' AS detector_key
FROM (SELECT suggestion_id, max_by(d, d.ts) AS r FROM v_src_decisions d
      WHERE kind = 'added' AND suggestion_id IS NOT NULL GROUP BY suggestion_id) m
LEFT JOIN document_lines dl ON dl.document_id = m.r.document_id AND dl.page_no = m.r.page_no
 AND dl.y_key = round(m.r.bbox.y0, 0);

CREATE OR REPLACE VIEW v_suggestions AS
WITH base AS (
    SELECT id, document_id, page_no, bbox, text, context, confidence, flag_tag, reason,
           entity_id, source, created_at, kind AS kind_stored, line_no, source_run_id, detector_key
    FROM suggestions
    UNION ALL BY NAME
    SELECT id, document_id, page_no, bbox, text, context, confidence, flag_tag, reason,
           entity_id, source, created_at, kind, line_no, source_run_id, detector_key
    FROM v_manual_suggestions
)
-- bbox stays STRUCT; unpack only at HTTP/JS edge (routes / canvas px).
SELECT b.id, b.document_id, b.page_no, b.line_no, b.bbox,
       b.text, b.context, b.confidence, b.flag_tag, b.reason, b.entity_id, b.source, b.created_at,
       b.source_run_id, b.detector_key,
       coalesce(e.kind, b.kind_stored) AS kind, e.canonical_text AS entity_text,
       coalesce(ld.status, CASE b.source WHEN 'manual' THEN 'accepted' ELSE 'pending' END) AS status,
       CASE WHEN b.flag_tag = 'false_positive' THEN 'flagged'
            WHEN b.confidence >= 90 THEN 'high'
            WHEN b.confidence >= 60 THEN 'review' ELSE 'flagged' END AS band,
       CASE WHEN b.entity_id IS NOT NULL THEN 'e:' || b.entity_id
            ELSE 't:' || lower(b.text) || '|' || coalesce(e.kind, b.kind_stored) END AS group_key
FROM base b
LEFT JOIN entities e ON e.id = b.entity_id
LEFT JOIN v_latest_decision ld ON ld.suggestion_id = b.id;

CREATE OR REPLACE VIEW v_lines AS
SELECT document_id, page_no, case_id,
       line_no AS line_number, line_no,
       line_text AS content, line_text,
       line_norm, token_norms, y_key, bbox
FROM document_lines;

-- Page text + scalarfs URI (read_lines without temp files).
-- Window: SET VARIABLE page_uri = (SELECT page_uri FROM v_page_text WHERE …);
--         SELECT * FROM read_lines(getvariable('page_uri'), lines := '42 +/-3');
-- Or pin text:  COPY (SELECT page_text …) TO 'variable:page_text' (FORMAT variable);
--               SELECT * FROM read_lines('variable:page_text');
CREATE OR REPLACE VIEW v_page_text AS
SELECT document_id, page_no, case_id,
       string_agg(line_text, chr(10) ORDER BY line_no) AS page_text,
       to_scalarfs_uri(string_agg(line_text, chr(10) ORDER BY line_no)) AS page_uri
FROM document_lines
GROUP BY document_id, page_no, case_id;

CREATE OR REPLACE VIEW v_decide_targets AS
SELECT s.id AS suggestion_id, s.document_id, d.case_id, s.text, s.entity_id, s.entity_text,
       s.band, s.status, s.group_key, s.confidence, coalesce(s.flag_tag, '') AS flag_tag
FROM v_suggestions s JOIN documents d ON d.id = s.document_id;
