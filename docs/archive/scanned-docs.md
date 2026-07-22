# Scanned / image-only PDFs

**Owner:** `server/pdf_io.sql`, `spikes/scans/**`, this doc  
**Product rule:** never silently treat zero text-layer words as “clean.”

## Why this exists

The redaction funnel assumes `read_pdf_words` boxes. Born-digital PDFs have a
text layer; many real court files are **scans** (image-only pages). Without OCR,
those pages produce **zero words → zero suggestions → silent gap**.

## Funnel impact

| Stage | Text-layer PDF | Image-only + OCR | Image-only, no OCR |
| --- | --- | --- | --- |
| Words | `source='text'` | `source='ocr'` (confidence damped ×0.92) | none |
| Suggestions | normal seed | seed matches OCR n-grams | none — **badge required** |
| Library | no scan badge | `scanned · OCR` | `scanned — no text layer` |
| Export | boxes as usual | same geometry path | nothing to ink; human must notice badge |

## OCR assessment (this host)

| Build | How to load | `auto_ocr` / `source` / `confidence` | `has_text_layer` / `used_ocr` | Live probe on fixture |
| --- | --- | --- | --- | --- |
| **Community signed** `INSTALL pdf FROM community` | default `app.sql` | **yes** | **no** | **works** (639 OCR words) |
| **Local unsigned** `~/duckdb-read_pdf/build/release/extension/pdf/pdf.duckdb_extension` | `LOAD '…/pdf.duckdb_extension'` with `-unsigned` (same as quackapi) | yes | yes | works |

**Conclusion:** community pdf is enough for OCR words. Local build is optional for
richer page flags. Tesseract eng model must exist (Homebrew
`/opt/homebrew/share/tessdata` is auto-detected; no `TESSDATA_PREFIX` required).

Capability is probed at boot into `pdf_ocr_capability` / `pdf_ocr_available()`.

## Wiring

1. `server/ingest.sql` — CTAS documents/pages/words for `samples/*.pdf` (native).
2. `server/pdf_io.sql` (after ingest, **before** seed):
   - Probe OCR.
   - Attach `spikes/scans/fixtures/*.pdf` as documents on case 1.
   - Rebuild `words` = native (`auto_ocr:=false`) ∪ OCR (`source='ocr'`) for pages with no text layer.
   - CTAS `page_scan_status`, `document_scan_status` (+ view).
   - Routes: `GET /api/documents/:id/scan`, `GET /api/cases/:id/scan`.
   - Export macros (`boxes_lit_for_doc`, `build_export_sql`, …).
3. `server/seed.sql` — suggestions over the enriched `words` (including OCR).
4. Library: `case.html` shows `scan_badge` from `document_scan_status` via `routes/pages.sql`.

## Badge contract

| Condition | `scan_badge` | Class |
| --- | --- | --- |
| native words > 0, no OCR | `NULL` | — |
| native = 0, OCR words > 0 | `scanned · OCR` | `b-blue` |
| native = 0, OCR words = 0 | **`scanned — no text layer`** | `b-rej` |

Gap detail always explains OCR-unavailable vs blank/unreadable raster.

## Fixture

`spikes/scans/fixtures/image_only_scanned.pdf` — page-1 raster of
`samples/incident_report_2024-001001.pdf` (PIL image→PDF, no text operators).
Contains subject PII for case `24-001001` so seed produces real suggestions after OCR.

Regenerate (optional):

```bash
pdftoppm -png -r 150 -f 1 -l 1 samples/incident_report_2024-001001.pdf /tmp/incident_p1
python3 -c "from PIL import Image; Image.open('/tmp/incident_p1-1.png').save('spikes/scans/fixtures/image_only_scanned.pdf','PDF',resolution=150.0)"
```

Note: `samples/messy/image_only_scanned.pdf` is a **vector gray-rect** stress toy
(0 images, 0 OCR tokens). Do not use it as the OCR happy-path fixture.

## Spike

```text
spikes/scans/
  fixtures/image_only_scanned.pdf
  01_ocr_probe.sql
  02_ingest_scan.sql
  out/   # probe logs
  README.md
```

## Verify

```bash
rm -f /tmp/scans.db /tmp/scans.db.wal
# port 8134 (avoid clashing with default 8117)
sed 's/8117/8134/g' server/app.sql > /tmp/app_scans.sql
/Users/aloksubbarao/personal/quackapi/build/release/duckdb -unsigned /tmp/scans.db -c ".read /tmp/app_scans.sql"
```

Then:

```bash
curl -s http://127.0.0.1:8134/api/cases/1/scan | head
curl -s "http://127.0.0.1:8134/api/cases/1/documents" | head
# HTML library should show badge on image_only_scanned
curl -s http://127.0.0.1:8134/cases/1 | grep -o 'scanned[^<]*'
```
