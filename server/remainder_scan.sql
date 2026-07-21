-- remainder_scan.sql — false-negative catcher over the word remainder.
-- Depends on: words, documents, entities, watchlist, v_suggestions (detect).
-- Mask words under accepted|pending boxes; re-run finetype/addrust/rapidfuzz.
-- residual_pii_hits → routes/remainder.sql. Entity groups: soundex + addrust.
-- Ext: finetype, rapidfuzz, us_address_standardizer, splink_udfs.
-- Geometry: words.bbox / v_suggestions.bbox / residual_pii_hits.bbox.

INSTALL finetype FROM community; LOAD finetype;
INSTALL rapidfuzz FROM community; LOAD rapidfuzz;
INSTALL us_address_standardizer FROM community; LOAD us_address_standardizer;
INSTALL splink_udfs FROM community; LOAD splink_udfs;

-- Address canon → /api/cases/:id/address-canon + address entity groups.
CREATE OR REPLACE TABLE entity_address_canon AS
SELECT cast(e.id AS VARCHAR) AS entity_id, e.case_id, e.canonical_text AS raw_text, e.kind,
       a.street_number, a.pre_direction, a.street_name, a.suffix,
       a.unit_type, a.unit, a.city, a.state, a.zip, a.po_box,
       ((a.street_number IS NOT NULL AND (a.city IS NOT NULL OR a.zip IS NOT NULL))
         OR (a.po_box IS NOT NULL AND (a.city IS NOT NULL OR a.zip IS NOT NULL))) AS is_full_address,
       (a.street_number IS NULL AND a.suffix IS NOT NULL
         AND a.city IS NULL AND a.zip IS NULL AND a.po_box IS NULL) AS is_street_fp_bait,
       upper(concat_ws('|', coalesce(a.street_number, a.po_box, ''),
                            coalesce(a.street_name, ''), coalesce(a.suffix, ''))) AS group_key,
       upper(trim(e.canonical_text)) AS standardized_text
FROM entities e, UNNEST([addrust_parse(e.canonical_text)]) AS u(a)
WHERE position('ADDRESS' IN e.kind) > 0 OR position('STREET' IN e.kind) > 0;

-- Bulk-judge groups (person soundex surname / address group_key).
CREATE OR REPLACE TABLE entity_groups AS
SELECT abs(hash(case_id || '|' || group_kind || '|' || group_key)) % 2147483647 AS group_id,
       case_id, group_key, root_entity_id, canonical_label, group_kind
FROM (
    SELECT case_id,
           'person:' || coalesce(soundex(list_extract(string_split(trim(canonical_text), ' '), -1)), 'x') AS group_key,
           min(cast(id AS VARCHAR)) AS root_entity_id,
           max(canonical_text) AS canonical_label,
           'person_fuzz' AS group_kind
    FROM entities
    WHERE position('PERSON' IN kind) > 0 AND trim(canonical_text) <> ''
    GROUP BY case_id, soundex(list_extract(string_split(trim(canonical_text), ' '), -1))
    UNION ALL BY NAME
    SELECT case_id, group_key, min(entity_id), max(standardized_text), 'address_std'
    FROM entity_address_canon
    WHERE group_key IS NOT NULL AND group_key <> '||'
    GROUP BY case_id, group_key
) g;

CREATE OR REPLACE TABLE entity_group_members AS
SELECT abs(hash(cast(group_id AS VARCHAR) || '|' || entity_id || '|' || variant_text)) % 2147483647 AS member_id,
       group_id, case_id, group_kind, canonical_label, entity_id,
       variant_text, score, method, is_full_address, is_canonical
FROM (
    SELECT g.group_id, g.case_id, g.group_kind, g.canonical_label,
           cast(e.id AS VARCHAR) AS entity_id, e.canonical_text AS variant_text,
           CASE WHEN cast(e.id AS VARCHAR) = g.root_entity_id THEN 100.0
                ELSE rapidfuzz_ratio(lower(e.canonical_text), lower(g.canonical_label)) END AS score,
           CASE WHEN cast(e.id AS VARCHAR) = g.root_entity_id THEN 'entity' ELSE 'soundex' END AS method,
           cast(NULL AS BOOLEAN) AS is_full_address,
           cast(e.id AS VARCHAR) = g.root_entity_id AS is_canonical
    FROM entity_groups g
    JOIN entities e ON e.case_id = g.case_id AND position('PERSON' IN e.kind) > 0
     AND soundex(list_extract(string_split(trim(e.canonical_text), ' '), -1))
         = replace(g.group_key, 'person:', '')
    WHERE g.group_kind = 'person_fuzz'
    UNION ALL BY NAME
    SELECT g.group_id, g.case_id, g.group_kind, g.canonical_label,
           c.entity_id, c.raw_text AS variant_text, 100.0 AS score,
           'addrust_entity' AS method, c.is_full_address,
           (c.entity_id = g.root_entity_id) AS is_canonical
    FROM entity_groups g
    JOIN entity_address_canon c ON c.case_id = g.case_id AND c.group_key = g.group_key
    WHERE g.group_kind = 'address_std'
) m;

