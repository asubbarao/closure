# UX compare: Closure vs clean-room apps

**Date:** 2026-07-19  
**Method:** Live walk (browser + keyboard), not mockups.  
**Write surface:** this file only. Clean-rooms were not modified and did not see Closure.

| App | How exercised | Scale under review |
| --- | --- | --- |
| **Closure** | `duckdb -unsigned … -c ".read server/app.sql"` — port **8117 boot failed** mid-tree edit (`Parser Error` at `NULL::BOOLEAN` in remainder scan). **Retried once.** Reviewed live instance on **`:8133`** (same `server/` + samples, 4 docs / **1643 suggestions**, residual groups, funnel, bulk, reject, add-missed, audit, export). | **Real volume** (~1.6k suggestions, 117-page consolidated PDF) |
| **Clean-room attempt-1** | `npm start` → **`:3001`**. Walked home → review → A/R/U/B/1/?/Apply. | 2 docs / **15** suggestions |
| **Clean-room attempt-2** | `npm start` on `:3010` → API 500; **`npm run dev` on `:3011`** worked. Walked case review + Similar panel + M add mode. | 3 docs / **23** suggestions |
| **Clean-room attempt-3** | `npm start` → **`:3002`**. Walked cases → J/K/A/Shift+A/S/?. | 2 docs / **17** suggestions |

**“Best clean-room” baseline for comparison:** **attempt-2** for overall case package + always-on similar bulk; borrow attempt-1 confidence filters + apply/undo discipline and attempt-3 select-text FN + Shift-similar keys when they win a flow.

**Lens:** throughput for **1000+ suggestions**. Aesthetic preference is irrelevant. Dead ends, full reloads, and “pretty but slow” lose.

---

## Executive read

| | Winner at 1000+ | Why (one line) |
| --- | --- | --- |
| **Architecture for volume** | **Closure** | Funnel (auto-pass high) + residual **group** unit of work can collapse hundreds of marks in a few keystrokes; clean-rooms only demo the idea on ~20 items. |
| **In-flow bulk similar** | **Clean-room (a2/a3)** | Similar bulk stays **in the review shell** with case/doc scope; Closure often **navigates away** to `/ui/bulk` or `/ui/reject`. |
| **Keyboard discoverability** | **Clean-room (all)** | Persistent hint strip + `?` modal; Closure has dense kbd chrome but inconsistent mapping (j = group vs instance; `n` leaves the page). |
| **False-negative add** | **Clean-room a3 (select text)** | Capture real string → bulk-apply case-wide without retyping; Closure draw-box + separate route is correct but slower. |
| **False-positive “why”** | **Closure** | Dedicated reject surface with prefilled reason + “Reject all 90 — street name” is the best FP interaction in the set. |
| **Export readiness** | **Closure** | Flagged-block + readiness checklist exists; clean-rooms have no export gate. |
| **SPA snappiness** | **Clean-room** | Doc switch / decide / bulk without full page reload; Closure page jumps are full navigations (`/documents/:id/pages/:n`). |

Closure is the only app that has *already* been forced through 1000+ marks. Clean-rooms are **interaction prototypes**: their per-keystroke model is often cleaner, but they have not paid the UI tax for residual funnels, real PDF geometry, or export policy. The right move is not “copy clean-room wholesale” — it is **steal their in-workspace bulk + filters + FN selection**, while **keeping Closure’s funnel/group/export/why-card**.

---

## Per-flow comparison

### 1. Dashboard / case entry

| | Closure | Best clean-room |
| --- | --- | --- |
| **What you get** | Landing is the **case library** for `24-001001`: funnel stats (pending / accepted / flagged / entities), export readiness, doc table, entity “decide once” rail, chain-of-custody, address minimap. Multi-case home template exists in tree but live `/` did not surface a case picker. | **a2** case list → one card → `/review/case-1`. **a1** same pattern with progress % + explainer. **a3** similar. |
| **Throughput** | Strong: stats are **actionable** (Accept all HIGH, Resolve flagged, Open next, entity bulk). Weak: custody BREAK table + address minimap **compete** with the next decision. | Clean entry, but **no volume pressure** — 14–23 pending is a demo inbox. |
| **Dead ends** | “Resolve 0 flagged” / “Accept all HIGH (0)” stay clickable-looking with empty work. Duplicate copy: “optional warn (optional warn, does not block)”. | None serious. |
| **Winner** | **Closure** for real ops; clean-room for **calm first screen**. |

