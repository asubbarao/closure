-- core.sql — app data model.
--
-- Naming: verbose CTEs/tables (words_from_pdf_tokens, hits_from_type_rules);
--   relation aliases 2–3 letters (doc, wrd, sug); 1-letter only in lambdas.
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
SELECT parse_filename(file_entry.filename, true) AS filename, file_entry.case_no
FROM (
    SELECT unnest(files) AS file_entry
    FROM read_json_auto('pathvariable:manifest_path')
)
WHERE file_entry.filename IS NOT NULL;

-- term trimmed once here; downstream never re-trims.
CREATE OR REPLACE VIEW v_src_watchlist AS
WITH terms_trimmed AS (
    SELECT trim(term) AS term, kind, case_no
    FROM read_json_auto('pathvariable:watchlist_path')
    WHERE term IS NOT NULL
)
SELECT term, kind, case_no FROM terms_trimmed WHERE nullif(term, '') IS NOT NULL;

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
SELECT tpl.name AS template, lnk.text AS link_text, lnk.href, lnk.line_number
FROM v_src_templates tpl,
     unnest(html_extract_links(tpl.body)) AS link_rows(lnk);

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
SELECT format('{:x}', rapidhash(man.case_no || chr(31) || pdf.filename)) AS id,
       man.case_no AS case_id, pdf.filename, pdf.source_path,
       pdf.page_count, pdf.width_pt, pdf.height_pt, pdf.file_size,
       -- display pins (UI uses these; views do not recompute)
       inflector_to_title_case(replace(pdf.filename, '_', ' ')) AS display_name,
       hsize(pdf.file_size) AS size_label
FROM v_src_pdf_info pdf
JOIN v_src_manifest man ON man.filename = pdf.filename;

-- Geometry + fixed review scale (680px wide). Downstream: SELECT scale, not recompute.
CREATE OR REPLACE TABLE pages AS
SELECT doc.id AS document_id, pdf.page_no, pdf.width_pt, pdf.height_pt,
       680.0 / pdf.width_pt AS scale,
       680.0 AS display_w,
       round(pdf.height_pt * 680.0 / pdf.width_pt, 1) AS display_h
FROM v_src_pdf_pages pdf
JOIN documents doc ON doc.filename = pdf.doc_filename;

-- Corpus = barcode-sanitizer shape: full intermediate tables, no lossy coalesce.
--   word_raw          occurrence grain (all surface forms kept)
--   token_types       DISTINCT token evidence (finetype + url) — debugable
--   kind_rules        enhanceable JSON (INSERT row = new format)
--   token_rule_hits   EVERY rule that matched (trace table; not collapsed)
--   token_kind        one primary kind per token (priority pick)
--   words             cheap app table: occurrence ⨝ types ⨝ primary kind

-- token pinned once (punctuation stripped). Downstream uses token / token_norm only.
CREATE OR REPLACE TABLE word_raw AS
WITH words_from_pdf AS (
    SELECT doc.id AS document_id, doc.case_id, wrd.page_no, wrd.word, wrd.bbox, wrd.font_size,
           trim(wrd.word, '.,;:()"''[]') AS token,
           round(wrd.bbox.y0, 0) AS y_key
    FROM v_src_pdf_words wrd
    JOIN documents doc ON doc.filename = wrd.doc_filename
),
tokens_present AS (
    -- empty after strip is a real empty string → drop; NULL token does not appear
    SELECT * FROM words_from_pdf WHERE nullif(token, '') IS NOT NULL
),
tokens_compacted AS (
    SELECT *,
           replace(replace(replace(replace(token, '-', ''), '(', ''), ')', ''), '.', '') AS token_compact
    FROM tokens_present
)
SELECT document_id, case_id, page_no, word, bbox, font_size, token, y_key,
       lower(unaccent(token)) AS token_norm,
       token_compact,
       length(token_compact) AS compact_len,
       try_cast(token_compact AS BIGINT) IS NOT NULL AS compact_is_int
FROM tokens_compacted;

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
SELECT raw.document_id, raw.case_id, raw.page_no, raw.word, raw.bbox, raw.font_size,
       raw.token, raw.token_norm, raw.token_compact, raw.compact_len, raw.compact_is_int, raw.y_key,
       length(raw.token) AS token_len,
       typ.type_label, typ.type_label_compact, typ.is_url, typ.hostname, typ.url_parts,
       kind.pii_kind, kind.pii_confidence, kind.pii_rule, kind.evidence AS pii_evidence,
       (kind.pii_kind IS NOT NULL) AS is_pii
