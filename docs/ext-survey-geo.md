# Geo / raster extensions vs Closure redaction (honest fit)

**Date:** 2026-07-19  
**Scope:** Can DuckDB **geo/raster** extensions help Closure’s **rendering** or
**geo-ish** features cheaply? Install what is available as **signed** builds for
**DuckDB v1.5.4 / osx_arm64**, read the function surface, judge fit against the
app’s real contracts. One spike under `spikes/ext-geo/`.

**Local probe:**

| Binary | Version |
|--------|---------|
| `~/.local/bin/duckdb154` | **v1.5.4** (Variegata) — used for INSTALL/LOAD |
| `duckdb` on PATH | v1.5.3 (same community CDN paths also HTTP 200) |

**CDN probe (`osx_arm64`):**

| Extension | Channel | v1.5.4 | v1.5.3 | LOAD on 1.5.4 |
|-----------|---------|--------|--------|----------------|
| **spatial** | core (`extensions.duckdb.org`) | 200 | 200 | **yes** |
| **raster** | community | 200 | 200 | **yes** |
| **h3** | community | 200 | 200 | **yes** |
| **osmium** | community | 200 | 200 | **yes** |
| **duckgl** | community | 200 | 200 | **yes** |
| **cityjson** | community | 200 | 200 | **yes** |
| geography (S2) | — | 404 both | 404 | n/a |

```sql
INSTALL spatial;                         -- core
INSTALL raster  FROM community;
INSTALL h3      FROM community;
INSTALL osmium  FROM community;
INSTALL duckgl  FROM community;
INSTALL cityjson FROM community;
LOAD spatial; LOAD raster; LOAD h3; LOAD osmium; LOAD duckgl; LOAD cityjson;
```

**App contracts this survey must match:**

| Plane | Reality in Closure |
|-------|--------------------|
| Page **rendering** | Pre-baked static PNGs under `pages/<filename>/pN.png`; review UI overlays CSS boxes from `x0,y0,x1,y1` (page points, **top-left** origin). `routes/pages.sql` comment: *page PNGs are static files*. |
| Word / suggestion geometry | `words` / suggestions: `(document_id, page_no, x0, y0, x1, y1)` — axis-aligned rectangles only. |
| Remainder / coverage | `server/remainder_scan.sql`: drop words that **AABB-overlap** any **accepted** box via hand-rolled separation test. |
| Export redaction | `pdf_redact` boxes; y-flip in `pdf_io.sql` (top-left → bottom-left). |
| “Geo” content | Addresses appear as **text** in documents; no map, no lat/lon store, no geocoder. |

---

## Executive verdict

| Extension | Verdict for Closure | One-liner |
|-----------|---------------------|-----------|
| **spatial** (core) | **Maybe useful (narrow)** — only for box predicates | `ST_MakeEnvelope` + `ST_Intersects` / `ST_Contains` / area-of-intersection can replace or enrich AABB remainder math. **Not** a render path. Spike shows **exact match** to current remainder predicate and fine microbench cost. |
| **raster** | **Stretch / no** for page serving | GDAL **geospatial** rasters (GeoTIFF/COG + band algebra). Can *open* a page PNG as a raster and even tile/write PNG, but you get `RT_DATACUBE` blobs, CRS pixel space, often grayscale, not a cheap substitute for static page images or `pdf_to_png`. |
| **h3** | **No** | Hex indexing of lat/lng. Zero intersection with page-point boxes. |
| **osmium** | **No** (unless you invent a map product) | Reads OSM XML/PBF → geometries. Not a geocoder; not document layout. |
| **duckgl** | **No** | deck.gl / MapLibre **map** UI (`duckgl_start` / `stop`). Wrong canvas for PDF review. |
| **cityjson** | **No** | 3D CityGML/CityJSON buildings. Pure domain mismatch. |

**Bottom line:** Almost all of this family is **true geospatial** (Earth CRS, OSM, city models, map UIs). Closure’s “geometry” is **2D page rectangles**. The **only non-stretch win** is borrowing **spatial’s planar predicates** for suggestion/word boxes. Even that is **optional polish**, not a missing capability — AABB already works and is easy to reason about. Raster does **not** cheaply replace pre-rendered PNGs.

---

## Master table (mechanism + honesty)

