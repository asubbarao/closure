# Head-to-head: Closure (DuckDB) vs clean-room Next.js controls

**Date:** 2026-07-20  
**Write target:** this file only  
**Compared:**

| Side | Path | Stack |
|------|------|--------|
| **Shipped** | `/Users/aloksubbarao/personal/closure` | DuckDB + quackapi HTTP + `pdf` + `tera`; one process on `:8117` |
| **Control 1** | `closure-cleanroom/attempt-1` | Next.js 15 / React 19 / TS / Tailwind / better-sqlite3 / Vitest |
| **Control 2** | `closure-cleanroom/attempt-2` | Same stack; `node:sqlite`; strongest clean-room product |
| **Control 3** | `closure-cleanroom/attempt-3` | Same stack; `node:sqlite`; best FN select-text path |

**Prior read:** `docs/review-cleanroom.md` (clean-room bugs/features), `docs/review-closure.md`, `docs/scaling-and-limits.md`, `docs/pdf-stress.md`, assignment brief, each app’s README/DESIGN.

**Method:** boot and HTTP-smoke all four; re-run clean-room unit tests; count LOC/fixtures/routes; measure live suggestion volumes, export policy, page PNGs, process RSS. No home-team bias — clean-room wins several axes below.

---

## 0. Executive summary

| Question | Answer |
|----------|--------|
| **Which to submit?** | **Closure (DuckDB app).** |
| **Why?** | The assignment’s singular hard problem is **throughput on 100+ / 1000+ AI suggestions with document context**, not “can you ship a typed Next app.” Only Closure proves that volume on **real PDF geometry** with **entity/band bulk**, **live export blocking**, and **case-scale corpora**. |
| **Where clean-room wins cleanly?** | **Clone → run**, conventional **TypeScript structure**, **component tests**, **keyboard UX polish density** at stub scale, **multi-reviewer switcher** (attempt-2), **select-text FN** (attempt-3), **apply-burn staging** (attempt-1). |
| **Where Closure loses?** | Grader friction (custom binary + `-unsigned`), home still hard-wired to case 1, missing words API, multi-GB stress corpus in tree, unconventional stack risk narrative. |

**One-line verdict:** Submit Closure as the product that *measures* the brief; treat attempt-2 as the UX/schema north star for ports, not as the submission.

---

## 1. Live evidence (this session)

### 1.1 Closure boot

```text
$ $HOME/personal/quackapi/build/release/duckdb -unsigned closure.db -c ".read server/app.sql"
→ http://127.0.0.1:8117/

boot summary | cases=4 | documents=9 | words=46439 | entities=54 | suggestions=1200
memory after serve | 3.7 GiB limit | process RSS ≈ 441 MiB (ps RSS 451664 KB)
```

| Document (basename) | Suggestions |
|---------------------|------------:|
| consolidated_case_file_2024-001001 | **717** |
| incident_report_2024-001001 | 66 |
| evidence_log_2024-001004 | 65 |
| witness_statement_2024-001003B | 65 |
| supplemental_report_2024-001001B | 61 |
| property_receipt_2024-001004B | 60 |
| interview_transcript_2024-001002 | 59 |
| case_summary_2024-001002B | 56 |
| arrest_report_2024-001003 | 51 |
| **Total** | **1200** |

**HTTP smoke (all 200 unless noted):**

| Path | Status | Size |
|------|--------|-----:|
| `/`, `/cases/1` | 200 | ~49 KB (same body — home still case-1) |
| `/cases/2` | 200 | ~48 KB |
| `/documents/1` review HTML | 200 | **~224–228 KB** |
| `/cases/1/audit` | 200 | ~80 KB |
| `/ui/add-missed`, `/ui/reject`, `/ui/bulk` | 200 | 13–18 KB |
| `/api/cases/1/suggestions` | 200 | **~387 KB**, **850 rows**, **0.02 s** |
| `/api/documents/1/suggestions` | 200 | 51 rows; real `x0,y0,x1,y1` |
| `/api/cases/1/export_plan` | 200 | `blocked:true`, `flagged_remaining:32` |
| page PNG `/pages/…/p1.png` (incident + consolidated) | **200** | 300–360 KB |
| `/api/documents/1/words` (+ page words) | **404** | still missing |

