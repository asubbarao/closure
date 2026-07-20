# Spike: scanned / image-only PDFs + OCR

Proves the product rule: image-only pages must either **OCR into `words`**
(`source='ocr'`) or show a **visible library badge** — never silent zero suggestions.

## Layout

| Path | Role |
| --- | --- |
| `fixtures/image_only_scanned.pdf` | Real raster of case-1 incident p1 (no text layer) |
| `01_ocr_probe.sql` | Community vs capability probe |
| `02_ingest_scan.sql` | Full enrich path (ingest → pdf_io) |
| `out/` | Run logs |

## Run

From repo root:

```bash
../quackapi/build/release/duckdb -unsigned :memory: \
  -c ".read spikes/scans/01_ocr_probe.sql" | tee spikes/scans/out/01_probe.log

../quackapi/build/release/duckdb -unsigned :memory: \
  -c ".read spikes/scans/02_ingest_scan.sql" | tee spikes/scans/out/02_ingest.log
```

App path: see `docs/scanned-docs.md` (port 8134 / `/tmp/scans.db`).