**Why:** At 1000+, the dashboard’s job is “where is the remaining work and what one action removes the most?” Closure’s 92 pending / 2 flagged / entity list answers that. Clean-room cards only say “14 pending.”

---

### 2. Library (multi-doc package)

| | Closure | Best clean-room |
| --- | --- | --- |
| **What you get** | Doc table: pages, size, suggestion counts, progress %, status, Open. Glob filter (`/`), multi-select + “Select matched”, import stub. | **a2** left **document rail** with per-doc pending, always visible in review (no separate library screen). **a1/a3** same idea. |
| **Throughput** | Good for large packages (117-page consolidated vs 3-page incident). Glob + multi-doc selection feeds bulk scope. | Faster doc switching (SPA, no leave-review). Weak at 50+ docs without virtualization (not tested). |
| **Winner** | **Split:** Closure for library-as-inventory; **a2** for library-as-always-on rail. |

**Concrete gap:** Reviewing incident then consolidated in Closure is **two full navigations**. In a2 you click rail item 2 and stay in the same keyboard context.

---

### 3. Review workspace (queue + canvas)

| | Closure | Best clean-room |
| --- | --- | --- |
| **Layout** | Left doc rail · center **real PDF page image** + marks · right **triage funnel + residual groups** · page minimap. | Left docs · center **text stand-in** · right queue (+ a2 Similar/Audit tabs). |
| **Unit of work** | **Group** (entity/kind/pattern). `j/k` moves groups; `Shift+j/k` instances; `a/r` instance; `Shift+A/R` group. | **Single suggestion**. `j/k` next/prev; `a/r` decide; auto-advance. |
| **Progress language** | “1552 of 1643 resolved · 91 residual left” — residual-aware. | “10 pending / 1 accepted” — status counts only. |
| **Throughput** | **Higher ceiling:** observed `Shift+A` → toast “Accepted group ×1” then groups of **×90** on officer/street clusters. Funnel “Accept all high-confidence” is the 1000+ weapon. | **Lower ceiling, smoother floor:** every decision is one key with no mode confusion. Breaks down when the same name appears 40× (must bulk). |
| **Clarity debt** | Funnel + threshold slider + band filters + judge panel + remainder scan + multi-select bar = **many competing models** in one rail. | Queue is immediately legible. |
| **Winner** | **Closure** for 1000+ once the operator knows the group model; **a1/a2** for first-hour learnability. |

**Specific interactions observed (Closure):**
- Open `incident_report` → real page text, marks, residual groups with “Accept group ×N / Reject group ×N”.
- `a` → toast **“Accepted — … u Undo”**, residual count ticks down.
- `u` restores.
- Funnel labels: threshold, HIGH/FLAGGED, “Flagged + known FPs never auto-pass.”
- Consolidated residual: groups of ×7 after prior triage; case-level residual still large.

**Specific interactions (clean-room):**
- a1: queue chips **≥85% / 60–84% / &lt;60%** + pending filter; row actions Accept / Reject / Accept all similar.
- a2: focus card + **Similar across case** list with counts ×4 / 3 docs; Accept all in case / this doc.
- a3: row shows **+1 similar**; Shift+A accepts similar; always-on audit stream.

---

### 4. Decisions (accept / reject / keyboard parity)

