# Deep tradeoff: where DuckDB-maximalist Closure breaks — and what clean-rooms still do better

**Date:** 2026-07-19  
**Write surface:** this file only  
**Builds on (do not re-read as substitute):** `tradeoff-analysis.md` (submit verdict + axis scores), `ux-compare.md` (interaction locality), `review-cleanroom.md` (bugs/features per attempt), `scaling-and-limits.md` (OLTP myth + quackapi limits).  

**This doc answers only two questions the earlier writeups leave half-open:**

1. **Where does the DuckDB-maximalist stack actually fail or degrade** — not as ideology, but as measured boundaries — vs the clean-room Next.js/TS apps?
2. **What can a clean-room do that Closure cannot or does not** — concrete capability gaps, ranked by assignment impact?

**Compared systems**

| | Path | Runtime model |
|--|------|----------------|
| **Closure** | `/Users/aloksubbarao/personal/closure` | One DuckDB process + quackapi HTTP + `pdf` + `tera`; decisions = append JSON under `exports/decisions/` |
| **attempt-1** | `closure-cleanroom/attempt-1` | Next 15 + better-sqlite3; accept → separate **Apply** burn |
| **attempt-2** | `closure-cleanroom/attempt-2` | Next 15 + `node:sqlite`; case workspace + Similar panel + reviewers |
| **attempt-3** | `closure-cleanroom/attempt-3` | Next 15 + `node:sqlite`; select-text FN + bulk exact |

**Fresh evidence this session (in addition to prior docs):** live Closure `:8117` (PID held `closure.db`, RSS ≈ **1.05 GiB**); multi-process DuckDB lock race; decision-log `read_json` scaling; concurrent HTML/decision storms; huge-PDF RSS; clean-room attempt-2 concurrent decide storm; `scope=all` manual-add fan-out check.

---

## Framing (so the rest is not re-argued)

The author’s honest stack reason is real: *DuckDB maximalist + existing `pdf` ext + quackapi*. That is a legitimate **prototype prior**. The rigorous follow-up is not “was that convenient?” but:

> At what load, concurrency, corpus size, or ops shape does this single-process architecture stop matching the product (1000+ suggestions, multi-doc packages, audit, export, multi-reviewer)?

Clean-rooms are not “better products at volume.” They are **conventional control surfaces** that share SQLite’s single-writer class of problems but **do not** share DuckDB’s multi-process lock hardness, Poppler RSS, or directory-as-decision-log read amplification. They also ship several **interaction and modeling** pieces Closure still lacks.

---

# Part 1 — Failure / scaling boundary of the DuckDB-maximalist app

For each axis: **break point → symptom → what the conventional stack does instead.**

---

## 1.1 Concurrent multi-reviewer writes (the real single-writer problem)

### What people mean by “DuckDB isn’t OLTP”

They usually mean **one process owns the writeable database file**. That is true and measured. They sometimes mean “concurrent inserts inside one process are impossible.” That is **false** for Closure’s append-only decision path (see `scaling-and-limits.md` §1).

### Head-to-head measurement (this session + prior)

| Experiment | Closure (DuckDB) | Clean-room (SQLite) |
|---|---|---|
| **10 OS processes** each `INSERT` into the same file | **5/10 fail** immediately: `IO Error: Conflicting lock is held…` (wall ~53 ms for the race; survivors wrote 6 rows total) | **20/20 succeed** (WAL + lock wait; wall ~29 ms) |
| Second CLI open of live `closure.db` while quackapi serves | **Hard fail** — same lock error (PID 88497 holds file) | N/A for demo: one Next process; second process **can** open SQLite in WAL with busy timeout |
| **Same-process** concurrent decision POSTs | Prior: 20 workers × 500 → **~3 k QPS**, p50 ~5–6 ms, 0 fails. This session on live `:8117`: 16 workers × 100 → **100/100 OK**, ~**221 QPS**, p50 **58 ms** (slower: larger decision dir + mixed load) | attempt-2: 16 workers × 80 decide → **80/80 OK**, ~**832 QPS**, p50 **17.6 ms** |
| Mixed 8 HTML + 40 decisions | HTML p50 **655 ms**, decisions p50 **160 ms**, all OK | SPA JSON decides stay ms-scale; HTML is client-rendered |