**Mutations exercised:**

| Call | Result |
|------|--------|
| `POST /api/suggestions/1/decision?status=accepted` | `[{"Count":1}]` |
| `POST /api/entities/31/decision?status=accepted` | `[{"Count":10}]` (entity fan-out) |
| `POST /api/documents/1/band/high/decision?status=accepted` | `[{"Count":33}]` |
| After band bulk on doc 1 | 43 accepted / 8 pending (flagged + residual) |

Coords sample (not mock rectangles):

```json
{
  "id": 108,
  "page_no": 1,
  "x0": 199.63, "y0": 60.82, "x1": 297.46, "y1": 70.07,
  "text": "Det. R. Feeney #8086",
  "confidence": 66,
  "flag_tag": "false_positive",
  "reason": "officer of record, not the subject"
}
```

### 1.2 Clean-room controls

| Check | attempt-1 | attempt-2 | attempt-3 |
|-------|-----------|-----------|-----------|
| `npm/pnpm test` (re-run) | **24/24** (~1.4s) | **18/18** (~1.6s) | **23/23** (~1.8s) |
| Production serve | `:3101` 200 | `:3102` 200 | `:3103` 200 |
| Fixture scale | **2 docs, 15 suggestions** | **3 docs, 23 suggestions** | **2 docs, 17 suggestions** |
| Accept mutation | PATCH → accepted | POST decide `{action,actorId}` OK | POST decide OK |
| PDF dependency | **none** | **none** | **none** |
| `src` LOC | ~4.3k | ~4.2k | ~4.1k |
| `node_modules` | ~447 MB | ~414 MB | ~563 MB |

Clean-room APIs return **% bboxes or text offsets on fixture layout**, not Poppler word boxes. Redaction is **CSS blackout**, not `pdf_redact`.

### 1.3 Size / structure counts

| Metric | Closure | Clean-room (each) |
|--------|--------:|------------------:|
| Server SQL (app + routes) | ~4.5–5.5k LOC | n/a |
| Templates HTML | ~2.7k | React components |
| Client JS (`static/`) | **6.3k** (review.js alone 1.2k) | in `src/components` |
| Sample PDFs | **9** demo + **~97** stress + messy | 0 |
| Page PNGs | **66** (stems match all 9 demo docs) | simulated canvas/text |
| Design mockups | **5** HTML + **5** PNG screens | UI *is* the design |
| Playwright specs | **11** core-flow specs | 0 e2e (Vitest unit/component only) |
| Vitest-style unit tests | stress SQL + e2e (not Vitest UI) | **18–24** tests |
| Design rationale | `docs/rationale.md` (~1 page) | `DESIGN*.md` |
| Redacted export PDFs on disk | **9** `*_redacted.pdf` | 0 |
| Decision event files | **83** JSON | SQLite rows |

---

## 2. Axis-by-axis tradeoff

Scoring: **1–5** per axis (5 = best for a take-home *submission that should be graded highly on that axis*).  
Clean-room score uses the **best of the three** on that axis (usually attempt-2).

### Axis A — End-to-end completeness vs assignment flows

Assignment requires: main review UI, fast FP reject, FN add, bulk similar, multi-doc, confidence, audit; SQLite-class DB; hardcoded suggestions OK; working prototype; design rationale.