| Extension | What it actually is | Key API (loaded surface) | Fit to **rendering** | Fit to **box / remainder** | Fit to **addresses / maps** | Cost to adopt |
|-----------|---------------------|---------------------------|----------------------|----------------------------|-----------------------------|---------------|
| **spatial** | Core GEOS/PROJ geometry type + `ST_*` | ~194 `ST_*` names; box-relevant: `ST_MakeEnvelope`, `ST_Intersects`, `ST_Contains`, `ST_Covers`, `ST_Intersection`, `ST_Area`, `ST_Union_Agg`, `ST_Buffer`, `ST_AsText`/`GeoJSON`/`SVG`, R-tree indexes | None (vector ops, not image pipeline). `ST_AsSVG` exists but **Y-flips** relative to screen (`M 72 -100 …`) — still not the review canvas | **Yes, planar.** Envelope boxes ≡ AABB for axis-aligned rects; extra: containment, coverage fraction, unioned mask | Geocode **only if** you already have lat/lng; no address resolver | Low: one core `LOAD`; rewrite predicates carefully (origin, page partition) |
| **raster** | GDAL raster → SQL tiles + band algebra | `RT_Read`, `RT_ReadCells`, `RT_Drivers`, `RT_Cube*`, `COPY … FORMAT RASTER`; types `RT_DATACUBE`, `RT_BBOX` | **Misleading.** Reads PNG/JPEG/PDF drivers, tiles via `blocksize_*`, can `COPY` to PNG — but pipeline is **geo datacube**, not “serve page tiles to `<img>`”. Live probe on `pages/.../p3.png`: default 1-row-high strips; `blocksize 256` → 20 tiles; export sample was **8-bit grayscale** | No word-box API | Clip/burn by polygon in map CRS — wrong domain | Medium weight (GDAL), high integration cost, **no product win** |
| **h3** | Uber H3 hex grid | 75 `h3_*` (latlng↔cell, grid disk, polyfill, …) | No | No (hexes ≠ page AABB) | Only if lat/lng + density maps | Zero value here |
| **osmium** | libosmium OSM reader | `osmium_read` (+ index settings) | No | No | Ingest planet extracts; **not** “geocode this street string” | Needs OSM files + spatial; product is a map app |
| **duckgl** | Embedded map server | `duckgl_start(host,port)`, `duckgl_stop()` | MapLibre viewer ≠ PDF page viewer | No | Visualize spatial tables on a basemap | Distraction; second UI |
| **cityjson** | CityJSON / FlatCityBuf 3D | `read_cityjson*`, `read_flatcitybuf`, metadata TFs | No | No | 3D city models | None |

---

## Per-extension notes

### 1. `spatial` — the only plausible win

**Mechanism for remainder / coverage** (page points treated as a flat Cartesian plane — do **not** assign EPSG:4326):

```sql
-- Word not covered by any accepted redaction (equivalent to remainder_scan AABB):
WHERE NOT EXISTS (
  SELECT 1 FROM accepted a
  WHERE a.document_id = w.document_id AND a.page_no = w.page_no
    AND ST_Intersects(
      ST_MakeEnvelope(w.x0, w.y0, w.x1, w.y1),
      ST_MakeEnvelope(a.x0, a.y0, a.x1, a.y1)
    )
);

-- Optional upgrades AABB does not express cleanly:
-- full containment: ST_Contains(accepted_env, word_env)
-- fraction of word area under mask:
--   ST_Area(ST_Intersection(w_env, a_env)) / ST_Area(w_env)
-- merged mask: ST_Union_Agg(ST_MakeEnvelope(...)) GROUP BY document_id, page_no
```

**Equivalence:** For **axis-aligned** rectangles, `ST_Intersects(envelope, envelope)` matches the app’s

```sql
NOT (w.x1 <= a.x0 OR w.x0 >= a.x1 OR w.y1 <= a.y0 OR w.y0 >= a.y1)
```

(open/closed edge cases on exact shared boundaries are the usual geometry footgun; Closure boxes are floats from PDF words — same class of risk either way.)

**Spike evidence** (`spikes/ext-geo/01_box_overlap.sql` on duckdb **1.5.4**):

| Check | Result |
|-------|--------|
| Synthetic remainder word lists AABB vs spatial | **Identical** (`[SSN, address, visible, partial]`) |
| `mismatched_rows` | **0** |
| Extra: `coverage_frac` / `fully_contained` | Works (`John` → 1.0 contained; free text → 0) |
| Microbench 50k words × 200 boxes, remainder `count(*)` | AABB **~18 ms** real; spatial on-the-fly envelopes **~7 ms**; prebuilt geom **~4 ms** (same remainder **n=46000**) |

So spatial is **not slower** at this scale; it is also **not necessary**. Wins would be:

1. **Clearer intent** (`ST_Intersects` / `ST_Contains` vs De Morgan AABB).
2. **Coverage math** (partial redaction, “how much of this token is under ink”).
3. **Mask union** (`ST_Union_Agg`) if you ever need multipolygon masks or non-rect future boxes.
4. Optional **R-tree** index on a persisted `GEOMETRY` column if box counts explode (current caseloads are nowhere near needing this).

**Non-wins / pitfalls:**

- Does **not** replace CSS overlays or `pdf_redact` box packing.
- `ST_AsSVG` is not a free “draw redaction UI” path (Y sign flip; still need HTML/CSS).
- Do not mix page-point geometry with geographic CRS functions / spheroid area.
- Always **partition by `document_id, page_no`** — geometry alone has no page.

**Recommendation:** Keep AABB as default. If remainder/coverage logic grows (partial coverage thresholds, multi-box dissolve, non-rect marks), **then** `LOAD spatial` and store optional `geom` columns. Not a priority ship item.

---

### 2. `raster` — looks like “images in SQL”; is not a page server

