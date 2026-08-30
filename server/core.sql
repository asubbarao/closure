-- core.sql — quackapi exemplar spine (reference app, not product).
-- v_src_* → pdf_words/pdf_lines → words/watchlist → name_rule_hits + detect_hits → suggestions.
-- Line grain = read_pdf_lines only. Score theater collapsed into CTEs inside pins.

-- ── unmat sources ──────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW v_src_manifest AS
SELECT file_entry.filename, file_entry.case_no
FROM (SELECT unnest(files) AS file_entry FROM read_json_auto('pathvariable:manifest_path'))
WHERE file_entry.filename IS NOT NULL;

CREATE OR REPLACE VIEW v_src_watchlist AS
SELECT trim(term) AS term, kind, case_no
FROM read_json_auto('pathvariable:watchlist_path')
WHERE nullif(trim(term), '') IS NOT NULL;

CREATE OR REPLACE VIEW v_src_decisions AS SELECT * FROM decisions;

CREATE OR REPLACE VIEW v_src_templates AS
SELECT filename AS path, file_name(filename) AS name, html AS body
FROM read_html_objects('pathvariable:template_files',
    filename := true, ignore_errors := true, maximum_file_size := 1048576);

CREATE OR REPLACE VIEW v_src_template_links AS
SELECT tpl.name AS template, lnk.text AS link_text, lnk.href, lnk.line_number
FROM v_src_templates tpl, unnest(html_extract_links(tpl.body)) AS link_rows(lnk);

CREATE OR REPLACE VIEW v_src_semantic_yaml AS
SELECT * FROM read_yaml('server/config/closure_semantic.yaml', ignore_errors := true);

CREATE OR REPLACE VIEW v_src_pdf_files AS
SELECT abs_path AS source_path, name AS filename, bytes AS file_size
FROM v_hostfs WHERE root = 'samples' AND is_file IS TRUE AND ext = '.pdf';

-- ── pins ───────────────────────────────────────────────────────────────────

CREATE OR REPLACE TABLE cases AS
SELECT DISTINCT case_no AS id, case_no,
       inflector_to_title_case('case') || ' ' || case_no AS title
FROM v_src_manifest;

CREATE OR REPLACE TABLE kind_rules AS
SELECT * FROM read_json_auto('pathvariable:detector_rules_path');

CREATE OR REPLACE TABLE template_links AS SELECT * FROM v_src_template_links;

CREATE OR REPLACE TABLE pdf_words AS
SELECT file_name(filename) AS filename, page AS page_no, word,
       (x0, y0, x1, y1)::bbox AS bbox, font_size
FROM read_pdf_words('pathvariable:sample_pdfs')
WHERE file_name(filename) IS NOT NULL;

CREATE OR REPLACE TABLE pdf_lines AS
SELECT file_name(filename) AS filename, page AS page_no, line AS line_no, text AS line_text
FROM read_pdf_lines('pathvariable:sample_pdfs')
WHERE file_name(filename) IS NOT NULL;

CREATE OR REPLACE TABLE documents AS
SELECT format('{:x}', rapidhash(man.case_no || chr(31) || geo.filename)) AS id,
       man.case_no AS case_id, geo.filename, f.source_path,
       geo.page_count, geo.width_pt, geo.height_pt, f.file_size,
       inflector_to_title_case(replace(replace(geo.filename, '.pdf', ''), '_', ' ')) AS display_name,
       hsize(f.file_size) AS size_label
FROM (
    SELECT filename, max(page_no)::INTEGER AS page_count,
           greatest(max(bbox.x1), 1.0) AS width_pt, greatest(max(bbox.y1), 1.0) AS height_pt
    FROM pdf_words GROUP BY filename
) geo
JOIN v_src_manifest man ON man.filename = geo.filename
JOIN v_src_pdf_files f ON f.filename = geo.filename;

CREATE OR REPLACE TABLE pages AS
SELECT doc.id AS document_id, wrd.page_no,
       greatest(max(wrd.bbox.x1), 1.0) AS width_pt,
       greatest(max(wrd.bbox.y1), 1.0) AS height_pt,
       680.0 / greatest(max(wrd.bbox.x1), 1.0) AS scale, 680.0 AS display_w,
       round(greatest(max(wrd.bbox.y1), 1.0) * 680.0 / greatest(max(wrd.bbox.x1), 1.0), 1) AS display_h