FROM word_raw raw
JOIN token_types typ ON typ.token = raw.token
LEFT JOIN token_kind kind ON kind.token = raw.token;

-- term already trimmed in v_src_watchlist — normalize once, never re-trim.
CREATE OR REPLACE TABLE watchlist AS
SELECT term, kind, case_no,
       lower(unaccent(term)) AS term_norm,
       string_split(lower(unaccent(term)), ' ') AS term_tokens,
       replace(replace(replace(replace(term, '-', ''), '(', ''), ')', ''), '.', '') AS term_compact,
       (kind IS NOT NULL AND position('NOT PII' IN kind) > 0) AS is_not_pii
FROM v_src_watchlist;

-- ── name matching: the same trace shape the token side already has ────────
--   watchlist_tokens  prepared watchlist side (norm + splink phonetic key)
--   name_scorers      thresholds as DATA — edit a row, not a WHERE clause
--   name_rule_hits    EVERY scorer that fired, with its score (trace table)
--   name_token_match  one primary scorer per (document token, watchlist term)
--
-- Why phonetic alongside edit distance: rapidfuzz catches a typo that keeps
-- the spelling close (Zielinski→Zielinsky); double_metaphone catches the same
-- name heard and respelled (Zielinski→Zelinsky), which edit distance scores
-- too low to pass. A redaction miss is unredacted PII; a false positive is one
-- reviewer click, and lands in the flagged band anyway. Recall earns its keep.
--
-- Note the prior phonetic attempt compared double_metaphone of the WHOLE term
-- ('kaleb johnson' → KLPJNS) against a single document token ('kaleb' → KLP),
-- so it could never match. Phonetic keys are per token on both sides.

CREATE OR REPLACE TABLE watchlist_tokens AS
SELECT term, kind, case_no, is_not_pii, tok AS term_token
FROM watchlist, unnest(term_tokens) AS token_rows(tok)
WHERE length(tok) >= 3;

-- Each scorer is a function of one uniform shape: score(token, term) -> 0..100.
-- rapidfuzz/jaro index spelling; phonetic returns 100 when the primary
-- double_metaphone codes agree (Smith/Smyth), 0 otherwise.
CREATE OR REPLACE MACRO score_edit(a, b)     AS rapidfuzz_ratio(a, b)::DOUBLE;
CREATE OR REPLACE MACRO score_jaro(a, b)     AS (100.0 * jaro_winkler_similarity(a, b))::DOUBLE;
CREATE OR REPLACE MACRO score_phonetic(a, b) AS
    (100.0 * (double_metaphone(a)[1] = double_metaphone(b)[1])::INT)::DOUBLE;

-- A scorer is a ROW that names its function, not a hardcoded WHERE clause or a
-- bespoke UNION arm. scorer_fn is applied by name (func_apply). Add a scorer =
-- add a macro + insert a row; the scan below and every downstream table follow.
CREATE OR REPLACE TABLE name_scorers AS
SELECT * FROM (VALUES
    ('edit',     'score_edit',     88.0, 1),
    ('jaro',     'score_jaro',     92.0, 2),
    ('phonetic', 'score_phonetic', 70.0, 3)
) AS t(scorer, scorer_fn, min_score, priority);

-- One scan, not three UNION arms: every (document token × watchlist token ×
-- scorer) is scored by apply()ing the scorer's function; a row survives when it
-- clears that scorer's threshold. This IS the trace table — every scorer that
-- fired, before name_token_match picks one primary.
CREATE OR REPLACE TABLE name_rule_hits AS
WITH tokens_from_documents AS (
    SELECT DISTINCT token_norm FROM words WHERE length(token_norm) >= 3
),
scored AS (
    SELECT tok.token_norm, wt.term, wt.term_token, wt.kind, wt.case_no, wt.is_not_pii,
           scr.scorer, scr.scorer_fn, scr.priority, scr.min_score,
           apply(scr.scorer_fn, tok.token_norm, wt.term_token)::DOUBLE AS score
    FROM tokens_from_documents tok
    CROSS JOIN watchlist_tokens wt
    CROSS JOIN name_scorers scr
)
SELECT token_norm, term, term_token, kind, case_no, is_not_pii,
       scorer, priority, score,
       format('{}({}, {}) = {}', scorer_fn, token_norm, term_token,
              round(score, 1)) AS evidence
