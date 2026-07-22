-- server/domain/detect.sql — finetype + watchlist → entities + AI suggestions.

CREATE OR REPLACE TABLE _detect_hits AS
WITH type_hits AS (
    SELECT * FROM (
        SELECT w.document_id, w.page_no, d.case_id,
               trim(w.word, '.,;:()"''[]') AS text,
               trim(w.word, '.,;:()"''[]') AS context,
               w.bbox,
               CASE
                   WHEN ft LIKE 'identity.commerce.isbn%' THEN 'SSN'
                   WHEN ft LIKE '%phone%' OR position('@' IN w.word) > 0
                        THEN 'PHONE · SUBJECT'
                   WHEN ft LIKE 'datetime.date%' THEN 'DATE OF BIRTH'
                   WHEN ft LIKE 'identity.person.email%' THEN 'PHONE · SUBJECT'
               END AS kind,
               75 AS confidence, 'finetype: ' || ft AS reason,
               NULL::VARCHAR AS flag_tag
        FROM words w
        JOIN documents d ON d.id = w.document_id
        CROSS JOIN LATERAL (SELECT finetype([trim(w.word, '.,;:()"''[]')]) AS ft)
        WHERE length(trim(w.word, '.,;:()"''[]')) BETWEEN 6 AND 40
          AND (position('-' IN w.word) > 0 OR position('/' IN w.word) > 0
            OR position('@' IN w.word) > 0 OR position('(' IN w.word) > 0)
    ) t WHERE kind IS NOT NULL
),
name_hits AS (
    SELECT l.document_id, l.page_no, l.case_id, wl.term AS text, l.line_text AS context,
           struct_pack(
               x0 := list_min(list_transform(mw, lambda m: m.bbox.x0)),
               y0 := list_min(list_transform(mw, lambda m: m.bbox.y0)),
               x1 := list_max(list_transform(mw, lambda m: m.bbox.x1)),
               y1 := list_max(list_transform(mw, lambda m: m.bbox.y1))
           ) AS bbox,
           wl.kind, greatest(1, least(99, round(sc)::INTEGER)) AS confidence,
           'rapidfuzz: ' || wl.term AS reason,
           CASE WHEN position('NOT PII' IN wl.kind) > 0 THEN 'false_positive' END AS flag_tag
    FROM document_lines l
    JOIN (
        SELECT case_no, kind, term,
               lower(trim(unaccent(term))) AS term_norm,
               string_split(lower(trim(unaccent(term))), ' ') AS term_tokens
        FROM watchlist
    ) wl ON wl.case_no = l.case_id
    CROSS JOIN LATERAL (
        SELECT greatest(
            rapidfuzz_token_sort_ratio(l.line_norm, wl.term_norm),
            rapidfuzz_partial_ratio(l.line_norm, wl.term_norm),
            100.0 * rapidfuzz_jaro_winkler_similarity(l.line_norm, wl.term_norm)
        ) AS sc,
        list_filter(l.word_meta, lambda m:
            list_bool_or(list_transform(wl.term_tokens, lambda t:
                rapidfuzz_ratio(
                    lower(trim(unaccent(trim(m.word, '.,;:()"''[]')))), t) >= 88
            ))) AS mw
    )
    WHERE sc >= 90 AND len(mw) > 0
)
SELECT * FROM type_hits
UNION ALL BY NAME SELECT * FROM name_hits;

CREATE OR REPLACE TABLE entities AS
SELECT md5(case_id || chr(31) || kind || chr(31) || canonical_text) AS id,
       case_id, canonical_text, kind
FROM (
    SELECT case_no AS case_id, term AS canonical_text, kind FROM watchlist
    UNION
    SELECT case_id, text, kind FROM _detect_hits
     WHERE kind IS NOT NULL AND text IS NOT NULL
) u
GROUP BY case_id, canonical_text, kind;

CREATE OR REPLACE TABLE suggestions AS
SELECT md5(h.document_id || chr(31) || h.page_no::VARCHAR || chr(31)
           || round(h.bbox.x0, 1)::VARCHAR || chr(31)
           || round(h.bbox.y0, 1)::VARCHAR || chr(31)
           || round(h.bbox.x1, 1)::VARCHAR || chr(31)
           || round(h.bbox.y1, 1)::VARCHAR || chr(31)
           || h.text || chr(31) || h.kind || chr(31) || 'ai') AS id,
       h.document_id, h.page_no, h.bbox, h.text,
       coalesce(h.context, h.text) AS context,
       h.confidence, h.flag_tag, h.reason, e.id AS entity_id, h.kind,
       'ai' AS source, TIMESTAMP '1970-01-01' AS created_at, dl.line_no
FROM _detect_hits h
LEFT JOIN entities e
  ON e.case_id = h.case_id AND e.kind = h.kind
 AND (e.canonical_text = h.text
   OR starts_with(e.canonical_text, h.text)
   OR starts_with(h.text, e.canonical_text))
LEFT JOIN document_lines dl
  ON dl.document_id = h.document_id AND dl.page_no = h.page_no
 AND dl.y_key = round(h.bbox.y0, 0);

DROP TABLE IF EXISTS _detect_hits;