| | Closure | Best clean-room |
| --- | --- | --- |
| **Keyboard** | `a/r` instance, `Shift+A/R` group or multi-select, `h` high-conf, `x` exclude from group, `o` navigate to instance page, `u` undo, `e` bulk UI, `n` add-missed **route**, `[]` threshold. | a1: `J/K A R U B X N Space 1/2/3 0 P [ ] Enter T ?`. a2: `J/K A R B M N ? [ ]`. a3: `J/K A R S ⇧A ⇧R M N/P ?`. |
| **Click parity** | Group buttons match Shift+A/R. Bulk bar for multi-select. Some actions (add-missed, entity bulk) only via nav. | Buttons mirror keys; a1 Enter = **Apply** (separate from accept). |
| **Undo** | Toast **u Undo** + undo stack (one, group, bulk, accept-high). | **a1 only** has first-class `U` → pending + separate Apply. a2/a3: re-decide or silent no-op (a3). |
| **Winner** | **Closure** for undo + group power; **a1** for key legend completeness + apply safety. |

**Blunt problems (Closure):**
1. **`j` = group, not next mark.** Operators trained on Gmail-style j/k will accept the wrong unit. Shift+j for instances is hidden in the hint string, not a `?` modal.
2. **`n` full-page navigates** to `/ui/add-missed` instead of toggling mode in place (clean-room M/N stay put).
3. **Page change = full document reload** (`/documents/5/pages/2`). Kills muscle memory mid-stream on a 117-page file.
4. Multi-select tools exist but sit under the funnel; easy to miss vs a1 Space multi-select.

**Blunt problems (clean-room):**
1. a2 `npm start` 500’d; only `next dev` served review — prototype fragility.
2. a3 re-decide can **lie** (UI toast vs DB still accepted) — trust killer if scaled.
3. a2 overwrites decisions without undo UX.

---

### 5. Flagged / why-card / judge

| | Closure | Best clean-room |
| --- | --- | --- |
| **What you get** | **Judge panel** on review rail; dedicated **`/ui/reject`**: “Likely a false positive — matched PERSON … street address”, **Reject all 90 — log as “street name”**, audit preview of the event that will be written. Flagged excluded from high-conf auto-pass. Export blocked while flagged remain. | Confidence band + “review carefully” (a1 low band). No structured why, no forced adjudication lane. |
| **Throughput** | Reject-all-matching is **exactly** how you clear citation/street FPs at volume. | Must R each or bulk-similar by text; no explanation surface. |
| **Winner** | **Closure, decisively.** |

**Caveat:** Why-card power is diluted when reject is a **separate route** from residual queue. Best of both worlds: pin why-card on current flagged residual group *without* leaving review (design mock already wanted this).

---

### 6. Bulk