FROM scored
WHERE score >= min_score;

-- One primary scorer per (document token, watchlist term) — not a coalesce.
CREATE OR REPLACE TABLE name_token_match AS
SELECT token_norm, term, term_token, kind, case_no, is_not_pii,
       scorer, score, evidence
FROM name_rule_hits
QUALIFY row_number() OVER (
    PARTITION BY token_norm, term ORDER BY score DESC, priority
) = 1;

-- Per-term candidate token set: the detector asks this, never re-scores inline.
CREATE OR REPLACE TABLE name_term_tokens AS
SELECT term, list(DISTINCT token_norm) AS matching_tokens
FROM name_token_match GROUP BY term;

-- Bloom over prepared watchlist tokens (v1.5.1 = bitfilters hash-compat pin).
SET VARIABLE watchlist_bloom = (
    SELECT bitfilters_duckdb_bloom_filter_create('v1.5.1', 64, hv)
    FROM (
        SELECT bitfilters_duckdb_hash('v1.5.1', term_norm) AS hv
        FROM watchlist WHERE NOT is_not_pii
        UNION ALL
        SELECT bitfilters_duckdb_hash('v1.5.1', tok) AS hv
        FROM watchlist, unnest(term_tokens) AS token_rows(tok)
        WHERE NOT is_not_pii AND length(tok) >= 3
    )
);

-- Line grain: keep word lists; line bbox = hull of word boxes (not min/max laundry).
CREATE OR REPLACE TABLE document_lines AS
SELECT wrd.document_id, wrd.page_no, wrd.case_id, wrd.y_key,
       dense_rank() OVER (
           PARTITION BY wrd.document_id, wrd.page_no ORDER BY wrd.y_key
       )::INTEGER AS line_no,
       string_agg(wrd.word, ' ' ORDER BY wrd.bbox.x0) AS line_text,
       string_agg(wrd.token_norm, ' ' ORDER BY wrd.bbox.x0) AS line_norm,
       list(wrd.token_norm ORDER BY wrd.bbox.x0) AS token_norms,
       list(struct_pack(token_norm := wrd.token_norm, bbox := wrd.bbox)
            ORDER BY wrd.bbox.x0) AS word_meta,
       list(wrd.bbox ORDER BY wrd.bbox.x0) AS word_bboxes,
       bbox_hull(list(wrd.bbox ORDER BY wrd.bbox.x0)) AS bbox
FROM words wrd
GROUP BY wrd.document_id, wrd.page_no, wrd.case_id, wrd.y_key;

-- detect: join prepared columns only
SET VARIABLE detect_run_id = (SELECT uuid()::VARCHAR);