### Break point

| Load | Closure behavior |
|------|------------------|
| 1–N reviewers **in one browser farm hitting one process** | **Works.** Mutations are `COPY` → JSON files / append events; no row-lock death spiral at human click rates. |
| **Two app servers / two duckdb processes** on one `closure.db` | **Hard fail** at process open. Symptom: `Conflicting lock is held in …/duckdb (PID …)`. Not a queue; not a timeout; immediate. |
| Horizontal pods (K8s) sharing a PVC writeable DuckDB file | Same hard fail, or silent split-brain if someone mounts read-write incorrectly. |
| “Failover” second instance while primary still holds lock | Cannot take over writeable state without killing primary / copying file. |

### What conventional stack does instead

| Concern | Next.js + SQLite (clean-room) | Prod Postgres + app |
|---------|------------------------------|---------------------|
| Multi-process writers on one machine | SQLite **allows** multi-process with `BEGIN IMMEDIATE` / busy timeout; throughput drops under lock contention but **does not hard-error on open** the way DuckDB does. | Normal: connection pool, many app workers, one primary. |
| Multi-node active-active | Still wrong for SQLite file on NFS; same class as DuckDB for **shared file**. Clean-rooms **don’t solve** multi-node; they just don’t pretend one binary is the cluster. | App is stateless; DB is the multi-writer system. |
| Concurrent human reviewers (2–10) | Fine in one Node process (measured). | Fine. |

### Honest takeaway

**DuckDB does not break when two clerks hit Accept at the same time on one server.**  
**DuckDB breaks the moment you scale the *HTTP tier* as multiple processes writing one file.**  

Clean-room SQLite is in the same **“one durable primary”** box for multi-node, but is **strictly more forgiving** for multi-process local writers (second Node worker, sidecar script, `sqlite3` CLI while server runs). That is a real ops difference, not FUD.

**Product implication for the assignment:** multi-reviewer **identity** (attempt-2 switcher) is orthogonal to multi-writer **storage**. Closure can take actor strings without multi-process DuckDB. Multi-reviewer **simultaneous edit of the same case** only needs one process — both stacks handle it.

---

## 1.2 Very large corpora (1 GB+ / 10k pages — memory, spill, latency)

Corpus scale has **three different machines** inside one process. Conflating them is how people over- or under-claim.

### Machine A — Word table after ingest (DuckDB buffer pool)

From `samples/stress/stress_metrics.csv` (5 000-page digital PDF, `memory_limit=512MB`):

| Op | Result |
|----|--------|
| CTAS `read_pdf_words(monster.pdf)` | **3 097 000** words, **8.2 s**, pool ~**241 MiB**, **spill 0** |
| Page-scoped `list(struct)` mid-doc | **~2 ms**, 630 words — review-route shape |
| `list(struct)` **all** words @ 512 MB | **OOM** (~488/488 MiB) — tera-bomb anti-pattern |
| `pdf_redact` one box on 5k-page file | **~305 ms** |

Linear extrapolation of word-table pool (same density as monster):

| Pages | Est. words | Est. DuckDB pool for full CTAS |
|------:|-----------:|-------------------------------:|
| 1 000 | ~0.6 M | ~50 MiB |
| 5 000 | 3.1 M | ~241 MiB (measured) |
| 10 000 | ~6.2 M | ~**480 MiB** |
| 28 000 | ~17 M | ~**1.4 GiB** (prior CTAS OK at 512 MB for 28k with different session; expect raise) |
| 100 000 | ~62 M | ~**4.8 GiB** — not a laptop interactive budget |

