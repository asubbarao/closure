# Closure stress test — DuckDB vs. enormous PDFs

**Date:** 2026-07-19  
**Thesis:** DuckDB (streaming, cache, spill-to-disk) can handle law-enforcement-scale PDFs (1+ GB, thousands of pages) where a naive in-memory Node/Python app would OOM.  
**Goal:** Prove what works under a deliberately tight budget, and name exactly what breaks.

**Stack under test:** DuckDB v1.5.4 (`quackapi` build) + community `pdf` extension (Poppler + libharu). No Python, no typst.

**Harness:** `server/stress.sql` → `tests/stress/run.sql` (steps `00`–`07`, including failure-mode fixtures and glob scale). Isolated OOM probe: `tests/stress/break_b1_all_list.sql`. Optional huge generator: `tests/stress/01b_generate_huge.sql`. Metrics: `samples/stress/stress_metrics.csv`.

---

## Headline numbers

| Artifact | Pages | File size | How produced |
|----------|------:|----------:|--------------|
| `samples/stress/monster.pdf` (canonical) | **5,000** | **27.23 MB** | `COPY … TO … (FORMAT pdf)` · 49,000 dense body rows · font 10 · letter |
| `samples/stress/monster_20k.pdf` | **28,169** | **143.95 MB** | Same writer · denser unique body · 200,000 rows |
| `samples/stress/monster_huge.pdf` | **130,419** | **709.4 MB** | Same writer · 700,000 rows · md5-padded text |

| Probe | Budget | Result |
|-------|--------|--------|
| Generate 5k pages | 2 GB gen budget | **~0.8 s** wall · pure SQL |
| Generate 130k / 709 MB | 4 GB gen budget | **~31 s** wall · pure SQL |
| Extract 5k → `words` CTAS | **`memory_limit=512MB`**, `temp_directory=/tmp/closure_spill` | **OK** · **3,097,000** words · **~8.5–20 s** · table ~60–240 MB resident · **spill 0 B** |
| Stream `count(*)` on 28k-page / 144 MB PDF | 512 MB | **OK** · **7,856,338** words · **~96 s** · DuckDB mem ~0.25 MB after · spill 0 B |
| Materialize 28k-page words table | 512 MB | **OK** · **181 MB** `BASE_TABLE` · ~80 s · spill 0 B |
| Page-scoped words mid 5k doc (`WHERE page_no=2500`) | 512 MB | **~1–4 ms** · **630** words |
| Page-scoped `list(struct_pack(…))` (review-route shape) | 512 MB | **~1 ms** · **630** structs |
| Page-scoped `read_pdf_words(…, first_page:=N, last_page:=N)` on **709 MB** file | 512 MB | **~0.75 s** · **345** words on page 65,000 |
| `pdf_to_png(monster, 2500, 72)` | 512 MB | **~201 ms** · **2,509** byte PNG |
| `pdf_to_text` whole 5k monster | 512 MB | **OK** · **~4.8 s** · **21.5 MB** VARCHAR |
| `list(struct)` over **all 7.86M** words (28k table) | 512 MB | **OOM** — see Breaking points |
| Full-doc `list(struct)` under residual session pressure (5k) | 512 MB | **OOM** at ~488 MiB used |

---

## Verdict on the thesis

**Mostly proven — with sharp caveats.**

1. **Generation scales.** libharu `COPY (FORMAT pdf)` built **5,000 pages in under a second** and **130k pages / 709 MB in ~31 s**, entirely in DuckDB. The “hundreds of MB / thousands of pages” generation claim holds for text-layer PDFs.

2. **Extraction streams under a tight RAM budget.** With `SET memory_limit='512MB'` and `SET temp_directory='/tmp/closure_spill'`, `read_pdf_words` + CTAS completed for **5k pages / 3.1M words** and for **28k pages / 7.9M words** without DuckDB OOM and without needing measurable spill. A pure aggregate (`count(*)` / `count(DISTINCT page)`) left almost no resident table memory — evidence of streaming, not “load the whole PDF into a Python list.”

3. **The interactive render path is O(one page).** Mid-document page filters and tera-shaped `list(struct_pack(…))` stay in the **millisecond** range with **hundreds of words**, not millions. On a **709 MB / 130k-page** file, a single-page `read_pdf_words` with `first_page`/`last_page` completed in **~0.75 s**. That matches how `server/routes.sql` already scopes the review route to the current page only.