**What it is good at:** GeoTIFF/COG mosaics, NDVI-style band algebra, polygon clip/burn, pixel stats, write via GDAL drivers.

**What Closure needs for rendering:** Serve (or generate) **document page images** for `<img src="/pages/.../pN.png">`, optionally tiled for huge pages.

**Live probe** (evidence log page PNG, ~229 KB, 850-wide):

| Call | Observation |
|------|-------------|
| `RT_Read(path)` | Returns many tiles with **1-row** strips, pixel CRS `POLYGON((0 0, 850 0, …))`, band type **`RT_DATACUBE`** — not PNG bytes. |
| `RT_Read(..., blocksize_x:=256, blocksize_y:=256)` | **20** tiles (256×256-ish). |
| `COPY … FORMAT RASTER DRIVER 'PNG'` (one tile) | Produced a **256×256 8-bit grayscale** PNG — format conversion / band semantics, not a transparent drop-in for the RGB page image. |
| Drivers include PNG, JPEG, PDF, GTiff, COG, MEM | Existence of a PNG driver ≠ HTTP image pipeline. |

**Why not use it for tiling huge pages?**

1. **Already have** static PNG + browser; PDF path is `pdf` extension (`pdf_to_png`), not GDAL.
2. Raster path forces **datacube** encoding; you still must re-encode and HTTP-serve.
3. Default geo assumptions (origin, nodata, single-band) fight document RGB pages.
4. “Huge page” problem in Closure is more **queue/DOM** (suggestion cap in `render_document`) than multi-megapixel image tiling.
5. Cost: GDAL in-process is the opposite of **cheap** compared to `read_file` / static mount.

**Verdict:** **Stretch.** Do not route page serving through `raster`. If someday you do satellite/scan analysis *as maps*, revisit; for redaction review, no.

---

### 3. `h3` — pure geo index

Hierarchical hex cells from **lat/lng**. No mapping from page points without inventing a fake globe. **No Closure use.**

---

### 4. `osmium` — OSM files, not geocoding

`osmium_read` loads `.osm` / `.pbf` into geometries (pair with `spatial`). Catalog fantasies about “addresses in documents geocoded” would require:

1. Extract address strings from text (already a NLP/regex problem).
2. **Geocode** against a database or API (osmium does not do this).
3. Plot on a map (duckgl) — a different product.

**Verdict:** **No** for redaction review. Fun for a side “where do our cases cluster?” dashboard only after a real geocoder exists.

---

### 5. `duckgl` — map SPA, wrong UI

```sql
SELECT duckgl_start('localhost', 8080);  -- deck.gl + MapLibre
SELECT duckgl_stop();
```

Closure’s review surface is a **document canvas** with keyboard inbox (`static/review.js`). A basemap viewer does not help box overlay, bulk accept, or export. **No.**

---

### 6. `cityjson` — 3D cities

`read_cityjson` / `read_cityjsonseq` / `read_flatcitybuf` + metadata helpers. Domain is buildings/terrain LOD. **No intersection** with PDF redaction.

---

## Spike

**Path:** `spikes/ext-geo/01_box_overlap.sql`  
**Run (from repo root):**

```bash
~/.local/bin/duckdb154 -unsigned < spikes/ext-geo/01_box_overlap.sql
# or any ≥1.5.3 with core spatial installable:
duckdb -unsigned < spikes/ext-geo/01_box_overlap.sql
```

**What it proves:**

1. AABB remainder ≡ `ST_Intersects(ST_MakeEnvelope…)` on synthetic page boxes.
2. Spatial adds **containment** and **coverage fraction** without hand-rolled intersection area.
3. `ST_Union_Agg` builds a multipolygon mask of accepted boxes.
4. At 50k×200, spatial is not a performance regression.

**What it does *not* claim:** production rewrite of `remainder_scan.sql`, R-tree necessity, or any rendering improvement.

---

## Decision checklist

| Idea | Ship? | Why |
|------|-------|-----|
| Replace AABB remainder with `ST_Intersects` | **Optional later** | Equivalent; readability / coverage features only |
| Persist `GEOMETRY` on words/suggestions | **Only if** spatial ops expand | Extra type + page partitioning discipline |
| Partial-coverage residual detection | **Maybe** | Spatial area ratio is the clean expression |
| Serve page images via `raster` / GDAL tiles | **No** | Wrong abstraction; static PNG + `pdf` already fit |
| Geocode document addresses (osmium/h3/duckgl) | **No** (product stretch) | No geocoder; map UI is not the review app |
| cityjson anything | **No** | Domain mismatch |

---

## If it’s all a stretch

Most of the geo family **is** a stretch for Closure. Honest summary:

- **raster, h3, osmium, duckgl, cityjson:** do not help redaction **rendering** or review cheaply; they solve Earth-map problems.
- **spatial:** the **one** extension that maps onto an existing app concept (boxes as geometries). The win is **real but small** — nicer predicates and coverage math for remainder/scan quality, not a rendering breakthrough, and **not required** while boxes stay axis-aligned rectangles and AABB remains correct.

Prefer investing in detection quality, export correctness, and UI performance over GDAL/map stacks.