**Break:** full-corpus materialization of geometry into one list/JSON for HTML — not “DuckDB can’t hold 10k pages in a table.”

### Machine B — Native PDF open (Poppler RSS, outside `memory_limit`)

This session, page-scoped open of **`monster_huge.pdf` (709 MiB / 130 419 pages)** under `memory_limit=512MB`:

| Metric | Value |
|--------|------:|
| Wall | **0.39 s** real (info + page-1 words) |
| **max RSS** | **~779 MiB** (816 807 936 B) |
| DuckDB pool claim | Still “under 512 MB” in accounting |

Prior doc: same class → RSS ≈ **791 MiB ≈ file size**. Full-document word scan of 130k pages was aborted after ~10 min / ~1 GB RSS with no result.

**Break point (hard):**

| File class | Interactive serve process |
|------------|---------------------------|
| ≤ ~30 MiB / multi-k pages (text) | Ingest + page UI OK under 512 MB–1 GB |
| **~100–700 MiB single PDF** | **Any open** costs **~file-size RSS** in the **only** process. Concurrent open of two huge files → OOM / thrash. |
| 1 GB+ scanned / image PDFs | Worse: OCR path; not proven green under tight RAM |

Spill-to-disk **does not help Poppler open**. `temp_directory` helps DuckDB hash joins, not the native PDF library.

### Machine C — Suggestion / decision scale (product axis)

| Scale | Closure observed | Clean-room |
|------:|------------------|------------|
| Suggestions | **1 200–1 643** live demos | **15–23** fixtures |
| Case JSON API | Case-1 suggestions **~793 KB** in **29 ms** | Entire stub in one React state object |
| Decision files | Growing with every accept; projection cost scales (next section) | Rows in SQLite tables with indexes |

**10k-page / 1 GB product story for Closure is true only if:**

1. Ingest is **chunked** (page ranges → `words` table), not full open on request path.  
2. UI is **page-scoped** (already the design of `server/routes/pages.sql`).  
3. Export/redact of huge originals is a **batch job**, not a browser-wait HTTP handler.  
4. Size guards use **`file_size`**, not `duckdb_memory()`.

### What conventional stack does instead

| Layer | Clean-room today | Real prod Next/Postgres |
|-------|------------------|-------------------------|
| Page geometry | Fake % boxes / text offsets — **no 1 GB problem** because no PDF | pdf.js client-side or pre-render page images in object storage |
| Corpus memory | Fixture JSON in RAM | Blob store + DB metadata; worker pipeline for OCR/extract |
| Export | None | Async job queue; stream download; never block web worker on 700 MB rewrite |
| Failure mode | “Doesn’t scale the real problem” | “Scales by isolation” — PDF CPU off the request thread |

**Clean-rooms do not win large-corpus engineering.** They **sidestep** it. That is a valid prototype choice (assignment says PDF optional) and a **gap** if the narrative is law-enforcement package redaction.

---

## 1.3 Many simultaneous users (read path + memory pool)

### Measured interactive ceilings (Closure)

| Workload | Result |
|----------|--------|
| Light GET | ~7 k QPS class (prior) |
| `v_suggestions` / stats under 16-way | Prior: p50 ~**1 s**, ~16–17 QPS — projection-bound |
| Review HTML sequential | This session: **~99 ms** / ~209 KB body (warm) |
| Review HTML **8 concurrent** | **8/8 OK**, p50 **216 ms**, wall **226 ms** |
| 8 HTML + 40 decides mixed | HTML p50 **655 ms** (contention with writes + projection) |
| Live process RSS | **~1.05 GiB** after triage + storms |
| quackapi default if post-serve raise forgotten | **`memory_limit` stomped to 256 MB** → OOM 500s on fat routes |

### Break points

