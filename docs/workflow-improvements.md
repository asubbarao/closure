# Workflow improvements — reviewer throughput (800 suggestions / 1 hour)

**Role:** AI redaction reviewer, multi-document case.  
**Method:** Fresh boot (`rm -f closure.db` + `duckdb -unsigned … ".read server/app.sql"`), then end-to-end exercise of the live app on `:8117` via curl + reading served HTML/JS (`static/*.js`, `server/templates/*`, `server/routes.sql`).  
**Corpus observed:** Case `24-001001` — 3 PDFs, ~600+ suggestions (fleet-wide ~968 across 4 cases). ~131 already accepted at first paint from leftover `exports/decisions/*.json` (see dead ends).

Focus: **throughput ergonomics** (keyboard, batching, defaults, progressive disclosure) — not visual polish. Ranked by impact on suggestions cleared per minute. Dead ends are labeled **BUG**.

---

## How a reviewer actually spends the hour

| Workstream | Rough share of case 1 | Correct tool |
|---|---|---|
| HIGH band, clear PII (DOB, address, subject name) | ~65–70% | Band bulk / Select HIGH → Shift+A |
| REVIEW band FPs (officer of record, similar) | ~10–15% | Entity bulk reject **or** reject-all matching |
| FLAGGED band (citations, conf &lt;60) | ~1% but **blocks export** | Individual (or reject-all) with reason |
| False negatives / manual ink | rare | Add-missed |
| Export + audit sign-off | once | Export when flagged pending = 0 |

At ~800 items, **one-by-one `a`/`r` is not viable** (~13 decisions/min for a full hour with zero navigation cost). Throughput lives or dies on: entity fan-out, band accept, reject-all-matching, and not full-reloading a 190–270 KB HTML page for every page change.

---

## Ranked improvements

### 1. **BUG — Dashboard Export does not lay mid-session ink (silent wrong PDFs)**

**What slows me down / dead end:** After resolving all pending `band=flagged` items, `POST /api/cases/1/export` returns `blocked:false, exported:3` and feels successful. The handler runs **boot-baked** `export_sql_case_N()` macros (`server/app.sql` → `server/_export_macros.sql`). On this boot those macros were literally:

```sql
SELECT 0 AS document_id, 0 AS pages WHERE false
```

So the primary “Export redacted case…” button can **no-op** while reporting success. Live boxes exist only via `GET /api/cases/:id/export_plan` + `POST /api/cases/:id/export/run` (which *did* write redacted PDFs when called with plan SQL). Comments in `app.sql` admit this split; the UI ignores it.

**Interaction change:** Export button always: (1) `GET export_plan`, (2) if `blocked` show flagged count + jump to first flagged doc/item, (3) else `POST export/run` with the returned `export_sql` (JSON body — form body 413’d on large SQL). Toast must say pages written, not just “exported 3”. Optionally regenerate macros only as a cache, never as the sole path.

**Files:** `static/dashboard.js` (`doExport`), `server/app.sql` / `server/routes.sql` (`export_case_live`, `api_case_export`), `server/templates/case.html` (result copy).

---

### 2. **BUG — Why-card + Reject-all-matching are a separate shell with no entry from Review**

**What slows me down:** The high-throughput FP path (why-card anchored to the mark + “Reject all N — log as citation/officer”) lives only at `GET /ui/reject?doc=&sug=`. The main review workspace (`/documents/:id`, `static/review.js`) has:

- `a` / `r` → single-id decision, **no reason**
- `e` → full-page navigate to bulk sheet
- **no link, no key, no auto-open** to `/ui/reject`

So for the 6–25 flagged/FP items that block export, the “designed” flow is undiscoverable unless you already know the URL. Review treats a citation the same as high-confidence subject DOB: one `r`.

**Interaction change:**

1. On focus of any pending item with `flag_tag=false_positive` **or** `band=flagged|review` with a non-empty `reason`, show the why-card **inline on the review canvas** (same data already on the suggestion row).
2. Right rail: when that item is current, swap/stack a **Reject all matching** panel (count + prefilled reason from `kind`/`reason`).
3. Keys: `r` alone still rejects **one**; `Shift+R` with no selection = reject-all matching (same text / same entity); `f` opens focused reject mode without leaving the doc.
4. Deep-link `#s{id}` already exists — use it when returning from bulk.

