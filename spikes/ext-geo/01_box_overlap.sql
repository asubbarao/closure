-- spikes/ext-geo/01_box_overlap.sql
-- Compare Closure's hand-rolled AABB remainder predicate vs spatial ST_*.
-- Run: duckdb154 -unsigned < spikes/ext-geo/01_box_overlap.sql
-- Or:  duckdb -unsigned < spikes/ext-geo/01_box_overlap.sql  (needs spatial installed)
--
-- Does NOT touch server/*.sql. Synthetic data only (no closure.db required).

INSTALL spatial;
LOAD spatial;

.timer off
.print === 1. Synthetic words + accepted redaction boxes (page points, top-left origin) ===

CREATE OR REPLACE TABLE words AS
SELECT * FROM (VALUES
  (1, 1, 1, 'John',        72.0, 100.0, 100.0, 112.0),
  (1, 1, 2, 'Doe',        105.0, 100.0, 130.0, 112.0),
  (1, 1, 3, 'SSN',         72.0, 130.0,  95.0, 142.0),
  (1, 1, 4, '123-45-6789',100.0, 130.0, 180.0, 142.0),
  (1, 1, 5, 'address',     72.0, 160.0, 120.0, 172.0),
  (1, 1, 6, 'visible',     72.0, 200.0, 120.0, 212.0),
  (1, 1, 7, 'partial',    150.0, 100.0, 200.0, 112.0)  -- grazes name box on the right
) t(document_id, page_no, seq, word, x0, y0, x1, y1);

CREATE OR REPLACE TABLE accepted AS
SELECT * FROM (VALUES
  (1, 1,  72.0,  98.0, 132.0, 114.0),  -- covers John+Doe
  (1, 1, 100.0, 128.0, 180.0, 144.0)   -- covers SSN digits
) t(document_id, page_no, x0, y0, x1, y1);

.print === 2. AABB remainder (exact copy of remainder_scan.sql predicate) ===

CREATE OR REPLACE TABLE aabb_remainder AS
SELECT w.*
FROM words w
WHERE NOT EXISTS (
  SELECT 1
  FROM accepted a
  WHERE a.document_id = w.document_id
    AND a.page_no = w.page_no
    AND NOT (w.x1 <= a.x0 OR w.x0 >= a.x1 OR w.y1 <= a.y0 OR w.y0 >= a.y1)
);

.print === 3. Spatial remainder via ST_Intersects(ST_MakeEnvelope(...)) ===

CREATE OR REPLACE TABLE spatial_remainder AS
SELECT w.*
FROM words w
WHERE NOT EXISTS (
  SELECT 1
  FROM accepted a
  WHERE a.document_id = w.document_id
    AND a.page_no = w.page_no
    AND ST_Intersects(
      ST_MakeEnvelope(w.x0, w.y0, w.x1, w.y1),
      ST_MakeEnvelope(a.x0, a.y0, a.x1, a.y1)
    )
);

SELECT 'aabb' AS method, list(word ORDER BY seq) AS remainder_words FROM aabb_remainder
UNION ALL
SELECT 'spatial', list(word ORDER BY seq) FROM spatial_remainder;

SELECT
  (SELECT count(*) FROM aabb_remainder) AS aabb_n,
  (SELECT count(*) FROM spatial_remainder) AS spatial_n,
  (
    SELECT count(*)
    FROM aabb_remainder a
    FULL OUTER JOIN spatial_remainder s
      USING (document_id, page_no, seq)
    WHERE a.word IS NULL OR s.word IS NULL
  ) AS mismatched_rows;

.print === 4. Extra geometry power AABB does not give: containment + coverage fraction ===

SELECT
  w.word,
  ST_Intersects(
    ST_MakeEnvelope(w.x0, w.y0, w.x1, w.y1),
    ST_MakeEnvelope(a.x0, a.y0, a.x1, a.y1)
  ) AS intersects,
  ST_Contains(
    ST_MakeEnvelope(a.x0, a.y0, a.x1, a.y1),
    ST_MakeEnvelope(w.x0, w.y0, w.x1, w.y1)
  ) AS fully_contained,
  round(
    ST_Area(ST_Intersection(
      ST_MakeEnvelope(w.x0, w.y0, w.x1, w.y1),
      ST_MakeEnvelope(a.x0, a.y0, a.x1, a.y1)
    ))
    / NULLIF(ST_Area(ST_MakeEnvelope(w.x0, w.y0, w.x1, w.y1)), 0),
    4
  ) AS coverage_frac
FROM words w
CROSS JOIN accepted a
WHERE w.word IN ('John', 'partial', 'visible')
  AND a.x0 = 72.0
ORDER BY w.seq;

.print === 5. Accepted-mask multipolygon (ST_Union_Agg) ===

SELECT
  document_id,
  page_no,
  ST_AsText(ST_Union_Agg(ST_MakeEnvelope(x0, y0, x1, y1))) AS mask_wkt,
  ST_Area(ST_Union_Agg(ST_MakeEnvelope(x0, y0, x1, y1))) AS mask_area
FROM accepted
GROUP BY 1, 2;

.print === 6. Scale microbench: 50k words x 200 boxes (same-page NOT EXISTS) ===

CREATE OR REPLACE TABLE big_words AS
SELECT
  1 AS document_id,
  1 AS page_no,
  i AS seq,
  'w' || i AS word,
  (i % 100) * 6.0 AS x0,
  (i // 100) * 12.0 AS y0,
  (i % 100) * 6.0 + 5.0 AS x1,
  (i // 100) * 12.0 + 10.0 AS y1
FROM range(50000) t(i);

CREATE OR REPLACE TABLE big_boxes AS
SELECT
  1 AS document_id,
  1 AS page_no,
  (i % 20) * 30.0 AS x0,
  (i // 20) * 60.0 AS y0,
  (i % 20) * 30.0 + 25.0 AS x1,
  (i // 20) * 60.0 + 40.0 AS y1
FROM range(200) t(i);

.timer on

SELECT count(*) AS aabb_remainder_n
FROM big_words w
WHERE NOT EXISTS (
  SELECT 1
  FROM big_boxes a
  WHERE NOT (w.x1 <= a.x0 OR w.x0 >= a.x1 OR w.y1 <= a.y0 OR w.y0 >= a.y1)
);

SELECT count(*) AS spatial_remainder_n
FROM big_words w
WHERE NOT EXISTS (
  SELECT 1
  FROM big_boxes a
  WHERE ST_Intersects(
    ST_MakeEnvelope(w.x0, w.y0, w.x1, w.y1),
    ST_MakeEnvelope(a.x0, a.y0, a.x1, a.y1)
  )
);

-- Precompute geometries once (fairer if tables persisted geometries)
CREATE OR REPLACE TABLE big_words_g AS
SELECT *, ST_MakeEnvelope(x0, y0, x1, y1) AS geom FROM big_words;

CREATE OR REPLACE TABLE big_boxes_g AS
SELECT *, ST_MakeEnvelope(x0, y0, x1, y1) AS geom FROM big_boxes;

SELECT count(*) AS spatial_prebuilt_remainder_n
FROM big_words_g w
WHERE NOT EXISTS (
  SELECT 1 FROM big_boxes_g a WHERE ST_Intersects(w.geom, a.geom)
);

.timer off
.print === done ===