4. **What would OOM a naive app still OOMs here if you ask for the whole document in one value.** Packing **all** words into a single `list(struct)` under 512 MB dies on the **28k-page / 7.9M-word** table:

   ```text
   Out of Memory Error: failed to allocate data of size 16.0 MiB (478.3 MiB/488.2 MiB used)
   ```

   That is exactly the anti-pattern of stuffing the entire document into a tera context map. **Page-scoped lists do not fail.**

5. **Caveats (honest limits of this run):**
   - These monsters are **text-layer** PDFs (libharu). Real 1 GB LE files are often **scanned image PDFs**; that path hits OCR (`auto_ocr` / Tesseract) and is **not** what this harness measured. Expect higher CPU, different memory, and different failure modes.
   - DuckDB’s `memory_limit` does **not** fully contain **Poppler process RSS**. During large `read_pdf_words` runs, process RSS climbed to **~600–900 MB** even with `memory_limit=512MB`, while `duckdb_memory()` still reported modest BASE_TABLE usage and **0** temp spill. The budget is real for DuckDB operators; native PDF library allocations sit beside it.
   - Poppler spams **“No display font for …”** to stderr on every page open (Courier/Helvetica/Times). On multi-10k-page runs that is **tens of MB of stderr I/O** and dominates operator experience; suppress when benchmarking wall time.
   - **Full-document** `read_pdf_words` over the **130k-page / 709 MB** file did **not** finish cleanly in this run: after **~10 minutes** process RSS had climbed past **~1.0 GB** (well above the 512 MB DuckDB limit) with **no result row yet**. The job was aborted as a documented break point. By contrast, the same file with `first_page`/`last_page` (one page) returned in **~0.75 s**. So “handles 1GB-class files” is true for **page-scoped** access and for **one-shot ingest into a table at moderate page counts (≤~28k proven)**; a **naive full-document re-scan of 100k+ pages in one query** is where the stack bleeds native RSS and wall time.

**Bottom line:** The architecture thesis is **sound for the review product shape** (ingest words to a table, serve **one page** of geometry + suggestions). DuckDB handles multi-thousand-page and multi-hundred-MB **text** PDFs under 512 MB *DuckDB* budget for extract+store. The claim **fails** if any hot path builds an **all-pages** list/JSON for tera, or if operators ignore Poppler RSS and stderr cost on 100k+ page opens.

---

## What was measured (detail)

### 1. Generation (pure DuckDB)

```sql
COPY (
  SELECT format('LINE {} SSN … {}', i, …, repeat('chain of custody …', 6))
  FROM generate_series(1, 49000) t(i)
) TO 'samples/stress/monster.pdf' (
  FORMAT pdf, FONT_SIZE 10, PAGE_SIZE 'letter', FOOTER 'page {page}'
);
SELECT page_count, file_size FROM pdf_info('samples/stress/monster.pdf');
-- → 5000 pages, 28549485 bytes
```

Form-feed / row-per-page does **not** force page breaks; libharu **auto-flows** text. Page count is controlled by body volume × font size × page size.

Optional huge (same pattern, 700k rows, md5-padded lines) → `monster_huge.pdf` · **130,419 pages · 709.4 MB · ~31 s**.

### 2. Extraction under 512 MB

```sql
SET memory_limit = '512MB';
SET temp_directory = '/tmp/closure_spill';
SET preserve_insertion_order = false;

CREATE TABLE stress_words AS
SELECT page::INTEGER AS page_no, word::VARCHAR AS word, x0, y0, x1, y1, font_size
FROM read_pdf_words('samples/stress/monster.pdf');
```

| Document | Words | Pages | Wall (approx) | DuckDB table mem | Spill dir |
|----------|------:|------:|---------------|------------------|-----------|
| monster 5k (27 MB) | 3,097,000 | 5,000 | 8.5–20 s | ~60–240 MB | **0 B** |
| monster_20k (144 MB) | 7,856,338 | 28,169 | ~80–96 s | ~181 MB | **0 B** |

