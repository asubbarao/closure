# Spike: webbed + crawler for Closure ingest

Isolated evaluation of DuckDB community extensions **webbed** and **crawler**
against the Closure redaction-review app. **Not wired into** `server/`,
`templates/`, `static/`, or `samples/`.

## Prerequisites

```text
DuckDB CLI ≥ 1.5.3 (this machine: v1.5.3)
osx_arm64 signed community builds (CDN HTTP 200 for v1.5.3 and v1.5.4):
  INSTALL webbed FROM community;
  INSTALL crawler FROM community;
```

## Run

From **repo root** (`/Users/aloksubbarao/personal/closure`):

```bash
# Fit 1 — multi-format HTML/XML → words-shaped tokens + PII n-gram hits
duckdb -markdown :memory: < spikes/web-ingest/01_html_xml_words.sql

# Fit 2 — URL fetch via crawler, then same parse path
# Terminal A:
python3 -m http.server 8765 --directory spikes/web-ingest/fixtures
# Terminal B:
duckdb -markdown :memory: < spikes/web-ingest/02_url_crawl.sql
```

Outputs land in `spikes/web-ingest/out/` (`words.csv`, `pii_hits.csv`,
`crawl_*.csv`, run logs).

## Files

| Path | Role |
|------|------|
| `fixtures/incident_report_24-000117.html` | Sample HTML with Magnolia Cronin PII (case 24-000117) |
| `fixtures/incident_report_24-000117.xml` | Same case as XML records export |
| `01_html_xml_words.sql` | webbed parse → `words` shape → `v_grams` PII match |
| `02_url_crawl.sql` | crawler `crawl()` → webbed extract → same pipeline |
| `out/` | Captured CSVs / run logs from a successful local run |

## Geometry contract (important)

App `words` (see `server/schema.sql`) uses **PDF point boxes** from
`read_pdf_words`. HTML/XML have **no page boxes**. This spike maps:

| Column | PDF meaning | HTML/XML spike meaning |
|--------|-------------|------------------------|
| `page_no` | PDF page | Always `1` (one logical page) |
| `x0` / `x1` | Left/right in points | Char offsets in flattened text |
| `y0` / `y1` | Top/bottom in points | Synthetic line band (`0` / `LINE_H`) |
| `font_size` | Real font size | Constant `LINE_H` placeholder |

Same-line n-grams (`abs(Δy) < 2`) still work because all tokens share `y0`.
**Export/redaction** for HTML cannot call `pdf_redact` with these coordinates —
that would need a separate HTML redaction path (selectors / char ranges).

## Crawler gotchas observed

- Default `respect_robots` + link following can hang or stall on simple fetches.
  Single-doc import: `max_depth := 0`, `respect_robots := false`, `delay := 0`.
- Upstream README `CRAWL (SELECT …) INTO …` is **not** parsed by the signed
  community build exercised here; use table function `crawl([...])`.
- Both extensions define `read_html` — avoid relying on that name when both are
  loaded; prefer crawler body + webbed `html_extract_text` scalars.

## Verdict summary

See [`docs/web-extensions-usage.md`](../../docs/web-extensions-usage.md).
Short version: **webbed multi-format = genuinely useful for suggestion/detect**;
**crawler URL import = marginal for this product** (useful only if remote HTML
sources become a real requirement).