FROM pdf_words wrd JOIN documents doc ON doc.filename = wrd.filename
GROUP BY doc.id, wrd.page_no;

CREATE OR REPLACE TABLE words AS
WITH raw AS (
    SELECT doc.id AS document_id, doc.case_id, wrd.page_no, wrd.word, wrd.bbox, wrd.font_size,
           trim(wrd.word, '.,;:()"''[]') AS token,
           replace(replace(replace(replace(
               trim(wrd.word, '.,;:()"''[]'), '-', ''), '(', ''), ')', ''), '.', '') AS token_compact
    FROM pdf_words wrd JOIN documents doc ON doc.filename = wrd.filename
    WHERE nullif(trim(wrd.word, '.,;:()"''[]'), '') IS NOT NULL
),
typed AS (
    SELECT token, token_compact, length(token_compact) AS compact_len,
           try_cast(token_compact AS BIGINT) IS NOT NULL AS compact_is_int,
           finetype(token) AS type_label, finetype(token_compact) AS type_label_compact,
           url_valid(token) AS is_url,
           CASE WHEN url_valid(token) THEN url_hostname(token) END AS hostname,
           CASE WHEN url_valid(token) THEN url_parse(token) END AS url_parts
    FROM (SELECT DISTINCT token, token_compact FROM raw)
),
hits AS (
    SELECT tt.token, r.rule, r.kind, r.confidence, r.priority, 'type_label=' || tt.type_label AS evidence
    FROM typed tt JOIN kind_rules r ON r.rule = 'finetype_prefix' AND starts_with(tt.type_label, r.type_prefix)
    UNION ALL BY NAME
    SELECT tt.token, r.rule, r.kind, r.confidence, r.priority, 'type_label_compact=' || tt.type_label_compact
    FROM typed tt JOIN kind_rules r ON r.rule = 'finetype_prefix' AND starts_with(tt.type_label_compact, r.type_prefix)
    UNION ALL BY NAME
    SELECT tt.token, r.rule, r.kind, r.confidence, r.priority, 'compact_len=' || tt.compact_len::VARCHAR
    FROM typed tt JOIN kind_rules r ON r.rule = 'shape' AND tt.compact_len = r.compact_len AND tt.compact_is_int
    UNION ALL BY NAME
    SELECT tt.token, r.rule, r.kind, r.confidence, r.priority, 'url_valid'
    FROM typed tt JOIN kind_rules r ON r.rule = 'url_valid' AND tt.is_url
    UNION ALL BY NAME
    SELECT tt.token, r.rule, r.kind, r.confidence, r.priority, 'urlpattern=' || r.url_pattern
    FROM typed tt JOIN kind_rules r ON r.rule = 'urlpattern' AND r.url_pattern IS NOT NULL
     AND urlpattern_test(r.url_pattern, tt.token)
),
kind AS (
    SELECT token, kind AS pii_kind, confidence AS pii_confidence, rule AS pii_rule, evidence
    FROM hits
    QUALIFY row_number() OVER (PARTITION BY token ORDER BY priority ASC, confidence DESC, rule) = 1
)
SELECT raw.document_id, raw.case_id, raw.page_no, raw.word, raw.bbox, raw.font_size,
       raw.token, lower(unaccent(raw.token)) AS token_norm, raw.token_compact,
       length(raw.token_compact) AS compact_len,
       try_cast(raw.token_compact AS BIGINT) IS NOT NULL AS compact_is_int,
       length(raw.token) AS token_len,
       typ.type_label, typ.type_label_compact, typ.is_url, typ.hostname, typ.url_parts,
       kind.pii_kind, kind.pii_confidence, kind.pii_rule, kind.evidence AS pii_evidence,
       (kind.pii_kind IS NOT NULL) AS is_pii
FROM raw JOIN typed typ ON typ.token = raw.token LEFT JOIN kind ON kind.token = raw.token;

