# PDF pipeline stress report

**Date:** 2026-07-19  
**Harness:** `tests/stress/` (DuckDB SQL only + community `pdf`)  
**Binary:** DuckDB **v1.5.4** (`duckdb154`) — required for full API (`pdf_info`, `pdf_encrypt`, `pdf_redact`, …).  
**Artifacts:** `samples/stress/`, metrics at `samples/stress/stress_metrics.csv`  
**Spill dir:** `/tmp/closure_spill`  
**Budgets under test:** `memory_limit='512MB'` (extract path); `256MB` (tera-bomb OOM); process RSS measured separately with `/usr/bin/time -l`.

This document answers: **exactly where and why PDF handling fails** for Closure’s design rationale.

---

## Headline scale numbers

| Artifact / op | Pages | Bytes | Wall | DuckDB pool (`duckdb_memory`) | Spill | Process max RSS | Verdict |
|---|---:|---:|---:|---:|---:|---:|---|
| **Generate** `monster.pdf` via `COPY … (FORMAT pdf)` | **5 000** | **27.2 MiB** | **0.75 s** | ~1 MiB | **0** | n/a | **OK** |
| **Generate** `monster_huge.pdf` (optional `01b`) | **130 419** | **709.4 MiB** | ~minutes (prior run) | gen uses 4 GB budget | 0 | n/a | **OK** (disk-heavy) |
| **`pdf_info(monster)`** under 512 MB | 5 000 | 27.2 MiB | ~1 ms | ~2 MiB | 0 | small | **OK** |
| **CTAS `read_pdf_words(monster)`** under 512 MB | 5 000 | → **3 097 000** words | **8.2 s** | **~241 MiB** | **0** | (fits in pool) | **OK — no spill, no OOM** |
| **`pdf_to_png(monster, page=2500, dpi=72)`** under 512 MB | 1 page | 2 509 B PNG | **~0.16 s** | residual ~241 MiB (table still live) | 0 | small delta | **OK** (O(page)) |
| **`pdf_redact` 1 box on monster page 2500** | 5 000 out rows | writes smoke PDF | **0.31 s** | ~242 MiB | 0 | n/a | **OK** |
| **`pdf_info(monster_huge)` + page-1 words + png** (fresh process, 512 MB limit) | 130 419 | 709.4 MiB | **2.27 s real** | DuckDB reports ~few–260 MiB | 0 | **~791 MiB** (829 243 392 B) | **“OK” in SQL, fails size-guard thesis** |
| **Page-scoped `list(struct)` mid page** | 630 words | — | ~2 ms | ~242 MiB | 0 | n/a | **OK — review-route shape** |
| **`list(struct)` ALL 3.1M words @ 256 MB** | 5 000 | — | fail | 208.9 / 244.1 MiB used | 0 | ~431 MiB | **OOM** (tera bomb) |
| **Same @ 512 MB** | 5 000 | — | often succeeds | borderline | 0 | ~577 MiB | **Do not rely on 512 MB for full-doc lists** |

### Does it stream + spill, or OOM?

For the **5k-page / 27 MiB** monster under **`memory_limit=512MB`**:

1. **Full word CTAS succeeds** without DuckDB spill (`spill_mb=0`). Resident pool ~**241 MiB** for 3.1M word rows.
2. **Page-scoped render shape is cheap** (filter + `list(struct)` one page ≈ ms).
3. **Spill does not appear** for this corpus because the working set fits the 512 MB pool. Spill would matter for larger intermediates (n-gram joins, full-doc lists), not for the PDF open itself.
4. For **~709 MiB / 130k-page** files: **`memory_limit` does not cap native Poppler open cost**. Fresh-process **max RSS ≈ file size + ~80 MiB** even when only `pdf_info` + one page of words + one PNG run. DuckDB’s buffer-pool accounting can stay “under 512 MB” while the **process** is ~**791 MiB**. **There is no streaming open** of huge PDFs through this extension path.

**Implication:** Closure can claim “handles multi-thousand-page digital PDFs under 512 MB” for **ingest of ~30 MiB class files** and **page-scoped UI**. It **cannot** claim “handles 1 GB PDFs under 512 MB RAM” for any op that **opens** the file in-process.

