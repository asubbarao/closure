-- detect.sql — generic AI redaction detection over words (ruling B).
-- Replaces seed.sql. Inputs: words, documents, watchlist; v_src_decisions.
-- Extensions: finetype, us_address_standardizer, rapidfuzz, splink_udfs.
-- No qnorm, v_grams, row_number, identities unpivot.

INSTALL finetype FROM community; LOAD finetype;
INSTALL us_address_standardizer FROM community; LOAD us_address_standardizer;
INSTALL rapidfuzz FROM community; LOAD rapidfuzz;
INSTALL splink_udfs FROM community; LOAD splink_udfs;

-- Line bags + splink ngrams (n constant) → phrase/box. Meta list carries coords.
CREATE OR REPLACE TABLE _detect_spans AS
WITH lines AS (
    SELECT w.document_id, w.page_no, d.case_id,
           list(w.word ORDER BY w.x0) AS word_list,
           list(struct_pack(word := w.word, x0 := w.x0, y0 := w.y0, x1 := w.x1, y1 := w.y1)
                ORDER BY w.x0) AS word_meta
    FROM words w JOIN documents d ON d.id = w.document_id
    GROUP BY w.document_id, w.page_no, d.case_id, round(w.y0, 0)
),
-- token_count = number of words in the span (1..4-gram). Positional UNION ALL
-- (not BY NAME — the size literal must align to token_count by position).
raw AS (
    SELECT l.*, 1 AS token_count, g.gram AS tokens, g.idx AS start_idx FROM lines l
    CROSS JOIN UNNEST(ngrams(l.word_list, 1)) WITH ORDINALITY AS g(gram, idx)
    UNION ALL
    SELECT l.*, 2, g.gram, g.idx FROM lines l
    CROSS JOIN UNNEST(ngrams(l.word_list, 2)) WITH ORDINALITY AS g(gram, idx)
    WHERE len(l.word_list) >= 2
    UNION ALL
    SELECT l.*, 3, g.gram, g.idx FROM lines l
    CROSS JOIN UNNEST(ngrams(l.word_list, 3)) WITH ORDINALITY AS g(gram, idx)
    WHERE len(l.word_list) >= 3
    UNION ALL
    SELECT l.*, 4, g.gram, g.idx FROM lines l
    CROSS JOIN UNNEST(ngrams(l.word_list, 4)) WITH ORDINALITY AS g(gram, idx)
    WHERE len(l.word_list) >= 4
)
SELECT document_id, page_no, case_id, token_count, start_idx,
       array_to_string(list_transform(tokens, lambda t: cast(t AS VARCHAR)), ' ') AS phrase,
       lower(trim(unaccent(array_to_string(
           list_transform(tokens, lambda t: cast(t AS VARCHAR)), ' ')))) AS phrase_norm,
       word_meta[start_idx].x0 AS x0, word_meta[start_idx].y0 AS y0,
       word_meta[start_idx + token_count - 1].x1 AS x1,
       list_max(list_transform(
           list_slice(word_meta, start_idx::BIGINT, (start_idx + token_count - 1)::BIGINT),
           lambda m: m.y1)) AS y1,
       array_to_string(list_transform(word_list, lambda t: cast(t AS VARCHAR)), ' ') AS context
FROM raw;