CREATE OR REPLACE TABLE watchlist AS
SELECT term, kind, case_no, lower(unaccent(term)) AS term_norm,
       string_split(lower(unaccent(term)), ' ') AS term_tokens,
       (kind IS NOT NULL AND position('NOT PII' IN kind) > 0) AS is_not_pii
FROM v_src_watchlist;

CREATE OR REPLACE VIEW document_lines AS
SELECT doc.id AS document_id, doc.case_id, ln.page_no, ln.line_no,
       ln.line_text, lower(unaccent(ln.line_text)) AS line_norm
FROM pdf_lines ln JOIN documents doc ON doc.filename = ln.filename;

CREATE OR REPLACE VIEW token_kind AS
SELECT DISTINCT token, pii_kind, pii_confidence, pii_rule, pii_evidence AS evidence
FROM words WHERE pii_kind IS NOT NULL;

CREATE OR REPLACE TABLE name_scorer_thresholds AS
SELECT * FROM (VALUES
    ('token', 'edit', 88.0, 1), ('token', 'jaro', 92.0, 2), ('token', 'phonetic', 70.0, 3),
    ('line', 'token_sort', 90.0, 1), ('line', 'partial', 90.0, 2), ('line', 'jaro', 90.0, 3)
) AS t(grain, scorer, min_score, priority);

CREATE OR REPLACE TABLE detect_run AS SELECT uuid()::VARCHAR AS run_id, now() AS ts;

-- Token scorer trace (dead-scorer invariant). Mid-hop norms/match/bloom killed.
CREATE OR REPLACE TABLE name_rule_hits AS
WITH wt AS (
    SELECT term, kind, case_no, is_not_pii, tok AS term_token, double_metaphone(tok)[1] AS ph
    FROM watchlist, unnest(term_tokens) AS u(tok) WHERE length(tok) >= 3
),
doc AS (
    SELECT token_norm, any_value(double_metaphone(token_norm)[1]) AS ph
    FROM words WHERE length(token_norm) >= 3 GROUP BY token_norm
),
scr AS (
    SELECT doc.token_norm, wt.term, wt.term_token, wt.kind, wt.case_no, wt.is_not_pii,
           rapidfuzz_ratio(doc.token_norm, wt.term_token)::DOUBLE AS edit_score,
           (100.0 * jaro_winkler_similarity(doc.token_norm, wt.term_token))::DOUBLE AS jaro_score,
           (100.0 * (doc.ph = wt.ph)::INT)::DOUBLE AS phonetic_score
    FROM doc JOIN wt ON wt.ph = doc.ph
)
SELECT token_norm, term, term_token, kind, case_no, is_not_pii, thr.scorer, thr.priority,
       edit_score AS score, format('edit({}, {}) = {}', token_norm, term_token, round(edit_score, 1)) AS evidence
FROM scr JOIN name_scorer_thresholds thr ON thr.grain = 'token' AND thr.scorer = 'edit'
WHERE edit_score >= thr.min_score
UNION ALL BY NAME
SELECT token_norm, term, term_token, kind, case_no, is_not_pii, thr.scorer, thr.priority, jaro_score,
       format('jaro({}, {}) = {}', token_norm, term_token, round(jaro_score, 1))
FROM scr JOIN name_scorer_thresholds thr ON thr.grain = 'token' AND thr.scorer = 'jaro'
WHERE jaro_score >= thr.min_score
UNION ALL BY NAME
SELECT token_norm, term, term_token, kind, case_no, is_not_pii, thr.scorer, thr.priority, phonetic_score,
       format('phonetic({}, {}) = {}', token_norm, term_token, round(phonetic_score, 1))
FROM scr JOIN name_scorer_thresholds thr ON thr.grain = 'token' AND thr.scorer = 'phonetic'
WHERE phonetic_score >= thr.min_score;