Spill stayed empty: the operator fit in RAM under 512 MB. The harness still sets `temp_directory` so a tighter budget or wider row (n-grams, joins) can spill instead of dying.

### 3. Page-scoped vs whole-document (render path)

Mirrors `server/routes.sql` review route (current-page words → `list(struct_pack(…))`).

| Query shape | n | wall | mem impact |
|-------------|--:|------|------------|
| `WHERE page_no = mid` | 630 | **~1–4 ms** | negligible |
| `list(struct_pack) WHERE page_no = mid` | 630 | **~1 ms** | negligible |
| `count(*)` all words | 3.1M | **~0–few ms** (table already warm) | aggregate only |
| `list(struct_pack)` **all** rows on 7.9M-word table | — | **OOM** | ~478 / 488 MiB |

On the 709 MB file, **page-bounded reader** (not full table filter):

```sql
SELECT count(*) FROM read_pdf_words(
  'samples/stress/monster_huge.pdf',
  first_page := 65000, last_page := 65000
);
-- 345 words · ~0.75 s · memory_limit 512MB
```

**Conclusion:** Renders must stay page-scoped. Whole-doc aggregates (`count`, band stats) are fine; whole-doc **value packing** is not.

### 4. Breaking points (what fails and why)

| # | Failure | Where | Why |
|---|---------|-------|-----|
| **B1** | `Out of Memory Error: failed to allocate data of size 16.0 MiB (478.3 MiB/488.2 MiB used)` | `SELECT len(list(struct_pack(...))) FROM stress_words` on **7.86M** rows under 512 MB | Builds one enormous in-memory list value — classic tera-context bomb. **Not** a `read_pdf_words` failure. |
| **B1b** | Same class of OOM under residual pressure | Full `list()` after other large tables already resident (earlier 5k session) | Session memory headroom matters; empty session can list 3.1M structs; busy session cannot. |
| **B2** | Soft limit only | Process RSS **600–900 MB** during large extracts despite `memory_limit=512MB` | Poppler/native allocations are **outside** DuckDB’s memory manager. OS OOM killer is the true ceiling if many concurrent extracts run. |
| **B3** | Operational | Multi-MB stderr from missing Type1 display fonts | Not a functional break; destroys logs and can look like hangs. |
| **B4** | Wall-time + native RSS growth | Full `read_pdf_words` + `count(*)` over **130,419 pages / 709 MB** under `memory_limit=512MB` | After **~10 min**, process RSS **>~1 GB** and still no result; aborted. Prefer **page ranges**, or **one-time CTAS** at ingest into a durable `words` table, then pure SQL. Do not re-parse 100k+ page PDFs per request. |
| **B5** | `COPY (FORMAT pdf)` rename | Concurrent writers to the same output path (`tmp_*.pdf` → final) | Extension writes via temp rename; two sessions targeting `monster.pdf` can race. Serialize generation. |
| **B6** | Not hit in this run | DuckDB spill on extract | Did not need spill for word CTAS up to ~8M rows / 181 MB table. Spill would appear under lower `memory_limit` or heavier post-processing (n-gram materialization, large hash joins). |
| **B7** | Out of scope (partial) | Scanned / image-only 1 GB PDFs | Graphics-only fixtures in `05_failure_modes.sql` return **0 words** without forced OCR; silent empty, not an error. Scanned PII is invisible to word-box redaction without OCR. |
| **B8** | Encrypted PDF | `read_pdf_words` without password | `IO Error: … is encrypted; supply the correct password via password := '...'` — one encrypted file aborts a glob ingest unless isolated/skipped. |
| **B9** | Corrupt / not-a-PDF | malformed xref, truncated, misnamed | Hard `IO Error: could not open … (corrupt or not a PDF)` or `has no readable pages` — same glob-abort risk. |
| **B10** | AcroForm fields | `pdf_redact` word box vs form `/V` | After box redaction, **form field value still holds SSN**; words may be gone. Word-box redaction ≠ form redaction. |
| **B11** | Annotations | sticky-note / comment PII | Present in `pdf_annotations.contents`, **absent** from `read_pdf_words` — invisible to word-box detection. |
| **B12** | `write_pdf` CJK | Helvetica-only writer | CJK becomes mojibake; silent wrong text, not an error. Do not plant non-Latin PII via `COPY (FORMAT pdf)`. |
| **B13** | Rotated pages | `pdf_rotate` then words | Word coords swap axes; `pdf_info` media box may still report portrait. Boxes must use **post-rotate** word geometry. |