| Users / pattern | Symptom |
|-----------------|---------|
| 1–3 reviewers, page-scoped UI, memory raised | Fine; decisions stay interactive |
| ~8–32 concurrent **full tera HTML** renders | Latency multiplies; RSS climbs toward multi-GB (prior storms 0.6–2.5 GiB); one fat query can starve siblings (**one global memory pool**) |
| Status dashboard polled hard while decision log is huge | Stats/review projections → **100 ms → seconds** while POSTs stay fast |
| Auth-less open port | Not a capacity break — a **compliance** break (any simultaneous “user” is unauthenticated) |

quackapi: **32 worker threads**, full response buffering, **no HTTP chunked streaming** of large bodies (`scaling-and-limits.md` §2).

### What conventional stack does instead

| | Clean-room Next | Prod |
|--|-----------------|------|
| HTML | Thin shell; data via JSON; React re-render | CDN + SSR/ISR optional; cache |
| Concurrent users | Node event loop + SQLite; bottleneck is single-threaded JS for CPU work, not DuckDB pool blast radius | Many app replicas behind LB; DB pool |
| Memory blast | One bad query rarely OOMs the **host DB engine** for everyone the same way; process may still die | Isolate PDF workers; cgroup limits per service |

**Closure fails multi-user first on shared memory + SSR cost**, not on write QPS.

---

## 1.4 Long-running exports

### Closure model

Export is the **real product burn**: `pdf_redact` over accepted boxes, gated on flags.

Live this session:

```json
{"exported":0,"blocked":true,"flagged_remaining":19,
 "export_sql":"SELECT 0 AS document_id, 0 AS pages WHERE false"}
```

Hard block when flagged remain is **correct compliance behavior** clean-rooms never implement.

### Break points for export

| Situation | Symptom |
|-----------|---------|
| Flagged pending | Export plan **blocked** (intended) |
| Large multi-doc case, many boxes | `pdf_redact` rewrites PDFs in-process; wall time grows with file size × pages; holds memory pool |
| Huge source PDF on interactive path | Same Poppler RSS ≈ file size; export can **wedge the only web process** |
| Long export under concurrent review | Review HTML latencies spike (shared process + pool) |
| Empty / wrong export SQL (historical bug class) | Silent empty package — must keep **live** box SQL only (now gated) |

Prior: one-box redact on 5k-page monster **~0.3 s**. That does **not** prove multi-hundred-page multi-box package export stays sub-second.

### What conventional stack does instead

| Clean-room | Prod |
|------------|------|
| **No export** — CSS blackout is preview only | Job queue (`Bull` / Cloud Tasks); progress UI; write to object storage; signed URL |
| Cannot wedge a PDF engine they don’t have | Web tier stays responsive during 10-minute package burns |

**Gap direction is asymmetric:** Closure **has** export but **couples** it to the interactive process; clean-rooms **lack** export entirely.

---

## 1.5 Decision-log read amplification (DuckDB-specific product footgun)

Runtime status is a **projection** over `exports/decisions/*.json` (event sourcing lite). POSTs stay cheap; **reads** pay for the whole log.

Synthetic `read_json_auto` over N decision files (this session, cold-ish CLI):

| Files | Wall to `count(*)` |
|------:|-------------------:|
| 100 | **22 ms** |
| 500 | **47 ms** |
| 2 000 | **185 ms** |
| 5 000 | **368 ms** |
| 2 000 + `arg_max` latest status | **138 ms** |

Live case after heavy use: **~109+** decision files on disk (and more after storms). Prior work: ~2.6 k files → `v_suggestions` p50 **~70–100 ms** sequential, **~1 s** under 16-way concurrency.

**Break:** tens of thousands of tiny JSON decision files as the **only** source of truth for every stats/review render. Symptom: dashboard and residual queue feel “stuck” while Accept still returns in tens of ms.

**Clean-room equivalent:** `suggestion_decisions` / `UPDATE suggestions` is a **table** with PK/index. attempt-2:

```sql
-- attempt-2/src/db/schema.sql
suggestion_decisions (suggestion_id PK, status, decided_by, decided_at, note)
```