CREATE OR REPLACE VIEW v_entity_groups AS
SELECT g.*,
       coalesce(t.member_count, 0) AS member_count,
       coalesce(t.variant_count, 0) AS variant_count
FROM entity_groups g
LEFT JOIN (
    SELECT group_id, count(*)::BIGINT AS member_count,
           count(DISTINCT variant_text)::BIGINT AS variant_count
    FROM entity_group_members GROUP BY group_id
) t ON t.group_id = g.group_id;

-- Residual hits: cover-masked ngrams → finetype + addrust + rapidfuzz.
CREATE OR REPLACE TABLE residual_pii_hits AS
WITH cover AS (
    SELECT document_id, page_no, bbox
    FROM v_suggestions WHERE status IN ('accepted', 'pending')
),
remainder AS (
    SELECT cast(w.document_id AS VARCHAR) AS document_id, w.page_no, d.case_id,
           w.word, w.bbox
    FROM words w
    JOIN documents d ON cast(d.id AS VARCHAR) = cast(w.document_id AS VARCHAR)
    WHERE NOT EXISTS (
        SELECT 1 FROM cover c
        WHERE c.document_id = cast(w.document_id AS VARCHAR) AND c.page_no = w.page_no
          AND NOT (w.bbox.x1 <= c.bbox.x0 OR w.bbox.x0 >= c.bbox.x1
                OR w.bbox.y1 <= c.bbox.y0 OR w.bbox.y0 >= c.bbox.y1)
    )
),
lines AS (
    SELECT document_id, page_no, case_id,
           list(word ORDER BY bbox.x0) AS word_list,
           list(struct_pack(word := word, x0 := bbox.x0, y0 := bbox.y0,
                            x1 := bbox.x1, y1 := bbox.y1) ORDER BY bbox.x0) AS word_meta
    FROM remainder GROUP BY document_id, page_no, case_id, round(bbox.y0, 0)
),
spans AS (
    SELECT document_id, page_no, case_id, n, start_idx, phrase,
           lower(trim(unaccent(phrase))) AS phrase_norm,
           struct_pack(
               x0 := word_meta[start_idx].x0,
               y0 := word_meta[start_idx].y0,
               x1 := word_meta[start_idx + n - 1].x1,
               y1 := list_max(list_transform(
                   list_slice(word_meta, start_idx::BIGINT, (start_idx + n - 1)::BIGINT),
                   lambda m: m.y1))
           ) AS bbox,
           array_to_string(word_list, ' ') AS context
    FROM (
        SELECT l.document_id, l.page_no, l.case_id, l.word_list, l.word_meta,
               len(g.gram) AS n, g.idx AS start_idx, array_to_string(g.gram, ' ') AS phrase
        FROM lines l,
             UNNEST([ngrams(l.word_list, 1)::VARCHAR[][], ngrams(l.word_list, 2)::VARCHAR[][],
                     ngrams(l.word_list, 3)::VARCHAR[][], ngrams(l.word_list, 4)::VARCHAR[][]]) AS gs(grams),
             UNNEST(gs.grams) WITH ORDINALITY AS g(gram, idx)
    ) raw
),
type_hits AS (
    SELECT document_id, page_no, case_id, token AS text, context, bbox,
           CASE
               WHEN position('@' IN token) > 0 OR ft_type LIKE 'identity.person.email%'
                   OR ft_type LIKE '%phone%' THEN 'PHONE'
               WHEN ft_type LIKE 'datetime.date%' THEN 'DATE OF BIRTH'
               WHEN ft_type LIKE 'identity.commerce.isbn%'
                   OR length(regexp_replace(token, '[^0-9]', '', 'g')) = 9 THEN 'SSN'
               WHEN length(regexp_replace(token, '[^0-9]', '', 'g')) = 10 THEN 'PHONE'
           END AS kind,
           greatest(1, least(99, cast(round(100.0 * coalesce(ft_conf, 0.70)) AS INTEGER)))::DOUBLE AS score,
           'finetype: ' || coalesce(ft_type, 'shape') AS why,
           'finetype' AS detector, cast(NULL AS VARCHAR) AS entity_id
    FROM (
        SELECT document_id, page_no, case_id, context, bbox,
               trim(phrase, '.,;:()"''[]') AS token,
               finetype([trim(phrase, '.,;:()"''[]')]) AS ft_type,
               try_cast(json_extract_string(
                   finetype_detail([trim(phrase, '.,;:()"''[]')])::JSON, '$.confidence') AS DOUBLE) AS ft_conf
        FROM spans
        WHERE n BETWEEN 1 AND 3
          AND length(trim(phrase, '.,;:()"''[]')) BETWEEN 6 AND 40
          AND (position('-' IN phrase) > 0 OR position('/' IN phrase) > 0
            OR position('.' IN phrase) > 0 OR position('@' IN phrase) > 0
            OR position('(' IN phrase) > 0 OR position(' ' IN phrase) > 0)
    ) t
    WHERE ft_type LIKE 'datetime.date%' OR ft_type LIKE 'identity.commerce.isbn%'
       OR ft_type LIKE 'identity.person.email%' OR ft_type LIKE '%phone%'
       OR position('@' IN token) > 0
       OR length(regexp_replace(token, '[^0-9]', '', 'g')) IN (9, 10)
),
addr_hits AS (
    SELECT document_id, page_no, case_id, phrase AS text, context, bbox,
           'ADDRESS' AS kind, 88.0 AS score,
           'addrust: ' || coalesce(a.street_number, '') || ' ' || coalesce(a.street_name, '') AS why,
           'addrust' AS detector, cast(NULL AS VARCHAR) AS entity_id
    FROM (SELECT s.*, addrust_parse(s.phrase) AS a FROM spans s
          WHERE s.n BETWEEN 3 AND 4
            AND try_cast(list_extract(string_split(s.phrase, ' '), 1) AS INTEGER) IS NOT NULL) p
    WHERE a.street_number IS NOT NULL
      AND (a.city IS NOT NULL OR a.zip IS NOT NULL OR a.street_name IS NOT NULL)
),
roster AS (
    SELECT cast(case_no AS VARCHAR) AS case_id, term,
           lower(trim(unaccent(term))) AS term_norm, kind, cast(NULL AS VARCHAR) AS entity_id
    FROM watchlist WHERE term IS NOT NULL AND trim(term) <> ''
    UNION
    SELECT case_id, canonical_text, lower(trim(unaccent(canonical_text))), kind, cast(id AS VARCHAR)
    FROM entities
    WHERE canonical_text IS NOT NULL AND trim(canonical_text) <> ''
      AND (position('PERSON' IN kind) > 0 OR position('OFFICER' IN kind) > 0)
),
name_hits AS (
    SELECT s.document_id, s.page_no, s.case_id, s.phrase AS text, s.context,
           s.bbox, 'PERSON' AS kind,
           greatest(rapidfuzz_token_sort_ratio(s.phrase_norm, r.term_norm),
                    100.0 * rapidfuzz_jaro_winkler_similarity(s.phrase_norm, r.term_norm)) AS score,
           'rapidfuzz: ' || r.term AS why, 'rapidfuzz' AS detector, r.entity_id
    FROM spans s JOIN roster r ON r.case_id = s.case_id
    WHERE s.n BETWEEN 1 AND 4
      AND len(string_split(trim(r.term), ' ')) = s.n
      AND s.phrase_norm <> r.term_norm
      AND (rapidfuzz_token_sort_ratio(s.phrase_norm, r.term_norm) >= 85
        OR rapidfuzz_jaro_winkler_similarity(s.phrase_norm, r.term_norm) >= 0.90)
),
fresh AS (
    SELECT u.* FROM (
        SELECT * FROM type_hits WHERE kind IS NOT NULL
        UNION ALL BY NAME SELECT * FROM addr_hits
        UNION ALL BY NAME SELECT * FROM name_hits
    ) u
    WHERE NOT EXISTS (
        SELECT 1 FROM v_suggestions s
        WHERE s.document_id = u.document_id AND s.page_no = u.page_no
          AND NOT (u.bbox.x1 <= s.bbox.x0 OR u.bbox.x0 >= s.bbox.x1
                OR u.bbox.y1 <= s.bbox.y0 OR u.bbox.y0 >= s.bbox.y1)
    )
),
dedup AS (
    SELECT document_id, page_no, kind,
           unnest(arg_max(struct_pack(text, bbox, why, detector, score, entity_id), prio))
    FROM (
        SELECT *, CASE detector WHEN 'rapidfuzz' THEN 3 WHEN 'addrust' THEN 2 ELSE 1 END AS prio
        FROM fresh
    ) f
    GROUP BY document_id, page_no,
             round(bbox.x0, 1), round(bbox.y0, 1), round(bbox.x1, 1), kind
)
SELECT CAST(substr(h, 1, 8) || '-' || substr(h, 9, 4) || '-' || substr(h, 13, 4) || '-' ||
            substr(h, 17, 4) || '-' || substr(h, 21, 12) AS VARCHAR) AS id,
       document_id, page_no AS page, bbox, text, kind, why, detector, score, entity_id
FROM dedup
CROSS JOIN LATERAL (
    SELECT md5(
        cast(document_id AS VARCHAR) || chr(31) || cast(page_no AS VARCHAR) || chr(31) ||
        cast(round(bbox.x0, 1) AS VARCHAR) || chr(31) || cast(round(bbox.y0, 1) AS VARCHAR) || chr(31) ||
        cast(round(bbox.x1, 1) AS VARCHAR) || chr(31) || cast(round(bbox.y1, 1) AS VARCHAR) || chr(31) ||
        cast(text AS VARCHAR) || chr(31) || cast(kind AS VARCHAR) || chr(31) || 'residual'
    ) AS h
);

SELECT 'remainder scan ready' AS status,
       (SELECT count(*) FROM residual_pii_hits) AS residual_n,
       (SELECT count(*) FROM entity_groups) AS entity_groups_n,
       (SELECT count(*) FROM entity_group_members) AS entity_members_n;
