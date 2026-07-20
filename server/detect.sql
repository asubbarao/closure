-- detect.sql — generic AI redaction detection over words (ruling B).
-- Inputs: words, documents, watchlist; v_src_decisions.
-- Ext: finetype, us_address_standardizer, rapidfuzz, splink_udfs.
-- No ngram union, no row_number. Taxonomy is data (kinds not sprinkled).

INSTALL finetype FROM community; LOAD finetype;
INSTALL us_address_standardizer FROM community; LOAD us_address_standardizer;
INSTALL rapidfuzz FROM community; LOAD rapidfuzz;
INSTALL splink_udfs FROM community; LOAD splink_udfs;

CREATE OR REPLACE TABLE pii_taxonomy AS
SELECT * FROM (VALUES
    ('finetype_ssn',   'SSN',               true),
    ('finetype_phone', 'PHONE · SUBJECT',   true),
    ('finetype_date',  'DATE OF BIRTH',     true),
    ('finetype_email', 'PHONE · SUBJECT',   true),
    ('addrust',        'ADDRESS · SUBJECT', true)
) AS t(code, kind, is_pii);

-- Visual lines: string_agg + word_meta ordered by x0 (bbox for name/address spans).
CREATE OR REPLACE TABLE _detect_lines AS
SELECT w.document_id, w.page_no, d.case_id,
       string_agg(w.word, ' ' ORDER BY w.x0) AS line_text,
       lower(trim(unaccent(string_agg(w.word, ' ' ORDER BY w.x0)))) AS line_norm,
       list(struct_pack(word := w.word, x0 := w.x0, y0 := w.y0, x1 := w.x1, y1 := w.y1)
            ORDER BY w.x0) AS word_meta
FROM words w JOIN documents d ON d.id = w.document_id
GROUP BY w.document_id, w.page_no, d.case_id, round(w.y0, 0);