---

## Glob / multi-file ingest scaling

Corpus from pure DuckDB: `mid100.pdf` (131 pages), `glob5/` (5), `glob20/` (20), `glob/` (40 small PDFs).

| Scenario | Files | Words (CTAS) | Wall | DuckDB pool after | Verdict |
|---|---:|---:|---:|---:|---|
| 1 × mid100 | 1 | 68 662 | **244 ms** | ~251 MiB | OK |
| glob5 | 5 | 635 | **6 ms** | ~251 MiB | OK |
| glob20 | 20 | 2 540 | **22 ms** | ~253 MiB | OK |
| glob40 | 40 | 41 080 | **165 ms** | ~259 MiB | OK |
| `pdf_info('samples/stress/*.pdf')` | 16 | 175 626 pages (includes huge) | ~0 (cached session) | ~259 MiB | OK in SQL; **RSS dominated by largest file** |

**Verdict:** For **small multi-file globs**, wall time is roughly linear in file count / word yield. The danger is not “40 tiny PDFs”; it is **one huge file inside a glob** (`samples/*.pdf` including a 700 MiB case file) — open cost ≈ that file’s size in RSS, and a **single corrupt/encrypted member aborts the whole scan** (see failures below).

---

## Scenario → result → verdict

| # | Scenario | What we did | Result | Verdict for Closure |
|---|---|---|---|---|
| S1 | Multi-k page generate | `COPY (SELECT …) TO monster.pdf (FORMAT pdf)` | 5 000 pages / 27 MiB in 0.75 s | **Supported** for synthetic digital PDFs |
| S2 | ~0.7 GB / 130k pages generate | `01b_generate_huge.sql` | 130 419 pages / 709 MiB | **Supported** to write; **not** safe to open under tight RAM |
| S3 | Full `read_pdf_words` CTAS @ 512 MB | ingest-shaped CTAS on monster | 3.1M words, 8.2 s, pool 241 MiB, spill 0 | **OK** for this size class |
| S4 | Page-scoped words + PNG @ 512 MB | `first_page`/`last_page`, `pdf_to_png` | Fast, O(page) output size | **Required pattern for UI** |
| S5 | Full-doc `list(struct)` @ 256 MB | tera-context anti-pattern | **OOM** at ~209/244 MiB | **Hard fail** — never pack all words into render context |
| S6 | Full-doc `list(struct)` @ 512 MB | same | Often succeeds on 5k corpus | **Borderline — not a safety guarantee** |
| S7 | Open 709 MiB PDF @ 512 MB limit | `pdf_info` + 1 page words + png | SQL ok; **RSS ~791 MiB** | **Size guard must use file size, not DuckDB pool** |
| S8 | Glob 1→40 files | `read_pdf_words('…/glob*.pdf')` | Near-linear wall for small files | **OK** if each file is small |
| F1 | Encrypted PDF | `pdf_encrypt` then `read_pdf_words` w/o password | **IO Error:** encrypted; supply `password := '…'` | **Ingest aborts**; need pre-check / prompt / skip |
| F2 | Encrypted + correct password | `password := 's3cret'` | Words extract OK; `is_encrypted=true` | Supported **if password known** |
| F3 | No text layer (empty / graphics-only) | raw PDF content stream empty or draw-only | **`read_pdf_words` → 0 rows**, silent; OCR also 0 without real image text | **Silent miss** — needs OCR/vision path for scans |
| F4 | Truncated PDF | incomplete objects | **IO Error:** corrupt or not a PDF | One bad file can kill a glob ingest |
| F5 | Not-a-PDF named `.pdf` | plain text file | Same hard **IO Error** | Validate before glob CTAS |
| F6 | Malformed xref / broken pages tree | bad catalog | **IO Error:** no readable pages | Same |
| F7 | CJK / non-Latin via `write_pdf` | JP/ZH/KR mixed with ASCII | **Silent mojibake**; ASCII survives; no error | `write_pdf`/Helvetica **cannot** round-trip CJK; real third-party PDFs with embedded fonts may still work |
| F8 | Rotated 90° | `pdf_rotate` then `read_pdf_words` | Word count preserved; **coords axes swap**; `pdf_info` width×height still media box | Redact boxes **must** come from post-rotate words |
| F9 | AcroForm field PII | `pdf_form_fields` + `pdf_redact` box | Field `/V` **still present after redaction**; words may clear | **Word-box redact ≠ form-value redact** |
| F10 | Annotation / sticky-note PII | `pdf_annotations.contents` | Contents **not** in `read_pdf_words` | **Invisible to detection** unless annotations scanned |
| F11 | `pdf_to_text` whole monster | scalar VARCHAR | ~21 MB string in ~4 s under 512 MB | Works here; **avoid** as default ingest (huge VARCHAR) |