Point lookups stay O(log n). Bulk decide is one transaction, not N files.

**This is the DuckDB-maximalist trap that is *not* “DuckDB can’t OLTP”** — it is **abusing the filesystem as an unindexed event store** because `COPY TO … JSON` was the convenient mutation primitive in SQL.

---

## 1.6 Deploy / ops boundary

| Dimension | Closure | Clean-room |
|-----------|---------|------------|
| Binary / install | Custom **44 MB** duckdb + **27 MB** unsigned `quackapi` extension; `-unsigned` required | `npm install` / `pnpm install` (~**414–563 MB** `node_modules`) |
| Boot | `.read server/app.sql` re-registers routes in-process (non-durable registry) | `next start` |
| Fresh machine | **Fails** without sibling quackapi build | Works with Node 20+/22.5+ |
| Multi-instance | **Impossible** on one writeable DB file | Possible for **stateless** Next if DB is remote; still single-writer for local SQLite |
| Observability | stderr Poppler font spam; no APM story | Standard Node tooling |
| Security review | Unsigned extension + open routes (no AUTH) | npm supply chain + experimental `node:sqlite` (a2/a3) |
| Memory footgun | Serve stomps **256 MB** unless re-raised | No equivalent global stomp |

**Break for Closure ops:** grader laptop, Codespaces, CI without vendored binary, enterprise “no unsigned native code,” second replica for HA.

**Break for clean-room ops:** not runability — **truthfulness** of redaction (CSS only) and **scale proof** (23 suggestions).

---

## 1.7 Boundary matrix (one screen)

| Axis | Comfortable | Degrades | Hard fail / redesign |
|------|-------------|----------|----------------------|
| Reviewers on **one** process | 1–5 humans | 8–32 HTML-heavy sessions | Multi-process multi-writer on one `.db` |
| Decision write QPS | ≪10/s real; 100s–1000s OK measured | — | Not the limiting axis |
| Decision **files** | &lt;~500 | 1k–5k (100–400 ms projections) | 10k+ files without compaction/table |
| Pages in **table** (text PDF) | ≤5k @ 512 MB | 10–28k need more pool | Full-doc `list()` / tera of all words |
| Single PDF **open** RSS | Small samples | 100s MiB files ≈ RSS | 1 GB+ in interactive process |
| Export | Small packages, flags cleared | Large multi-doc in-request | Huge file redact on web thread |
| Auth / multi-tenant | Loopback demo | — | Real case data / multi-org |
| Deploy | Author machine | Grader friction | Unsigned-ext enterprise ban |

---

# Part 2 — Gap identifier: what clean-rooms do that Closure cannot / does not

**Rule for this list:** only capabilities where a clean-room has a **working interaction or robustness property** Closure lacks or only partially has. Not “they use TypeScript.” Ranked by impact on the **singular requirement** (1000+ clearance with FN catch, audit, revert).