-- Hits: finetype words | tightened addrust | watchlist×lines rapidfuzz. No ngrams.
CREATE OR REPLACE TABLE _detect_hits AS
WITH type_hits AS (
    SELECT c.document_id, c.page_no, c.case_id, c.token AS text, c.token AS context,
           c.x0, c.y0, c.x1, c.y1, tax.kind,
           greatest(1, least(99, cast(round(100.0 * coalesce(c.ft_conf, 0.70)) AS INTEGER))) AS confidence,
           'finetype: ' || c.ft_type AS reason, cast(NULL AS VARCHAR) AS flag_tag
    FROM (
        SELECT w.document_id, w.page_no, d.case_id, w.x0, w.y0, w.x1, w.y1,
               trim(w.word, '.,;:()"''[]') AS token,
               finetype([trim(w.word, '.,;:()"''[]')]) AS ft_type,
               try_cast(json_extract_string(
                   finetype_detail([trim(w.word, '.,;:()"''[]')])::JSON, '$.confidence') AS DOUBLE) AS ft_conf
        FROM words w JOIN documents d ON d.id = w.document_id
        WHERE length(trim(w.word, '.,;:()"''[]')) BETWEEN 6 AND 40
          AND (position('-' IN w.word) > 0 OR position('/' IN w.word) > 0
            OR position('@' IN w.word) > 0 OR position('(' IN w.word) > 0)
    ) c
    JOIN pii_taxonomy tax ON tax.code = CASE
        WHEN c.ft_type LIKE 'identity.commerce.isbn%' THEN 'finetype_ssn'
        WHEN c.ft_type LIKE '%phone%' THEN 'finetype_phone'
        WHEN c.ft_type LIKE 'datetime.date%' THEN 'finetype_date'
        WHEN c.ft_type LIKE 'identity.person.email%' OR position('@' IN c.token) > 0 THEN 'finetype_email'
    END
    WHERE nullif(trim(tax.code), '') IS NOT NULL
),
addr_hits AS (
    SELECT p.document_id, p.page_no, p.case_id, p.addr_span AS text, p.line_text AS context,
           list_min(list_transform(p.span_words, lambda m: m.x0)) AS x0,
           list_min(list_transform(p.span_words, lambda m: m.y0)) AS y0,
           list_max(list_transform(p.span_words, lambda m: m.x1)) AS x1,
           list_max(list_transform(p.span_words, lambda m: m.y1)) AS y1,
           tax.kind, 92 AS confidence,
           'addrust: ' || p.a.street_number || ' ' || coalesce(p.a.street_name, '') AS reason,
           cast(NULL AS VARCHAR) AS flag_tag
    FROM (
        SELECT document_id, page_no, case_id, line_text, addr_span, addrust_parse(addr_span) AS a,
               list_filter(word_meta, lambda m:
                   position(lower(trim(unaccent(m.word))) IN lower(trim(unaccent(addr_span)))) > 0) AS span_words
        FROM (
            SELECT *, regexp_extract(line_text,
                '(\d{2,6}\s+[A-Za-z][A-Za-z0-9 .''-]{1,40}?,\s*[A-Za-z .]{2,30},\s*[A-Z]{2}\s+\d{5})', 1
            ) AS addr_span FROM _detect_lines
        ) e WHERE nullif(trim(addr_span), '') IS NOT NULL
    ) p
    JOIN pii_taxonomy tax ON tax.code = 'addrust'
    WHERE nullif(trim(p.a.street_number), '') IS NOT NULL
      AND nullif(trim(p.a.zip), '') IS NOT NULL
      AND nullif(trim(p.a.city), '') IS NOT NULL
      AND len(p.span_words) > 0
),
name_hits AS (
    SELECT s.document_id, s.page_no, s.case_id, s.wl_term AS text, s.line_text AS context,
           list_min(list_transform(s.match_words, lambda m: m.x0)) AS x0,
           list_min(list_transform(s.match_words, lambda m: m.y0)) AS y0,
           list_max(list_transform(s.match_words, lambda m: m.x1)) AS x1,
           list_max(list_transform(s.match_words, lambda m: m.y1)) AS y1,
           s.wl_kind AS kind,
           greatest(1, least(99, cast(round(greatest(s.token_sort, s.partial_ratio,
               100.0 * s.jaro_winkler)) AS INTEGER))) AS confidence,
           'rapidfuzz: ' || s.wl_term AS reason,
           CASE WHEN position('NOT PII' IN s.wl_kind) > 0 THEN 'false_positive' END AS flag_tag
    FROM (
        SELECT l.document_id, l.page_no, l.case_id, l.line_text, wl.term AS wl_term, wl.kind AS wl_kind,
               rapidfuzz_token_sort_ratio(l.line_norm, wl.term_norm) AS token_sort,
               rapidfuzz_partial_ratio(l.line_norm, wl.term_norm) AS partial_ratio,
               rapidfuzz_jaro_winkler_similarity(l.line_norm, wl.term_norm) AS jaro_winkler,
               list_filter(l.word_meta, lambda m: list_bool_or(list_transform(wl.term_tokens, lambda t:
                   rapidfuzz_ratio(lower(trim(unaccent(trim(m.word, '.,;:()"''[]')))), t) >= 88))) AS match_words
        FROM _detect_lines l
        JOIN (
            SELECT case_no, kind, term, lower(trim(unaccent(term))) AS term_norm,
                   string_split(lower(trim(unaccent(term))), ' ') AS term_tokens
            FROM watchlist WHERE nullif(trim(term), '') IS NOT NULL
        ) wl ON wl.case_no = l.case_id
    ) s
    WHERE CASE WHEN s.token_sort >= 90 THEN true
               WHEN s.jaro_winkler >= 0.93 THEN true
               WHEN s.partial_ratio >= 95 THEN true
               ELSE false END
      AND len(s.match_words) > 0
)
SELECT * FROM type_hits
UNION ALL BY NAME SELECT * FROM addr_hits
UNION ALL BY NAME SELECT * FROM name_hits;

