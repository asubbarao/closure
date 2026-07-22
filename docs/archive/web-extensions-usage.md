# webbed + crawler vs Closure redaction review

**Date:** 2026-07-19  
**Scope:** Honest fit assessment of DuckDB community extensions **webbed** and
**crawler** for the Closure app at this repo. Spikes only under
`spikes/web-ingest/` — **no** edits to `server/*.sql`, `templates/`, `static/`,
or `samples/`.

**Local DuckDB:** `v1.5.3` (osx_arm64)  
**Signed community builds (CDN `community-extensions.duckdb.org`):**

| Extension | v1.5.3 osx_arm64 | v1.5.4 osx_arm64 |
|-----------|------------------|------------------|
| webbed    | HTTP 200         | HTTP 200         |
| crawler   | HTTP 200         | HTTP 200         |

```sql
INSTALL webbed FROM community;   -- verified LOAD
INSTALL crawler FROM community;  -- verified LOAD
```

---

## Extension surface (what they actually do)

### webbed

Markup **parse / extract / convert** — not an HTTP client.

| Function (used or relevant) | Role |
|-----------------------------|------|
| `html_extract_text(html [, xpath])` | Text nodes; **1-arg form concatenates with no spaces** — always use XPath `//text()` + `array_to_string(..., ' ')` for tokenization |
| `html_to_duck_blocks(html)` | Structured block list (headings, paragraphs, lists, inlines) — good side-channel, **not** word boxes |
| `html_extract_links` / `html_extract_images` / `html_extract_tables` | Structure scrape |
| `xml_to_json` / `xml_extract_text` / `xml_extract_all_text` | XML plane |
| `read_html` / `read_xml` / `parse_html*` / `parse_xml*` | File/string → table or typed markup |

**Not present:** `html_to_json` (only `xml_to_json` + `html_to_duck_blocks`).

### crawler

SQL-native **HTTP crawl + HTML payload** — not a layout engine.

| Function | Role |
|----------|------|
| `crawl([...], max_depth, respect_robots, timeout, delay, …)` | Fetch URLs → `url, status, content_type, html.document, …` |
| `crawl_url(url, …)` | Per-row LATERAL fetch (same payload idea) |
| `jq` / `htmlpath` / `read_html` | Extraction helpers (overlap/confusion with webbed names) |
| `sitemap` | Sitemap expand |

**Not available in this signed build:** parser statement `CRAWL (SELECT …) INTO …`
from upstream README (syntax error). Use `crawl()` table function.

**Operational gotcha:** defaults that respect robots + follow links can stall;
single-document import needs `max_depth := 0`, `respect_robots := false`, short
`timeout` / `delay := 0`.

---

## App contract being matched

From `server/schema.sql` / `server/ingest.sql`, the detection pipeline hangs off:

```text
words(document_id, page_no, seq, word, x0, y0, x1, y1, font_size)
  → v_grams (1–4 consecutive same-line tokens, abs(Δy) < 2)
  → suggestion seeding / remainder scan / review UI boxes
```

PDF geometry is **page points**, top-left origin (`read_pdf_words`). Export uses
those boxes with `pdf_redact`. Any non-PDF ingest must either:

1. Emulate enough geometry for **text matching** only, and accept that
   **visual redaction/export** needs another path; or  
2. Invent a parallel position model (char ranges, CSS selectors) end-to-end.

---

## Fit 1 — Multi-format documents (HTML / XML)

### Verdict: **genuinely useful** (for detect/suggest; partial for full product)

### Mechanism

1. Load fixture with `read_text` (table function → `content`).
2. **HTML:** `html_extract_text(raw::HTML, '//text()')` → `array_to_string(..., ' ')`.
3. **XML:** `xml_extract_text(raw, '//text()')` → same join (or `xml_to_json` for
   structured fields).
4. Tokenize with `regexp_extract_all(..., '[^[:space:]]+')` + ordinality.
5. Emit **synthetic geometry**:
   - `page_no = 1`
   - `x0`/`x1` = cumulative char offsets in flattened text
   - `y0 = 0`, `y1 = LINE_H` so same-line n-grams keep working
6. Reuse the app’s `qnorm` + `v_grams` matcher against identity-catalog phrases.

Optional side-channels (not substitutes for `words`):

- `html_to_duck_blocks` — outline / block kinds (spike showed headings + narrative
  paragraphs; `<dl>` subject fields were **not** fully promoted to blocks).
- `xml_to_json` — field-oriented XML exports.

### Spike result (`spikes/web-ingest/01_html_xml_words.sql`)

| Format | Words extracted | Notes |
|--------|----------------:|-------|
| HTML   | 91              | Title + body text nodes; char span ~0–612 |
| XML    | 38              | Element text only; char span ~0–276 |

**PII / plant hits** (same n-gram matcher as the app):

| Format | Hit | Example position (x0–x1, y0=0) |
|--------|-----|--------------------------------|
| HTML | PERSON · SUBJECT `Magnolia Cronin` ×2 | 124–139, 286–301 |
| HTML | SSN `271-72-1446` ×2 | 169–180, 340–351 |
| HTML | DOB `08/16/1979` ×1 | 154–164 |
| HTML | PERSON · WITNESS `Marques Cruickshank` | 386–405 |
| HTML | STREET plant `Cronin Street` | 512–525 |
| XML | Same entity types hit (name, SSN, DOB, witness, street plant) | (see `out/pii_hits.csv`) |

**Did not match as whole phrases (honest limits):**

- **Full address** — token count &gt; 4 after whitespace split; app n-grams max at 4
  (same ceiling as PDF path).
- **Phone `(613) 235-3301`** — tokenization + `qnorm` leave a `)` residue on the
  catalog form vs split tokens (`613` + `235-3301`); not a webbed bug.

