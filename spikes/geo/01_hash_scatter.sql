-- spikes/geo/01_hash_scatter.sql
-- Prove deterministic, API-free "coordinates" for address minimap dots.
-- Not real geography: city centroid anchors + stable hash jitter in a unit box.
--
-- Run from repo root:
--   duckdb -unsigned < spikes/geo/01_hash_scatter.sql
--   or: ~/.local/bin/duckdb154 -unsigned < spikes/geo/01_hash_scatter.sql

.print === 1. Static city anchors (schematic Oregon layout, unit square) ===

CREATE OR REPLACE TABLE city_anchor AS
SELECT * FROM (
    SELECT 'Portland' AS city, 'OR' AS state, 0.28 AS cx, 0.30 AS cy, 0.10 AS half UNION ALL
    SELECT 'Salem',    'OR', 0.32, 0.48, 0.09 UNION ALL
    SELECT 'Eugene',   'OR', 0.30, 0.68, 0.09 UNION ALL
    SELECT 'Bend',     'OR', 0.62, 0.52, 0.09 UNION ALL
    SELECT 'Unknown',  '',   0.50, 0.50, 0.12
);

SELECT * FROM city_anchor ORDER BY cy, cx;

.print === 2. Sample addresses (corpus-shaped) + parse city via position() ===

CREATE OR REPLACE TABLE sample_addrs AS
SELECT * FROM (
    SELECT 1 AS entity_id, 1 AS case_id, 'ADDRESS · SUBJECT' AS kind,
           '6396 Maple St, Portland, OR 97205' AS canonical_text UNION ALL
    SELECT 13, 1, 'STREET NAME · NOT PII', 'Feeney Street' UNION ALL
    SELECT 14, 2, 'ADDRESS · SUBJECT', '9045 Oakwood Dr, Salem, OR 97301' UNION ALL
    SELECT 27, 2, 'STREET NAME · NOT PII', 'Schmidt Street' UNION ALL
    SELECT 28, 3, 'ADDRESS · SUBJECT', '5139 Industrial Blvd, Eugene, OR 97401' UNION ALL
    SELECT 41, 4, 'ADDRESS · SUBJECT', '2675 River Rd, Bend, OR 97701'
);

CREATE OR REPLACE TABLE plotted AS
WITH subject_city AS (
    SELECT
        case_id,
        CASE
            WHEN position('PORTLAND' IN upper(canonical_text)) > 0 THEN 'Portland'
            WHEN position('SALEM'    IN upper(canonical_text)) > 0 THEN 'Salem'
            WHEN position('EUGENE'   IN upper(canonical_text)) > 0 THEN 'Eugene'
            WHEN position('BEND'     IN upper(canonical_text)) > 0 THEN 'Bend'
            ELSE 'Unknown'
        END AS city
    FROM sample_addrs
    WHERE position('ADDRESS' IN upper(kind)) > 0
),
enriched AS (
    SELECT
        a.entity_id,
        a.case_id,
        a.kind,
        a.canonical_text,
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
        END AS city
    FROM sample_addrs a
    LEFT JOIN subject_city sc ON sc.case_id = a.case_id
),
jitter AS (
    SELECT
        e.*,
        a.cx,
        a.cy,
        a.half,
        -- Stable pseudo-random in [-1, 1] from DuckDB hash (no geocoder).
        ((hash(e.canonical_text) % 10000) / 5000.0) - 1.0 AS jx,
        ((hash(e.canonical_text || chr(1) || 'y') % 10000) / 5000.0) - 1.0 AS jy
    FROM enriched e
    JOIN city_anchor a ON a.city = e.city
)
SELECT
    entity_id,
    case_id,
    kind,
    canonical_text,
    city,
    least(0.96, greatest(0.04, cx + jx * half)) AS map_x,
    least(0.96, greatest(0.04, cy + jy * half)) AS map_y
FROM jitter
ORDER BY case_id, entity_id;

SELECT * FROM plotted;

.print === 3. Determinism: recompute must match exactly ===

CREATE OR REPLACE TABLE plotted_again AS
SELECT * FROM plotted;  -- same definition already stable; re-run hash path:

WITH subject_city AS (
    SELECT
        case_id,
        CASE
            WHEN position('PORTLAND' IN upper(canonical_text)) > 0 THEN 'Portland'
            WHEN position('SALEM'    IN upper(canonical_text)) > 0 THEN 'Salem'
            WHEN position('EUGENE'   IN upper(canonical_text)) > 0 THEN 'Eugene'
            WHEN position('BEND'     IN upper(canonical_text)) > 0 THEN 'Bend'
            ELSE 'Unknown'
        END AS city
    FROM sample_addrs
    WHERE position('ADDRESS' IN upper(kind)) > 0
),
enriched AS (
    SELECT
        a.entity_id,
        a.case_id,
        a.kind,
        a.canonical_text,
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
        END AS city
    FROM sample_addrs a
    LEFT JOIN subject_city sc ON sc.case_id = a.case_id
),
jitter AS (
    SELECT
        e.*,
        a.cx, a.cy, a.half,
        ((hash(e.canonical_text) % 10000) / 5000.0) - 1.0 AS jx,
        ((hash(e.canonical_text || chr(1) || 'y') % 10000) / 5000.0) - 1.0 AS jy
    FROM enriched e
    JOIN city_anchor a ON a.city = e.city
),
recomputed AS (
    SELECT
        entity_id,
        least(0.96, greatest(0.04, cx + jx * half)) AS map_x,
        least(0.96, greatest(0.04, cy + jy * half)) AS map_y
    FROM jitter
)
SELECT
    count(*) AS rows_checked,
    count(*) FILTER (
        WHERE abs(p.map_x - r.map_x) > 1e-12 OR abs(p.map_y - r.map_y) > 1e-12
    ) AS mismatched
FROM plotted p
JOIN recomputed r USING (entity_id);

.print === 4. Distinct city clusters (addresses in same city share anchor) ===

SELECT city, count(*) AS n, round(avg(map_x), 3) AS avg_x, round(avg(map_y), 3) AS avg_y
FROM plotted
GROUP BY city
ORDER BY city;

.print === DONE: honest pseudo-geo for visual grouping only ===