**Files:** `static/review.js`, `server/templates/review.html` (why-card + match-panel markup), optionally fold `static/reject.js` logic into review and keep `/ui/reject` as a thin alias.

---

### 3. **Entity / band bulk must clear the common FP classes that currently skip**

**What slows me down:** `POST /api/entities/:id/decision` **hard-excludes** `band = 'flagged'` (`server/routes.sql`). Citation entity (e.g. entity 2, “Klein v. Ohio”) is almost entirely flagged → entity reject returned `Count:1` (only the non-flagged twin) while **6+ pending flagged cites remained**. Officer entity (entity 4) worked well (`Count:62`) because those sit in `review`.

Bulk sheet (`static/bulk.js`) correctly defaults checkboxes off for flagged, but there is **no one-click “Reject all flagged matches of this entity (log reason)”** — you must check them manually or use the orphan reject shell.

**Interaction change:**

- On entity bulk for kinds `CITATION · NOT PII`, `OFFICER · NOT SUBJECT PII`, etc.: primary button becomes **“Reject all N pending (incl. flagged) — log as {reason}”** with reason required/prefilled.
- API: either allow `include_flagged=1` on entity decision when `status=rejected`, or add `POST /api/entities/:id/reject_all` that does not filter band (export gate still requires each row decided — rejecting is deciding).
- From library entity list: one click should open bulk with that default action, not leave you guessing why the pill still says pending.

**Files:** `server/routes.sql` (`api_entity_decision`), `static/bulk.js`, `static/dashboard.js` (entity click → bulk), `server/templates/bulk.html`, `server/templates/case.html`.

---

### 4. **Default the first 5 minutes: “Accept all HIGH in case/selection”**

**What slows me down:** 400+ HIGH pending on case 1 at start. Library has **Accept HIGH in selection** (good) but:

- Requires multi-select first (checkbox/glob) — no “Accept all HIGH in case” primary.
- Review has Select HIGH + Shift+A, but only for the **current document’s loaded queue**, and flagged are excluded (good) while HIGH still need explicit select.
- No single keystroke from case dashboard for “clear the safe pile.”

**Interaction change:**

1. Case library header when `high_pending > 0`: primary secondary-action **“Accept all HIGH in case (N)”** with confirm toast + Undo (U).
2. Review: **`Shift+H`** = select all eligible HIGH on current doc + accept in one step (select+decide).
3. After accept, auto-advance cursor to first pending REVIEW/FLAGGED on the current page (not another HIGH).
4. Progress copy: “N HIGH left · M need judgment” not only “X of Y reviewed.”

**Files:** `static/dashboard.js`, `static/review.js`, `server/templates/case.html`, `server/templates/review.html`; reuse `POST /api/documents/:id/band/high/decision`.

---

### 5. **Stop full-page reloads on page change (biggest navigation tax)**

**What slows me down:** `j`/`k` onto a suggestion on another page does `window.location.href = /documents/:id/pages/:p#s…`. Each review page SSR is **~190–270 KB** of word-box HTML (~40ms server, plus parse/layout). A 13-page consolidated file × dozens of cross-page hops burns minutes.

**Interaction change:**

- SPA-lite page switch: fetch page fragment or `/api/documents/:id/suggestions` + words for page N; swap `#pdf-page` / marks; update URL with `history.pushState`.
- Keep SSR for first paint only.
- Minimap clicks and `g`+Enter use the same path.
- Prefetch adjacent pages’ suggestion coords when idle.

**Files:** `static/review.js`, `server/routes.sql` (page-scoped words/suggestions if missing), `server/templates/review.html`.

---

### 6. **One decision POST for bulk, not N sequential HTTP calls**