CREATE OR REPLACE TABLE detect_hits AS
WITH hits_from_type_rules AS (
    SELECT wrd.document_id, wrd.page_no, wrd.case_id,
           wrd.token AS text, wrd.token AS context, wrd.bbox,
           wrd.pii_kind AS kind,
           wrd.pii_confidence AS confidence,
           wrd.pii_rule || ': ' || wrd.pii_evidence AS reason,
           NULL::VARCHAR AS flag_tag,
           'detector:corpus' AS detector_key
    FROM words wrd
    WHERE wrd.is_pii
),
-- Bloom admits lines holding an exact watchlist token (cheap, no join).
-- Phonetic matches are spelled differently by definition, so they cannot pass
-- a bloom — those lines come from name_token_match, which already knows them.
lines_passing_watchlist_bloom AS (
    SELECT document_id, page_no, y_key
    FROM words
    WHERE bitfilters_duckdb_bloom_filter_probe(
        'v1.5.1', getvariable('watchlist_bloom'), token_norm)
    GROUP BY document_id, page_no, y_key
    UNION
    SELECT wrd.document_id, wrd.page_no, wrd.y_key
    FROM words wrd
    JOIN name_token_match nm ON nm.token_norm = wrd.token_norm
    GROUP BY wrd.document_id, wrd.page_no, wrd.y_key
),
scores_from_rapidfuzz_watchlist AS (
    SELECT lin.document_id, lin.page_no, lin.case_id,
           wl.term AS text, lin.line_text AS context, wl.kind, wl.is_not_pii,
           greatest(
               rapidfuzz_token_sort_ratio(lin.line_norm, wl.term_norm),
               rapidfuzz_partial_ratio(lin.line_norm, wl.term_norm),
               100.0 * jaro_winkler_similarity(lin.line_norm, wl.term_norm)
           ) AS score,
           list_filter(lin.word_meta,
                       m -> list_contains(ntt.matching_tokens, m.token_norm)) AS matched_words
    FROM document_lines lin
    JOIN lines_passing_watchlist_bloom bloom
      ON bloom.document_id = lin.document_id
     AND bloom.page_no = lin.page_no
     AND bloom.y_key = lin.y_key
    JOIN watchlist wl ON wl.case_no = lin.case_id
    JOIN name_term_tokens ntt ON ntt.term = wl.term
),
hits_from_name_match AS (
    SELECT document_id, page_no, case_id, text, context,
           bbox_hull(list_transform(matched_words, m -> m.bbox)) AS bbox,
           kind, greatest(1, least(99, round(score)::INTEGER)) AS confidence,
           'rapidfuzz: ' || text AS reason,
           CASE WHEN is_not_pii THEN 'false_positive' END AS flag_tag,
           'detector:rapidfuzz-watchlist' AS detector_key
    FROM scores_from_rapidfuzz_watchlist
    WHERE score >= 90 AND len(matched_words) > 0
)
SELECT * FROM hits_from_type_rules
UNION ALL BY NAME SELECT * FROM hits_from_name_match;

CREATE OR REPLACE TABLE entities AS
SELECT format('{:x}', rapidhash(case_id || chr(31) || kind || chr(31) || canonical_text)) AS id,
       case_id, canonical_text, kind,
       inflector_to_title_case(replace(lower(kind), ' · ', ' ')) AS kind_label,
       (kind IN ('SSN', 'DATE OF BIRTH') OR starts_with(kind, 'PHONE')) AS mono
FROM (
    SELECT case_no AS case_id, term AS canonical_text, kind FROM watchlist
    UNION
    SELECT case_id, text, kind FROM detect_hits
    WHERE kind IS NOT NULL AND text IS NOT NULL
) entity_seeds
GROUP BY case_id, canonical_text, kind;

-- Suggestions = mark grain (interactor state in a real app).
--   bbox    PDF page space (source of truth)
--   screen  canvas pin (screen_box) — scale applied once at write
-- text/context as stored + lower pins (SELECT * still has raw text). No re-lower in judge.
CREATE OR REPLACE TABLE suggestions AS
SELECT format('{:x}', rapidhash(concat_ws(chr(31),
           hit.document_id, hit.page_no, bbox_key(hit.bbox), hit.text, hit.kind, 'ai'))) AS id,
       hit.document_id, hit.page_no, hit.bbox,
       bbox_to_screen(hit.bbox, pag.scale, 0) AS screen,
       hit.text,
       lower(hit.text) AS text_lower,
       hit.context,
       lower(hit.context) AS context_lower,
       hit.confidence, hit.flag_tag, hit.reason, ent.id AS entity_id, hit.kind,
       lower(hit.kind) AS kind_lower,
       'ai' AS source, TIMESTAMP '1970-01-01' AS created_at, lin.line_no,
       getvariable('detect_run_id') AS source_run_id, hit.detector_key
FROM detect_hits hit
LEFT JOIN entities ent
  ON ent.case_id = hit.case_id AND ent.kind = hit.kind
 AND (ent.canonical_text = hit.text
      OR starts_with(ent.canonical_text, hit.text)
      OR starts_with(hit.text, ent.canonical_text))
LEFT JOIN document_lines lin
  ON lin.document_id = hit.document_id AND lin.page_no = hit.page_no
 AND lin.y_key = round(hit.bbox.y0, 0)
JOIN pages pag
  ON pag.document_id = hit.document_id AND pag.page_no = hit.page_no;

DROP TABLE IF EXISTS detect_hits;

