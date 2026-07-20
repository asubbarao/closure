# Public court-document samples

**Owned paths:** `samples/public/**`, this file.

Real U.S. federal court / DOJ materials used to exercise the DuckDB `pdf`
extension pipeline **outside** case ingest. They are **not** wired into
`server/ingest.sql` (which globs `samples/*.pdf` only). Use a standalone
`duckdb154` session with `LOAD pdf`.

All items below are **public domain** as U.S. government works (judicial opinions
and executive-branch filings), or are a documented derivative re-packaging of
such works. Do not add copyrighted reporter headnotes, West annotations, or
PACER-only sealed material.

## Inventory

| File | Source URL | Court / case | Why chosen | Licensing / public-domain basis |
|------|------------|--------------|------------|----------------------------------|
| `scotus_25-365_trump_v_barbara.pdf` | https://www.supremecourt.gov/opinions/25pdf/25-365_4hdj.pdf | SCOTUS, *Trump v. Barbara*, No. 25-365 (slip op. 06/30/2026) | **Born-digital** Distiller slip opinion; **long** (194 pp) | U.S. Supreme Court opinion — U.S. government work; public domain |
| `scotus_24-1021_galette_v_nj_transit.pdf` | https://www.supremecourt.gov/opinions/25pdf/24-1021_p860.pdf | SCOTUS, *Galette v. New Jersey Transit Corp.*, No. 24-1021 (03/04/2026) | Born-digital short opinion (~28 pp) | U.S. Supreme Court opinion — public domain |
| `scotus_25-95_pung_v_isabella_county.pdf` | https://www.supremecourt.gov/opinions/25pdf/25-95_dc8e.pdf | SCOTUS, *Pung v. Isabella County*, No. 25-95 (06/23/2026) | Born-digital medium opinion (~31 pp) | U.S. Supreme Court opinion — public domain |
| `doj_us_v_google_complaint.pdf` | https://www.justice.gov/opa/press-release/file/1328941/download | D.D.C., *United States et al. v. Google LLC*, No. 1:20-cv-03010 (complaint, filed 10/20/2020) | DOJ civil filing; **scan-origin** (`Paper Capture` producer) with embedded OCR text layer (~64 pp) | DOJ / United States complaint — U.S. government work; public domain |
| `doj_us_v_google_sj_opinion_redacted.pdf` | https://www.justice.gov/d9/2023-10/416980.pdf | D.D.C., same case, Memorandum Opinion on Summary Judgment [Redacted] (Doc. 728, filed 10/06/2023) | District court opinion PDF published via DOJ reading room; scan-origin + OCR (~60 pp) | Federal judicial opinion published by DOJ — U.S. government work; public domain (redactions as published) |
| `govinfo_usreports_vol5.pdf` | https://www.govinfo.gov/content/pkg/USREPORTS-5/pdf/USREPORTS-5.pdf | U.S. Reports vol. 5 (Cranch) — SCOTUS terms 1801 / 1803 | **Historical long volume** (328 pp, ~34 MiB); page-image + ABBYY OCR (GovInfo) | Official U.S. Reports via GPO GovInfo — U.S. government work; public domain |
| `doj_us_v_google_complaint_imageonly_p1-5.pdf` | *Derived from* `doj_us_v_google_complaint.pdf` pp. 1–5 | Same complaint, pages 1–5 | **True image-only** packaging (no text layer) for the 0-word / OCR path | Same public-domain content as the DOJ complaint; local raster re-pack only (not a new official filing) |

### Mix summary

| Class | Files |
|-------|--------|
| Born-digital text PDFs | 3 SCOTUS slip opinions (28 / 31 / **194** pages) |
| Scan-origin + OCR text layer | DOJ Google complaint, SJ opinion, GovInfo U.S. Reports vol. 5 (**328** pages) |
| Image-only (no text layer) | Derived 5-page complaint raster PDF |

## Standalone pipeline test (not app ingest)

```sh
cd /path/to/closure
duckdb154 -c "LOAD pdf;
  SELECT regexp_extract(file, '[^/]+\$') AS file, page_count, file_size
  FROM pdf_info('samples/public/*.pdf');"

# Per file (literals only — read_pdf_words does not take lateral path columns):
duckdb154 -c "LOAD pdf;
  SELECT count(*) AS words_native
  FROM read_pdf_words('samples/public/scotus_25-365_trump_v_barbara.pdf',
                      ocr := false, auto_ocr := false);
  SELECT octet_length(pdf_to_png('samples/public/scotus_25-365_trump_v_barbara.pdf', 1, 72));"
```