**What slows me down:** Review multi-select and bulk sheet accept/reject fire **one POST per suggestion** (`Promise.all` / `for` loop). Entity route is the only true fan-out. Accepting 50 HIGH = 50 JSON files under `exports/decisions/`, 50 audit rows (and today often **duplicated** — see #12). Latency and failure toast (“k of N POSTs failed”) show up under real load.

**Interaction change:**

- `POST /api/suggestions/batch/decision` with body `{ ids: [...], status, reason, actor }` writing one multi-row COPY or one JSON array.
- UI keeps optimistic local state; one undo event restores the batch.
- Keep per-id route for single keys.

**Files:** `server/routes.sql`, `static/review.js` (`bulkDecide`), `static/bulk.js` (`decide`), `static/reject.js` (`rejectAllMatching`).

---

### 7. **Flagged workqueue as a first-class “finish export” lane**

**What slows me down:** Export blocked banner says “Jump to flagged items →” but only scrolls to `#library` / first `tr.flagged-row`. It does **not** open the first flagged suggestion. Library status shows “N flagged” but Open still lands on page 1 (often zero flagged marks).

**Interaction change:**

1. Banner CTA → `/documents/{first_flagged_doc}/pages/{p}#s{id}` or `/ui/reject?doc=&sug=`.
2. Library: per-doc action **“Resolve N flagged”** (not just Open).
3. Review: band filter preset URL `?band=flagged` and default cursor to first pending flagged when arriving from export banner.
4. Case-level **Adjudication** list: flat table of all pending `band=flagged` with one-key reject/accept and reject-all-by-text.

**Files:** `static/dashboard.js` (`wireJump`, export banner), `server/templates/case.html`, `static/review.js` (boot cursor / query params), new small route or bulk `?band=flagged`.

---

### 8. **BUG — Decision status is free text (`banana`, `flagged` as status)**

**What I hit:** `POST …/decision?status=banana` persisted; `status=flagged` on a HIGH-band item created a fourth pseudo-state. Projection (`v_latest_decision` in `server/seed.sql`) accepts any string. Progress math counts only `accepted|rejected` as resolved → **banana/flagged pollute pending counts and export semantics** (export gate is `band=flagged AND status=pending` only — a `status=flagged` HIGH does **not** block export and **does not** lay ink).

**Interaction change:** Server allow-list `accepted|rejected|pending` (and map `undone`→pending). Reject others with 400. UI never posts `flagged` as status; “flag for supervisor” if needed is a separate tag, not status.

**Files:** `server/routes.sql` (`api_suggestion_decision`), `server/seed.sql` / `v_suggestions`, `static/review.js` (`decide` statuses).

---

### 9. **BUG — Page PNGs for reject / add-missed are wrong corpus (404)**

**What I hit:** `static/reject.js` / `addmissed.js` load `/pages/{filename}/p{n}.png`. Served tree is `pages/incident_report_2024-0117/…` while live docs are `incident_report_2024-001001`. Result: **404**, canvas background hidden — why-card floats over empty page. Review still works (word boxes SSR); FP and add-missed modes feel broken.

**Interaction change:** Generate `pages/` for the active sample filenames at ingest, **or** make reject/add-missed use the same word-box stage as review (no PNG dependency). Prefer word boxes — one renderer, always in sync with coords.

**Files:** ingest/page render scripts, `static/reject.js`, `static/addmissed.js`, `pages/`.

---

### 10. **Add-missed `scope=all` is a lie (one box only)**

**What I hit:** UI promises “Redact all N matches.” `POST /api/documents/:id/add` writes **one** `kind=added` row with a `scope` field; no fan-out boxes for other pages/docs. Search works (`/api/search?q=&case=` — note param is `case`, not `case_id`). Match counts can look real while confirm only inks the drag rect.

**Interaction change:** On confirm with scope=all: for each search hit, emit an accepted manual suggestion (batch). Show “Added ink on N pages / D docs.” Default scope = **all** when match count &gt; 1 (progressive disclosure: “this instance only” secondary).

**Files:** `server/routes.sql` (`api_document_add` or new batch add), `static/addmissed.js`, `server/templates/add_missed.html`.

---

### 11. **Keyboard completeness & mode consistency**

| Context | Today | Missing for speed |
|---|---|---|
| Review | `j k a r x u e n g`, Shift+A/R bulk | `Shift+H` accept HIGH; `f` flagged lane; `p`/`[` `]` page without reload; `?` cheat-sheet toggle |
| Bulk sheet | mouse + glob Enter | `a`/`r` accept/reject selection; `x` toggle row; `j/k` move; Esc closes back to **referrer doc#s** |
| Reject shell | `a r` + reject-all | Wired, but orphaned — see #2 |
| Library | almost none | `o` open first selected; `h` accept HIGH in selection; `/` focus glob |
| Audit | none | `/` filter, `j/k` |

**Files:** respective `static/*.js` + hint bars in templates.

---

### 12. **BUG — Audit log doubles every event; no filter**

**What I hit:** `GET /api/cases/1/audit` returned **477 rows / 239 unique** (every event twice). HTML audit is a flat dump (“134 rows” at one point) with no filter by actor, action, document, or suggestion. After a bulk hour this is unusable for “what did I just do?”

**Interaction change:** Fix the double-read (likely double-expand of `read_json` / UNION of decision files). Audit page: filter chips (decision / added / export), search box, click row → open `/documents/…#s{id}`. API: dedupe or fix source view.

**Files:** `server/seed.sql` (`v_decision_log`), `server/routes.sql` (`api_case_audit`, `render_audit`), `server/templates/audit.html`.

---

### 13. **BUG — Fresh DB is not a fresh review (decisions sidecar survives)**

**What I hit:** `rm -f closure.db` only. Boot re-ingests PDFs then folds **all** `exports/decisions/*.json` into `v_suggestions`. First paint already `131 / 618` accepted, plus a prior `status=banana` row. Reviewer cannot trust “cold start” metrics; stress tests contaminate demos.

**Interaction change:** `run.sh` / docs: `rm -f closure.db exports/decisions/dec_*.json exports/decisions/add_*.json` (keep sentinel). Or boot flag `CLOSURE_FRESH=1`. Library should show “including N decisions from prior sessions” if any.

**Files:** `run.sh`, `server/app.sql` / `server/seed.sql` (optional ignore), `README.md`.

---

### 14. **Multi-case fleet is invisible**

**What I hit:** `api/stats` → 4 cases / 9 docs / 968 suggestions. `GET /` is hardwired `render_case(1)` (`routes.sql`). `render_home()` / `home.html` exist but are unwired. No case switcher in chrome. One-hour multi-case review cannot even pick the next case without typing `/cases/2`.

**Interaction change:** `/` = case list (home template) with pending/flagged/export-ready columns. Case chrome: switcher dropdown. Deep links only.

**Files:** `server/routes.sql` (home route), `server/templates/home.html`, app bar partials in `case.html` / `review.html`.

---

### 15. **Progressive disclosure on the review queue**

**What slows me down:** Queue groups by entity with “Select N” / “Accept all in case” but:

- Entity counts are **doc-local** (`suggestions` array is document-scoped) while label says “in case.”
- Already-accepted rows still occupy scroll space.
- No collapse of “all HIGH remaining for this entity.”
- Checkbox disabled for flagged with no explanation in-row (only a global flag-excl banner when selection active).

**Interaction change:**

- Default filter: **Pending only** (toggle “Show decided”).
- Entity header: case-wide pending count from a cheap `/api/cases/:id/entities` or embedded boot stats.
- Row subtitle for FP: show `reason` one line (so why-card is not the only place).
- Collapse decided groups; sticky “N pending above/below” jump.

**Files:** `static/review.js` (`renderQueue`, `entityMeta`), `server/templates/review.html`, `server/routes.sql` if case entity stats needed.

---

### 16. **Export readiness checklist (blockers → actions)**

**What slows me down:** Binary disabled Export + banner. No list of *what* to clear. After resolving flagged via API without reload, button state depends on client re-fetch (`data-flagged-count` SSR).

**Interaction change:** Expandable checklist under the banner:

1. N pending flagged → link to adjudication lane  
2. M pending REVIEW (optional warn, don’t block)  
3. Docs with 0 accepted ink (warn)  
4. Ready → Export  

On successful resolve in-page, re-fetch `/api/cases/:id/export_plan` and enable button without full reload.

**Files:** `static/dashboard.js`, `server/templates/case.html`.

---

### 17. **Library multi-doc scope should be the default for entity work**

**What works:** Glob filter, select matched, “Review selected…”, entity bulk with `?docs=`.  

**What slows me down:** Scope is easy to forget; entity click from the card ignores current selection unless you re-open with scope. “Accept HIGH in selection” is powerful but unlabeled as the recommended first action.

**Interaction change:** When any docs selected, entity clicks auto-append `docs=`. Empty selection = whole case (explicit chip). Keyboard `/` focuses glob; Enter selects matched then offers HIGH accept.

**Files:** `static/dashboard.js`, `server/templates/case.html`.

---

### 18. **Reason capture without slowing the happy path**

**What slows me down:** Single `r` on review logs empty reason. Audit then useless for FOIA challenge. Reject shell auto-reasons (“case citation”, “officer of record”) — that intelligence never reaches review.

**Interaction change:**

- Happy path HIGH accept: no reason dialog.
- Reject on `flag_tag` / non-high: auto-fill reason from `s.reason` or kind map (same as `auditReasonLabel` in `reject.js`); show in toast; `Shift+Enter` to edit once.
- Never block accept on HIGH with a modal.

**Files:** `static/review.js`, share helper with `static/reject.js`.

---

## Dead ends / bugs checklist (honest)

| # | Symptom | Severity |
|---|---|---|
| D1 | Export button uses empty boot macros → success without redactions | **P0** |
| D2 | Why-card / reject-all not reachable from main review | **P0** throughput |
| D3 | Entity decision skips `band=flagged` → citations uncleared | **P0** for export gate |
| D4 | Free-form decision status (`banana`) | **P1** data integrity |
| D5 | Page PNGs path/corpus mismatch → blank FP/add-missed canvas | **P1** |
| D6 | Add-missed scope=all does not fan out | **P1** |
| D7 | Audit events duplicated ~2× | **P1** |
| D8 | `rm closure.db` keeps prior decisions | **P2** demo/hygiene |
| D9 | `/` not multi-case home | **P2** |
| D10 | Full HTML reload per page | **P1** throughput |
| D11 | N HTTP posts per bulk | **P2** reliability |
| D12 | Search requires `case` (easy to call wrong) | **P2** |

---

## Suggested 1-hour playbook *with today’s code* (workarounds)

1. Open `/cases/1`. Note flagged count; **do not** trust Export until you have called `export_plan` and preferably `export/run` yourself.
2. Select all docs → **Accept HIGH in selection** (library). Repeat per case if needed via `/cases/2`… typed URLs.
3. Click each high-volume entity (subject, DOB, address) → bulk Accept. For **officer** entities → Reject all eligible.
4. For **citations / FLAGGED**: open  
   ` /ui/reject?doc={id}&sug={flagged_id} `  
   (discover IDs from `GET /api/cases/1/suggestions` filtered `band=flagged`) → **Reject all matching**. PNG may be blank; marks still clickable if API coords load.
5. Review remaining REVIEW band with `j/k` + `a/r`; use `e` for entity bursts; avoid cross-page `j` thrash — jump via minimap.
6. `n` add-missed only for true misses; use scope=one until fan-out is fixed.
7. Export:  
   `GET /api/cases/1/export_plan` → if not blocked → `POST /api/cases/1/export/run` with plan SQL JSON — **not** the dashboard button alone.
8. Audit: expect duplicates; filter mentally by timestamp.

---

## Highest-leverage file touch map

| Priority | Files | Outcome |
|---|---|---|
| P0 | `static/dashboard.js`, `server/app.sql`, `server/routes.sql` | Live export path |
| P0 | `static/review.js`, `server/templates/review.html` (+ reject panel) | FP throughput in main lane |
| P0 | `server/routes.sql` entity decision, `static/bulk.js` | Flagged entity clear |
| P1 | `static/review.js` page fetch | Kill full reloads |
| P1 | batch decision route + JS callers | Bulk reliability |
| P1 | `static/reject.js` / pages ingest or word-box reuse | FP canvas works |
| P1 | `static/addmissed.js` + add API | Scope=all real |
| P2 | status allow-list, audit dedupe, home route, fresh-boot script | Trust & hygiene |

---

## North-star interaction (target state)

1. Land on case → **one click** accepts all HIGH (undoable).  
2. Entity rail → decide once; FPs including flagged reject-all with auto reason.  
3. Stay in document: why-card + reject-all without route change; pages soft-navigate.  
4. Flagged lane empties → Export runs **live** boxes → audit is a filterable single source of truth.  

Anything that forces a full navigation, a hidden URL, or a silent no-op export is a direct tax on the 800/hour goal.