-- ── FN remainder: PII-shaped tokens not already covered by a suggestion ────
INSERT INTO suggestions BY NAME
SELECT format('{:x}', rapidhash(concat_ws(chr(31),
           wrd.document_id, wrd.page_no, bbox_key(wrd.bbox), wrd.token, 'remainder'))) AS id,
       wrd.document_id, wrd.page_no, wrd.bbox,
       bbox_to_screen(wrd.bbox, pag.scale, 0) AS screen,
       wrd.token AS text,
       lower(wrd.token) AS text_lower,
       wrd.token AS context,
       lower(wrd.token) AS context_lower,
       55 AS confidence, NULL::VARCHAR AS flag_tag,
       'remainder: residual PII-shaped token not in prior hits' AS reason,
       NULL::VARCHAR AS entity_id,
       CASE WHEN wrd.pii_kind IS NULL THEN 'UNKNOWN' ELSE wrd.pii_kind END AS kind,
       lower(CASE WHEN wrd.pii_kind IS NULL THEN 'UNKNOWN' ELSE wrd.pii_kind END) AS kind_lower,
       'ai' AS source, now() AS created_at, NULL::INTEGER AS line_no,
       getvariable('detect_run_id') AS source_run_id,
       'detector:remainder' AS detector_key
FROM words wrd
JOIN pages pag
  ON pag.document_id = wrd.document_id AND pag.page_no = wrd.page_no
WHERE wrd.is_pii
  AND NOT exists (
      SELECT 1 FROM suggestions sug
      WHERE sug.document_id = wrd.document_id AND sug.page_no = wrd.page_no
        AND (sug.text = wrd.token
             OR (sug.context IS NOT NULL AND contains(sug.context, wrd.token)))
  );

-- ── Judge panel: uses text_lower / kind_lower pins (raw text still on row).
CREATE OR REPLACE TABLE suggestion_judges AS
WITH votes_from_pattern_context_prior AS (
    SELECT sug.id AS suggestion_id, sug.text, sug.context, sug.kind, sug.confidence,
           sug.flag_tag, sug.detector_key,
           CASE
               WHEN sug.confidence >= 90 THEN 'redact'
               WHEN sug.confidence < 60 THEN 'keep'
               ELSE 'review'
           END AS vote_pattern,
           CASE
               WHEN sug.flag_tag = 'false_positive' THEN 'keep'
               WHEN sug.text_lower IS NOT NULL AND (
                    ends_with(sug.text_lower, ' street')
                 OR starts_with(sug.text_lower, 'det.')
                 OR starts_with(sug.text_lower, 'ofc.')
                 OR contains(sug.text_lower, ' v. ')
               ) THEN 'keep'
               WHEN sug.context_lower IS NOT NULL AND (
                    contains(sug.context_lower, ' street')
                 OR contains(sug.context_lower, ' officer')
               ) THEN 'keep'
               WHEN sug.kind_lower IS NOT NULL AND contains(sug.kind_lower, 'citation') THEN 'keep'
               WHEN sug.confidence >= 70 THEN 'redact'
               ELSE 'review'
           END AS vote_context,
           CASE
               WHEN sug.flag_tag = 'false_positive' THEN 'keep'
               WHEN sug.kind IN ('SSN', 'DATE OF BIRTH') THEN 'redact'
               WHEN sug.kind IS NOT NULL AND starts_with(sug.kind, 'PHONE') THEN 'redact'
               WHEN sug.kind_lower IS NOT NULL AND (
                    contains(sug.kind_lower, 'not pii')
                 OR contains(sug.kind_lower, 'officer')
                 OR contains(sug.kind_lower, 'street')
                 OR contains(sug.kind_lower, 'citation')
               ) THEN 'keep'
               ELSE 'review'
           END AS vote_prior
    FROM suggestions sug
)
SELECT suggestion_id, vote_pattern, vote_context, vote_prior,
       CASE
           WHEN vote_pattern = vote_context AND vote_context = vote_prior THEN vote_pattern
           WHEN vote_pattern = vote_context THEN vote_pattern
           WHEN vote_pattern = vote_prior THEN vote_pattern
           WHEN vote_context = vote_prior THEN vote_context
           ELSE 'conflict'
       END AS panel,
       'pattern=' || vote_pattern || ' context=' || vote_context ||
           ' prior=' || vote_prior AS judge_reason
