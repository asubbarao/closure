-- remainder_scan.sql — automated false-negative catcher over the word remainder.
-- Depends on: words, v_suggestions (seed), documents, entities.
--
-- Concept: mask words covered by accepted/pending suggestions → scan what
-- REMAINS for residual PII the main detector missed. Surfaced as
-- residual_pii_candidates for the human as "possible missed redactions".
--
-- Detection stack:
--   (a) regexp_matches — SSN (dash / dot / spaced), phone (dotted/dashed/paren), email
--   (b) rapidfuzz (community v1.5.4) — roster PERSON names vs remainder tokens/bigrams
--       (catches misspellings like "Norene Kuze" / "Robyn Prce"); also fuzzy-groups
--       entity VARIANTS for bulk judgment (same person spelled two ways)
--   (c) finetype (community) — phone/email class on identifier-shaped 1-grams
--   (d) us_address_standardizer (community) — canonicalize ADDRESS entities +
--       address-shaped residual hits regex misses (house# + locality / po_box)
--
-- HARD rules: no LIKE / contains; CTAS + views only; no decision writes.
-- Substring ops banned — use regexp_matches / position / rapidfuzz only.

INSTALL finetype FROM community;
LOAD finetype;
INSTALL rapidfuzz FROM community;
LOAD rapidfuzz;
INSTALL us_address_standardizer FROM community;
LOAD us_address_standardizer;

DROP VIEW IF EXISTS residual_pii_candidates CASCADE;
DROP VIEW IF EXISTS v_residual_pii_candidates CASCADE;
DROP VIEW IF EXISTS v_entity_groups CASCADE;
DROP VIEW IF EXISTS v_entity_group_members CASCADE;
DROP VIEW IF EXISTS v_address_entity_canon CASCADE;
DROP TABLE IF EXISTS residual_pii_hits CASCADE;
DROP TABLE IF EXISTS entity_group_members CASCADE;
DROP TABLE IF EXISTS entity_groups CASCADE;
DROP TABLE IF EXISTS entity_address_canon CASCADE;
DROP TABLE IF EXISTS _remainder_grams CASCADE;
DROP TABLE IF EXISTS _remainder_words CASCADE;
DROP TABLE IF EXISTS _accepted_boxes CASCADE;
DROP TABLE IF EXISTS _cover_boxes CASCADE;
DROP TABLE IF EXISTS _suggestion_boxes CASCADE;
DROP TABLE IF EXISTS _roster_persons CASCADE;
DROP TABLE IF EXISTS _name_variant_pairs CASCADE;
DROP TABLE IF EXISTS _residual_regex CASCADE;
DROP TABLE IF EXISTS _residual_fuzz CASCADE;
DROP TABLE IF EXISTS _residual_finetype CASCADE;
DROP TABLE IF EXISTS _residual_addrust CASCADE;
DROP TABLE IF EXISTS _addrust_parsed CASCADE;

-- ═══════════════════════════════════════════════════════════════════════════
-- Address entity canonicalize (us_address_standardizer)
-- One standardized key per real address; partial forms group with full forms.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE entity_address_canon AS
WITH parsed AS (
    SELECT
        e.id AS entity_id,
        e.case_id,
        e.canonical_text AS raw_text,
        e.kind,
        addrust_parse(e.canonical_text) AS a
    FROM entities e
    WHERE position('ADDRESS' IN e.kind) > 0
       OR position('STREET' IN e.kind) > 0
),
keyed AS (
    SELECT
        entity_id,
        case_id,
        raw_text,
        kind,
        a.street_number AS street_number,
        a.pre_direction AS pre_direction,
        a.street_name AS street_name,
        a.suffix AS suffix,
        a.unit_type AS unit_type,
        a.unit AS unit,
        a.city AS city,
        a.state AS state,
        a.zip AS zip,
        a.po_box AS po_box,
        -- Full-address gate (PII residual / entity quality)
        (
            (a.street_number IS NOT NULL AND (a.city IS NOT NULL OR a.zip IS NOT NULL))
            OR (a.po_box IS NOT NULL AND (a.city IS NOT NULL OR a.zip IS NOT NULL))
        ) AS is_full_address,
        -- Street-name-only FP bait (surname + Street, no house/locality)
        (
            a.street_number IS NULL
            AND a.suffix IS NOT NULL
            AND a.city IS NULL
            AND a.zip IS NULL
            AND a.po_box IS NULL
        ) AS is_street_fp_bait,
        -- Canonical grouping key: house + street + suffix (+ zip when present).
        -- Partials without zip still share house|street|suffix with the full form.
        upper(concat_ws(
            '|',
            coalesce(a.street_number, a.po_box, ''),
            coalesce(a.street_name, ''),
            coalesce(a.suffix, ''),
            coalesce(a.zip, '')
        )) AS std_key_full,
        upper(concat_ws(
            '|',
            coalesce(a.street_number, a.po_box, ''),
            coalesce(a.street_name, ''),
            coalesce(a.suffix, '')
        )) AS std_key_core,
        -- Display form rebuilt from components (stable, uppercase street)
        CASE
            WHEN a.po_box IS NOT NULL THEN
                trim(concat_ws(
                    ', ',
                    'PO BOX ' || a.po_box,
                    nullif(concat_ws(' ', a.city, a.state, a.zip), '')
                ))
            WHEN a.street_number IS NOT NULL OR a.street_name IS NOT NULL THEN
                trim(concat_ws(
                    ', ',
                    trim(concat_ws(
                        ' ',
                        a.street_number,
                        a.pre_direction,
                        a.street_name,
                        a.suffix,
                        CASE WHEN a.unit IS NOT NULL
                             THEN coalesce(a.unit_type, 'UNIT') || ' ' || a.unit
                             ELSE NULL END
                    )),
                    nullif(concat_ws(' ', a.city, a.state, a.zip), '')
                ))
            ELSE upper(trim(raw_text))
        END AS standardized_text
    FROM parsed
)
SELECT *
FROM (
    SELECT
        entity_id,
        case_id,
        raw_text,
        kind,
        street_number,
        pre_direction,
        street_name,
        suffix,
        unit_type,
        unit,
        city,
        state,
        zip,
        po_box,
        is_full_address,
        is_street_fp_bait,
        -- Prefer core key (no zip) for grouping variants that drop locality
        CASE
            WHEN street_number IS NOT NULL OR po_box IS NOT NULL
                THEN std_key_core
            ELSE std_key_full
        END AS group_key,
        standardized_text
    FROM keyed
) keyed_out
WHERE group_key IS NOT NULL AND group_key <> '||';

CREATE OR REPLACE VIEW v_address_entity_canon AS
SELECT * FROM entity_address_canon;

-- Also standardize distinct ADDRESS suggestion texts (seed uses 3-token partials).
CREATE OR REPLACE TABLE _address_text_variants AS
WITH texts AS (
    SELECT DISTINCT
        e.case_id,
        e.id AS entity_id,
        s.text AS variant_text
    FROM suggestions s
    JOIN entities e ON e.id = s.entity_id
    WHERE position('ADDRESS' IN coalesce(e.kind, s.text)) > 0
       OR position('ADDRESS' IN coalesce(e.kind, '')) > 0
    UNION
    SELECT
        e.case_id,
        e.id AS entity_id,
        e.canonical_text AS variant_text
    FROM entities e
    WHERE position('ADDRESS' IN e.kind) > 0
),
parsed AS (
    SELECT
        case_id,
        entity_id,
        variant_text,
        addrust_parse(variant_text) AS a
    FROM texts
    WHERE variant_text IS NOT NULL AND trim(variant_text) <> ''
)
SELECT
    case_id,
    entity_id,
    variant_text,
    a.street_number AS street_number,
    a.street_name AS street_name,
    a.suffix AS suffix,
    a.city AS city,
    a.state AS state,
    a.zip AS zip,
    a.po_box AS po_box,
    upper(concat_ws(
        '|',
        coalesce(a.street_number, a.po_box, ''),
        coalesce(a.street_name, ''),
        coalesce(a.suffix, '')
    )) AS group_key,
    (
        (a.street_number IS NOT NULL AND (a.city IS NOT NULL OR a.zip IS NOT NULL))
        OR (a.po_box IS NOT NULL AND (a.city IS NOT NULL OR a.zip IS NOT NULL))
    ) AS is_full_address
FROM parsed
WHERE coalesce(a.street_number, a.po_box, a.street_name) IS NOT NULL;

-- ═══════════════════════════════════════════════════════════════════════════
-- rapidfuzz entity name variants — same person spelled two ways → one group
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE _roster_persons AS
SELECT
    e.id AS entity_id,
    e.case_id,
    e.canonical_text AS roster_name,
    lower(trim(e.canonical_text)) AS roster_norm,
    e.kind,
    lower(regexp_extract(trim(e.canonical_text), '^(\S+)', 1)) AS first_norm,
    lower(regexp_extract(trim(e.canonical_text), '(\S+)$', 1)) AS last_norm
FROM entities e
WHERE position('PERSON' IN e.kind) > 0
  AND e.canonical_text IS NOT NULL
  AND trim(e.canonical_text) <> '';

-- Cross-entity pairs within a case (e.g. OCR drift if two roster rows near-match).
CREATE OR REPLACE TABLE _name_variant_pairs AS
SELECT
    a.case_id,
    a.entity_id AS entity_id_a,
    b.entity_id AS entity_id_b,
    a.roster_name AS name_a,
    b.roster_name AS name_b,
    rapidfuzz_ratio(a.roster_norm, b.roster_norm) AS score,
    'entity_pair' AS method
FROM _roster_persons a
JOIN _roster_persons b
  ON b.case_id = a.case_id
 AND b.entity_id > a.entity_id
WHERE rapidfuzz_ratio(a.roster_norm, b.roster_norm) >= 90.0
  AND a.roster_norm <> b.roster_norm;

-- Suggestion / word-surface variants: distinct spellings near an entity name.
CREATE OR REPLACE TABLE _name_surface_variants AS
WITH sug AS (
    SELECT DISTINCT
        r.case_id,
        r.entity_id,
        r.roster_name,
        r.roster_norm,
        lower(trim(s.text)) AS surface_norm,
        s.text AS surface_text
    FROM _roster_persons r
    JOIN suggestions s ON s.entity_id = r.entity_id
    WHERE s.text IS NOT NULL AND trim(s.text) <> ''
),
-- Word bigrams (corpus surface forms including trailing punctuation)
grams AS (
    SELECT
        d.case_id,
        lower(trim(regexp_replace(
            w.word || ' ' || lead(w.word) OVER (
                PARTITION BY w.document_id, w.page_no ORDER BY w.seq
            ),
            '[^A-Za-z0-9''\- ]+',
            ''
        ))) AS surface_norm,
        trim(regexp_replace(
            w.word || ' ' || lead(w.word) OVER (
                PARTITION BY w.document_id, w.page_no ORDER BY w.seq
            ),
            '[^A-Za-z0-9''\- ]+',
            ''
        )) AS surface_text
    FROM words w
    JOIN documents d ON d.id = w.document_id
),
gram_hits AS (
    SELECT
        r.case_id,
        r.entity_id,
        r.roster_name,
        r.roster_norm,
        g.surface_norm,
        g.surface_text,
        rapidfuzz_ratio(g.surface_norm, r.roster_norm) AS score
    FROM grams g
    JOIN _roster_persons r
      ON r.case_id = g.case_id
    WHERE g.surface_norm IS NOT NULL
      AND g.surface_norm <> ''
      AND regexp_matches(g.surface_norm, '^[a-z][a-z''\-]* [a-z][a-z''\-]*$')
      AND rapidfuzz_ratio(g.surface_norm, r.roster_norm) >= 90.0
),
unioned AS (
    SELECT
        case_id,
        entity_id,
        roster_name,
        roster_norm,
        surface_norm,
        surface_text,
        rapidfuzz_ratio(surface_norm, roster_norm) AS score,
        'suggestion' AS method
    FROM sug
    WHERE surface_norm <> roster_norm
      AND rapidfuzz_ratio(surface_norm, roster_norm) >= 90.0
    UNION ALL BY NAME
    SELECT
        case_id,
        entity_id,
        roster_name,
        roster_norm,
        surface_norm,
        surface_text,
        score,
        'word_bigram' AS method
    FROM gram_hits
    WHERE surface_norm <> roster_norm
)
SELECT
    case_id,
    entity_id,
    roster_name,
    surface_text AS variant_text,
    surface_norm AS variant_norm,
    score,
    method,
    row_number() OVER (
        PARTITION BY case_id, entity_id, surface_norm
        ORDER BY score DESC, method
    ) AS rn
FROM unioned;

-- ═══════════════════════════════════════════════════════════════════════════
-- entity_groups / entity_group_members — funnel bulk-judgment grouping
-- ═══════════════════════════════════════════════════════════════════════════

-- Address groups: one group per (case_id, group_key) for full-address entities.
CREATE OR REPLACE TABLE entity_groups AS
WITH addr_roots AS (
    SELECT
        case_id,
        group_key,
        min(entity_id) AS root_entity_id,
        any_value(standardized_text) FILTER (WHERE is_full_address) AS preferred_label,
        any_value(standardized_text) AS any_label,
        'address_std' AS group_kind
    FROM entity_address_canon
    WHERE is_full_address
       OR (street_number IS NOT NULL AND street_name IS NOT NULL)
    GROUP BY case_id, group_key
),
-- Person groups: root = entity_id; expand via fuzzy pairs (union-find lite: min id)
person_link AS (
    SELECT case_id, entity_id_a AS entity_id, entity_id_b AS linked_id, score
    FROM _name_variant_pairs
    UNION ALL
    SELECT case_id, entity_id_b, entity_id_a, score
    FROM _name_variant_pairs
),
person_root AS (
    SELECT
        r.case_id,
        r.entity_id,
        least(
            r.entity_id,
            coalesce(
                (SELECT min(least(p.entity_id, p.linked_id))
                 FROM person_link p
                 WHERE p.case_id = r.case_id
                   AND (p.entity_id = r.entity_id OR p.linked_id = r.entity_id)),
                r.entity_id
            )
        ) AS root_entity_id,
        r.roster_name
    FROM _roster_persons r
),
person_groups AS (
    SELECT
        case_id,
        'person:' || cast(root_entity_id AS VARCHAR) AS group_key,
        root_entity_id,
        max(roster_name) AS preferred_label,
        max(roster_name) AS any_label,
        'person_fuzz' AS group_kind
    FROM person_root
    GROUP BY case_id, root_entity_id
)
SELECT
    row_number() OVER (ORDER BY case_id, group_kind, group_key)::INTEGER AS group_id,
    case_id,
    group_key,
    root_entity_id,
    coalesce(preferred_label, any_label) AS canonical_label,
    group_kind
FROM (
    SELECT case_id, group_key, root_entity_id, preferred_label, any_label, group_kind
    FROM addr_roots
    UNION ALL BY NAME
    SELECT case_id, group_key, root_entity_id, preferred_label, any_label, group_kind
    FROM person_groups
) g;

CREATE OR REPLACE TABLE entity_group_members AS
-- Address: every entity_address_canon row whose group_key maps to a group
WITH addr_m AS (
    SELECT
        g.group_id,
        g.case_id,
        g.group_kind,
        g.canonical_label,
        c.entity_id,
        c.raw_text AS variant_text,
        100.0 AS score,
        'addrust_entity' AS method,
        c.is_full_address,
        (c.entity_id = g.root_entity_id) AS is_canonical
    FROM entity_groups g
    JOIN entity_address_canon c
      ON c.case_id = g.case_id
     AND c.group_key = g.group_key
    WHERE g.group_kind = 'address_std'
),
-- Address: suggestion / partial text variants under the same std key
addr_var AS (
    SELECT
        g.group_id,
        g.case_id,
        g.group_kind,
        g.canonical_label,
        v.entity_id,
        v.variant_text,
        100.0 AS score,
        'addrust_variant' AS method,
        v.is_full_address,
        false AS is_canonical
    FROM entity_groups g
    JOIN _address_text_variants v
      ON v.case_id = g.case_id
     AND v.group_key = g.group_key
    WHERE g.group_kind = 'address_std'
      AND NOT EXISTS (
          SELECT 1 FROM addr_m m
          WHERE m.group_id = g.group_id
            AND lower(trim(m.variant_text)) = lower(trim(v.variant_text))
      )
),
-- Person: each roster entity as member of its fuzzy group
person_m AS (
    SELECT
        g.group_id,
        g.case_id,
        g.group_kind,
        g.canonical_label,
        r.entity_id,
        r.roster_name AS variant_text,
        100.0 AS score,
        'entity' AS method,
        NULL::BOOLEAN AS is_full_address,
        (r.entity_id = g.root_entity_id) AS is_canonical
    FROM entity_groups g
    JOIN _roster_persons r
      ON r.case_id = g.case_id
     AND r.entity_id = g.root_entity_id
    WHERE g.group_kind = 'person_fuzz'
    UNION ALL BY NAME
    -- Linked entities (other near-match entity rows)
    SELECT
        g.group_id,
        g.case_id,
        g.group_kind,
        g.canonical_label,
        r.entity_id,
        r.roster_name AS variant_text,
        coalesce(p.score, 100.0) AS score,
        'entity_pair' AS method,
        NULL::BOOLEAN AS is_full_address,
        false AS is_canonical
    FROM entity_groups g
    JOIN _name_variant_pairs p
      ON p.case_id = g.case_id
     AND (p.entity_id_a = g.root_entity_id OR p.entity_id_b = g.root_entity_id)
    JOIN _roster_persons r
      ON r.entity_id = CASE
            WHEN p.entity_id_a = g.root_entity_id THEN p.entity_id_b
            ELSE p.entity_id_a
         END
    WHERE g.group_kind = 'person_fuzz'
),
-- Person: surface spellings (suggestion / word bigram near-matches)
person_var AS (
    SELECT
        g.group_id,
        g.case_id,
        g.group_kind,
        g.canonical_label,
        v.entity_id,
        v.variant_text,
        v.score,
        'rapidfuzz:' || v.method AS method,
        NULL::BOOLEAN AS is_full_address,
        false AS is_canonical
    FROM entity_groups g
    JOIN _name_surface_variants v
      ON v.case_id = g.case_id
     AND v.entity_id = g.root_entity_id
     AND v.rn = 1
    WHERE g.group_kind = 'person_fuzz'
)
SELECT
    row_number() OVER (
        ORDER BY group_id, is_canonical DESC, score DESC, variant_text
    )::INTEGER AS member_id,
    group_id,
    case_id,
    group_kind,
    canonical_label,
    entity_id,
    variant_text,
    score,
    method,
    is_full_address,
    is_canonical
FROM (
    SELECT * FROM addr_m
    UNION ALL BY NAME SELECT * FROM addr_var
    UNION ALL BY NAME SELECT * FROM person_m
    UNION ALL BY NAME SELECT * FROM person_var
) m;

CREATE OR REPLACE VIEW v_entity_groups AS
SELECT
    g.group_id,
    g.case_id,
    g.group_key,
    g.root_entity_id,
    g.canonical_label,
    g.group_kind,
    (SELECT count(*) FROM entity_group_members m WHERE m.group_id = g.group_id) AS member_count,
    (SELECT count(DISTINCT m.variant_text)
     FROM entity_group_members m WHERE m.group_id = g.group_id) AS variant_count
FROM entity_groups g;

CREATE OR REPLACE VIEW v_entity_group_members AS
SELECT * FROM entity_group_members;

-- ═══════════════════════════════════════════════════════════════════════════
-- Cover mask + remainder geometry
-- ═══════════════════════════════════════════════════════════════════════════

-- Cover mask: accepted OR pending suggestion boxes (already on the review path).
CREATE OR REPLACE TABLE _cover_boxes AS
SELECT
    s.id AS suggestion_id,
    s.document_id,
    s.page_no,
    s.x0, s.y0, s.x1, s.y1
FROM v_suggestions s
WHERE s.status IN ('accepted', 'pending');

-- Any existing suggestion box (any status) — residual is for misses, not re-queue.
CREATE OR REPLACE TABLE _suggestion_boxes AS
SELECT
    s.id AS suggestion_id,
    s.document_id,
    s.page_no,
    s.x0, s.y0, s.x1, s.y1,
    s.text,
    s.status
FROM v_suggestions s;

-- Words not covered by an accepted/pending redaction (literal remainder).
CREATE OR REPLACE TABLE _remainder_words AS
SELECT
    w.document_id,
    d.case_id,
    w.page_no,
    w.seq,
    w.word,
    -- Strip trailing/leading punctuation for pattern checks; keep raw for display.
    regexp_replace(w.word, '^[^A-Za-z0-9@]+|[^A-Za-z0-9@]+$', '') AS token,
    w.x0, w.y0, w.x1, w.y1
FROM words w
JOIN documents d ON d.id = w.document_id
WHERE NOT EXISTS (
    SELECT 1
    FROM _cover_boxes a
    WHERE a.document_id = w.document_id
      AND a.page_no = w.page_no
      AND NOT (w.x1 <= a.x0 OR w.x0 >= a.x1 OR w.y1 <= a.y0 OR w.y0 >= a.y1)
);

-- Same-line n-grams over the remainder (1–8 grams: names, SSN, addresses).
CREATE OR REPLACE TABLE _remainder_grams AS
WITH base AS (
    SELECT
        document_id,
        case_id,
        page_no,
        seq,
        word,
        token,
        x0, y0, x1, y1,
        lead(word, 1)  OVER win AS word1,
        lead(token, 1) OVER win AS token1,
        lead(x1, 1)    OVER win AS x1_1,
        lead(y0, 1)    OVER win AS y0_1,
        lead(y1, 1)    OVER win AS y1_1,
        lead(word, 2)  OVER win AS word2,
        lead(token, 2) OVER win AS token2,
        lead(x1, 2)    OVER win AS x1_2,
        lead(y0, 2)    OVER win AS y0_2,
        lead(y1, 2)    OVER win AS y1_2,
        lead(word, 3)  OVER win AS word3,
        lead(token, 3) OVER win AS token3,
        lead(x1, 3)    OVER win AS x1_3,
        lead(y0, 3)    OVER win AS y0_3,
        lead(y1, 3)    OVER win AS y1_3,
        lead(word, 4)  OVER win AS word4,
        lead(token, 4) OVER win AS token4,
        lead(x1, 4)    OVER win AS x1_4,
        lead(y0, 4)    OVER win AS y0_4,
        lead(y1, 4)    OVER win AS y1_4,
        lead(word, 5)  OVER win AS word5,
        lead(token, 5) OVER win AS token5,
        lead(x1, 5)    OVER win AS x1_5,
        lead(y0, 5)    OVER win AS y0_5,
        lead(y1, 5)    OVER win AS y1_5,
        lead(word, 6)  OVER win AS word6,
        lead(token, 6) OVER win AS token6,
        lead(x1, 6)    OVER win AS x1_6,
        lead(y0, 6)    OVER win AS y0_6,
        lead(y1, 6)    OVER win AS y1_6,
        lead(word, 7)  OVER win AS word7,
        lead(token, 7) OVER win AS token7,
        lead(x1, 7)    OVER win AS x1_7,
        lead(y0, 7)    OVER win AS y0_7,
        lead(y1, 7)    OVER win AS y1_7
    FROM _remainder_words
    WINDOW win AS (PARTITION BY document_id, page_no ORDER BY seq)
)
-- 1-grams
SELECT
    document_id, case_id, page_no, seq, 1 AS n,
    token AS text_norm, word AS text_raw,
    x0, y0, x1, y1
FROM base
WHERE token IS NOT NULL AND token <> ''
UNION ALL
-- 2-grams (full name misspellings: "Norene Kuze"), same line only
SELECT
    document_id, case_id, page_no, seq, 2,
    token || ' ' || token1,
    word || ' ' || word1,
    x0, y0, x1_1, greatest(y1, y1_1)
FROM base
WHERE token1 IS NOT NULL AND token1 <> '' AND abs(y0_1 - y0) < 2
UNION ALL
-- 3-grams (spaced SSN: ddd dd dddd), same line only
SELECT
    document_id, case_id, page_no, seq, 3,
    token || ' ' || token1 || ' ' || token2,
    word || ' ' || word1 || ' ' || word2,
    x0, y0, x1_2, greatest(y1, y1_1, y1_2)
FROM base
WHERE token1 IS NOT NULL AND token2 IS NOT NULL
  AND abs(y0_1 - y0) < 2 AND abs(y0_2 - y0) < 2
UNION ALL
-- 4–8 grams for address windows (standardizer needs multi-token locality)
SELECT
    document_id, case_id, page_no, seq, 4,
    token || ' ' || token1 || ' ' || token2 || ' ' || token3,
    word || ' ' || word1 || ' ' || word2 || ' ' || word3,
    x0, y0, x1_3, greatest(y1, y1_1, y1_2, y1_3)
FROM base
WHERE token3 IS NOT NULL
  AND abs(y0_1 - y0) < 2 AND abs(y0_2 - y0) < 2 AND abs(y0_3 - y0) < 2
UNION ALL
SELECT
    document_id, case_id, page_no, seq, 5,
    token || ' ' || token1 || ' ' || token2 || ' ' || token3 || ' ' || token4,
    word || ' ' || word1 || ' ' || word2 || ' ' || word3 || ' ' || word4,
    x0, y0, x1_4, greatest(y1, y1_1, y1_2, y1_3, y1_4)
FROM base
WHERE token4 IS NOT NULL
  AND abs(y0_1 - y0) < 2 AND abs(y0_2 - y0) < 2
  AND abs(y0_3 - y0) < 2 AND abs(y0_4 - y0) < 2
UNION ALL
SELECT
    document_id, case_id, page_no, seq, 6,
    token || ' ' || token1 || ' ' || token2 || ' ' || token3 || ' ' || token4 || ' ' || token5,
    word || ' ' || word1 || ' ' || word2 || ' ' || word3 || ' ' || word4 || ' ' || word5,
    x0, y0, x1_5, greatest(y1, y1_1, y1_2, y1_3, y1_4, y1_5)
FROM base
WHERE token5 IS NOT NULL
  AND abs(y0_1 - y0) < 2 AND abs(y0_2 - y0) < 2 AND abs(y0_3 - y0) < 2
  AND abs(y0_4 - y0) < 2 AND abs(y0_5 - y0) < 2
UNION ALL
SELECT
    document_id, case_id, page_no, seq, 7,
    token || ' ' || token1 || ' ' || token2 || ' ' || token3 || ' ' || token4
        || ' ' || token5 || ' ' || token6,
    word || ' ' || word1 || ' ' || word2 || ' ' || word3 || ' ' || word4
        || ' ' || word5 || ' ' || word6,
    x0, y0, x1_6, greatest(y1, y1_1, y1_2, y1_3, y1_4, y1_5, y1_6)
FROM base
WHERE token6 IS NOT NULL
  AND abs(y0_1 - y0) < 2 AND abs(y0_2 - y0) < 2 AND abs(y0_3 - y0) < 2
  AND abs(y0_4 - y0) < 2 AND abs(y0_5 - y0) < 2 AND abs(y0_6 - y0) < 2
UNION ALL
SELECT
    document_id, case_id, page_no, seq, 8,
    token || ' ' || token1 || ' ' || token2 || ' ' || token3 || ' ' || token4
        || ' ' || token5 || ' ' || token6 || ' ' || token7,
    word || ' ' || word1 || ' ' || word2 || ' ' || word3 || ' ' || word4
        || ' ' || word5 || ' ' || word6 || ' ' || word7,
    x0, y0, x1_7, greatest(y1, y1_1, y1_2, y1_3, y1_4, y1_5, y1_6, y1_7)
FROM base
WHERE token7 IS NOT NULL
  AND abs(y0_1 - y0) < 2 AND abs(y0_2 - y0) < 2 AND abs(y0_3 - y0) < 2
  AND abs(y0_4 - y0) < 2 AND abs(y0_5 - y0) < 2 AND abs(y0_6 - y0) < 2
  AND abs(y0_7 - y0) < 2;

-- ═══════════════════════════════════════════════════════════════════════════
-- Detect residual PII: regex + rapidfuzz + finetype + address standardizer
-- Staged CTAS (not one giant CTE): DuckDB's planner otherwise cross-applies
-- detectors/correlated NOT EXISTS against 600k+ grams and never finishes.
-- ═══════════════════════════════════════════════════════════════════════════

-- (a) Regex detectors
CREATE OR REPLACE TABLE _residual_regex AS
SELECT
    g.document_id,
    g.page_no,
    g.seq,
    g.n,
    g.text_norm AS text,
    g.x0, g.y0, g.x1, g.y1,
    CASE
        WHEN g.n = 3 AND regexp_matches(g.text_norm, '^[0-9]{3} [0-9]{2} [0-9]{4}$')
            THEN 'SSN'
        WHEN g.n = 1 AND regexp_matches(g.text_norm, '^[0-9]{3}-[0-9]{2}-[0-9]{4}$')
            THEN 'SSN'
        WHEN g.n = 1 AND regexp_matches(g.text_norm, '^[0-9]{3}\.[0-9]{2}\.[0-9]{4}$')
            THEN 'SSN'
        WHEN g.n = 1 AND regexp_matches(g.text_norm, '^[0-9]{3}\.[0-9]{3}\.[0-9]{4}$')
            THEN 'PHONE'
        WHEN g.n = 1 AND regexp_matches(g.text_norm, '^[0-9]{3}-[0-9]{3}-[0-9]{4}$')
            THEN 'PHONE'
        WHEN g.n = 1 AND regexp_matches(g.text_norm, '^\([0-9]{3}\)[0-9]{3}-[0-9]{4}$')
            THEN 'PHONE'
        WHEN g.n = 1 AND regexp_matches(g.text_norm, '^\([0-9]{3}\)[ ]?[0-9]{3}-[0-9]{4}$')
            THEN 'PHONE'
        WHEN g.n = 1 AND regexp_matches(g.text_norm, '^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$')
            THEN 'EMAIL'
        ELSE NULL
    END AS kind,
    CASE
        WHEN g.n = 3 AND regexp_matches(g.text_norm, '^[0-9]{3} [0-9]{2} [0-9]{4}$')
            THEN 'regex: spaced SSN (ddd dd dddd)'
        WHEN g.n = 1 AND regexp_matches(g.text_norm, '^[0-9]{3}-[0-9]{2}-[0-9]{4}$')
            THEN 'regex: dashed SSN'
        WHEN g.n = 1 AND regexp_matches(g.text_norm, '^[0-9]{3}\.[0-9]{2}\.[0-9]{4}$')
            THEN 'regex: dotted SSN'
        WHEN g.n = 1 AND regexp_matches(g.text_norm, '^[0-9]{3}\.[0-9]{3}\.[0-9]{4}$')
            THEN 'regex: dotted phone'
        WHEN g.n = 1 AND regexp_matches(g.text_norm, '^[0-9]{3}-[0-9]{3}-[0-9]{4}$')
            THEN 'regex: dashed phone'
        WHEN g.n = 1 AND regexp_matches(g.text_norm, '^\([0-9]{3}\)[0-9]{3}-[0-9]{4}$')
            THEN 'regex: parenthesized phone (compact)'
        WHEN g.n = 1 AND regexp_matches(g.text_norm, '^\([0-9]{3}\)[ ]?[0-9]{3}-[0-9]{4}$')
            THEN 'regex: parenthesized phone'
        WHEN g.n = 1 AND regexp_matches(g.text_norm, '^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$')
            THEN 'regex: email'
        ELSE NULL
    END AS why,
    'regex' AS detector,
    NULL::DOUBLE AS score,
    NULL::INTEGER AS entity_id
FROM _remainder_grams g
WHERE (
       (g.n = 3 AND regexp_matches(g.text_norm, '^[0-9]{3} [0-9]{2} [0-9]{4}$'))
    OR (g.n = 1 AND regexp_matches(g.text_norm, '^[0-9]{3}-[0-9]{2}-[0-9]{4}$'))
    OR (g.n = 1 AND regexp_matches(g.text_norm, '^[0-9]{3}\.[0-9]{2}\.[0-9]{4}$'))
    OR (g.n = 1 AND regexp_matches(g.text_norm, '^[0-9]{3}\.[0-9]{3}\.[0-9]{4}$'))
    OR (g.n = 1 AND regexp_matches(g.text_norm, '^[0-9]{3}-[0-9]{3}-[0-9]{4}$'))
    OR (g.n = 1 AND regexp_matches(g.text_norm, '^\([0-9]{3}\)[0-9]{3}-[0-9]{4}$'))
    OR (g.n = 1 AND regexp_matches(g.text_norm, '^\([0-9]{3}\)[ ]?[0-9]{3}-[0-9]{4}$'))
    OR (g.n = 1 AND regexp_matches(g.text_norm, '^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$'))
);

-- (b) rapidfuzz: roster PERSON names vs 2-grams + surname near-miss
CREATE OR REPLACE TABLE _residual_fuzz AS
WITH fuzz_bigram AS (
    SELECT
        g.document_id,
        g.page_no,
        g.seq,
        g.n,
        g.text_norm AS text,
        g.x0, g.y0, g.x1, g.y1,
        'PERSON' AS kind,
        'rapidfuzz: roster "' || r.roster_name || '" score '
            || printf('%.1f', rapidfuzz_ratio(lower(g.text_norm), r.roster_norm)) AS why,
        'rapidfuzz' AS detector,
        rapidfuzz_ratio(lower(g.text_norm), r.roster_norm) AS score,
        r.entity_id,
        row_number() OVER (
            PARTITION BY g.document_id, g.page_no, g.seq, g.n
            ORDER BY rapidfuzz_ratio(lower(g.text_norm), r.roster_norm) DESC, r.entity_id
        ) AS rn
    FROM _remainder_grams g
    JOIN _roster_persons r
      ON r.case_id = g.case_id
    WHERE g.n = 2
      AND regexp_matches(g.text_norm, '^[A-Za-z][A-Za-z''\-]* [A-Za-z][A-Za-z''\-]*$')
      AND rapidfuzz_ratio(lower(g.text_norm), r.roster_norm) >= 85.0
      AND lower(g.text_norm) <> r.roster_norm
),
fuzz_surname AS (
    SELECT
        g.document_id,
        g.page_no,
        g.seq,
        2 AS n,
        (g_prev.token || ' ' || g.token) AS text,
        g_prev.x0 AS x0,
        g_prev.y0 AS y0,
        g.x1 AS x1,
        greatest(g_prev.y1, g.y1) AS y1,
        'PERSON' AS kind,
        'rapidfuzz: roster surname "' || r.roster_name || '" score '
            || printf('%.1f', rapidfuzz_ratio(lower(g.token), r.last_norm)) AS why,
        'rapidfuzz' AS detector,
        rapidfuzz_ratio(lower(g.token), r.last_norm) AS score,
        r.entity_id,
        row_number() OVER (
            PARTITION BY g.document_id, g.page_no, g.seq
            ORDER BY rapidfuzz_ratio(lower(g.token), r.last_norm) DESC, r.entity_id
        ) AS rn
    FROM _remainder_words g
    JOIN _remainder_words g_prev
      ON g_prev.document_id = g.document_id
     AND g_prev.page_no = g.page_no
     AND g_prev.seq = g.seq - 1
     AND abs(g_prev.y0 - g.y0) < 2
    JOIN _roster_persons r
      ON r.case_id = g.case_id
    WHERE g.token IS NOT NULL
      AND length(g.token) >= 3
      AND regexp_matches(g.token, '^[A-Za-z][A-Za-z''\-]*$')
      AND lower(g_prev.token) = r.first_norm
      AND lower(g.token) <> r.last_norm
      AND rapidfuzz_ratio(lower(g.token), r.last_norm) >= 85.0
)
SELECT document_id, page_no, seq, n, text, x0, y0, x1, y1, kind, why, detector, score, entity_id
FROM fuzz_bigram WHERE rn = 1
UNION ALL BY NAME
SELECT document_id, page_no, seq, n, text, x0, y0, x1, y1, kind, why, detector, score, entity_id
FROM fuzz_surname WHERE rn = 1;

-- (c) finetype on identifier-shaped 1-grams
CREATE OR REPLACE TABLE _residual_finetype AS
WITH finetype_raw AS (
    SELECT
        g.document_id,
        g.page_no,
        g.seq,
        g.n,
        g.text_norm AS text,
        g.x0, g.y0, g.x1, g.y1,
        ft_infer(g.text_norm) AS ft_type
    FROM _remainder_grams g
    WHERE g.n = 1
      AND (
            regexp_matches(g.text_norm, '^[0-9(].*[0-9)]$')
         OR regexp_matches(g.text_norm, '@')
      )
)
SELECT
    document_id, page_no, seq, n, text, x0, y0, x1, y1,
    CASE
        WHEN regexp_matches(ft_type, 'phone_number') THEN 'PHONE'
        WHEN regexp_matches(ft_type, 'email') THEN 'EMAIL'
        ELSE NULL
    END AS kind,
    'finetype: ' || ft_type AS why,
    'finetype' AS detector,
    NULL::DOUBLE AS score,
    NULL::INTEGER AS entity_id
FROM finetype_raw
WHERE regexp_matches(ft_type, 'phone_number|email');

-- (d) us_address_standardizer: remainder grams + under-covered page windows
-- Materialize parses first, then set-based cover/entity joins (no correlated
-- scalar subqueries — those re-scan cover/entity tables per candidate and hang).
CREATE OR REPLACE TABLE _addrust_parsed AS
WITH address_from_remainder AS (
    SELECT
        g.document_id,
        g.case_id,
        g.page_no,
        g.seq,
        g.n,
        g.text_raw AS text,
        g.x0, g.y0, g.x1, g.y1,
        addrust_parse(g.text_raw) AS a,
        'remainder' AS addr_src
    FROM _remainder_grams g
    WHERE (
            (g.n = 1 AND (
                regexp_matches(g.text_raw, '^[0-9]+ .+,.+')
             OR regexp_matches(upper(g.text_raw), '^P\.?O\.? BOX ')
            ))
         OR (g.n BETWEEN 3 AND 8 AND (
                regexp_matches(g.text_norm, '^[0-9]+ ')
             OR regexp_matches(upper(g.text_norm), '^P\.?O\.? BOX ')
            ))
          )
),
address_page_windows AS (
    SELECT
        w.document_id,
        d.case_id,
        w.page_no,
        w.seq,
        6 AS n,
        trim(concat_ws(
            ' ',
            w.word,
            lead(w.word, 1) OVER win,
            lead(w.word, 2) OVER win,
            lead(w.word, 3) OVER win,
            lead(w.word, 4) OVER win,
            lead(w.word, 5) OVER win
        )) AS text,
        w.x0,
        w.y0,
        lead(w.x1, 5) OVER win AS x1,
        greatest(
            w.y1,
            lead(w.y1, 1) OVER win,
            lead(w.y1, 2) OVER win,
            lead(w.y1, 3) OVER win,
            lead(w.y1, 4) OVER win,
            lead(w.y1, 5) OVER win
        ) AS y1,
        lead(w.word, 5) OVER win AS w5,
        lead(w.y0, 1) OVER win AS y0_1,
        lead(w.y0, 2) OVER win AS y0_2,
        lead(w.y0, 3) OVER win AS y0_3,
        lead(w.y0, 4) OVER win AS y0_4,
        lead(w.y0, 5) OVER win AS y0_5
    FROM words w
    JOIN documents d ON d.id = w.document_id
    WINDOW win AS (PARTITION BY w.document_id, w.page_no ORDER BY w.seq)
),
address_from_page AS (
    SELECT
        p.document_id,
        p.case_id,
        p.page_no,
        p.seq,
        p.n,
        p.text,
        p.x0, p.y0, p.x1, p.y1,
        addrust_parse(p.text) AS a,
        'undercover' AS addr_src
    FROM address_page_windows p
    WHERE p.w5 IS NOT NULL
      AND abs(p.y0_1 - p.y0) < 2
      AND abs(p.y0_2 - p.y0) < 2
      AND abs(p.y0_3 - p.y0) < 2
      AND abs(p.y0_4 - p.y0) < 2
      AND abs(p.y0_5 - p.y0) < 2
      AND regexp_matches(p.text, '^[0-9]+ ')
)
SELECT * FROM address_from_remainder
UNION ALL BY NAME
SELECT * FROM address_from_page;

CREATE OR REPLACE TABLE _residual_addrust AS
WITH qualified AS (
    SELECT
        p.document_id,
        p.case_id,
        p.page_no,
        p.seq,
        p.n,
        p.text,
        p.x0, p.y0, p.x1, p.y1,
        p.a,
        p.addr_src,
        upper(concat_ws(
            '|',
            coalesce(p.a.street_number, p.a.po_box, ''),
            coalesce(p.a.street_name, ''),
            coalesce(p.a.suffix, '')
        )) AS group_key
    FROM _addrust_parsed p
    WHERE (
            (p.a.street_number IS NOT NULL AND (p.a.city IS NOT NULL OR p.a.zip IS NOT NULL))
         OR (p.a.po_box IS NOT NULL AND (p.a.city IS NOT NULL OR p.a.zip IS NOT NULL))
          )
      AND NOT (
            p.a.street_number IS NULL
            AND p.a.suffix IS NOT NULL
            AND p.a.city IS NULL
            AND p.a.zip IS NULL
            AND p.a.po_box IS NULL
          )
),
-- Full-box cover: keep residual only when NO cover fully contains the box.
uncovered AS (
    SELECT q.*
    FROM qualified q
    WHERE NOT EXISTS (
        SELECT 1
        FROM _cover_boxes c
        WHERE c.document_id = q.document_id
          AND c.page_no = q.page_no
          AND c.x0 <= q.x0 + 0.5
          AND c.y0 <= q.y0 + 0.5
          AND c.x1 >= q.x1 - 0.5
          AND c.y1 >= q.y1 - 0.5
    )
),
-- Best entity match per group_key (set-based; was a correlated scalar subquery).
entity_pick AS (
    SELECT
        case_id,
        group_key,
        entity_id,
        row_number() OVER (
            PARTITION BY case_id, group_key
            ORDER BY is_full_address DESC, entity_id
        ) AS rn
    FROM entity_address_canon
),
ranked AS (
    SELECT
        u.document_id,
        u.page_no,
        u.seq,
        u.n,
        u.text,
        u.x0, u.y0, u.x1, u.y1,
        'ADDRESS' AS kind,
        'addrust: ' || u.addr_src || ' house=' || coalesce(u.a.street_number, u.a.po_box, '?')
            || ' street=' || coalesce(u.a.street_name, '')
            || ' city=' || coalesce(u.a.city, '')
            || ' zip=' || coalesce(u.a.zip, '') AS why,
        'addrust' AS detector,
        NULL::DOUBLE AS score,
        ep.entity_id,
        row_number() OVER (
            PARTITION BY u.document_id, u.page_no, round(u.x0, 1), round(u.y0, 1)
            ORDER BY u.n DESC, u.addr_src
        ) AS rn
    FROM uncovered u
    LEFT JOIN entity_pick ep
      ON ep.case_id = u.case_id
     AND ep.group_key = u.group_key
     AND ep.rn = 1
)
SELECT document_id, page_no, seq, n, text, x0, y0, x1, y1, kind, why, detector, score, entity_id
FROM ranked
WHERE rn = 1;

-- Merge + prefer regex > addrust > rapidfuzz > finetype; drop already-suggested spans
CREATE OR REPLACE TABLE residual_pii_hits AS
WITH unioned AS (
    SELECT document_id, page_no, seq, n, text, x0, y0, x1, y1, kind, why, detector, score, entity_id
    FROM _residual_regex
    WHERE kind IS NOT NULL
    UNION ALL BY NAME
    SELECT document_id, page_no, seq, n, text, x0, y0, x1, y1, kind, why, detector, score, entity_id
    FROM _residual_fuzz
    WHERE kind IS NOT NULL
    UNION ALL BY NAME
    SELECT document_id, page_no, seq, n, text, x0, y0, x1, y1, kind, why, detector, score, entity_id
    FROM _residual_finetype
    WHERE kind IS NOT NULL
    UNION ALL BY NAME
    SELECT document_id, page_no, seq, n, text, x0, y0, x1, y1, kind, why, detector, score, entity_id
    FROM _residual_addrust
    WHERE kind IS NOT NULL
),
dedup AS (
    SELECT
        u.*,
        row_number() OVER (
            PARTITION BY u.document_id, u.page_no, round(u.x0, 1), round(u.y0, 1), round(u.x1, 1), u.kind
            ORDER BY
                CASE u.detector
                    WHEN 'regex' THEN 0
                    WHEN 'addrust' THEN 1
                    WHEN 'rapidfuzz' THEN 2
                    ELSE 3
                END,
                coalesce(u.score, 0) DESC,
                u.n DESC
        ) AS rn
    FROM unioned u
    WHERE
      u.detector = 'addrust'
      OR NOT EXISTS (
        SELECT 1
        FROM _suggestion_boxes s
        WHERE s.document_id = u.document_id
          AND s.page_no = u.page_no
          AND NOT (u.x1 <= s.x0 OR u.x0 >= s.x1 OR u.y1 <= s.y0 OR u.y0 >= s.y1)
      )
)
SELECT
    row_number() OVER (
        ORDER BY document_id, page_no, y0, x0, kind
    )::INTEGER AS id,
    document_id,
    page_no AS page,
    x0, y0, x1, y1,
    text,
    kind,
    why,
    detector,
    score,
    entity_id,
    seq AS start_seq,
    n AS n_tokens
FROM dedup
WHERE rn = 1;

DROP TABLE IF EXISTS _residual_regex;
DROP TABLE IF EXISTS _residual_fuzz;
DROP TABLE IF EXISTS _residual_finetype;
DROP TABLE IF EXISTS _residual_addrust;
DROP TABLE IF EXISTS _addrust_parsed;

CREATE OR REPLACE VIEW residual_pii_candidates AS
SELECT
    id,
    document_id,
    page,
    struct_pack(x0 := x0, y0 := y0, x1 := x1, y1 := y1) AS box,
    x0, y0, x1, y1,
    text,
    kind,
    why,
    detector,
    score,
    entity_id
FROM residual_pii_hits;

-- Alias for naming consistency with other v_* views.
CREATE OR REPLACE VIEW v_residual_pii_candidates AS
SELECT * FROM residual_pii_candidates;

-- Residual FN spellings join person groups (snapshot prior members, pure CTAS).
CREATE OR REPLACE TABLE _egm_prior AS
SELECT
    group_id, case_id, group_kind, canonical_label, entity_id,
    variant_text, score, method, is_full_address, is_canonical
FROM entity_group_members;

CREATE OR REPLACE TABLE entity_group_members AS
WITH residual_m AS (
    SELECT
        g.group_id,
        g.case_id,
        g.group_kind,
        g.canonical_label,
        r.entity_id,
        r.text AS variant_text,
        coalesce(r.score, 85.0) AS score,
        'rapidfuzz:residual' AS method,
        NULL::BOOLEAN AS is_full_address,
        false AS is_canonical
    FROM residual_pii_hits r
    JOIN entity_groups g
      ON g.root_entity_id = r.entity_id
     AND g.group_kind = 'person_fuzz'
    JOIN documents d ON d.id = r.document_id AND d.case_id = g.case_id
    WHERE r.detector = 'rapidfuzz'
      AND r.entity_id IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM _egm_prior p
          WHERE p.group_id = g.group_id
            AND lower(trim(p.variant_text)) = lower(trim(r.text))
      )
)
SELECT
    row_number() OVER (
        ORDER BY group_id, is_canonical DESC, score DESC, variant_text
    )::INTEGER AS member_id,
    group_id,
    case_id,
    group_kind,
    canonical_label,
    entity_id,
    variant_text,
    score,
    method,
    is_full_address,
    is_canonical