| | Closure | Best clean-room |
| --- | --- | --- |
| **Surfaces** | (1) Funnel accept-high. (2) Residual **group** accept/reject. (3) Multi-select page/high. (4) **`/ui/bulk`** entity sheet: scope docs, band filters, select eligible, Accept 90 — lay the ink, per-doc expand. (5) Entity rail “decide once”. | a2 **Similar panel always open** with case/doc scope. a1 B/X + row “Accept all similar”. a3 Shift+A/R + multi-select bulk bar. |
| **Throughput** | Highest theoretical: group ×90 + high-conf auto-pass. | Best **interaction locality**: bulk without route change. |
| **Friction** | Opening `/ui/bulk?case=1` **defaulted to officer entity** (“Det. T. Bergstrom #7303”) with 1643 instances — wrong default, expensive cognitive load. Entity click from library did not reliably deep-link in walk. | a1 “similar” badge is **doc-local** while bulk is case-wide (under-promise). a2 no multi-select of heterogeneous IDs. |
| **Winner** | **Closure for power; a2 for placement.** |

---

### 7. Add missed (false negatives)

| | Closure | Best clean-room |
| --- | --- | --- |
| **Mode** | `/ui/add-missed?doc=` — **ADD MISSED MODE** banner, drag box on PDF, category, scope search (exact/fuzzy counts in JS). Exit back to review. Remainder scan panel can one-tap residual PII. | **a3/a2:** select text on page → dialog; **bulk-apply default case/doc**. **a1:** N → draw box → **retype text** (slow, error-prone). |
| **Throughput** | Real PDF coords = production-correct. Extra navigation + draw-without-OCR-text is slower than select-text. Remainder scan is a **unique win** (finds spaced SSN etc.). | a3 bulk-apply exact string across case is the FN pattern that matters at volume. |
| **Winner** | **a3** for interaction; **Closure remainder scan** for discovery. |

---

### 8. Undo / history / audit

| | Closure | Best clean-room |
| --- | --- | --- |
| **Undo** | Toast `u` + stack covering high-conf, group, bulk, single. History drawer (`h` / History button) + server undo routes. | **a1** only: U + un-apply via status. a2/a3: weak. |
| **Audit** | `/cases/:id/audit` append-only, 1500+ rows after triage; recent list on library. | a1 modal trail; a2 tab; a3 **always-visible** trail (best continuous accountability). |
| **Winner** | **Closure** for undo depth; **a3** for always-on audit without a second screen. |

**Friction:** History drawer DOM exists but was easy to miss in walk (button works; `h` depends on history.js mount). Audit list is dense timestamps without grouping by batch (“accepted group ×90” should be one expandable row).

---

### 9. Export

| | Closure | Best clean-room |
| --- | --- | --- |
| **What you get** | Export readiness checklist, blocked when flagged remain, Export button, lineage on custody table. | **None** (out of MVP). |
| **Winner** | **Closure** (only player). |

**Blunt:** Export UX exists; prior deep reviews flag soft-block / empty-macro risks. From pure UX walk: readiness messaging is clear; competing “Ready — Export” while “90 pending REVIEW” still shows is ambiguous (warn vs block hierarchy is written twice, poorly).

---

## Ranked UX improvements Closure should adopt

Each item: **concrete interaction change** + **file hints**. Ordered by impact on **1000+ suggestion throughput**.

### P0 — steal immediately

1. **Keep bulk similar inside the review shell (no full navigation for the common path)**  
   - **Change:** Selecting a residual group or pressing `e` opens a **right-rail / bottom sheet** with case|doc scope + Accept/Reject all (a2 pattern), not only `window.location = /ui/bulk`. Full bulk sheet remains for giant entity dumps.  
   - **Why:** Every full navigation costs context + re-fetch; at 1000+ that is minutes/hour.  
   - **Hints:** `static/review.js` (`case "e"`), `server/templates/review.html`, `static/bulk.js` (extract panel), a2 reference: `components/BulkSimilarPanel.tsx`.

2. **In-place add-missed mode (stop routing `n` off-page)**  
   - **Change:** `n` toggles ADD MISSED MODE on the current page (banner already designed); drag or **text selection** posts add; Esc returns to residual queue focus. Keep `/ui/add-missed` as deep link only.  
   - **Why:** FN is a 2-second interrupt, not a mode change to another app.  
   - **Hints:** `static/review.js` `case "n"`, `static/addmissed.js`, `server/templates/add_missed.html` → fold into `review.html`.

3. **Select-text FN with bulk-apply default (a3)**  
   - **Change:** On mouse-up over word layer, prefill text + category guess; default radio **“Redact all N matches in case”** (compute N before confirm); Enter commits.  
   - **Why:** Retyping phones/emails is how FNs get mistyped; bulk-apply is the real FN payoff.  
   - **Hints:** `static/addmissed.js`, word layer in `server/templates/review.html`, a3 `ManualRedactionDialog.tsx` + `DocumentViewer.tsx`.

4. **Auto-advance after instance decide; make group keys explicit**  
   - **Change:** After `a`/`r` on an instance, move to next residual instance (or next group if empty). Show a single sticky legend: **`j/k` groups · `J/K` or `⇧j/⇧k` instances · `⇧A/⇧R` group decide**. Add `?` modal (a1).  
   - **Why:** Observed toast accepted citation instance but cursor model is easy to misread; clean-room auto-advance is why j/k feels “fast.”  
   - **Hints:** `static/review.js` `decideInstance`, `moveGroup`/`moveInstance`, `server/templates/review.html` hint-bar.

5. **SPA page navigation (no full reload for page/doc switch)**  
   - **Change:** Prev/next page and residual jump update marks + URL via `history.pushState` + fetch page payload; keep full load as fallback.  
   - **Why:** 117-page consolidated + residual instances across pages is unusable if every jump reboots the workspace.  
   - **Hints:** `static/review.js` `jumpToPage` / `focusCurrentInstance`, page routes in `server/routes/pages.sql`.

### P1 — high leverage

6. **Confidence band keyboard filters `1/2/3/0` (a1)**  
   - **Change:** `1` high only, `2` review, `3` flagged, `0` all — filter residual groups and multi-select tools. Map to existing band toggles.  
   - **Why:** “Work only the dangerous band” is how humans clear 1000+ without reading every HIGH.  
   - **Hints:** `static/review.js` `bandsOn` / `wireBands`, a1 `SuggestionQueue.tsx` + key handler in `ReviewWorkspace.tsx`.

7. **Pin why-card on current flagged residual (merge reject into review)**  
   - **Change:** When current group/instance is flagged or `flag_tag` FP, show why + **Reject all matching N — reason** inline (copy from `/ui/reject`). `r` on flagged opens reject-all confirm with prefilled reason.  
   - **Why:** Best FP UX in Closure is stranded on `/ui/reject`.  
   - **Hints:** `static/reject.js`, `static/judge.js`, `server/templates/reject.html` → `review.html` queue.

8. **Default bulk entity intelligently**  
   - **Change:** `/ui/bulk?case=` without entity opens **largest pending entity that is bulk-eligible** (not officer-of-record). Never open 1643-row officer dump as default.  
   - **Hints:** `server/templates/bulk.html`, `static/bulk.js`, entity queries in `server/routes/`.

9. **Always-visible audit stream (a3) for last N decisions**  
   - **Change:** Compact “Last decisions” under residual queue (actor · action · text · undo). Full audit stays separate.  
   - **Why:** Trust + fast undo discovery without opening History.  
   - **Hints:** `static/history.js`, `server/templates/review.html`, a3 `AuditTrail.tsx`.

10. **Virtualize residual queue + bulk instance lists**  
    - **Change:** Render only visible rows; group headers sticky; “Show N more” already exists on bulk — apply to residual instance expand.  
    - **Why:** 90-instance group + 1500 bulk rows will jank the main thread.  
    - **Hints:** `static/review.js` `renderQueue`, `static/bulk.js`.

### P2 — polish that still matters at volume

11. **Fix copy noise on case library**  
    - Deduplicate “optional warn”; disable or restyle zero-work primary buttons (“Accept all HIGH (0)”).  
    - **Hints:** `server/templates/case.html`, `static/dashboard.js`.

12. **Demote custody/map below the fold by default**  
    - **Change:** Collapse Chain of custody + Address minimap behind “Integrity / map” disclosure so NEXT actions win the fold.  
    - **Hints:** `server/templates/case.html`, `static/geo.js`.

13. **Heterogeneous multi-select with Space (a1/a3)**  
    - **Change:** Space toggles current instance into selection; Shift+A/R applies to selection preferentially (already partially true). Visible bulk bar when `selected.size > 0`.  
    - **Hints:** `static/review.js` `selected` / `onKey`.

14. **Optional separate Apply burn (a1) for export-critical cases**  
    - **Change:** Accept = “will redact”; Apply = irreversible ink + export eligibility. Toast undo only works pre-Apply.  
    - **Why:** Legal comfort; slightly slower — make it a case policy toggle, not default for all triage.  
    - **Hints:** decision model in `server/routes/decisions.sql`, UI in `review.js` / export readiness.

15. **Batch-aware audit rows**  
    - **Change:** One audit line for “Accepted group ×90 — Det. …” expandable to members.  
    - **Hints:** audit write paths in group decision routes, `server/templates/audit.html`.

---

## Shortlist: what Closure does better (keep + emphasize)

1. **Triage funnel + auto-pass high-confidence**  
   The only design that treats 1000+ as a **math problem** (total → auto → residual), not a flat list. Emphasize: one primary CTA “Accept all HIGH ≥T” above residual groups; don’t bury it under chrome.

2. **Group as unit of work**  
   “Accept group ×90” is the throughput killer feature clean-rooms only approximate with similar keys. Emphasize group headers; de-emphasize per-instance until group is open.

3. **Real PDF geometry + marks**  
   Clean-room text stubs cannot train FP judgment on layout (street in address block vs person). Keep page image + mark overlay as the source of truth.

4. **Why-card + reject-all matching with prefilled audit reason**  
   `/ui/reject` “Reject all 90 — log as street name” + audit preview is **best-in-class FP UX**. Promote it into the main residual loop; don’t orphan it.

5. **Flagged never auto-pass + export readiness**  
   Clean-rooms have no release gate. Emphasize blocked export as a **forcing function** to finish hard items first.

6. **Entity “decide once” + multi-doc bulk sheet**  
   Case-wide entity model (subject vs officer vs citation) is stronger than pure string `groupKey`. Keep HUMAN REQUIRED non-bulkable entities.

7. **Undo stack across high-conf / group / bulk / single**  
   Toast `u Undo` after group accept is production-grade. Emphasize; make History drawer the multi-step undo browser.

8. **Remainder scan**  
   Proactive FN discovery (spaced SSN, dotted phone, fuzz names) has no clean-room equivalent. Surface as a first-class residual section, not a quiet panel.

9. **Case library as ops console**  
   Progress meter, pending/flagged counts, doc inventory, audit snippet — this is a real records desk, not a demo card.

10. **Judge ensemble signal on hard items**  
    Agree/split/conflict chips on flagged rows justify skepticism; keep for adjudication mode.

---

## What not to copy from clean-rooms

| Tempting | Skip because |
| --- | --- |
| Flat pending-only queue as sole model | Collapses at 1000+ without funnel/groups |
| Separate Apply as default for every accept | Good for compliance demos; kills clerk speed unless optional |
| Stub text canvas | Loses layout FPs; Closure already has real pages |
| a2 free re-decide without undo | Audit mush |
| a3 silent no-op re-decide | Trust failure |

---

## Throughput scenario (1000 pending, same-day release)

| Step | Closure today | With P0/P1 adopted | Best clean-room alone |
| --- | --- | --- | --- |
| Clear HIGH | Funnel accept-high (strong) | Same + band `1` focus | Manual j/k or bulk-similar per string |
| Clear street/citation FPs | `/ui/reject` reject-all (strong but navigational) | Inline why + reject-all | Bulk similar by text, no why |
| Clear residual groups | Shift+A groups (strong) | + in-shell bulk + auto-advance | Similar panel (a2) |
| Catch FNs | Draw on separate page + remainder | Select-text + case bulk-apply in place | a3 select + bulk |
| Export | Readiness + flagged block | Same, clearer warn/block | N/A |

**Bottom line:** Closure already has the **right volume architecture**. Clean-rooms have the **right local interactions**. Ship the former; steal the latter. Anything that forces a full page navigation for a decision that should be a keystroke is a regression at 1000+.

---

## Session evidence appendix

| Check | Result |
| --- | --- |
| Boot `:8117` fresh | Failed after seed: `Parser Error: syntax error at or near "::"` in remainder path (concurrent edit risk). Retry same failure class. |
| Live Closure | `:8133` — 4 docs, 1643 suggestions, residual funnel, group accept, reject UI, add-missed, audit, export readiness |
| a1 | `:3001` — review keyboard + filters + bulk similar + `?` help |
| a2 | `:3011` dev — case workspace, Similar panel case/doc, M select-text mode; prod start 500 |
| a3 | `:3002` — Shift+A similar, always-on audit, multi-select |
| Files touched | **Only** `docs/ux-compare.md` |
)
