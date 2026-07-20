-- routes/geo.sql — address minimap (visual grouping, not real geography).
--
-- GET /api/cases/:id/addresses
--   Standardized address-like entities for a case with deterministic map_x/map_y
--   in unit square [0,1]². No geocoder, no external API, no map library.
--
-- GET /api/cases/:id/addresses/:entity_id/suggestions
--   Suggestion rows for one address entity (click-filter target).
--
-- GET /ui/geo?case=ID  — standalone panel shell (optional).
--
-- Dependencies: entities, v_suggestions, documents, app_templates.
-- Honesty: positions are city-anchor + hash jitter — label as such in the UI.

-- ── Case address dots ─────────────────────────────────────────────────────
CREATE OR REPLACE ROUTE api_case_addresses GET '/api/cases/:id/addresses' AS
WITH city_anchor AS (
    SELECT 'Portland' AS city, 0.28 AS cx, 0.30 AS cy, 0.10 AS half UNION ALL
    SELECT 'Salem',    0.32, 0.48, 0.09 UNION ALL
    SELECT 'Eugene',   0.30, 0.68, 0.09 UNION ALL
    SELECT 'Bend',     0.62, 0.52, 0.09 UNION ALL
    SELECT 'Unknown',  0.50, 0.50, 0.12
),
addr_entities AS (
    SELECT
        e.id AS entity_id,
        e.case_id,
        e.kind,
        e.canonical_text,
        CASE
            WHEN position('STREET' IN upper(e.kind)) > 0 THEN true
            ELSE false
        END AS is_street_fp
    FROM entities e
    WHERE e.case_id = $id::INTEGER
      AND (
            position('ADDRESS' IN upper(e.kind)) > 0
         OR position('STREET' IN upper(e.kind)) > 0
      )
),
subject_city AS (
    SELECT
        case_id,
        CASE
            WHEN position('PORTLAND' IN upper(canonical_text)) > 0 THEN 'Portland'
            WHEN position('SALEM'    IN upper(canonical_text)) > 0 THEN 'Salem'
            WHEN position('EUGENE'   IN upper(canonical_text)) > 0 THEN 'Eugene'
            WHEN position('BEND'     IN upper(canonical_text)) > 0 THEN 'Bend'
            ELSE 'Unknown'
        END AS city,
        CASE
            WHEN position(' OR ' IN upper(canonical_text)) > 0
              OR position(', OR' IN upper(canonical_text)) > 0 THEN 'OR'
            ELSE ''
        END AS state
    FROM addr_entities
    WHERE position('ADDRESS' IN upper(kind)) > 0
),
enriched AS (
    SELECT
        a.entity_id,
        a.case_id,
        a.kind,
        a.canonical_text,
        a.is_street_fp,
        CASE
            WHEN position('ADDRESS' IN upper(a.kind)) > 0 THEN
                CASE
                    WHEN position('PORTLAND' IN upper(a.canonical_text)) > 0 THEN 'Portland'
                    WHEN position('SALEM'    IN upper(a.canonical_text)) > 0 THEN 'Salem'
                    WHEN position('EUGENE'   IN upper(a.canonical_text)) > 0 THEN 'Eugene'
                    WHEN position('BEND'     IN upper(a.canonical_text)) > 0 THEN 'Bend'
                    ELSE 'Unknown'
                END
            ELSE coalesce(sc.city, 'Unknown')
        END AS city,
        CASE
            WHEN position('ADDRESS' IN upper(a.kind)) > 0 THEN
                CASE
                    WHEN position(' OR ' IN upper(a.canonical_text)) > 0
                      OR position(', OR' IN upper(a.canonical_text)) > 0 THEN 'OR'
                    ELSE ''
                END
            ELSE coalesce(sc.state, '')
        END AS state,
        -- ZIP when present at end of standardized subject address.
        -- regexp_extract returns '' on no match; nullif restores absent = NULL
        -- (the NULL-retaining direction, not a key trick).
        nullif(regexp_extract(a.canonical_text, '(\\d{5})$', 1), '') AS zip
    FROM addr_entities a
    LEFT JOIN subject_city sc ON sc.case_id = a.case_id
),
jitter AS (
    SELECT
        e.*,
        ca.cx,
        ca.cy,
        ca.half,
        ((hash(e.canonical_text) % 10000) / 5000.0) - 1.0 AS jx,
        ((hash(e.canonical_text || chr(1) || 'y') % 10000) / 5000.0) - 1.0 AS jy
    FROM enriched e
    JOIN city_anchor ca ON ca.city = e.city
),
stats AS (
    SELECT
        s.entity_id,
        count(*)::BIGINT AS suggestion_count,
        count(*) FILTER (WHERE s.status = 'pending')::BIGINT AS pending_count,
        count(*) FILTER (WHERE s.status = 'accepted')::BIGINT AS accepted_count,
        count(*) FILTER (WHERE s.status = 'rejected')::BIGINT AS rejected_count,
        min(s.document_id)::INTEGER AS first_document_id,
        min(s.page_no)::INTEGER AS first_page_no
    FROM v_suggestions s
    JOIN documents d ON d.id = s.document_id
    WHERE d.case_id = $id::INTEGER
      AND s.entity_id IS NOT NULL
    GROUP BY s.entity_id
)
SELECT
    j.entity_id,
    j.case_id,
    j.kind,
    j.canonical_text,
    j.city,
    j.state,
    j.zip,
    j.is_street_fp,
    least(0.96, greatest(0.04, j.cx + j.jx * j.half))::DOUBLE AS map_x,
    least(0.96, greatest(0.04, j.cy + j.jy * j.half))::DOUBLE AS map_y,
    coalesce(st.suggestion_count, 0)::BIGINT AS suggestion_count,
    coalesce(st.pending_count, 0)::BIGINT AS pending_count,
    coalesce(st.accepted_count, 0)::BIGINT AS accepted_count,
    coalesce(st.rejected_count, 0)::BIGINT AS rejected_count,
    st.first_document_id,
    st.first_page_no,
    -- Explicit honesty flag for clients / audit.
    true AS is_schematic,
    'city-anchor + hash jitter; not geocoded' AS placement_method