FROM (
    SELECT * FROM _egm_prior
    UNION ALL BY NAME
    SELECT * FROM residual_m
) u;

DROP TABLE IF EXISTS _egm_prior;

DROP TABLE IF EXISTS _remainder_grams;
DROP TABLE IF EXISTS _remainder_words;
DROP TABLE IF EXISTS _cover_boxes;
DROP TABLE IF EXISTS _accepted_boxes;
DROP TABLE IF EXISTS _suggestion_boxes;
-- Keep _roster_persons for diagnostics? Drop to stay clean; groups already materialised.
DROP TABLE IF EXISTS _roster_persons;
DROP TABLE IF EXISTS _name_variant_pairs;
DROP TABLE IF EXISTS _name_surface_variants;
DROP TABLE IF EXISTS _address_text_variants;

SELECT 'remainder scan ready' AS status,
       (SELECT count(*) FROM residual_pii_hits) AS residual_n,
       (SELECT count(*) FROM residual_pii_hits WHERE kind = 'SSN') AS ssn_n,
       (SELECT count(*) FROM residual_pii_hits WHERE kind = 'PHONE') AS phone_n,
       (SELECT count(*) FROM residual_pii_hits WHERE kind = 'PERSON') AS person_n,
       (SELECT count(*) FROM residual_pii_hits WHERE kind = 'ADDRESS') AS address_n,
       (SELECT count(*) FROM residual_pii_hits WHERE detector = 'rapidfuzz') AS fuzz_n,
       (SELECT count(*) FROM residual_pii_hits WHERE detector = 'addrust') AS addrust_n,
       (SELECT count(*) FROM residual_pii_hits WHERE position('spaced' IN why) > 0) AS spaced_ssn_n,
       (SELECT count(*) FROM residual_pii_hits WHERE position('dotted' IN why) > 0) AS dotted_n,
       (SELECT count(*) FROM entity_groups) AS entity_groups_n,
       (SELECT count(*) FROM entity_group_members) AS entity_members_n,
       (SELECT count(*) FROM entity_address_canon WHERE is_full_address) AS addr_full_n;