`pdf_to_png` / `pdf_to_text` on the 5k monster **succeeded** under 512 MB (single-page PNG ~160–200 ms; full text ~4–5 s / 21 MB string). Full-text as one VARCHAR will not scale to multi-hundred-MB *text* payloads — prefer page or chunk readers.

**Harness metrics snapshot** (from a full `tests/stress/run.sql` pass, 2026-07-19): generate 5k in **753 ms**; extract CTAS **8.2 s / 3.1M words / ~241 MB / spill 0**; page list **2 ms**; plus failure-mode rows in `samples/stress/stress_metrics.csv`.

---

## Recommendations

1. **Renders must always be page-scoped**  
   Keep `routes.sql` pattern: words + suggestions for `page_no = current` only. Never `list()` the whole `words` table into tera.

2. **Set `temp_directory` (and a real `memory_limit`) in boot SQL**  
   `run.sh` currently sets `memory_limit='4GB'` and does not set `temp_directory`. For production-ish boxes:
   ```sql
   SET memory_limit = '2GB';           -- or machine-appropriate
   SET temp_directory = '/tmp/closure_spill';  -- durable, monitored disk
   SET preserve_insertion_order = false;
   ```
   (Owned by the `app.sql` / boot agent — called out here as a finding, not edited.)

3. **Ingest once, query many**  
   CTAS `words` from `read_pdf_words` at ingest (as `ingest.sql` already does). Interactive routes should hit the table, not re-parse the PDF per request. Use `first_page`/`last_page` only for ad-hoc / export tooling.

4. **Index or cluster for page filters**  
   At multi-million-word scale, ensure page filters stay cheap (physical clustering by `(document_id, page_no)` or an ART index if lookups slow down). Current mid-doc filters were ~1 ms on 3M rows — revisit after n-gram / suggestion joins.

5. **Suppress or redirect Poppler font noise in ops**  
   Benchmark and long extracts should not inherit multi-million-line stderr. Fix display font config or redirect when invoking DuckDB.

6. **Do not treat `memory_limit` as cgroup RSS**  
   Size the process limit (container/systemd) above DuckDB’s limit to leave headroom for Poppler. Concurrent extracts need isolation.

7. **Generation races**  
   Serialize `COPY TO 'same.pdf' (FORMAT pdf)` / `write_pdf` to a given path.

8. **Next stress targets (not done here)**  
   - Scanned 1 GB PDF (OCR on) under 512 MB  
   - Materialize `v_grams` over 8M words under 512 MB  
   - `pdf_redact` on 5k-page input with thousands of boxes  
   - tera_render with page-scoped maps at concurrent QPS  

---

## How to re-run

From repo root, DuckDB **1.5.4+** with unsigned extensions (same binary as `run.sh`):

```bash
mkdir -p samples/stress /tmp/closure_spill
# Primary suite (generate 5k + extract + page vs all + break probes + metrics export)
duckdb -unsigned 2>samples/stress/run.err <<'SQL'
.read tests/stress/run.sql
SQL

# Isolated full-doc list OOM (expect failure under 512MB on large tables)
duckdb -unsigned -c ".read tests/stress/break_b1_all_list.sql" \
  2>samples/stress/break_b1.err || true

# Optional: hundreds-of-MB / 100k+ pages (disk-heavy)
duckdb -unsigned <<'SQL'
.read tests/stress/00_setup.sql
.read tests/stress/01b_generate_huge.sql
SQL
```

Artifacts: `samples/stress/monster.pdf`, `samples/stress/stress_metrics.csv`, `samples/stress/stress_metrics.json`.

---

## Machine snapshot (this run)

- Host: macOS arm64  
- DuckDB: v1.5.4 (Variegata) via `/Users/aloksubbarao/personal/quackapi/build/release/duckdb`  
- Extension: `INSTALL pdf FROM community` (unsigned load)  
- Stress budget: `memory_limit=512MB`, `temp_directory=/tmp/closure_spill`, `threads=4`, `preserve_insertion_order=false`