-- Hits: (1) finetype PII  (2) addrust addresses  (3) rapidfuzz × watchlist names.
-- finetype(col) bulk-profiles; finetype([tok]) is per-row. SSN lands as isbn.
CREATE OR REPLACE TABLE _detect_hits AS
WITH type_hits AS (
    SELECT document_id, page_no, case_id, token AS text, context, x0, y0, x1, y1,
           CASE
               WHEN position('@' IN token) > 0 OR ft_type LIKE 'identity.person.email%'
                   OR ft_type LIKE '%phone%' THEN 'PHONE · SUBJECT'
               WHEN ft_type LIKE 'datetime.date%' THEN 'DATE OF BIRTH'
               WHEN ft_type LIKE 'identity.commerce.isbn%' THEN 'SSN'
           END AS kind,
           greatest(1, least(99, cast(round(100.0 * coalesce(ft_conf, 0.70)) AS INTEGER))) AS confidence,
           'finetype: ' || ft_type AS reason,
           cast(NULL AS VARCHAR) AS flag_tag
    FROM (
        SELECT document_id, page_no, case_id, context, x0, y0, x1, y1,
               trim(phrase, '.,;:()"''[]') AS token,
               finetype([trim(phrase, '.,;:()"''[]')]) AS ft_type,
               try_cast(json_extract_string(
                   finetype_detail([trim(phrase, '.,;:()"''[]')])::JSON, '$.confidence'
               ) AS DOUBLE) AS ft_conf
        FROM _detect_spans
        WHERE token_count = 1 AND length(trim(phrase, '.,;:()"''[]')) BETWEEN 6 AND 40
          AND (position('-' IN phrase) > 0 OR position('/' IN phrase) > 0
            OR position('@' IN phrase) > 0 OR position('(' IN phrase) > 0)
    ) t
    WHERE ft_type LIKE 'datetime.date%' OR ft_type LIKE 'identity.commerce.isbn%'
       OR ft_type LIKE 'identity.person.email%' OR ft_type LIKE '%phone%'
       OR position('@' IN token) > 0
),
addr_hits AS (
    SELECT document_id, page_no, case_id, phrase AS text, context, x0, y0, x1, y1,
           'ADDRESS · SUBJECT' AS kind, 88 AS confidence,
           'addrust: ' || coalesce(a.street_number, '') || ' ' || coalesce(a.street_name, '') AS reason,
           cast(NULL AS VARCHAR) AS flag_tag
    FROM (
        SELECT *, addrust_parse(phrase) AS a FROM _detect_spans
        WHERE token_count BETWEEN 3 AND 4
          AND try_cast(list_extract(string_split(phrase, ' '), 1) AS INTEGER) IS NOT NULL
    ) p
    WHERE a.street_number IS NOT NULL
      AND (a.city IS NOT NULL OR a.zip IS NOT NULL OR a.street_name IS NOT NULL)
),
-- watchlist normalized ONCE (was recomputed 4×/row): term_norm for fuzzy match,
-- term_token_count so we only compare a span to same-length watchlist terms.
wl_norm AS (
    SELECT case_no, kind, term,
           lower(trim(unaccent(term)))        AS term_norm,
           len(string_split(trim(term), ' ')) AS term_token_count
    FROM watchlist
    WHERE coalesce(trim(term), '') <> ''
),
name_scored AS (   -- score ONCE (was computed twice, in SELECT and WHERE)
    SELECT s.document_id, s.page_no, s.case_id, s.phrase, s.context,
           s.x0, s.y0, s.x1, s.y1, wl.kind AS wl_kind, wl.term AS wl_term,
           rapidfuzz_token_sort_ratio(s.phrase_norm, wl.term_norm)               AS token_sort,
           100.0 * rapidfuzz_jaro_winkler_similarity(s.phrase_norm, wl.term_norm) AS jaro_winkler
    FROM _detect_spans s
    JOIN wl_norm wl ON wl.case_no = s.case_id AND wl.term_token_count = s.token_count
),
name_hits AS (
    SELECT document_id, page_no, case_id, phrase AS text, context, x0, y0, x1, y1,
           wl_kind AS kind,
           greatest(1, least(99, cast(round(greatest(token_sort, jaro_winkler)) AS INTEGER))) AS confidence,
           'rapidfuzz: ' || wl_term AS reason,
           CASE WHEN position('NOT PII' IN wl_kind) > 0 THEN 'false_positive' END AS flag_tag
    FROM name_scored
    WHERE CASE WHEN token_sort   >= 88   THEN true
               WHEN jaro_winkler >= 92   THEN true
               ELSE false END
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
CREATE OR REPLACE VIEW v_decision_log AS SELECT * FROM v_src_decisions;

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