| Rank | Gap | Who has it | Why it matters for the assignment | Closure status | File pointers (clean-room) | Closure landing / blocker |
|-----:|-----|------------|-----------------------------------|----------------|----------------------------|---------------------------|
| **1** | **Select-text FN → exact-string bulk-apply across case** | **a3** best; a2 partial | FN catch is half the singular requirement. Typing DOB/phone is how misses stay missed. | Drag-box add-missed **exists**; **`scope=all` writes one event only** (this session: `Count:1`, **1** decision file for `ScopeAllProbeToken`); words API **404** → scrape fallback | `attempt-3/.../DocumentViewer.tsx` (`handleMouseUp`, `segmentText`); `repository.ts` `addManualRedaction` + `bulkApply` / `findTextOccurrences`; `ManualRedactionDialog.tsx` | `static/addmissed.js` `loadWordsApi`; `server/routes/decisions.sql` `api_document_add` (scope stored, **not expanded**); no `/api/documents/:id/words` |
| **2** | **In-shell Similar panel with explicit doc vs case scope** | **a2** | At volume, bulk must not require leaving the residual keyboard context. | Entity/band bulk **power** exists; common path **navigates** to `/ui/bulk` or `/ui/reject` (`window.location`) | `BulkSimilarPanel.tsx`; `repository.ts` `listSimilarGroups`, `bulkDecideByGroup`; `ReviewWorkspace.tsx` tabs | `static/review.js` (`case "e"`, location hrefs); `static/bulk.js`; `server/templates/bulk.html` |
| **3** | **SPA page/doc switch (no full reload)** | **all clean-rooms** | 100–1000 page packages: full navigation kills muscle memory between residual instances | Page change = `window.location.href = "/documents/"+id+"/pages/"+p` | a2 `ReviewWorkspace.tsx` state + `fetch` suggestions; a1/a3 same | `static/review.js` ~L1164, ~L759–762 |
| **4** | **Staged Accept vs Apply (burn) + visual separation** | **a1** | Legal mental model: triage freely, burn deliberately; undo before apply | Export is the true burn (good), but **canvas treats accepted as “looks redacted”** without a separate apply audit verb | `repository.ts` `applyRedactions` / `applied=1`; `api/redactions/apply/route.ts`; overlay classes in `DocumentViewer.tsx` / `globals.css` | Decision model + `static/review.js` overlay; export already finalizes ink |
| **5** | **Reviewer identity switcher (first-class actors)** | **a2** | Audit trail without identity is a stack of anonymous `decision` events | `actor` query param defaults to `'reviewer'`; no UI switcher / roles | `schema.sql` `reviewers`; header `data-testid="reviewer-select"` in `ReviewWorkspace.tsx`; `api/reviewers` | Wire actors into existing POST params; small reviewers table or config |
| **6** | **Always-on audit stream in the review shell** | **a3** | Continuous accountability while clearing residual; discover undo without `/cases/:id/audit` | Full audit page + history drawer; easy to miss mid-flow | `attempt-3/.../AuditTrail.tsx` always-on pane | `static/history.js`; `server/templates/review.html` |
| **7** | **Confidence-band queue filters as primary keyboard (1/2/3)** | **a1** | “Work only the dangerous band” at 1000+ | Bands exist in funnel UI; polish/discoverability weaker than a1 chips | `SuggestionQueue.tsx`; `confidence.ts`; keys in `ReviewWorkspace.tsx` | `static/review.js` `bandsOn` / residual filters |
| **8** | **Heterogeneous multi-select bulk bar (mixed IDs)** | **a3** (+ a1 Space) | Not everything is one entity string; mixed page triage | Multi-select exists but under-discovered vs floating bar | `BulkActionBar.tsx`; Space/S toggle | `static/review.js` `selected` |
| **9** | **Immutable suggestions + separate decision rows (schema clarity)** | **a2** | Cleaner audit, easier “who decided,” maps to compliance narrative | Philosophically event-sourced via JSON files, but **projection is lossy/generic** (`decision` verb) and log is files not a table | `schema.sql` `suggestions` + `suggestion_decisions`; `decideSuggestion` | Move decisions into DuckDB table; keep append-only; fix audit verbs |
| **10** | **First-class undo of single decision in UX (U → pending)** | **a1** | High-volume error recovery without history spelunking | Closure has **stronger** undo stack for bulk/high (toast `u`) — but a1’s model is simpler for single-item mental model; a2/a3 **weaker** (overwrite / silent no-op) | a1 `undoOne` / `reset_pending` | Keep Closure stack; steal a1 simplicity for single-item |
| **11** | **Versioned fixture contract (Zod / JSON Schema)** | **a2 / a3** | Drop real detector output without rewriting seed | Seed is SQL + samples; no external fixture schema for graders | `attempt-2/src/data/contract.ts`; `attempt-3/data/fixture.schema.json` | Optional JSON fixture loader into `suggestions` |
| **12** | **Planted FP/FN metadata for evaluation honesty** | **all** (richest a2) | Graders/evaluators know which items are traps | Detection reasons exist; no first-class `planted_misses` table in UI | a2 `planted_misses`, `plantedAsFalsePositive`; a3 `plantedAs` | Optional eval mode |
| **13** | **Component / repository unit tests (Vitest)** | **all** | Grader-runnable confidence without live DuckDB | Playwright e2e + stress SQL; **no** Testing Library surface | `*.test.tsx`, `repository.test.ts` (18–24 tests green) | Optional; not a product gap |
| **14** | **Clone → run in &lt;5 minutes** | **all** | Submission ops risk | Custom binary + `-unsigned` | `npm run dev` / `start` | Vendor binary or document Codespaces image |
| **15** | **Typed API boundaries / 0 `any` culture** | **all** | Maintainability for a TS-hiring bar | SQL macros + vanilla JS | Strict TS throughout `src/` | Port only if rewriting client |