-- entities + suggestions: uuid issued once at load (ruling C).
CREATE OR REPLACE TABLE entities AS
SELECT uuid() AS id, case_id, canonical_text, kind
FROM (
    SELECT cast(case_no AS VARCHAR) AS case_id, term AS canonical_text, kind FROM watchlist
    WHERE coalesce(trim(term), '') <> ''
    UNION
    SELECT case_id, text, kind FROM _detect_hits WHERE coalesce(kind, '') <> '' AND text IS NOT NULL
) c GROUP BY case_id, canonical_text, kind;

CREATE OR REPLACE TABLE suggestions AS
SELECT uuid() AS id, h.document_id, h.page_no, h.x0, h.y0, h.x1, h.y1,
       h.text, coalesce(h.context, h.text) AS context, h.confidence,
       h.flag_tag, h.reason, e.id AS entity_id, h.kind, 'ai' AS source, now() AS created_at
FROM _detect_hits h
LEFT JOIN entities e ON e.case_id = h.case_id AND e.kind = h.kind
 AND (e.canonical_text = h.text OR starts_with(e.canonical_text, h.text)
   OR starts_with(h.text, e.canonical_text));

-- Decision fold (arg_max, no row_number). VARCHAR ids unify UUID + legacy BIGINT.
-- Reads v_src_decisions directly — no alias view. routes/decisions.sql owns its
-- own richer v_decision_log (filename := true for shard-derived batch ids).
CREATE OR REPLACE VIEW v_latest_decision AS
SELECT cast(suggestion_id AS VARCHAR) AS suggestion_id,
       arg_max(status, coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01')) AS status,
       arg_max(actor,  coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01')) AS actor,
       arg_max(reason, coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01')) AS reason,
       max(try_cast(ts AS TIMESTAMP)) AS ts
FROM v_src_decisions
WHERE kind = 'decision' AND suggestion_id IS NOT NULL
GROUP BY cast(suggestion_id AS VARCHAR);

CREATE OR REPLACE VIEW v_manual_suggestions AS
SELECT cast(suggestion_id AS VARCHAR) AS id, cast(document_id AS VARCHAR) AS document_id,
       try_cast(page_no AS INTEGER) AS page_no,
       try_cast(x0 AS DOUBLE) AS x0, try_cast(y0 AS DOUBLE) AS y0,
       try_cast(x1 AS DOUBLE) AS x1, try_cast(y1 AS DOUBLE) AS y1,
       cast(text AS VARCHAR) AS text,
       coalesce(cast(context AS VARCHAR), cast(text AS VARCHAR)) AS context,
       coalesce(try_cast(confidence AS INTEGER), 99) AS confidence,
       cast(flag_tag AS VARCHAR) AS flag_tag, cast(reason AS VARCHAR) AS reason,
       cast(entity_id AS VARCHAR) AS entity_id, cast(NULL AS VARCHAR) AS kind,
       'manual' AS source, coalesce(try_cast(ts AS TIMESTAMP), now()) AS created_at
FROM (
    SELECT suggestion_id,
           arg_max(document_id, coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01')) AS document_id,
           arg_max(page_no, coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01')) AS page_no,
           arg_max(x0, coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01')) AS x0,
           arg_max(y0, coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01')) AS y0,
           arg_max(x1, coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01')) AS x1,
           arg_max(y1, coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01')) AS y1,
           arg_max(text, coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01')) AS text,
           arg_max(context, coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01')) AS context,
           arg_max(confidence, coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01')) AS confidence,
           arg_max(flag_tag, coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01')) AS flag_tag,
           arg_max(reason, coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01')) AS reason,
           arg_max(entity_id, coalesce(try_cast(ts AS TIMESTAMP), TIMESTAMP '1970-01-01')) AS entity_id,
           max(try_cast(ts AS TIMESTAMP)) AS ts
    FROM v_src_decisions WHERE kind = 'added' AND suggestion_id IS NOT NULL
    GROUP BY suggestion_id
) m;

-- status: latest decision wins; manual→accepted, ai→pending.
-- band: high≥90 / review 60–89 / flagged<60.
CREATE OR REPLACE VIEW v_suggestions AS
WITH base AS (
    SELECT cast(s.id AS VARCHAR) AS id, cast(s.document_id AS VARCHAR) AS document_id,
           s.page_no, s.x0, s.y0, s.x1, s.y1, s.text, s.context, s.confidence,
           s.flag_tag, s.reason, cast(s.entity_id AS VARCHAR) AS entity_id,
           s.source, s.created_at, s.kind AS kind_stored
    FROM suggestions s
    UNION ALL BY NAME
    SELECT id, document_id, page_no, x0, y0, x1, y1, text, context, confidence,
           flag_tag, reason, entity_id, source, created_at, kind
    FROM v_manual_suggestions
)
SELECT b.id, b.document_id, b.page_no, b.x0, b.y0, b.x1, b.y1, b.text, b.context,
       b.confidence, b.flag_tag, b.reason, b.entity_id, b.source, b.created_at,
       coalesce(e.kind, b.kind_stored) AS kind, e.canonical_text AS entity_text,
       coalesce(ld.status, CASE b.source WHEN 'manual' THEN 'accepted' ELSE 'pending' END) AS status,
       CASE WHEN b.confidence >= 90 THEN 'high'
            WHEN b.confidence >= 60 THEN 'review' ELSE 'flagged' END AS band
FROM base b
LEFT JOIN entities e ON cast(e.id AS VARCHAR) = b.entity_id
LEFT JOIN v_latest_decision ld ON ld.suggestion_id = b.id;

-- One GROUP BY stats view (no correlated subselects).
CREATE OR REPLACE VIEW v_document_stats AS
SELECT cast(d.id AS VARCHAR) AS document_id, d.case_id, d.filename, d.page_count,
       d.file_size, d.width_pt, d.height_pt,
       coalesce(wc.n, 0) AS word_count, coalesce(pc.n, 0) AS page_rows,
       coalesce(sc.suggestion_count, 0) AS suggestion_count,
       coalesce(sc.pending_count, 0) AS pending_count,
       coalesce(sc.accepted_count, 0) AS accepted_count,
       coalesce(sc.rejected_count, 0) AS rejected_count,
       coalesce(sc.flagged_count, 0) AS flagged_count,
       coalesce(sc.high_count, 0) AS high_count,
       coalesce(sc.review_count, 0) AS review_count
FROM documents d
LEFT JOIN (SELECT cast(document_id AS VARCHAR) AS document_id, count(*)::BIGINT AS n
           FROM words GROUP BY 1) wc ON wc.document_id = cast(d.id AS VARCHAR)
LEFT JOIN (SELECT cast(document_id AS VARCHAR) AS document_id, count(*)::BIGINT AS n
           FROM pages GROUP BY 1) pc ON pc.document_id = cast(d.id AS VARCHAR)
LEFT JOIN (
    SELECT document_id, count(*)::BIGINT AS suggestion_count,
           count(*) FILTER (WHERE status = 'pending')::BIGINT AS pending_count,
           count(*) FILTER (WHERE status = 'accepted')::BIGINT AS accepted_count,
           count(*) FILTER (WHERE status = 'rejected')::BIGINT AS rejected_count,
           count(*) FILTER (WHERE band = 'flagged' AND status = 'pending')::BIGINT AS flagged_count,
           count(*) FILTER (WHERE band = 'high')::BIGINT AS high_count,
           count(*) FILTER (WHERE band = 'review')::BIGINT AS review_count
    FROM v_suggestions GROUP BY document_id
) sc ON sc.document_id = cast(d.id AS VARCHAR);

DROP TABLE IF EXISTS _detect_hits;
DROP TABLE IF EXISTS _detect_spans;

SELECT 'detect complete' AS status,
       (SELECT count(*) FROM suggestions) AS suggestions,
       (SELECT count(*) FROM entities) AS entities,
       (SELECT count(*) FROM suggestions WHERE flag_tag = 'false_positive') AS false_positives;