-- One detect pin: corpus PII ∪ line watchlist (bloom + line scores + geometry as CTEs).
CREATE OR REPLACE TABLE detect_hits AS
WITH wt AS (
    SELECT term, kind, case_no, is_not_pii, tok AS term_token, term_norm
    FROM watchlist, unnest(term_tokens) AS u(tok) WHERE length(tok) >= 3
),
bloom AS (
    SELECT bitfilters_duckdb_bloom_filter_create('v1.5.1', 64, hv) AS filter FROM (
        SELECT bitfilters_duckdb_hash('v1.5.1', term_norm) AS hv FROM watchlist WHERE NOT is_not_pii
        UNION ALL
        SELECT bitfilters_duckdb_hash('v1.5.1', term_token) FROM wt
        JOIN watchlist wl ON wl.term = wt.term WHERE NOT wl.is_not_pii
    )
),
pass AS (
    SELECT document_id, page_no, line_no
    FROM document_lines, unnest(string_split(line_norm, ' ')) AS u(tok)
    WHERE length(tok) >= 3
      AND bitfilters_duckdb_bloom_filter_probe('v1.5.1', (SELECT filter FROM bloom), tok)
    GROUP BY document_id, page_no, line_no
    UNION
    SELECT lin.document_id, lin.page_no, lin.line_no
    FROM document_lines lin
    JOIN words wrd ON wrd.document_id = lin.document_id AND wrd.page_no = lin.page_no
     AND contains(lin.line_norm, wrd.token_norm)
    JOIN name_rule_hits nm ON nm.token_norm = wrd.token_norm
    GROUP BY lin.document_id, lin.page_no, lin.line_no
),
ntt AS (SELECT term, list(DISTINCT term_token) AS matching_tokens FROM wt GROUP BY term),
line_scr AS (
    SELECT lin.document_id, lin.page_no, lin.case_id, lin.line_no, lin.line_text, lin.line_norm,
           wl.term, wl.kind, wl.is_not_pii, ntt.matching_tokens,
           greatest(
               rapidfuzz_token_sort_ratio(lin.line_norm, wl.term_norm),
               rapidfuzz_partial_ratio(lin.line_norm, wl.term_norm),
               100.0 * jaro_winkler_similarity(lin.line_norm, wl.term_norm)
           )::DOUBLE AS score
    FROM document_lines lin
    JOIN pass ON pass.document_id = lin.document_id AND pass.page_no = lin.page_no AND pass.line_no = lin.line_no
    JOIN watchlist wl ON wl.case_no = lin.case_id
    JOIN ntt ON ntt.term = wl.term
    WHERE greatest(
              rapidfuzz_token_sort_ratio(lin.line_norm, wl.term_norm),
              rapidfuzz_partial_ratio(lin.line_norm, wl.term_norm),
              100.0 * jaro_winkler_similarity(lin.line_norm, wl.term_norm)
          ) >= (SELECT min(min_score) FROM name_scorer_thresholds WHERE grain = 'line')
      AND len(ntt.matching_tokens) > 0
),
scored AS (
    SELECT *, (SELECT t FROM unnest(matching_tokens) AS u(t) ORDER BY length(t) DESC, t LIMIT 1) AS anchor_tok
    FROM line_scr
),
line_occ AS (
    SELECT s.*,
           (SELECT count(*)::BIGINT FROM document_lines l2
            WHERE l2.document_id = s.document_id AND l2.page_no = s.page_no
              AND l2.line_no <= s.line_no AND contains(l2.line_norm, s.anchor_tok)) AS occ
    FROM scored s WHERE s.anchor_tok IS NOT NULL
),
word_occ AS (
    SELECT document_id, page_no, token_norm, bbox,
           row_number() OVER (PARTITION BY document_id, page_no, token_norm ORDER BY bbox.y0, bbox.x0) AS occ
    FROM words
),
line_hits AS (
    SELECT lo.document_id, lo.page_no, lo.case_id, lo.term AS text, lo.line_text AS context,
           lo.kind, lo.is_not_pii, lo.score,
           list_value(struct_pack(bbox := wo.bbox)) AS matched_words
    FROM line_occ lo
    JOIN word_occ wo ON wo.document_id = lo.document_id AND wo.page_no = lo.page_no
     AND wo.token_norm = lo.anchor_tok AND wo.occ = lo.occ
)
SELECT wrd.document_id, wrd.page_no, wrd.case_id, wrd.token AS text, wrd.token AS context,
       wrd.bbox, wrd.pii_kind AS kind, wrd.pii_confidence AS confidence,
       wrd.pii_rule || ': ' || wrd.pii_evidence AS reason,
       NULL::VARCHAR AS flag_tag, 'detector:corpus' AS detector_key
