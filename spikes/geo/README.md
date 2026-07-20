# Spike: address minimap without a geocoder

**Question:** Can we plot case addresses as a useful **dot map** with **no external
geocoding API** and **no heavy map library**?

**Answer:** Yes — as a **visual grouping aid**, not as real geography. Ship it
labeled that way. Do not claim map accuracy.

## What we use

| Input | Source |
|-------|--------|
| Address text | `entities` (`ADDRESS · *`, `STREET NAME · *`) |
| City cluster | substring parse of city names present in the corpus (OR cities) |
| Dot position | static city anchor in a unit square + **deterministic hash jitter** |
| Render | inline SVG (app design tokens) |

No `h3`, `osmium`, `duckgl`, or geocoding — see `docs/ext-survey-geo.md`. Those
extensions need real lat/lng or OSM extracts; we have neither at ingest time.

## Honesty

- Dots **do not** sit on true street coordinates.
- Same-city addresses **cluster** (useful for batch judgment); street-level
  placement is **stable noise** so dots do not stack.
- STREET NAME entities inherit the **case subject’s city** so FP street names
  sit near the subject address for that case.
- UI copy must say **“Visual grouping — not real geography.”**

## Run

```bash
# from repo root
duckdb -unsigned < spikes/geo/01_hash_scatter.sql
```

Expect: zero `mismatched` rows on recompute; Portland/Salem/Eugene/Bend
clusters at distinct anchors.

## Product wiring

| Path | Role |
|------|------|
| `server/routes/geo.sql` | `GET /api/cases/:id/addresses` |
| `server/templates/geo_panel.html` | dashboard panel shell |
| `static/geo.js` | SVG dots + click → filter entity / jump bulk |