### Gaps that **do not** matter much for the assignment (honest demotion)

| Tempting “they have it” | Why demote |
|-------------------------|------------|
| CSS redaction “works” without PDF | Assignment allows it; domain narrative still weak |
| Lucide icons / marketing home (a3) | Aesthetics ≠ 1000+ clearance |
| Experimental `node:sqlite` | Not a capability win |
| Free re-decide without undo (a2) | **Anti-feature** for compliance |
| Silent re-decide no-op (a3) | **Bug**, not a gap to port |

### Reverse gaps (Closure has; clean-rooms cannot)

Kept short — already covered in `tradeoff-analysis.md` / `ux-compare.md`:

- Funnel + residual **group** unit of work at **1k+** scale  
- Real PDF geometry + `pdf_redact` export + **flag hard-block**  
- Reject-all why-card / judge signals  
- Remainder scan for residual PII  
- Deep undo / restore batches (`server/routes/history.sql`)  
- Multi-case real corpus (4 cases, 9 docs, 40k+ words)

These are why Closure remains the submission; they are **not** excuses to ignore rows 1–5 above.

---

## Part 3 — Interaction locality vs architecture (the synthesis)

`ux-compare.md` already said: *Closure has the volume architecture; clean-rooms have the local interactions.*

Deepen that with failure modes:

| If you only ship… | You fail the singular requirement by… |
|-------------------|----------------------------------------|
| Clean-room UX on stub data | Never proving 1000+; no export gate; FN bulk untested at package scale |
| Closure power with full-page navigations for bulk/FN | Paying **context reset tax** on every common action — minutes per hour at 1000+ |
| Closure with directory decision log forever | Write path stays fast while **read path dies** under its own audit success |
| Closure multi-process “scale-out” fantasy | **Hard lock** — must redesign storage first |

The correct “maximalist” read is:

> DuckDB-maximalism is **correct for detection + page-scoped geometry + single-box prototype HTTP**.  
> It is **incorrect as a religion** for multi-writer HA, huge-PDF interactive open, unbounded JSON decision globs, and SPA interaction density.

---

## Part 4 — Defendable rationale + prod change list

### Why DuckDB here (3 sentences the author can stand behind)

**I already owned a DuckDB PDF extension and a quackapi HTTP surface, so the fastest path from “detect PII in real packages” to “keyboard triage with real boxes and a blocked export” was one process that treats geometry as tables and decisions as append-only events — not a greenfield Next app that fakes pages.**  
**That maximalism matches the assignment’s hard problem (clearing 1000+ suggestions with document context): set-based detection, entity/band collapse, and `pdf_redact` as the release artifact are native SQL operations measured at case scale (1200+ suggestions, multi-thousand-page extract under a 512 MB pool for digital text PDFs).**  
**Single-process simplicity is an intentional prototype bound — concurrent in-process accepts are fine at human rates; the architecture does not claim multi-node writers, and the clean-room controls prove interaction polish, not volume or real redaction.**

### In prod I’d change X (ordered)

