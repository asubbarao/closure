# Spike: spatial box overlap vs Closure AABB remainder

Isolated evaluation of DuckDB **core `spatial`** (and a light `raster` probe
documented in `docs/ext-survey-geo.md`) against Closure redaction boxes.
**Not wired into** `server/`, `templates/`, `static/`, or `samples/`.

## Prerequisites

```text
DuckDB CLI ≥ 1.5.3 (probe used v1.5.4: ~/.local/bin/duckdb154)
osx_arm64 signed core build: INSTALL spatial;
```

## Run

From **repo root**:

```bash
~/.local/bin/duckdb154 -unsigned < spikes/ext-geo/01_box_overlap.sql
```

## Files

| Path | Role |
|------|------|
| `01_box_overlap.sql` | Synthetic words + accepted boxes; AABB vs `ST_Intersects`; coverage fraction; 50k×200 microbench |

## Expected headline

- Remainder word lists **identical** (0 mismatched rows).
- Spatial not slower at 50k words × 200 boxes on this machine.
- See `docs/ext-survey-geo.md` for full multi-extension verdict (raster/h3/osmium/duckgl/cityjson mostly **no**).