FROM votes_from_pattern_context_prior;

INSERT INTO pipeline_runs BY NAME
SELECT getvariable('detect_run_id') AS run_id,
       'detect' AS kind,
       now() AS ts,
       NULL::JSON AS raw;

INSERT INTO pipeline_runs BY NAME
SELECT uuid()::VARCHAR AS run_id, 'judge' AS kind, now() AS ts, NULL::JSON AS raw;

-- Session profile pin for base extract (before derived suggestion view).
COPY (FROM (SUMMARIZE words)) TO 'variable:profile_words' (FORMAT variable, LIST rows);

-- ── projections (unmat views only) ─────────────────────────────────────────

CREATE OR REPLACE VIEW v_latest_decision AS
SELECT suggestion_id,
       max_by(status, ts) AS status,
       max_by(actor, ts) AS actor,
       max_by(reason, ts) AS reason,
       max(ts) AS ts
FROM v_src_decisions
WHERE kind = 'decision' AND suggestion_id IS NOT NULL
GROUP BY suggestion_id;

CREATE OR REPLACE VIEW v_manual_suggestions AS
WITH latest_added_from_decisions AS (
    SELECT suggestion_id,
           max_by(document_id, ts) AS document_id,
           max_by(page_no, ts) AS page_no,
           max_by(bbox, ts) AS bbox,
           max_by(text, ts) AS text,
           max_by(context, ts) AS context,
           max_by(confidence, ts) AS confidence,
           max_by(flag_tag, ts) AS flag_tag,
           max_by(reason, ts) AS reason,
           max_by(entity_id, ts) AS entity_id,
           max(ts) AS ts
    FROM v_src_decisions
    WHERE kind = 'added' AND suggestion_id IS NOT NULL
    GROUP BY suggestion_id
)
SELECT add.suggestion_id AS id, add.document_id, add.page_no, add.bbox,
       bbox_to_screen(add.bbox, pag.scale, 0) AS screen,
       add.text, lower(add.text) AS text_lower,
       add.context, lower(add.context) AS context_lower,
       CASE WHEN add.confidence IS NULL THEN 99 ELSE add.confidence END AS confidence,
       add.flag_tag, add.reason, add.entity_id,
       NULL::VARCHAR AS kind, NULL::VARCHAR AS kind_lower,
       'manual' AS source, add.ts AS created_at, lin.line_no,
       NULL::VARCHAR AS source_run_id, 'manual' AS detector_key
FROM latest_added_from_decisions add
LEFT JOIN document_lines lin
  ON lin.document_id = add.document_id
 AND lin.page_no = add.page_no
 AND lin.y_key = round(add.bbox.y0, 0)
JOIN pages pag
  ON pag.document_id = add.document_id AND pag.page_no = add.page_no;

-- FP/FN product fold: status/band only. Leave NULLs as NULL (3-value).
CREATE OR REPLACE VIEW v_suggestions AS
WITH suggestions_ai_and_manual AS (
    SELECT id, document_id, page_no, bbox, screen, text, text_lower, context, context_lower,
           confidence, flag_tag, reason,
           entity_id, source, created_at, kind AS kind_stored, kind_lower, line_no, source_run_id, detector_key
    FROM suggestions
    UNION ALL BY NAME
    SELECT id, document_id, page_no, bbox, screen, text, text_lower, context, context_lower,
           confidence, flag_tag, reason,
           entity_id, source, created_at, kind, kind_lower, line_no, source_run_id, detector_key
    FROM v_manual_suggestions
)
SELECT row.id, row.document_id, row.page_no, row.line_no, row.bbox, row.screen,
       row.text, row.text_lower, row.context, row.context_lower,
       row.confidence, row.flag_tag, row.reason, row.entity_id, row.source, row.created_at,
       row.source_run_id, row.detector_key,
       CASE WHEN ent.kind IS NOT NULL THEN ent.kind ELSE row.kind_stored END AS kind,
       CASE WHEN ent.kind IS NOT NULL THEN lower(ent.kind) ELSE row.kind_lower END AS kind_lower,
       ent.canonical_text AS entity_text,
       CASE
           WHEN dec.status IS NOT NULL THEN dec.status
           WHEN row.source = 'manual' THEN 'accepted'
           ELSE 'pending'
       END AS status,
       -- FLAGGED = likely FP or judge conflict — never bulk-accepted
       CASE
           WHEN row.flag_tag = 'false_positive' THEN 'flagged'
           WHEN jdg.panel IN ('keep', 'conflict') THEN 'flagged'
           WHEN row.confidence >= 90 AND (jdg.panel IS NULL OR jdg.panel = 'redact') THEN 'high'
           WHEN row.confidence >= 60 THEN 'review'
           ELSE 'flagged'
       END AS band,
       jdg.panel AS judge_panel,
       jdg.vote_pattern,
       jdg.vote_context,
       jdg.vote_prior,
       CASE WHEN jdg.judge_reason IS NOT NULL THEN jdg.judge_reason ELSE row.reason END AS judge_reason,
       CASE WHEN row.entity_id IS NOT NULL THEN 'e:' || row.entity_id
            WHEN row.text_lower IS NOT NULL THEN
                 't:' || row.text_lower || '|' ||
                 CASE WHEN ent.kind IS NOT NULL THEN ent.kind ELSE row.kind_stored END
            ELSE NULL
       END AS group_key