| Flow | Closure | attempt-1 | attempt-2 | attempt-3 |
|------|:-------:|:---------:|:---------:|:---------:|
| Queue + page context | ✅ real PDF canvas | ✅ fixture paper | ✅ fixture paper | ✅ text stand-in |
| Fast reject FP | ✅ `r` + reject UI | ✅ A/R | ✅ A/R | ✅ A/R |
| Add FN | ✅ drag UI (`n`) — **server `scope=all` still weak** | ✅ draw+type | ✅ select text | ✅ **best** select + bulk exact |
| Bulk similar | ✅ entity + band + multi-select | ✅ B/X case-wide | ✅ **Similar panel** doc/case | ✅ Shift+A/R + multi-select |
| Multi-document | ✅ within case rail; **home is case 1 only** | ✅ sidebar hops | ✅ **case workspace + N** | ✅ sidebar N/P |
| Confidence | ✅ bands + filters + reasons | ✅ % + **1/2/3 filters** | ✅ % + band | ✅ % + band |
| Audit trail | ✅ HTML + API; action often generic `decision` | ✅ panel | ✅ tab | ✅ **always-on** |
| Apply / blackout | ✅ **real `pdf_redact` export** + hard flag block | ✅ **Apply burn step** | ✅ immediate CSS black | ✅ CSS black |
| Export package | ✅ plan + live SQL + blocked gate | ❌ | ❌ | ❌ |
| Part 1 hi-fi design | ✅ 5 mockups + screens | UI-as-design | UI-as-design | UI-as-design |
| Part 3 rationale | ✅ | ✅ | ✅ | ✅ |

**Honest read:** Clean-rooms complete the *clickable workflow checklist* more cleanly at stub scale (especially attempt-2 shell + attempt-1 apply/undo + attempt-3 FN). Closure completes the *product loop including release* (export with real ink + flag gate) and multi-case data, but still has product holes (home, words API, FN fan-out, some audit lossiness — see `review-closure.md`).

| | Closure | Best clean-room |
|--|:-------:|:---------------:|
| **Score** | **4** | **4** (attempt-2+1 hybrid) |
| **Winner** | **Tie** on “assignment checkbox completeness”; Closure pulls ahead only if export + real corpus count. |

---

### Axis B — Throughput UX for **1000+ suggestions** (singular requirement)

This is the brief’s hard problem. Design docs and rationale state it explicitly.

| Evidence | Closure | Clean-room |
|----------|---------|------------|
| Live suggestion count | **1200** boot / **850** on case 1 alone / **717** on one PDF | **15 / 23 / 17** |
| Bulk that collapses volume | Entity POST **10**; band-high POST **33** (this session); prior docs report entity bulk **259** | Similar-group bulk works but only on tiny groups |
| Queue strategy | Band filters, entity grouping, multi-select, keyboard `j/k a/r x u e n g` | Excellent keyboard at stub scale; **no virtualization** either side |
| Case-scale API payload | 850 rows / 387 KB in **20 ms** | Entire case fits in one React state object |
| Proven on 100+ items? | **Yes (measured)** | **No — claimed in DESIGN, not proven** |

**Clean-room honesty:** All three *design for* 100+ (group keys, pending filters, bulk). None *demonstrates* it. Loading 1000 fixture rows would likely work in SQLite/React, but:

1. No fixture/generator proves layout + confidence + planted FP/FN at that scale.
2. No page-scoped rendering strategy for a real multi-hundred-page PDF.
3. Attempt-1 similar badge **under-counts case scope** (known bug) — dangerous at volume.

**Closure honesty:** Throughput tools exist and were exercised at 800–1200 scale. Gaps: no queue virtualization, full case JSON can grow with decision files, officer/street FPs can still sit in REVIEW and be bulk-eligible if not flagged (policy hole). Page-scoped HTML is the right pattern (~224 KB review page).

| | Closure | Best clean-room |
|--|:-------:|:---------------:|
| **Score** | **5** | **2** |
| **Winner** | **Closure — decisive** |

---

### Axis C — Real PDF handling (words / coords / redaction / scans)

| Capability | Closure | Clean-room |
|------------|---------|------------|
| Word extraction | `read_pdf_words` → **46 439** words | Fixture strings / text blocks |
| Coordinates | PDF points top-left; export Y-flip in `pdf_io.sql` | % of fake page or char offsets |
| Redaction | `pdf_redact` → real files under `exports/*_redacted.pdf` | CSS `background: black` |
| Page raster | Pre-rendered PNGs; live stems **match** all 9 docs (200 OK) | Drawn “paper” or plain text |
| Stress corpus | 5 000-page monster: 3.1M words **8.2 s** @512 MB pool; 130k-page open ≈ RSS≈file size | N/A |
| Scans / forms / annotations | **Known miss** (image-only, AcroForm `/V`, sticky notes) — documented in `pdf-stress.md` | Not in scope; simulated |
| Encrypted / corrupt | Fail closed on ingest (stress F1–F6) | N/A |