---

## Honest “this can’t do PDFs if X” list

Closure’s word-box pipeline (`read_pdf_words` → suggestions → `pdf_redact` boxes) **cannot correctly handle a case if**:

1. **The PDF is encrypted and no password is supplied**  
   Hard error; can abort multi-file ingest.

2. **The page is image-only / scanned with no text layer**  
   Zero words, no error. PII on the scan is invisible. Extension *can* OCR when Tesseract models + real raster text exist (`ocr` / `auto_ocr`), but empty/graphics-only fixtures produced **0 OCR words** here — scans need a real OCR path and acceptance of OCR error rates.

3. **PII lives only in AcroForm field values**  
   `pdf_form_fields` sees them; `pdf_redact` on geometry **does not clear `/V`**. Residual PII in the form dictionary after “successful” redaction.

4. **PII lives only in annotations / comments**  
   `pdf_annotations.contents` holds it; `read_pdf_words` does not. Missed by detection and by box redaction.

5. **You need reliable CJK (or other non-Latin) from `write_pdf` / `COPY FORMAT pdf`**  
   Helvetica path → mojibake. (Third-party PDFs with embedded CID fonts are a different story — not disproven here.)

6. **You open a multi-hundred-MB / ~1 GB PDF inside the interactive serve process under a tight RAM budget**  
   Process RSS tracks **file size**, not `memory_limit`. Spill does not help Poppler open.

7. **You materialize all words into one list for HTML/tera** under the quackapi **256 MB** serve default  
   Reproduced OOM: `failed to allocate 64.0 MiB (208.9 MiB/244.1 MiB used)`.

8. **A glob ingest includes one corrupt/truncated member without isolation**  
   Whole statement fails; no partial progress unless you pre-validate file-by-file.

9. **You assume `pdf_info` width/height reflect visual rotation**  
   Media box can stay letter while word coords already reflect rotate — box math can be wrong if you mix sources.

10. **You treat DuckDB `memory_limit` as a process RSS cap**  
    It is a **buffer-pool** cap. Native extension allocations (Poppler) sit outside it.

---

## Coordinate / geometry notes (for design)

- Observed `read_pdf_words` on libharu output: **y increases downward** (first line y≈47, second y≈61) — consistent with Closure’s schema comment (top-left style for layout), not raw PDF bottom-left intuition.
- Extension docs claim bottom-left user space; **Closure must keep using word boxes as returned**, and convert to `pdf_redact` `(page,x,y,w,h)` in **one** place (export), never re-derive from media-box folklore.
- After `pdf_rotate(90)`, min(x) jumps (~54 → ~722) while word count is stable — always re-extract words after structural transforms.

---

## Recommendations

### Product / pipeline

1. **OCR fallback** for pages with `count(words)=0` but `pdf_to_png` / `pdf_images` non-empty: run `read_pdf_words(..., ocr := true)` (or `auto_ocr`) with tessdata present; surface “OCR-derived” confidence in UI. Do not claim coverage for scans without this.
2. **Form + annotation passes** at ingest: union PII candidates from `pdf_form_fields` and `pdf_annotations` with word hits. Export must **clear or flatten form values**, not only paint black boxes.
3. **Encryption gate:** `pdf_info` / meta `is_encrypted` before ingest; prompt for password or quarantine. Never put password PDFs in a blind `samples/*.pdf` glob on the serve process.
4. **Streaming rules:**  
   - UI: page-scoped SQL only (`WHERE page_no = ?`, `first_page`/`last_page`, `pdf_to_png` one page).  
   - Ingest: chunk large files by page ranges into `words`; never `list()` the full table for HTML.  
   - Export: treat `pdf_redact` of huge originals as **batch**, not request-path, when `file_size ≳ available RAM`.
