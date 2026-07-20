# Design rationale (Part 3) — Closure

**Singular requirement:** a human must thoroughly clear AI redaction suggestions across **1000+ pages**, fast, with auditability. At ~1 redaction/page that is **1000+ suggestions minimum** (multi-thousand on long packages). Everything serves throughput + audit.

## 1. Core interaction model — the funnel

Review is **triage**, not reading. The unit of work is a **decision**, not a page scroll.

**Design principle** (not a measured 3k→800 run): high-confidence auto-pass + easy bulk groups clear most of the queue; a human hand-reviews only the residual, **grouped** (names, addresses, patterns) for batch judgment; FNs are caught by remainder scan + add-missed — not by rereading every page.

**Our corpus (measured):** **1 328** suggestions / **11** docs / **210** pages / **22 247** words; one 110-page file holds **964**. Live entity bulk: **259** instances in one POST. Queue page-capped (≤80).

**Keyboard-first, full click parity** (`j`/`k` `a`/`r` Shift-bulk `e` entity `n` missed `u` undo). Confidence is three **bands** (HIGH / REVIEW / FLAGGED) — decision modes, not a slider. PDF canvas is non-negotiable: without surrounding text you cannot separate subject, citation, officer, or street. **Undo/history is a headline:** batch undo (Ctrl+Z / `u`), restore-to-prior-status, and an **append-only** decision log so a multi-hour session is reversible and legally reconstructable.

## 2. Why this design / what I rejected

**Rejected:** table-only review (no context); continuous confidence filters; silent entity apply (would ink “Det. X” with the subject); multi-service React+API+PDF as the *demo* stack (serialization hops, no shared geometry).

**Control:** I also built **three Next.js 15 / React 19 / SQLite** clean-room apps (`docs/review-cleanroom.md`). All build, test, smoke; best is attempt-2 (case workspace, immutable suggestions + decisions, similar-group bulk). They top out at **~15–23 fixture suggestions**, **no real PDF**, no export. Same UX sketch; no proof of 1000-page volume. Closure wins where the brief’s pain lives: real `read_pdf_words` boxes, case-scale entity fan-out, band + judge projection, remainder-scan FN candidates, `pdf_redact` with live geometry.

## 3. FP / FN + reviewer’s mental model

**AI proposes, human disposes.** Detectors never write status — only append-only `exports/decisions/*.json` (`v_suggestions` projects latest). **Nothing auto-redacts silently.**

| | Built mechanism |
|--|-----------------|
| **FP** | Why-card + reject / reject-all-matching; citation/officer/street → **FLAGGED** or non-bulkable; export blocked while flagged pending |
| **FN** | `n`+drag → `source=manual`; find-all scope; **remainder scan** masks accepted boxes, re-detects residual SSN/phone/email → candidates only (still human-accepted) |
| **Ambiguity** | Judge ensemble (pattern/context/prior): **split/conflict → flagged** (“judges disagree”), not a quiet mid-score |

Clerk model: bulk-clear HIGH when safe → walk REVIEW on canvas → stop cold on FLAGGED → confirm misses → export.

## 4. Architecture — one DuckDB process

This is a **prototype**. I was already building a DuckDB PDF extension and **quackapi** (a FastAPI-class web framework *inside* DuckDB), so collapsing the stack into one process was the fastest path to a working tool **and** a real stress test of my own ecosystem. DuckDB: single reader/writer, in-memory-fast with disk spill for query intermediates, near-zero dependencies, trivially easy deploy, and I know the ecosystem well.

```
browser → DuckDB [ quackapi(CREATE ROUTE) · pdf · tera ]
```

DB + HTTP + PDF + HTML share **one address space**. Handlers are SQL; `pdf_redact` / `read_pdf_words` / `tera_render` are function calls, not RPC. Buys: no ORM skew, set-based detection (words→n-grams→roster), page-scoped review, one binary to demo.

**Honest limits:** single-writer file lock across processes; human-rate appends are fine (**~3k decision QPS**, p50 **~5 ms** in-process — not the bottleneck); quackapi **256 MB serve stomp** must re-raise post-serve; unsigned extension pending community submit. **In production multi-writer concurrency I would reach for Postgres + a conventional app tier + object storage**, keeping DuckDB as the geometry/analytics side-engine — not the horizontally scaled HTTP tier.

## 5. Scale (measured)

| Axis | Evidence |
|------|----------|
| **100+ suggestions** | Live **1 328** / 11 docs; 110-page doc **964** alone |
| **50+ docs class** | Glob ingest near-linear (40 files, **165 ms** word CTAS); humans scale via entity/band bulk |
| **Multi-k pages** | `pdf-stress`: **5 000** pp / 27 MiB → 3.1M words **8.2 s**, pool **~241 MiB**, spill **0** @512 MB; page words/PNG **O(page)** |
| **Not claimed** | Open **~709 MiB / 130k pp** ≈ RSS ≈ file size (~791 MiB); full-doc list @256 MB **OOM**; scans/forms/annotations need extra paths |

## 6. Users · MVP vs ideal

**Users:** clerks/detectives, desktop, multi-hour FOIA release, keyboard-comfortable, legally accountable. They understand redaction, not ML. Bulk must preview the audit log.

**MVP:** real PDF boxes + roster seed, keyboard triage (click parity), entity/band bulk, add-missed, judge + remainder modules, append-only audit + undo/history, `pdf_redact` export with flagged gate.

**More time:** real OCR for image-only pages; local-LLM judges; multi-reviewer FLAGGED sign-off; table-backed decision log; hard file-size guards + batch huge redact; published quackapi extension.

*Claims map to: `server/{seed,judge,remainder_scan,routes,app}.sql`, `static/*.js`, `docs/{pdf-stress,scaling-and-limits,review-cleanroom,detection-design,sanity-check}.md`.*