Assignment says real PDF is optional. For a **law-enforcement redaction** narrative, optional is not equal:

- Clean-room **cannot** show “this black bar is the release artifact.”
- Closure **can**, and export is **hard-blocked** while flagged pending (`exported:0`, `flagged_remaining:32` this session) — a compliance-relevant behavior clean-rooms never implement.

| | Closure | Best clean-room |
|--|:-------:|:---------------:|
| **Score** | **5** (with honest scan/OCR gap) | **1** (by design) |
| **Winner** | **Closure — decisive** |

---

### Axis D — Code quality + structure

| Concern | Closure | Clean-room |
|---------|---------|------------|
| Language discipline | SQL macros + vanilla JS; no types | **Strict TS**, Zod contracts, **0 `any`** hits in `src` |
| Module layout | Improving (`server/routes/*`, `pdf_io.sql`) but still dense; dual-boot history | Clear `app/api`, `components`, `lib/db`, fixtures |
| Separation of concerns | PDF I/O increasingly isolated; routes still thick | Repository pattern consistent |
| Config hygiene | Paths to quackapi binary/extension; localhost prototype | `npm`/`pnpm` portable |
| Dead code / drift | Historical: README/run.sh drift (partially fixed); experimental modules | Small surface; less rot |
| Idiom familiarity for graders | **Low** (CREATE ROUTE in SQL) | **High** (Next App Router) |

**Clean-room wins this axis.** Attempt-2’s schema (immutable suggestions + `suggestion_decisions` + reviewers + planted_misses) is cleaner *as application modeling* than Closure’s seed + JSON-event projection, even though the event-log idea is sound for audit.

Closure’s strength is **architectural coherence for PDF+HTTP in one process**, not conventional full-stack layering. A grader who scores “looks like a well-typed product codebase” will prefer attempt-2.

| | Closure | Best clean-room |
|--|:-------:|:---------------:|
| **Score** | **3** | **5** |
| **Winner** | **Clean-room (attempt-2)** |

---

### Axis E — Tests

| | Closure | Clean-room |
|--|---------|------------|
| Unit / component | Sparse for JS; domain logic in SQL | **Vitest + Testing Library** 18–24 tests, all green |
| Repository tests | Via e2e + manual smoke | Real (decide, bulk, apply paths) |
| E2E | **11 Playwright specs** covering assignment flows | None |
| Stress / scale | **`tests/stress/` SQL** + `pdf-stress.md` metrics | None |
| What they prove | Browser flows + PDF scale envelopes | UI contracts + small DB mutations |

**Split decision:** Clean-room tests are **higher signal per line** for UI correctness and easier for a grader to run (`npm test`). Closure’s Playwright suite matches the brief’s flows better *in name*, but depends on a live DuckDB server and is heavier. Stress tests are unique to Closure and matter for the volume claim.

| | Closure | Best clean-room |
|--|:-------:|:---------------:|
| **Score** | **3.5** | **4** |
| **Winner** | **Clean-room slightly** (runability + coverage density); Closure unique on scale tests |

---

### Axis F — Deploy / run simplicity (clone → run)

| Step | Closure | Clean-room |
|------|---------|------------|
| Install | Custom **quackapi-built** DuckDB (~45 MB binary) + **unsigned** extension | `npm install` / `pnpm install` |
| Boot | `duckdb -unsigned closure.db -c ".read server/app.sql"` | `npm run dev` or `build && start` |
| Port | 8117 | 3000 |
| Fresh machine? | **Fails** without sibling quackapi build | **Works** with Node 20+/22.5+ |
| Time to first paint | Boot ingest of 9 PDFs + seed (seconds–tens of seconds) + Poppler font noise | Seconds after install |
| README truth | Now documents real path; still ecosystem-coupled | Accurate and conventional |

**Clean-room wins decisively** on grader “can I run this in 5 minutes?” risk. Closure’s run story is a **demo machine story**, not a GitHub Codespaces story.

| | Closure | Best clean-room |
|--|:-------:|:---------------:|
| **Score** | **2** | **5** |
| **Winner** | **Clean-room** |

---