5. **Size guards (hard):**  
   - Refuse interactive open/redact when `file_size > min(memory_limit, host_budget) * 0.5` (or a fixed ceiling, e.g. 100–200 MiB for demo hosts).  
   - Guard is on **`file_size`**, not DuckDB pool usage.  
   - Glob ingest: sum sizes or max size pre-check.
6. **Corrupt-file isolation:** `pdf_info` / open per file in a loop (or extension `ignore_errors` where available on multi-file reads) so one truncated PDF does not zero the case.
7. **CJK:** do not use `write_pdf` for non-Latin evidence generation; for production, require embedded fonts in source PDFs and add a smoke test that known CJK tokens survive `read_pdf_words`.
8. **Serve memory:** quackapi’s 256 MB default is hostile to full-doc ops; keep post-serve raise **and** page-scoped routes so a regression cannot reintroduce the tera bomb.

### How to re-run

```bash
cd /Users/aloksubbarao/personal/closure
mkdir -p samples/stress/{fail,glob,glob5,glob20} /tmp/closure_spill
# overwrite of COPY FORMAT pdf can fail if target exists — remove first
rm -f samples/stress/monster.pdf samples/stress/mid100.pdf
duckdb154 -unsigned 2>samples/stress/run.err <<'SQL'
.read tests/stress/run.sql
SQL

# Isolated OOM (256MB)
duckdb154 -unsigned -c ".read tests/stress/break_b1_all_list.sql" \
  2>samples/stress/break_b1.err || true

# Optional huge generate + budget probe
# duckdb154 -unsigned -c ".read tests/stress/00_setup.sql" \
#   -c ".read tests/stress/01b_generate_huge.sql" \
#   -c ".read tests/stress/02b_huge_budget.sql"
```

Metrics: `samples/stress/stress_metrics.csv` / `.json`.

---

## Harness map

| File | Role |
|---|---|
| `tests/stress/00_setup.sql` | `LOAD pdf`, metrics table, mem/spill macros |
| `tests/stress/01_generate.sql` | ≥5k-page `monster.pdf` |
| `tests/stress/01b_generate_huge.sql` | optional ~700 MiB / 130k pages |
| `tests/stress/01c_generate_folder.sql` | mid100 + glob{,5,20} corpora |
| `tests/stress/02_extract.sql` | info / CTAS / page range / png @ 512 MB |
| `tests/stress/02b_huge_budget.sql` | huge open probes under 512 MB |
| `tests/stress/03_page_vs_all.sql` | page list vs full-doc anti-pattern |
| `tests/stress/04_break.sql` | png / text / redact / deferred OOM |
| `tests/stress/05_failure_modes.sql` | encrypt, empty, corrupt, CJK, rotate, forms, annotations |
| `tests/stress/06_glob_scale.sql` | 1/5/20/40 file ingest timing |
| `tests/stress/07_export_metrics.sql` | CSV + JSON metrics |
| `tests/stress/break_b1_all_list.sql` | isolated 256 MB full-list OOM |
| `tests/stress/run.sql` | full suite entrypoint |

---

## Bottom line

| Claim | Evidence |
|---|---|
| Multi-thousand-page **digital** PDFs can be generated and word-extracted under 512 MB | **Yes** — 5k pages / 3.1M words / ~241 MiB pool / 0 spill |
| Page-scoped review (words + PNG) is O(page) | **Yes** |
| Full-doc word lists under serve-default 256 MB | **OOM** |
| ~1 GB / 130k-page class opens under 512 MB process budget | **No** — RSS ≈ file size (~791 MiB for 709 MiB file) |
| DuckDB spill saves huge PDF open | **No** — spill is for query operators, not Poppler |
| Pipeline is complete for scans, forms, annotation PII, encrypted globs | **No** — each is a concrete failure mode above |

These limits are the design rationale for: **page-scoped SQL**, **file-size guards**, **OCR + form/annotation side channels**, and **batch (not request-path) treatment of huge `pdf_redact`**.