FROM words wrd WHERE wrd.is_pii
UNION ALL BY NAME
SELECT document_id, page_no, case_id, text, context,
       list_reduce(list_transform(matched_words, m -> m.bbox),
           (a, b) -> (least(a.x0, b.x0), least(a.y0, b.y0),
                      greatest(a.x1, b.x1), greatest(a.y1, b.y1))::bbox) AS bbox,
       kind, greatest(1, least(99, round(score)::INTEGER)) AS confidence,
       'rapidfuzz: ' || text AS reason,
       CASE WHEN is_not_pii THEN 'false_positive' ELSE NULL END AS flag_tag,
       'detector:rapidfuzz-watchlist' AS detector_key
FROM line_hits WHERE len(matched_words) > 0;

CREATE OR REPLACE TABLE entities AS
SELECT format('{:x}', rapidhash(case_id || chr(31) || kind || chr(31) || canonical_text)) AS id,
       case_id, canonical_text, kind, kind AS kind_label,
       kind IN ('SSN', 'DATE OF BIRTH') OR starts_with(kind, 'PHONE') AS mono
FROM (
    SELECT case_no AS case_id, term AS canonical_text, kind FROM watchlist
    UNION
    SELECT case_id, text, kind FROM detect_hits WHERE kind IS NOT NULL AND text IS NOT NULL
) s GROUP BY case_id, canonical_text, kind;

CREATE OR REPLACE TABLE suggestions AS
SELECT format('{:x}', rapidhash(concat_ws(chr(31), hit.document_id, hit.page_no,
           concat_ws(chr(31), round(hit.bbox.x0, 0), round(hit.bbox.y0, 0),
                     round(hit.bbox.x1, 0), round(hit.bbox.y1, 0)),
           hit.text, hit.kind, 'ai'))) AS id,
       hit.document_id, doc.case_id, doc.filename, hit.page_no, hit.bbox,
       (round(hit.bbox.x0 * pag.scale, 2), round(hit.bbox.y0 * pag.scale, 2),
        round((hit.bbox.x1 - hit.bbox.x0) * pag.scale, 2),
        round(greatest(hit.bbox.y1 - hit.bbox.y0, 0) * pag.scale, 2))::screen_box AS screen,
       hit.text, lower(hit.text) AS text_lower, hit.context, lower(hit.context) AS context_lower,
       hit.confidence, hit.flag_tag, hit.reason, ent.id AS entity_id, ent.canonical_text AS entity_text,
       hit.kind, lower(hit.kind) AS kind_lower, 'ai' AS source, (SELECT ts FROM detect_run) AS created_at,
       (SELECT min(lin.line_no) FROM document_lines lin
        WHERE lin.document_id = hit.document_id AND lin.page_no = hit.page_no
          AND contains(lin.line_norm, lower(unaccent(hit.text)))) AS line_no,
       (SELECT run_id FROM detect_run) AS source_run_id, hit.detector_key,
       CASE WHEN ent.id IS NOT NULL THEN ent.id
            ELSE format('{:x}', rapidhash(lower(hit.text) || chr(31) || hit.kind)) END AS group_key,
       NULL::VARCHAR AS judge_panel, NULL::INTEGER AS judge_agreement,
       NULL::VARCHAR AS judge_votes, NULL::VARCHAR AS judge_reason, NULL::VARCHAR AS band
FROM detect_hits hit
JOIN documents doc ON doc.id = hit.document_id
JOIN pages pag ON pag.document_id = hit.document_id AND pag.page_no = hit.page_no
LEFT JOIN entities ent
  ON ent.case_id = hit.case_id AND ent.kind = hit.kind AND ent.canonical_text = hit.text;