### Axis G — Memory / scale on large docs

From live process + `docs/pdf-stress.md` + `docs/scaling-and-limits.md`:

| Scenario | Closure | Clean-room |
|----------|---------|------------|
| Interactive case (~1.2k suggestions, 9 docs) | RSS **~441 MiB**; serve limit raised to **3.7 GiB** | Tiny; browser holds full stub |
| 5k-page digital PDF word CTAS | **OK** ~241 MiB pool, 8.2 s | Not applicable |
| ~709 MiB / 130k-page open | Process RSS **~791 MiB** (≈ file size); not under 512 MB claim | Not applicable |
| Full-doc word list in HTML @256 MB | **OOM** (tera bomb) — mitigated by page-scoped routes | N/A |
| Multi-process writers on one DB | **Hard fail** (file lock) | SQLite single-writer too, but Next is still one node process for the demo |
| Decision write path | Append JSON; ~3k QPS in prior concurrent storms | SQLite row updates / decision upserts |

**Closure is the only side with measured large-doc behavior.** That is both a win (evidence) and a risk (Poppler RSS, memory stomp if post-serve raise is forgotten).

| | Closure | Best clean-room |
|--|:-------:|:---------------:|
| **Score** | **4** (measured + page-scoped; huge-file honest limits) | **2** (unknown / untested at scale) |
| **Winner** | **Closure** |

---

### Axis H — Risk profile

| Risk | Closure | Clean-room |
|------|---------|------------|
| Unsigned custom extension | **High** for any real deploy / security review | None |
| Single-writer DuckDB file | **High** for multi-node; **low** for one-clerk demo | SQLite same class, better understood |
| quackapi 256 MB serve stomp | **Medium** if boot forgets re-raise | None |
| Arbitrary SQL export/run path | **Medium** if bound beyond loopback (prior review) | Standard REST only |
| Experimental `node:sqlite` | n/a | attempt-2/3 (attempt-1 uses better-sqlite3 — safer) |
| Supply chain | DuckDB + few extensions | **Next + hundreds of npm packages** (~400–560 MB node_modules) |
| Talent / maintenance | Few people write quackapi SQL apps | Huge hiring pool |
| Product lie risk | Export was historically empty-macro; **live path now hard-blocks flags** | CSS blackout can over-promise “redacted” |
| Silent empty ingest | Mitigated by boot assert (docs claim; boot this session produced 9 docs) | Seed always tiny but consistent |

**Net:** Closure has **sharper technical risks** (unsigned, single process, custom HTTP). Clean-room has **conventional risks** (npm surface, experimental sqlite in 2/3, decision overwrite bugs, no real redaction). For a take-home **prototype**, unconventional stack risk is acceptable if called out; for an agency production RFP, neither stack as-is ships without a rewrite plan.

| | Closure | Best clean-room |
|--|:-------:|:---------------:|
| **Score** | **2.5** | **3.5** |
| **Winner** | **Clean-room** (more boring = safer to explain) |

---

### Axis I — What a grader would think

Assume a busy FDE/fullstack grader with **15–25 minutes**.

#### Closure narrative

> “Ambitious. Real PDFs, 1200 suggestions, keyboard triage, entity bulk, export with flag gate. Design mockups exist. Architecture is either brilliant or a red flag depending on taste. I need a special binary to run it. Home is weird (only case 1). Is the ML real? No — roster match — but they don’t pretend. Throughput claim is backed by numbers. I’d interview this person about tradeoffs.”

**Likely grade drivers:** uniqueness + measured scale + PDF depth **up**; run friction + stack unfamiliarity + residual bugs **down**.

#### Clean-room narrative (attempt-2)

> “Professional Next app, typed, tests green, polished keyboard UX, clean schema, good DESIGN.md. Does everything the checklist asks at demo scale. No PDF, 23 suggestions — fine per brief. Looks like many strong take-homes. Harder to stand out; easy to run and easy to like.”

**Likely grade drivers:** craft + runability + UX polish **up**; no volume proof + simulated doc **neutral-to-down** if grader cares about the problem statement’s pain.

#### attempt-1 / attempt-3 capsules for graders