FROM jitter j
LEFT JOIN stats st ON st.entity_id = j.entity_id
ORDER BY j.is_street_fp, j.canonical_text, j.entity_id;

-- ── Suggestions for one address entity (filter target) ────────────────────
CREATE OR REPLACE ROUTE api_case_address_suggestions GET '/api/cases/:id/addresses/:entity_id/suggestions' AS
SELECT
    s.id,
    s.document_id,
    d.filename,
    s.page_no,
    s.x0, s.y0, s.x1, s.y1,
    s.text,
    s.context,
    s.confidence,
    s.flag_tag,
    s.reason,
    s.entity_id,
    s.source,
    s.status,
    s.band,
    s.kind,
    s.entity_text
FROM v_suggestions s
JOIN documents d ON d.id = s.document_id
WHERE d.case_id = $id::INTEGER
  AND s.entity_id = $entity_id::INTEGER
ORDER BY s.document_id, s.page_no, s.id;

-- Integration alias: same schematic address dots as /addresses.
CREATE OR REPLACE ROUTE api_case_geo GET '/api/cases/:id/geo' AS
WITH city_anchor AS (
    SELECT 'Portland' AS city, 0.28 AS cx, 0.30 AS cy, 0.10 AS half UNION ALL
    SELECT 'Salem',    0.32, 0.48, 0.09 UNION ALL
    SELECT 'Eugene',   0.30, 0.68, 0.09 UNION ALL
    SELECT 'Bend',     0.62, 0.52, 0.09 UNION ALL
    SELECT 'Unknown',  0.50, 0.50, 0.12
),
addr_entities AS (
    SELECT
        e.id AS entity_id,
        e.case_id,
        e.kind,
        e.canonical_text,
        CASE
            WHEN position('STREET' IN upper(e.kind)) > 0 THEN true
            ELSE false
        END AS is_street_fp
    FROM entities e
    WHERE e.case_id = $id::INTEGER
      AND (
            position('ADDRESS' IN upper(e.kind)) > 0
         OR position('STREET' IN upper(e.kind)) > 0
      )
),
subject_city AS (
    SELECT
        case_id,
        CASE
            WHEN position('PORTLAND' IN upper(canonical_text)) > 0 THEN 'Portland'
            WHEN position('SALEM'    IN upper(canonical_text)) > 0 THEN 'Salem'
            WHEN position('EUGENE'   IN upper(canonical_text)) > 0 THEN 'Eugene'
            WHEN position('BEND'     IN upper(canonical_text)) > 0 THEN 'Bend'
            ELSE 'Unknown'
        END AS city,
        CASE
            WHEN position(' OR ' IN upper(canonical_text)) > 0
              OR position(', OR' IN upper(canonical_text)) > 0 THEN 'OR'
            ELSE ''
        END AS state
    FROM addr_entities
    WHERE position('ADDRESS' IN upper(kind)) > 0
),
enriched AS (
    SELECT
        a.entity_id,
        a.case_id,
        a.kind,
        a.canonical_text,
        a.is_street_fp,
        CASE
            WHEN position('ADDRESS' IN upper(a.kind)) > 0 THEN
                CASE
                    WHEN position('PORTLAND' IN upper(a.canonical_text)) > 0 THEN 'Portland'
                    WHEN position('SALEM'    IN upper(a.canonical_text)) > 0 THEN 'Salem'
                    WHEN position('EUGENE'   IN upper(a.canonical_text)) > 0 THEN 'Eugene'
                    WHEN position('BEND'     IN upper(a.canonical_text)) > 0 THEN 'Bend'
                    ELSE 'Unknown'
                END
            ELSE coalesce(sc.city, 'Unknown')
        END AS city,
        CASE
            WHEN position('ADDRESS' IN upper(a.kind)) > 0 THEN
                CASE
                    WHEN position(' OR ' IN upper(a.canonical_text)) > 0
                      OR position(', OR' IN upper(a.canonical_text)) > 0 THEN 'OR'
                    ELSE ''
                END
            ELSE coalesce(sc.state, '')
        END AS state,
        -- regexp_extract '' on no match → NULL (NULL-retaining direction).
        nullif(regexp_extract(a.canonical_text, '(\\d{5})$', 1), '') AS zip
    FROM addr_entities a
    LEFT JOIN subject_city sc ON sc.case_id = a.case_id
),
jitter AS (
    SELECT
        e.*,
        ca.cx,
        ca.cy,
        ca.half,
        ((hash(e.canonical_text) % 10000) / 5000.0) - 1.0 AS jx,
        ((hash(e.canonical_text || chr(1) || 'y') % 10000) / 5000.0) - 1.0 AS jy
    FROM enriched e
    JOIN city_anchor ca ON ca.city = e.city
),
stats AS (
    SELECT
        s.entity_id,
        count(*)::BIGINT AS suggestion_count,
        count(*) FILTER (WHERE s.status = 'pending')::BIGINT AS pending_count,
        count(*) FILTER (WHERE s.status = 'accepted')::BIGINT AS accepted_count,
        count(*) FILTER (WHERE s.status = 'rejected')::BIGINT AS rejected_count,
        min(s.document_id)::INTEGER AS first_document_id,
        min(s.page_no)::INTEGER AS first_page_no
    FROM v_suggestions s
    JOIN documents d ON d.id = s.document_id
    WHERE d.case_id = $id::INTEGER
      AND s.entity_id IS NOT NULL
    GROUP BY s.entity_id
)
SELECT
    j.entity_id,
    j.case_id,
    j.kind,
    j.canonical_text,
    j.city,
    j.state,
    j.zip,
    j.is_street_fp,
    least(0.96, greatest(0.04, j.cx + j.jx * j.half))::DOUBLE AS map_x,
    least(0.96, greatest(0.04, j.cy + j.jy * j.half))::DOUBLE AS map_y,
    coalesce(st.suggestion_count, 0)::BIGINT AS suggestion_count,
    coalesce(st.pending_count, 0)::BIGINT AS pending_count,
    coalesce(st.accepted_count, 0)::BIGINT AS accepted_count,
    coalesce(st.rejected_count, 0)::BIGINT AS rejected_count,
    st.first_document_id,
    st.first_page_no,
    true AS is_schematic,
    'city-anchor + hash jitter; not geocoded' AS placement_method
FROM jitter j
LEFT JOIN stats st ON st.entity_id = j.entity_id
ORDER BY j.is_street_fp, j.canonical_text, j.entity_id;

-- ── Standalone panel page ─────────────────────────────────────────────────
CREATE OR REPLACE ROUTE ui_geo_panel GET '/ui/geo'
  PARAM case_id INTEGER DEFAULT 1
AS
SELECT tera_render(
    (SELECT content FROM app_templates WHERE name = 'geo_panel.html'),
    {
        'case_id': coalesce($case_id::INTEGER, 1),
        'case': {
            'id': coalesce($case_id::INTEGER, 1)
        },
        'standalone': true
    }::JSON
) AS html;