INSERT INTO suggestions BY NAME
SELECT format('{:x}', rapidhash(concat_ws(chr(31), wrd.document_id, wrd.page_no,
           concat_ws(chr(31), round(wrd.bbox.x0, 0), round(wrd.bbox.y0, 0),
                     round(wrd.bbox.x1, 0), round(wrd.bbox.y1, 0)),
           wrd.token, 'remainder'))) AS id,
       wrd.document_id, wrd.case_id, doc.filename, wrd.page_no, wrd.bbox,
       (round(wrd.bbox.x0 * pag.scale, 2), round(wrd.bbox.y0 * pag.scale, 2),
        round((wrd.bbox.x1 - wrd.bbox.x0) * pag.scale, 2),
        round(greatest(wrd.bbox.y1 - wrd.bbox.y0, 0) * pag.scale, 2))::screen_box AS screen,
       wrd.token AS text, lower(wrd.token) AS text_lower, wrd.token AS context, lower(wrd.token) AS context_lower,
       55 AS confidence, NULL::VARCHAR AS flag_tag,
       'remainder: residual PII-shaped token not in prior hits' AS reason,
       NULL::VARCHAR AS entity_id, NULL::VARCHAR AS entity_text,
       wrd.pii_kind AS kind, lower(wrd.pii_kind) AS kind_lower, 'ai' AS source,
       (SELECT ts FROM detect_run) AS created_at, NULL::INTEGER AS line_no,
       (SELECT run_id FROM detect_run) AS source_run_id, 'detector:remainder' AS detector_key,
       format('{:x}', rapidhash(lower(wrd.token) || chr(31) || wrd.pii_kind)) AS group_key,
       NULL::VARCHAR AS judge_panel, NULL::INTEGER AS judge_agreement,
       NULL::VARCHAR AS judge_votes, NULL::VARCHAR AS judge_reason, NULL::VARCHAR AS band
FROM words wrd
JOIN documents doc ON doc.id = wrd.document_id
JOIN pages pag ON pag.document_id = wrd.document_id AND pag.page_no = wrd.page_no
ANTI JOIN suggestions sug
  ON sug.document_id = wrd.document_id AND sug.page_no = wrd.page_no AND sug.text = wrd.token
WHERE wrd.is_pii AND wrd.pii_kind IS NOT NULL;

.read server/judge.sql

INSERT INTO suggestions BY NAME
SELECT add.suggestion_id AS id, add.document_id, doc.case_id, doc.filename, add.page_no, add.bbox,
       (round(add.bbox.x0 * pag.scale, 2), round(add.bbox.y0 * pag.scale, 2),
        round((add.bbox.x1 - add.bbox.x0) * pag.scale, 2),
        round(greatest(add.bbox.y1 - add.bbox.y0, 0) * pag.scale, 2))::screen_box AS screen,
       add.text, lower(add.text) AS text_lower, add.context, lower(add.context) AS context_lower,
       add.confidence, add.flag_tag, add.reason, add.entity_id, NULL::VARCHAR AS entity_text,
       add.flag_tag AS kind, lower(add.flag_tag) AS kind_lower, 'manual' AS source, add.ts AS created_at,
       NULL::INTEGER AS line_no, NULL::VARCHAR AS source_run_id, 'manual' AS detector_key,
       format('{:x}', rapidhash(lower(add.text) || chr(31) || add.flag_tag)) AS group_key,
       NULL::VARCHAR AS judge_panel, NULL::INTEGER AS judge_agreement,
       NULL::VARCHAR AS judge_votes, NULL::VARCHAR AS judge_reason, 'high' AS band
FROM (
    SELECT * FROM v_src_decisions WHERE kind = 'added' AND suggestion_id IS NOT NULL
    QUALIFY row_number() OVER (PARTITION BY suggestion_id ORDER BY ts DESC) = 1
) add
JOIN documents doc ON doc.id = add.document_id
JOIN pages pag ON pag.document_id = add.document_id AND pag.page_no = add.page_no
ANTI JOIN suggestions sug ON sug.id = add.suggestion_id;

INSERT INTO pipeline_runs BY NAME
SELECT run_id, 'detect' AS kind, ts, NULL::JSON AS raw FROM detect_run;

INSERT INTO pipeline_runs BY NAME
SELECT uuid()::VARCHAR AS run_id, 'judge' AS kind, now() AS ts, NULL::JSON AS raw;