- **attempt-1:** Best legal mental model (accept vs apply + undo). Doc-primary routing feels smaller. Similar-count bug is a credibility ding if found.
- **attempt-3:** Best FN story; silent re-decide bug is a compliance ding; least PDF-like.

| | Closure | Best clean-room |
|--|:-------:|:---------------:|
| **Score (impress + hire signal)** | **4** | **3.5** |
| **Score (low-friction grade)** | **2.5** | **4.5** |
| **Winner** | **Depends on grader;** for *this* brief’s stated hard parts → Closure; for *generic* fullstack rubric → clean-room |

---

## 3. Scoring table (summary)

Scale 1–5. Clean-room = best-of-three on that axis.

| Axis | Weight (brief) | Closure | Clean-room | Winner |
|------|---------------:|--------:|-----------:|--------|
| A. E2E assignment flows | High | 4 | 4 | Tie |
| B. **1000+ throughput UX** | **Critical** | **5** | **2** | **Closure** |
| C. Real PDF / redaction | High (optional but central) | **5** | 1 | **Closure** |
| D. Code quality / structure | High | 3 | **5** | **Clean-room** |
| E. Tests | Medium–High | 3.5 | **4** | **Clean-room** |
| F. Clone → run | Medium (submission ops) | 2 | **5** | **Clean-room** |
| G. Memory / large-doc scale | Medium | **4** | 2 | **Closure** |
| H. Risk profile | Medium | 2.5 | **3.5** | **Clean-room** |
| I. Grader impression (problem-aware) | — | **4** | 3.5 | **Closure** |
| I′. Grader impression (generic rubric) | — | 2.5 | **4.5** | **Clean-room** |

### Weighted verdict math (problem-aware)

Approximate weights matching the assignment text + BUILD_PROMPT hyperfocus (workflow + volume):

| Axis | Weight | Closure | Clean-room | C×W | CR×W |
|------|-------:|--------:|-----------:|----:|-----:|
| B Throughput 1000+ | 0.25 | 5 | 2 | 1.25 | 0.50 |
| A E2E flows | 0.15 | 4 | 4 | 0.60 | 0.60 |
| C PDF real | 0.15 | 5 | 1 | 0.75 | 0.15 |
| D Code quality | 0.12 | 3 | 5 | 0.36 | 0.60 |
| E Tests | 0.08 | 3.5 | 4 | 0.28 | 0.32 |
| F Clone-run | 0.08 | 2 | 5 | 0.16 | 0.40 |
| G Scale/memory | 0.07 | 4 | 2 | 0.28 | 0.14 |
| H Risk | 0.05 | 2.5 | 3.5 | 0.13 | 0.18 |
| I Grader (problem) | 0.05 | 4 | 3.5 | 0.20 | 0.18 |
| **Total** | **1.00** | | | **4.01** | **3.07** |

If you **reweight** toward “standard take-home” (code quality 0.25, clone-run 0.20, throughput 0.10), clean-room can win. That reweight **fights** the brief’s own emphasis on volume UX.

---

## 4. Verdict: what to submit and why

### Submit **Closure** (`/Users/aloksubbarao/personal/closure`)

**Reasons (evidence-backed):**

1. **Singular requirement:** live **1200** suggestions (850 in one case, 717 in one PDF). Controls top out at **23**. Only Closure forces the UI to confront volume.
2. **Real geometry + redaction:** `read_pdf_words` boxes, PNG canvas backgrounds (verified 200), `pdf_redact` exports, export **hard-block** with flags remaining.
3. **Bulk primitives that matter at scale:** entity fan-out (10), band bulk (33), multi-select + keyboard in `static/review.js` — not just “similar string on 15 rows.”
4. **Part 1 design artifacts** exist as separate hi-fi HTML/PNG (assignment explicitly wants design quality).
5. **Stress literature** (`pdf-stress`, scaling docs) shows you measured failure modes — rare and impressive in a take-home.
6. Clean-room apps are **excellent controls** proving the UX vocabulary; they are not a substitute for proving the problem’s scale.

### Do **not** submit a clean-room attempt as the primary package