1. **Stop using unbounded `exports/decisions/*.json` as the live status store** — append to a DuckDB/Postgres **decisions table** (or compacting log); keep event semantics; index by `suggestion_id` / `batch_id`.  
2. **Never open multi-hundred-MB PDFs on the interactive request thread** — size guard on `file_size`; page-range ingest workers; object storage for blobs.  
3. **Export/redact as an async job** with progress + artifact URL; web process only enqueues and serves status.  
4. **Fix quackapi memory policy** (no unconditional 256 MB stomp) and **bound concurrent SSR** or move UI to thin shell + JSON (steal clean-room SPA).  
5. **AuthN/Z** before real case data (`CREATE AUTH` / reverse-proxy OIDC); real reviewer identities (port a2 switcher).  
6. **If multi-box / multi-user HA is required:** Postgres (or single primary) for events/users; object store for PDFs; workers for OCR/redact; **keep DuckDB as the analytics/PDF geometry engine**, not the horizontally scaled HTTP tier.  
7. **Do not multi-process write one `.db`.** Snapshots/read replicas only.  
8. **Port clean-room product gaps that matter:** select-text FN + case bulk-apply; in-shell Similar scope; accept vs apply staging (policy flag); SPA page nav; always-on audit.  
9. **Vendor/sign the extension** or replace quackapi with a boring HTTP layer calling DuckDB — remove `-unsigned` from the deploy story.  
10. **OCR + form/annotation passes** for scans (known silent misses) — out of stack maximalism, into detection completeness.

---

## Appendix A — Commands / numbers from this session

```text
# Multi-process DuckDB writers
10 processes INSERT same file → 5/10 lock fail, wall ~53ms

# SQLite control
20 threads multi-conn INSERT WAL → 20/20 ok ~29ms
500 serialized updates → ~8k QPS

# Decision log read_json scale
100 / 500 / 2000 / 5000 files → 22 / 47 / 185 / 368 ms

# Live Closure :8117
RSS ≈ 1.05 GiB; case suggestions ~793 KB / 29 ms
HTML ×8 → p50 216 ms; mixed HTML+decide → HTML p50 655 ms, dec p50 160 ms
DEC storm 100 @16 → 100/100, ~221 QPS, p50 58 ms
export_plan → blocked:true, flagged_remaining:19
POST add scope=all → Count:1 (no fan-out); 1 decision file

# Huge PDF page-scoped open
monster_huge 709 MiB → max RSS ~779 MiB in 0.39s

# attempt-2 decide storm
80 @16 → 80/80, ~832 QPS, p50 17.6 ms

# Second process open closure.db while serve
IO Error: Conflicting lock is held … PID 88497
```

## Appendix B — Related docs (what not to duplicate)

| Doc | Owns |
|-----|------|
| `tradeoff-analysis.md` | Submit verdict, weighted scores, port list summary |
| `ux-compare.md` | Per-flow keyboard/locality comparison |
| `review-cleanroom.md` | Per-attempt bugs and steal list |
| `scaling-and-limits.md` | OLTP myth experiments, quackapi 256 MB, thread pool |
| `pdf-stress.md` / `stress-test.md` | PDF extract/OOM/spill tables |
| `review-closure.md` | Closure product bugs (home, words 404, etc.) |

---

## Bottom line

**DuckDB-maximalist Closure breaks as a *system architecture* at multi-process writers, huge-PDF interactive open, unbounded decision-file projections, and coupled long exports — not at “two humans accepting suggestions.”**  

**Clean-rooms break as a *solution to the brief* at volume proof, real geometry, and release gates — but they still own concrete product gaps (select-text FN bulk, in-shell similar scope, SPA navigation, apply staging, reviewer identity) that Closure should steal rather than dismiss.**  

**Defend the stack on prototype speed + owned PDF/SQL ecosystem + single-process honesty; defend the product on measured 1000+ triage; change storage, PDF isolation, export async, and the five UX gaps before anyone calls it production.**
