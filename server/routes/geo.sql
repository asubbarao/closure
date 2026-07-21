-- routes/geo.sql — address minimap (schematic, not real geography).
-- city-anchor + hash jitter; addrust_parse for city/state/zip (no string hacks).
-- Routes: /api/cases/:id/addresses, /geo, /addresses/:entity_id/suggestions, /ui/geo.
-- Params VARCHAR (case_no / uuid). Shared body lives in v_address_map once.

-- Address minimap placement + suggestion tallies per entity (set-based GROUP BY).
-- Consumers: /api/cases/:id/addresses, /api/cases/:id/geo.
CREATE OR REPLACE VIEW v_address_map AS
WITH city_anchor AS (
    SELECT * FROM (VALUES
        ('Portland', 0.28, 0.30, 0.10),
        ('Salem',    0.32, 0.48, 0.09),
        ('Eugene',   0.30, 0.68, 0.09),
        ('Bend',     0.62, 0.52, 0.09),
        ('Unknown',  0.50, 0.50, 0.12)
    ) AS t(city, cx, cy, half)
),
addr AS (
    SELECT
        e.id AS entity_id,
        e.case_id,
        e.kind,
        e.canonical_text,
        position('STREET' IN upper(e.kind)) > 0 AS is_street_fp,
        addrust_parse(e.canonical_text) AS parsed
    FROM entities e
    WHERE position('ADDRESS' IN upper(e.kind)) > 0
       OR position('STREET'  IN upper(e.kind)) > 0
),
resolved AS (
    SELECT
        a.entity_id, a.case_id, a.kind, a.canonical_text, a.is_street_fp,
        ca.city AS parsed_city,
        a.parsed.state AS parsed_state,
        a.parsed.zip  AS parsed_zip
    FROM addr a
    LEFT JOIN city_anchor ca
      ON upper(ca.city) = upper(a.parsed.city) AND ca.city <> 'Unknown'
),
-- STREET-only rows inherit a case-level subject city when they lack locality.
case_city AS (
    SELECT case_id,
           any_value(parsed_city)  AS city,
           any_value(parsed_state) AS state
    FROM resolved
    WHERE NOT is_street_fp AND parsed_city IS NOT NULL
    GROUP BY case_id
),
placed AS (
    SELECT
        r.entity_id, r.case_id, r.kind, r.canonical_text, r.is_street_fp,
        coalesce(r.parsed_city, cc.city, 'Unknown') AS city,
        coalesce(r.parsed_state, cc.state, '') AS state,
        r.parsed_zip AS zip,
        a.cx, a.cy, a.half,
        ((hash(r.canonical_text) % 10000) / 5000.0) - 1.0 AS jx,
        ((hash(r.canonical_text || chr(1) || 'y') % 10000) / 5000.0) - 1.0 AS jy
    FROM resolved r
    LEFT JOIN case_city cc ON cc.case_id = r.case_id
    JOIN city_anchor a ON a.city = coalesce(r.parsed_city, cc.city, 'Unknown')
),
stats AS (
    SELECT
        s.entity_id,
        count(*) AS suggestion_count,
        count(*) FILTER (WHERE s.status = 'pending')  AS pending_count,
        count(*) FILTER (WHERE s.status = 'accepted') AS accepted_count,
        count(*) FILTER (WHERE s.status = 'rejected') AS rejected_count,
        min(s.document_id) AS first_document_id,
        min(s.page_no)     AS first_page_no
    FROM v_suggestions s
    WHERE s.entity_id IS NOT NULL
    GROUP BY s.entity_id
)
SELECT
    p.entity_id, p.case_id, p.kind, p.canonical_text,
    p.city, p.state, p.zip, p.is_street_fp,
    least(0.96, greatest(0.04, p.cx + p.jx * p.half)) AS map_x,
    least(0.96, greatest(0.04, p.cy + p.jy * p.half)) AS map_y,
    coalesce(st.suggestion_count, 0) AS suggestion_count,
    coalesce(st.pending_count, 0)    AS pending_count,
    coalesce(st.accepted_count, 0)   AS accepted_count,
    coalesce(st.rejected_count, 0)   AS rejected_count,
    st.first_document_id,
    st.first_page_no,
    true AS is_schematic,
    'city-anchor + hash jitter; not geocoded' AS placement_method
FROM placed p
LEFT JOIN stats st ON st.entity_id = p.entity_id;

CREATE OR REPLACE ROUTE api_case_addresses GET '/api/cases/:id/addresses' AS
SELECT * FROM v_address_map
WHERE case_id = $id
ORDER BY is_street_fp, canonical_text, entity_id;

CREATE OR REPLACE ROUTE api_case_geo GET '/api/cases/:id/geo' AS
SELECT * FROM v_address_map
WHERE case_id = $id
ORDER BY is_street_fp, canonical_text, entity_id;

CREATE OR REPLACE ROUTE api_case_address_suggestions GET '/api/cases/:id/addresses/:entity_id/suggestions' AS
SELECT
    s.id, s.document_id, d.filename, s.page_no,
    s.bbox.x0 AS x0, s.bbox.y0 AS y0, s.bbox.x1 AS x1, s.bbox.y1 AS y1,
    s.text, s.context, s.confidence, s.flag_tag, s.reason,
    s.entity_id, s.source, s.status, s.band, s.kind, s.entity_text
FROM v_suggestions s
JOIN documents d ON d.id = s.document_id
WHERE d.case_id = $id
  AND s.entity_id = $entity_id
ORDER BY s.document_id, s.page_no, s.id;

CREATE OR REPLACE ROUTE ui_geo_panel GET '/ui/geo'
  PARAM case_id VARCHAR DEFAULT ''
AS
SELECT tera_render(
    (SELECT content FROM app_templates WHERE name = 'geo_panel.html'),
    {
        'case_id': $case_id,
        'case': { 'id': $case_id },
        'standalone': true
    }::JSON
) AS html;