They would score well on a **generic** fullstack rubric and are safer to run, but they **do not evidence** the volume story the problem statement centers. Submitting attempt-2 alone invites: “Nice React app; how do you know this works at 100+ suggestions on real PDFs?”

### Submission hygiene if Closure is the package

Before send, prioritize (from live gaps + prior reviews):

1. One-command run doc that either vendors the binary or links a release (reduce “sibling quackapi” pain).
2. `/` → multi-case `render_home` (home == case 1 is a grader trap).
3. Words API for FN path (still 404).
4. Confirm export UI only uses live plan (already better than empty-macro era).
5. Call out in rationale: detection is roster/n-gram + judges, not ML — honesty scores.

---

## 5. Best 3–5 things to port from clean-room → DuckDB app

Ranked by leverage on 1000+ package review. File pointers are clean-room sources; Closure landing zones included.

### 1. Case-level **Similar** panel with explicit **doc vs package** scope  
**From:** attempt-2  
**Files:**  
- `closure-cleanroom/attempt-2/src/components/BulkSimilarPanel.tsx`  
- `closure-cleanroom/attempt-2/src/db/repository.ts` (`listSimilarGroups`, `bulkDecideByGroup`)  
- `closure-cleanroom/attempt-2/src/components/ReviewWorkspace.tsx` (right rail tabs)  

**Why:** Closure has entity + band bulk but not a first-class “this string across the package” explorer with scope toggle. That is the multi-doc volume weapon.  
**Land in:** `static/review.js` + `server/routes/triage.sql` / decisions routes; group key already partially present via `entity_text` / text.

### 2. **Select-text FN → exact-string bulk apply** across the case  
**From:** attempt-3 (best), attempt-2 (partial)  
**Files:**  
- `closure-cleanroom/attempt-3/src/components/DocumentViewer.tsx` (`handleMouseUp`, `segmentText`)  
- `closure-cleanroom/attempt-3/src/lib/db/repository.ts` (`addManualRedaction`, cover-skip, bulk exact)  
- `closure-cleanroom/attempt-3/src/components/ManualRedactionDialog.tsx`  

**Why:** Closure’s add-missed UI exists (`static/addmissed.js`) but server `scope=all` still does not fan out (prior P1). Select-from-text-layer (or word hit-test from `/words` once implemented) + n-gram expand is the real FN weapon.  
**Land in:** `static/addmissed.js` + `server/routes/decisions.sql` (or documents routes); needs words API first.

### 3. **Staged Accept vs Apply (burn)** + undo as first-class  
**From:** attempt-1  
**Files:**  
- `closure-cleanroom/attempt-1/src/lib/repository.ts` (`applyRedactions`, status vs `applied`)  
- `closure-cleanroom/attempt-1/src/app/api/redactions/apply/route.ts`  
- `closure-cleanroom/attempt-1/src/components/DocumentViewer.tsx` (accepted tint vs applied black)  

**Why:** Legal mental model: triage freely, burn deliberately. Closure’s export is the burn, but the **canvas** currently conflates “accepted” with “looks redacted.” Staging reduces accidental release confidence and matches attempt-1’s strongest idea.  
**Land in:** suggestion projection (`status` vs `applied` flag or export-only ink); `static/review.js` overlay classes; audit event `redaction.apply`.

### 4. **Confidence-band queue filters (1/2/3) + heterogeneous multi-select bar**  
**From:** attempt-1 filters + attempt-3 `BulkActionBar`  
**Files:**  
- `closure-cleanroom/attempt-1/src/components/SuggestionQueue.tsx`  
- `closure-cleanroom/attempt-1/src/lib/confidence.ts`  
- `closure-cleanroom/attempt-3/src/components/BulkActionBar.tsx`  

**Why:** Closure already has band filters and multi-select in `static/review.js` — closer than clean-room on raw machinery — but clean-room’s **keyboard affordances and visual density** (chip filters, floating bulk bar, Shift+similar) are cleaner. Port **interaction polish**, not the idea from zero.  
**Land in:** `server/templates/review.html` + `static/review.js` (shortcut chrome, always-visible bulk bar).