FROM suggestions_ai_and_manual row
LEFT JOIN entities ent ON ent.id = row.entity_id
LEFT JOIN v_latest_decision dec ON dec.suggestion_id = row.id
LEFT JOIN suggestion_judges jdg ON jdg.suggestion_id = row.id;

-- After v_suggestions exists (SUMMARIZE cannot precede CREATE VIEW).
COPY (FROM (SUMMARIZE v_suggestions)) TO 'variable:profile_suggestions' (FORMAT variable, LIST rows);

CREATE OR REPLACE VIEW v_lines AS
SELECT document_id, page_no, case_id,
       line_no AS line_number, line_no,
       line_text AS content, line_text,
       line_norm, token_norms, y_key, bbox
FROM document_lines;

-- Page text + scalarfs URI for read_lines (no temp files).
CREATE OR REPLACE VIEW v_page_text AS
SELECT document_id, page_no, case_id,
       string_agg(line_text, chr(10) ORDER BY line_no) AS page_text,
       to_scalarfs_uri(string_agg(line_text, chr(10) ORDER BY line_no)) AS page_uri
FROM document_lines
GROUP BY document_id, page_no, case_id;

-- read_lines earned: ±3 lines around each suggestion via scalarfs page_uri.
CREATE OR REPLACE VIEW v_suggestion_line_context AS
SELECT sug.id AS suggestion_id, sug.document_id, sug.page_no, sug.line_no AS hit_line,
       ln.line_number, ln.content AS line_text,
       abs(ln.line_number - sug.line_no)::INTEGER AS dist
FROM v_suggestions sug
JOIN v_page_text ptx
  ON ptx.document_id = sug.document_id AND ptx.page_no = sug.page_no
CROSS JOIN LATERAL (
    SELECT line_number, content FROM read_lines_lateral(ptx.page_uri)
) ln
WHERE sug.line_no IS NOT NULL
  AND abs(ln.line_number - sug.line_no) <= 3;

-- dns earned: resolve hostnames extracted from document tokens (lazy — network on read).
-- GROUP BY hostname collapses the grain (no DISTINCT subquery, no token_n count).
CREATE OR REPLACE VIEW v_url_hosts AS
SELECT hostname,
       dns_lookup(hostname) AS a_record,
       dns_lookup_all(hostname) AS a_records
FROM token_types
WHERE nullif(hostname, '') IS NOT NULL
GROUP BY hostname;

-- Decision write source — enough grain for append-only audit reconstructability.
CREATE OR REPLACE VIEW v_decide_targets AS
SELECT sug.id AS suggestion_id,
       sug.document_id,
       doc.case_id,
       doc.filename,
       sug.page_no,
       sug.bbox,
       sug.text,
       sug.context,
       sug.entity_id,
       sug.entity_text,
       sug.band,
       sug.status,
       sug.group_key,
       sug.confidence,
       sug.flag_tag,
       sug.source,
       sug.judge_panel,
       sug.judge_reason,
       sug.vote_pattern,
       sug.vote_context,
       sug.vote_prior
FROM v_suggestions sug
JOIN documents doc ON doc.id = sug.document_id;