**Important:** `read_pdf_words` defaults include **auto-OCR**. Image-only PDFs
can return non-zero words under the default. For a pure text-layer count, pass
`ocr := false, auto_ocr := false`.

Proof renders (page 1 @ 72 dpi) live under `samples/public/_renders/` (optional;
regenerate anytime).

## Compatibility table (honest results)

Tested with **DuckDB v1.5.4** + community `pdf` extension, 2026-07-19.
Standalone session only — **not** loaded by `server/ingest.sql`.

| File | Pages | Words (native text layer) | Words (default / auto-OCR) | `pdf_to_png` p1 | Notes |
|------|------:|--------------------------:|---------------------------:|:---------------:|-------|
| `scotus_25-365_trump_v_barbara.pdf` | 194 | 65 801 | 65 801 | OK (96 045 B) | Long born-digital; Distiller |
| `scotus_24-1021_galette_v_nj_transit.pdf` | 28 | 10 227 | 10 227 | OK (98 208 B) | Born-digital |
| `scotus_25-95_pung_v_isabella_county.pdf` | 31 | 10 062 | 10 062 | OK (91 780 B) | Born-digital |
| `doj_us_v_google_complaint.pdf` | 64 | 17 223 | 17 223 | OK (9 846 B) | Paper Capture + OCR layer; p1 PNG small (sparse page raster) |
| `doj_us_v_google_sj_opinion_redacted.pdf` | 60 | 19 713 | 19 713 | OK (83 770 B) | Paper Capture + OCR layer |
| `govinfo_usreports_vol5.pdf` | 328 | 207 361 | 207 408 | OK (381 155 B) | Historical scan + ABBYY; 3 empty pages in native extract |
| `doj_us_v_google_complaint_imageonly_p1-5.pdf` | 5 | **0** | **1 210** | OK (117 649 B) | **0 = scan** only with `ocr:=false, auto_ocr:=false`; default auto-OCR recovers text |

### Takeaways for the app

1. **Born-digital SCOTUS slips** work end-to-end: `pdf_info`, full-doc
   `read_pdf_words`, and `pdf_to_png` are solid.
2. **Long docs** (194 pp, 328 pp) extract without special handling at this size
   class; still use page ranges for interactive UI (see `docs/stress-test.md`).
3. **“Scanned” PACER/DOJ PDFs often already carry OCR text.** Native word count
   is non-zero even with OCR disabled — they are not blank image PDFs.
4. **True image-only** needs explicit `ocr := false, auto_ocr := false` to
   measure the zero-text path; default `read_pdf_words` **auto-OCRs** (~1.2k
   words on 5 pages of the complaint raster).
5. **Poppler** may log missing standard fonts (`Helvetica`, `Times-Roman`, …)
   on Distiller/PostScript-origin files; extraction and PNG still succeed.
6. Do **not** point app ingest at `samples/public/*.pdf` without reviewing
   PII / sealed content policy — these are public opinions/filings, not the
   synthetic LE sample triad.

## Re-download

```sh
mkdir -p samples/public
curl -fsSL -o samples/public/scotus_25-365_trump_v_barbara.pdf \
  'https://www.supremecourt.gov/opinions/25pdf/25-365_4hdj.pdf'
curl -fsSL -o samples/public/scotus_24-1021_galette_v_nj_transit.pdf \
  'https://www.supremecourt.gov/opinions/25pdf/24-1021_p860.pdf'
curl -fsSL -o samples/public/scotus_25-95_pung_v_isabella_county.pdf \
  'https://www.supremecourt.gov/opinions/25pdf/25-95_dc8e.pdf'
curl -fsSL -o samples/public/doj_us_v_google_complaint.pdf \
  'https://www.justice.gov/opa/press-release/file/1328941/download'
curl -fsSL -o samples/public/doj_us_v_google_sj_opinion_redacted.pdf \
  'https://www.justice.gov/d9/2023-10/416980.pdf'
curl -fsSL -o samples/public/govinfo_usreports_vol5.pdf \
  'https://www.govinfo.gov/content/pkg/USREPORTS-5/pdf/USREPORTS-5.pdf'
# Image-only derivative: rasterize pp.1–5 of the complaint into a textless PDF
# (pdftoppm + Pillow/img2pdf) — see session notes; not an official court URL.
```