### 5. **Reviewer identity switcher + always-on audit stream**  
**From:** attempt-2 reviewers + attempt-3 live audit  
**Files:**  
- `closure-cleanroom/attempt-2/src/db/schema.sql` (`reviewers`)  
- attempt-2 header `data-testid="reviewer-select"` in `ReviewWorkspace.tsx`  
- `closure-cleanroom/attempt-3/src/components/AuditTrail.tsx` (always-on pane)  

**Why:** Closure hard-codes actor strings; audit often shows generic `decision`. Cheap credibility for legal compliance storytelling.  
**Land in:** small `reviewers` table or JSON config; actor query param already exists on decision POSTs; audit template + right rail.

**Honorable mention (schema):** attempt-2’s **immutable suggestions + append-only decisions** is already *philosophically* what Closure does with `exports/decisions/*.json` + `v_suggestions`. Port the **clarity** (separate decision verb in audit: `accept`/`reject`/`undo`, not only `decision`) rather than rewriting storage.

---

## 6. Directional honesty checklist (no home-team)

| Claim someone might make | Truth |
|--------------------------|--------|
| “DuckDB app is always better code” | **False.** Clean-room TS structure and tests are cleaner for a conventional bar. |
| “Clean-room is a full alternative product” | **False at volume.** 15–23 suggestions and CSS blackout do not replace 1200 real boxes + export. |
| “Closure is hard to run, so it fails the assignment” | **Partial.** Run friction is real; assignment evaluates workflow + code quality, not npm DX alone. Mitigate with packaging. |
| “Clean-room can’t do bulk” | **False.** Bulk UX is often *nicer* at stub scale (especially attempt-2 Similar panel). |
| “Closure already has everything worth stealing” | **False.** Similar-scope panel, select-text FN fan-out, apply-burn staging, reviewer switcher are still worth porting. |
| “Real PDF was optional so ignore it” | **Technically true, strategically false** for standing out and for the problem domain. |

---

## 7. Appendix — commands run

```text
# Closure
cd /Users/aloksubbarao/personal/closure
rm -f closure.db closure.db.wal
$HOME/personal/quackapi/build/release/duckdb -unsigned closure.db -c ".read server/app.sql"
# boot: cases=4 docs=9 words=46439 entities=54 suggestions=1200 → :8117
# curl smokes: /, /cases/*, /documents/1, APIs, export_plan, page PNGs
# POST decision / entity bulk / band bulk

# Clean-room
attempt-1: npm test → 24/24; PORT=3101 npm start → 200; 15 suggestions
attempt-2: npm test → 18/18; PORT=3102 npm start → 200; 23 suggestions
attempt-3: pnpm/npm test → 23/23; PORT=3103 npm start → 200; 17 suggestions

# Prior written reviews (not re-copied)
docs/review-cleanroom.md
docs/review-closure.md
docs/pdf-stress.md
docs/scaling-and-limits.md
```

### Key paths

| Side | Entry | Design | Review UI | Data |
|------|-------|--------|-----------|------|
| Closure | `server/app.sql`, `README.md` | `design/0*.html`, `docs/rationale.md` | `static/review.js`, `server/templates/review.html` | `samples/*.pdf`, `exports/decisions/` |
| attempt-1 | `README.md` | `DESIGN.md` | `src/components/ReviewWorkspace.tsx` | `src/lib/fixtures/stub.ts` |
| attempt-2 | `README.md` | `DESIGN.md` | `ReviewWorkspace.tsx`, `BulkSimilarPanel.tsx` | `src/data/fixtures/stub.ts`, `src/db/schema.sql` |
| attempt-3 | `README.md` | `DESIGN_RATIONALE.md` | `DocumentViewer.tsx`, `BulkActionBar.tsx` | `src/lib/fixtures/stub.ts` |

---

## 8. Bottom line

**Submit Closure.** It is the only implementation that **earns** the assignment’s volume and multi-document claims with measured evidence (1200 suggestions, real PDF coordinates, entity/band bulk, hard-blocked export).  

**Study attempt-2 as the UX/schema control**, attempt-3 for FN selection, attempt-1 for legal apply/undo — and port the five items above rather than replacing the stack.  

**If a grader cannot run quackapi,** the clean-room apps are the fallback demo of interaction design, not the submission of record for the problem as stated.