**Coordinate difference from PDF (do not paper over):**

| | PDF | HTML/XML spike |
|--|-----|----------------|
| Position meaning | Ink boxes on a page | Char offsets in a 1D text stream |
| Multi-page | Real `page_no` | Forced to `1` |
| UI overlay | Scale boxes to page PNG | No page image; would need HTML highlight |
| Export | `pdf_redact` boxes | **Cannot** reuse PDF export with these coords |

### Recommendation

| Integrate? | How (roughly) |
|------------|----------------|
| **Yes — optional ingest path**, if multi-format is a product goal | Add `source_kind` (`pdf` \| `html` \| `xml`) on `documents`. Branch ingest: PDF stays `read_pdf_words`; HTML/XML run the webbed flatten + char-offset words. Detection/seed reuse `v_grams` as-is. |
| **Review UI** | PDF page renderer path stays default. HTML needs a text/HTML viewer + span highlights by char range (or map ranges back to DOM via a richer offset model later). |
| **Export** | PDF redaction unchanged. HTML redaction = rewrite/mask source markup (or emit redacted plain text) — **separate work**, not “feed synthetic boxes to pdf_redact”. |
| **Do not** | Pretend `x0/y0` are layout boxes or that `html_to_duck_blocks` alone is a words table. |

**Why genuine, not force-fit:** Closure’s value is suggestion/review on **tokens +
entities**. webbed cleanly supplies tokens from HTML/XML inside DuckDB with no
Python soup. The stretch is **visual redaction**, not detection.

---

## Fit 2 — URL / source import (crawler)

### Verdict: **marginal** for Closure as it exists today

### Mechanism

1. Serve or point at a document URL.
2. `crawl([url], max_depth := 0, respect_robots := false, delay := 0, …)` →
   `html.document`.
3. Hand body to the **same webbed tokenize path** as Fit 1.
4. Store `source_path` / `source_url` on the document row.

### Spike result (`spikes/web-ingest/02_url_crawl.sql`)

Local fixture server (`python3 -m http.server 8765` on `fixtures/`):

| Field | Value |
|-------|-------|
| URL | `http://127.0.0.1:8765/incident_report_24-000117.html` |
| status | 200 |
| content_type | `text/html` |
| html_bytes | 1267 |
| words | **91** (identical pipeline to local HTML file) |
| PII | name ×2, SSN ×2, DOB ×1 — same hits as Fit 1 HTML |

Confirmed: crawler is a **fetch front-end**; all semantic value still comes from
webbed (or crawler’s own `jq`/`htmlpath`, which we did not need).

### Why marginal (not “no”)

| Argument for | Argument against |
|--------------|------------------|
| Pure-SQL remote ingest if agencies publish HTML case files | Product is a **local PDF review** take-home; samples are files under `samples/` |
| Robots/delay/workers useful for bulk site harvest | Single-file import is one GET — `http_client` / `httpfs` / shell `curl` already cover that with less machinery |
| Structured extras (readability, schema.org) | Closure does not need SPA hydration / product schema |
| | Operational footguns (hangs with default robots/follow; dual `read_html`) |

### Recommendation

| Integrate? | How (roughly) |
|------------|----------------|
| **Leave as documented capability** unless a concrete “import from URL” requirement appears | If it does: thin route `POST /import?url=` → `crawl_url`/`crawl` with **hard** `max_depth=0`, timeout, size cap, allowlist hosts → webbed words path. |
| **Do not** pull crawler into boot for the PDF-only MVP | Adds weight, settings surface, and network semantics without matching current UX (case files are uploaded/local). |
| Prefer lighter fetch for one-shot URLs | `http_client.http_get` or `read_text('https://…')` via httpfs, then webbed — crawler earns its keep only for multi-page / sitemap / merge crawls. |

---

## Combined architecture sketch (if ever productized)

```text
                    ┌──────────────┐
  samples/*.pdf ───►│ pdf ext      │──► words (real boxes) ──► v_grams ──► suggestions
                    └──────────────┘                              ▲
                                                                  │
  *.html / *.xml ──►│ webbed       │──► words (char offsets) ─────┘
        ▲           └──────────────┘
        │
  http URL ──► crawler (optional) ──┘
```

Shared: entity catalog, `qnorm`, n-gram match, decision/audit.  
Divergent: page UI, export/redact.

---

## Spike outputs (artifacts)

After a successful run from repo root:

| File | Contents |
|------|----------|
| `spikes/web-ingest/out/words.csv` | HTML+XML tokens with synthetic geometry |
| `spikes/web-ingest/out/pii_hits.csv` | Entity hits for Fit 1 |
| `spikes/web-ingest/out/crawl_meta.csv` | Crawl status / bytes |
| `spikes/web-ingest/out/crawl_words.csv` | Tokens from URL body |
| `spikes/web-ingest/out/crawl_pii_hits.csv` | Entity hits for Fit 2 |
| `spikes/web-ingest/out/01_run.log` / `02_run.log` | Full markdown query reports |

Reproduce: see `spikes/web-ingest/README.md`.

---

## Bottom line

| Fit | Verdict | Integrate into app? |
|-----|---------|---------------------|
| **1. Multi-format via webbed** | **Genuinely useful** for non-PDF **detection** on the same suggestion pipeline | **Yes, behind a source-kind branch**, when multi-format is in scope; pair with a non-PDF viewer/export later |
| **2. URL import via crawler** | **Marginal** | **No for MVP**; document as optional fetch front-end if remote HTML becomes real |

Do not force-fit crawler into a PDF-local review loop. Do use webbed when HTML/XML
records show up — that is the extension that actually moves the redaction needle.
