# Closure deep review — DuckDB + quackapi redaction tool

**Date:** 2026-07-19  
**App:** `/Users/aloksubbarao/personal/closure`  
**Boot exercised:**  
`/Users/aloksubbarao/personal/quackapi/build/release/duckdb -unsigned closure.db -c ".read server/app.sql"`  
→ `http://127.0.0.1:8117/` · fresh `closure.db` · prior `:8117` killed  
**Method:** Read `server/*.sql`, `static/*.js`, templates; boot real tree; HTTP exercise of every major route + mutations + export + concurrent POSTs. One aligned-corpus exercise tree under `/tmp` was used only when the live sample triad was mid-desync; final probes re-ran on the **current** repo after re-boot.

### Live baseline (current repo, post-boot)

| Metric | Value |
|--------|------:|
| Cases | 4 |
| Documents | 9 |
| Pages | 37 |
| Words | 22,789 |
| Entities | 54 |
| AI suggestions | 968 |
| Memory after serve | **3.7 GiB** (post-raise; see §2) |

Case 1 (`24-001001`, *State v. Klein*): 617 suggestions across 3 docs (consolidated alone ~494). Subject PII is real geometry from `read_pdf_words`, not mock rectangles.

---

## 1. BUGS

Ranked by severity. Only defects I could reproduce or prove from the live process + source.

### B1 — **P0: Sample triad desync → silent empty app**

**What:** `ingest.sql` builds `documents` with **INNER** joins of `manifest.json` × `identities.json` case_no × `pdf_info('samples/*.pdf')` basenames. If any leg drifts, you get **cases + entities** and **zero documents/words/suggestions**, and the server still says “ready.”

**Repro (observed this session):** First boot of the day on the real tree reported:

```
boot summary | cases=4 | documents=0 | words=0 | entities=54 | suggestions=0
```

HTTP: `GET /` 200 but empty library; `GET /documents/1` 422. Later, after samples were re-aligned (manifest filenames = on-disk PDFs, case_no = identities), boot became 9 docs / 968 suggestions. No error row, no failed boot exit — just a hollow product.

**Severity:** P0 for submission / demo.  
**Where:** `server/ingest.sql` (documents CTAS); no boot assert in `server/app.sql`.

---

### B2 — **P0: `POST /api/cases/:id/export` redacts with boot-time empty boxes**

**What:** `export_case_live` runs **boot-baked** macros `export_sql_case_N()` generated in `app.sql` before any reviewer decisions. At boot, accepted set is empty → macros embed `[]::STRUCT(...)[]`. Mid-session accepts **do not** update those macros.

**Observed (current process):**

| Source | Content |
|--------|---------|
| `GET /api/cases/1/export_plan` | Live SQL **~8.3 KB** with real `{page, x, y, w, h}` boxes (100+ accepted on doc 3) |
| `server/_export_macros.sql` | `export_sql_case_1()` still has **empty** box array |
| `POST /api/cases/1/export` | **200** `{"exported":1,"blocked":true,"flagged_remaining":6}` — runs the **empty** macro |

So the primary export button can write a “redacted” PDF that **inks nothing**, while the UI still reports a successful export count.

**Severity:** P0 product lie (legal release path).  
**Where:** `server/app.sql` L130–159; comments admit the issue; `export_plan` + `export/run` are the real path but not what a clerk hits first.

---

### B3 — **P0: Export “blocked” is soft — partial export still runs**

**What:** `export_case_exec` sets `blocked = (flagged_remaining > 0)` but still builds SQL for docs **without** pending flagged rows and runs `pdf_redact` on those.

**Observed:** With `flagged_remaining: 6` and `blocked: true`, POST export returned `exported: 1` and wrote `exports/consolidated_case_file_2024-001001_redacted.pdf`. Design intent (“export blocked until flagged resolved”) is violated.

**Severity:** P0 policy bug.  
**Where:** `server/routes.sql` `build_export_sql` / `export_case_exec`; `export_case_live`.

---

### B4 — **P1: Decision `status` is unconstrained free text**

**What:** `POST /api/suggestions/:id/decision?status=` writes whatever string you send into the decision JSON. Projection takes latest status with **no** enum check.

**Repro:**

```http
POST /api/suggestions/689/decision?status=banana&actor=current-review
→ 200 [{"Count":1}]
GET  /api/documents/5/suggestions → that row status: "banana"
```

Also works for `status=pending` (undo path — good) and garbage. UI `markVisualStatus` only special-cases `accepted` / `rejected` / flagged-by-confidence; `"banana"` renders as pending-looking ink and pollutes progress math (`resolved` counts only accepted|rejected).

**Severity:** P1 data integrity / audit.  
**Where:** `routes.sql` `api_suggestion_decision`; `seed.sql` `v_latest_decision` / `v_suggestions`.

---

### B5 — **P1: `POST /api/cases/:id/export/run?sql=` is arbitrary SQL execution**

**What:** Handler is `SELECT * FROM run_sql($sql::VARCHAR)` with `run_sql → query(q)`.

**Repro:**

```http
POST /api/cases/1/export/run?sql=SELECT%201%20AS%20x
→ 200 [{"x":1}]
```

Any client that can hit the port can run arbitrary DuckDB SQL (file read, `COPY`, extension fun). Prototype localhost assumption; still a real footgun if ever bound beyond loopback.

**Severity:** P1 security.  
**Where:** `routes.sql` L807–809, L514–515.

---

### B6 — **P1: `scope=all` on add-missed does not fan out**

**What:** UI (`static/addmissed.js`) posts `scope=all|one`. Server `api_document_add` stores `scope` on the JSON row and creates **one** synthetic suggestion. No case-wide match expansion.

**Repro:** `POST .../add?...&text=ScopeAllNow&scope=all` → Count 1; case-wide suggestions with that text = **1**.

**Severity:** P1 vs design (`docs/rationale.md`, mockup 04) and FN workflow.  
**Where:** `routes.sql` `api_document_add`; client already sends scope.

---

### B7 — **P1: Page PNGs out of sync with sample stems → broken canvas background**

**What:** Review template sets `src="{{ page.png_href }}"` → `/pages/{filename}/p{n}.png`. Live HTML:

```html
<img class="pdf-bg" src="&#x2F;pages&#x2F;incident_report_2024-001001&#x2F;p1.png" ...>
```

**Observed:**

| URL | Result |
|-----|--------|
| `/pages/incident_report_2024-001001/p1.png` | **404** |
| `/pages/incident_report_2024-0117/p1.png` | **200** (stale corpus under `pages/`) |

Word marks still paint (absolute px from PDF points × scale). Canvas looks like a blank page with floating boxes — half a product.

**Severity:** P1 UX.  
**Where:** no boot-time `pdf_to_png` (or equivalent); `pages/` not regenerated with `scripts/generate-samples.sh`.

---

### B8 — **P1: Words API advertised / depended on, not implemented**

**What:** README lists `GET /api/documents/:id/words`. `static/addmissed.js` tries `/api/documents/:id/pages/:page/words` then `/api/documents/:id/words`, then scrapes review HTML.

**Observed:** both API paths **404** `{"detail":"Not Found"}`. Scrape fallback works only if review HTML is reachable and parseable.

**Severity:** P1 for FN flow robustness.  
**Where:** missing routes in `routes.sql`; client `addmissed.js` L255–256.

---

### B9 — **P1: Home is hard-coded to case 1 — multi-case entry broken**

**What:**

```sql
CREATE OR REPLACE ROUTE home GET '/' AS SELECT * FROM render_case(1);
```

`render_home()` + `home.html` exist and are unused. Four cases ingest; `/` shows only `24-001001`. `/cases/2` works (State v. Mayer).

**Severity:** P1 vs assignment “multiple files / multi-document workflow.”  
**Where:** `routes.sql` L546; dead `render_home`.

---

### B10 — **P2: Search is single-token substring, not phrase**

**What:** `position(lower($q) IN lower(w.word))` per word.

**Observed:** `q=Esta` → 63 hits; `q=Esta%20Klein` → **0**; multi-word subject names are unsearchable as phrases.

**Severity:** P2.  
**Where:** `routes.sql` `api_search`.

---

### B11 — **P2: Street / officer FPs land in REVIEW, not FLAGGED — bulk can ink them**

**What:** Bands are pure confidence thresholds (`≥90` high, `≥60` review, else flagged). Seed sets:

| Bucket | base_conf | Resulting band |
|--------|----------:|----------------|
| Citation FP | ~58 | **flagged** (good) |
| Officer FP | ~64 | **review** |
| Street FP | ~71 | **review** |

Entity bulk and band bulk **exclude only `band = flagged`**. Officers and “Klein Street” are bulk-eligible.

**Observed:** entity accept on subject worked; officer rows stay `review` / pending; street rows accepted in concurrent race. Design docs say FPs need human gate; code only hard-gates conf &lt; 60.

**Severity:** P2 product/safety (can become P1 if bulk-accept-all-high is used casually).  
**Where:** `seed.sql` base_conf; `v_suggestions` band CASE; `api_entity_decision` / `api_doc_band_decision` filters.

---

### B12 — **P2: Audit log loses accept vs reject; duplicates under concurrency**

**What:** Decision events store `kind: "decision"` and put accept/reject only in `status`. `v_audit` / `api_case_audit` expose `action = 'decision'|'added'|…`, not `accepted`/`rejected`.

**Observed:** after many POSTs, `GET /api/cases/1/audit` actions were almost all `"decision"`. Concurrent race produced **duplicate** audit rows for the same suggestion_id/ts (same event listed twice in the union projection).

**Severity:** P2 compliance UX.  
**Where:** `routes.sql` decision COPY; `app.sql` `v_audit`; `api_case_audit` UNION.

---

### B13 — **P2: Invalid case/doc IDs → opaque 422 Tera errors**

**What:** `GET /cases/99`, `GET /documents/999` → 422 with FastAPI-ish validation body or log lines:

```
Variable `case.case_no` not found in context
Variable `doc.filename` not found in context
```

Server stayed up (does not crash), but user-facing error is useless.

**Severity:** P2.  
**Where:** render macros assume row exists; no empty-state branch.

---

### B14 — **P2: HTML-escaped `/` in `png_href` (Tera autoescape)**

**Observed raw:** `src="&#x2F;pages&#x2F;..."`. Browsers usually decode attribute entities, so this may work when the file exists; it is still wrong for a static path and confuses debugging.

**Severity:** P2 polish / potential strict-client break.  
**Where:** `tera_render` of `page.png_href` in `routes.sql` `render_document`; template `review.html` L274–275.

---

### B15 — **P3: `proof` CTE still hardcodes demo surnames**

**What:** `render_document` proof picks words matching `Yasmine|Nienow|Reyes|Rosamond|Arvel` etc. Current corpus is Klein/Mayer/… — proof block empty (harmless noise, leftover demo).

**Severity:** P3.  
**Where:** `routes.sql` L277–297.

---

### B16 — **P3: Empty POST body not rejected**

README claims empty body → 400. Live: POST decision with no body still **200** `[{"Count":1}]` when query params carry status. Minor doc/code mismatch.

---

## 2. LIMITATIONS

Honest constraints of the architecture — not all are “bugs,” but each will break the product under the wrong load or expectations.

### L1 — Single process, single writer, unsigned extension

- Requires **quackapi-built** DuckDB (`CREATE ROUTE` parser extension). Stock Homebrew duckdb is not enough.
- Paths hard-coded to `/Users/aloksubbarao/personal/quackapi/build/release/...` in `app.sql` / `run.sh`.
- Second process on the same `closure.db` → `Conflicting lock` (reproduced when probing DB while serve held the file).
- **No auth, no multi-user sessions.** Fine for a take-home; not an agency deploy.

### L2 — quackapi `ApplyServeResourceGuards` 256 MB stomp

Documented in `app.sql` and `docs/backend-oom-and-fastapi.md`: `quackapi_serve()` forces `memory_limit = 256MB` (~**244.1 MiB** effective). `app.sql` re-raises to 4 GB **after** serve (live boot showed **3.7 GiB**).  

**`run.sh` phase-3 still does not re-raise** (if anyone uses it). Under the 256 MB cap, large HTML renders / `pdf_redact` historically OOM. Limit is **database-global**, not per HTTP worker.

### L3 — Mutations are filesystem events, not OLTP row updates

Decisions = `COPY` → `exports/decisions/dec_{uuid}.json`. Status = projection over glob (`v_decision_log` → `v_latest_decision` → `v_suggestions`).

| Works well | Breaks when |
|------------|-------------|
| Human click rates, one process | Multi-node writers |
| Append-only audit story | Decision file count grows without bound (every click = file or packed multi-row file) |
| No UPDATE lock fights | `read_json('exports/decisions/*.json')` cost on every status projection |

Concurrent 12× POST accept in one process: **12/12** succeeded (good). That does **not** make multi-process OLTP safe.

### L4 — Single-SELECT route handlers

quackapi routes are one SQL statement. Consequences already encoded in the app:

- No transactional multi-table write in one handler.
- `pdf_redact` args must be **literals / foldable constants** → boot macros + `export/run?sql=` hack.
- Dynamic HTML must be one `tera_render` blob (full response buffering).

### L5 — Page-scoped render assumptions

`render_document` loads **current page** words + marks only; suggestion queue **hard-capped at 80**. Good for the 110-page historical corpus and the current 13-page consolidated (494 suggestions).  

**Breaks when:** user expects full-document queue in DOM; deep-link to suggestion id beyond the 80-cap set without API refresh; or you remove the cap and re-introduce multi-MB Tera contexts.

### L6 — Text-layer only — no OCR

Detection is n-gram match on `read_pdf_words`.  

**Breaks on:** scanned / image-only PDFs (`samples/messy/image_only_scanned.pdf` exists as a fixture), photos of reports, many court PDF exports with broken text layers. Assignment allows hardcoded suggestions; production LE release cannot.

### L7 — Detection is roster match, not “AI”

`seed.sql` matches `identities.json` phrases to same-line word n-grams. Confidence is base_conf ± hash jitter — **not** a model score. Planted FPs (street, citation, officer) are the only “hard” cases. Spaced SSNs / dotted phones are intentional FNs per seed comments — good for demo, easy to over-claim as ML.

### L8 — Geometry space

Boxes are PDF points, top-left origin from `read_pdf_words`. Export flips Y with `height_pt - y1` for `pdf_redact`. One conversion path — sound — but any second writer of boxes that forgets the flip will mis-ink.

### L9 — Dual / rotting boot paths

| Path | Reality |
|------|---------|
| `app.sql` | Current canonical (ingest + seed + routes + serve) |
| `run.sh` | Older narrative: schema.sql, shellfs, empty suggestions, no post-serve memory raise |
| `README.md` | Still claims empty suggestions, `mutate.sh`, wrong route table |

Reviewer following README alone will not understand the running system.

### L10 — No automated gate on the review loop

`tests/e2e` Playwright tree exists; stress SQL exists. No boot smoke that fails CI when documents=0 or export macros empty. Sample regeneration (`scripts/generate-samples.sh`) is easy to run half-way (PDFs+identities without manifest) — see B1.

### L11 — Scale ceilings (measured elsewhere, still binding)

From in-repo stress docs (not re-run this pass): multi-thousand-page `read_pdf_words` is OK as CTAS; full open of huge PDFs grows **native Poppler RSS** outside DuckDB `memory_limit`. Per-request full-document word lists are intentionally avoided. Concurrent large `pdf_redact` + HTML render under a forgotten 256 MB cap will fail.

---

## 3. TOP FEATURES

Highest-leverage **adds** for the assignment goals (fast triage of ~800+ suggestions, FP/FN handling, bulk, multi-doc, confidence, audit). Ranked by **impact / effort**.

| Rank | Feature | Impact | Effort | Why |
|-----:|---------|--------|--------|-----|
| **1** | **Fix export truth: live boxes + hard block** | Critical | S | Wire `POST /export` to `export_plan` SQL (or regenerate macros on each export). Refuse write when `flagged_remaining > 0`. Without this, the product cannot be trusted for release. |
| **2** | **Boot integrity asserts** | Critical | XS | After ingest/seed: fail boot if `documents=0` or `suggestions=0` when PDFs exist; print join diagnostics (orphan manifest rows). Prevents B1 demo death. |
| **3** | **Regenerate page PNGs in sample pipeline** | High | S | `pdf_to_png` (or poppler) into `pages/{stem}/` from the same stems as ingest. Restores the “document” half of the canvas. |
| **4** | **Promote structural FPs to FLAGGED (or non-bulkable)** | High | S | Force `band=flagged` (or `bulk_eligible=false`) for officer / street / citation kinds regardless of conf 60–89. Aligns bulk with design intent and assignment FP story. |
| **5** | **Real multi-case home** | High | XS | `GET /` → `render_home()`; case cards with pending/flagged counts. Unlocks multi-doc *across cases*, not only rail-within-case. |
| **6** | **Entity bulk with instance-level exceptions UI** | High | M | Design already points here: accept entity case-wide but require click-through on flagged/near-matches (Det. X vs subject). Today bulk is “all non-flagged pending for entity_id” with a full-page `/ui/bulk` shell. |
| **7** | **FN scope=all server fan-out** | High | M | On `scope=all`, n-gram search of `text` across case words, create one `added` event per hit (capped), same geometry as seed. Makes “missed redaction” scale. |
| **8** | **Status enum + audit action = accepted\|rejected\|undone** | Med-High | S | Validate POST status; store action as the decision verb; fix audit list for legal storytelling. |
| **9** | **Why-card from `reason` / `flag_tag` on canvas** | Med-High | S | Seed already has reason strings for FPs; review UI barely surfaces them on the mark. Assignment wants confidence *meaning*, not just a number. |
| **10** | **Keyboard stay-on-page bulk for HIGH** | Med | S | “Accept all high on this page” without navigation; already have band POST API. Cuts time on 800-suggestion queues. |
| **11** | **Phrase search + “find unredacted residual”** | Med | M | Search across n-grams; post-export residual scan (remainder_scan.sql exists but is not boot-wired). Assignment care: nothing missed. |
| **12** | **OCR path for scanned pages** | Med (prod) | L | Out of MVP scope per assignment, but the real LE failure mode. Messy fixtures already in tree. |
| **13** | **Multi-reviewer / actor picker** | Low-Med | S | Actor is hard-coded `A. Subbarao` in JS. Dropdown + actor on every event is cheap credibility for audit. |
| **14** | **Confidence calibration legend + sort** | Low-Med | S | Explain bands; default sort flagged → review → high for risk-first triage (inverse of pure speed). |

**If only three ship before a human reviewer opens the laptop:** (1) export truth, (2) boot asserts, (3) page PNGs + FP band gating.

---

## 4. ENHANCEMENTS

Concrete improvements to **what exists** — specific files and changes. Not greenfield features.

### E1 — Docs / entrypoint honesty (XS)

| File | Change |
|------|--------|
| `README.md` | Rewrite stack table and routes to match `app.sql` + `routes.sql` (seeded suggestions, decision JSON, `/api/...`, no `mutate.sh`). |
| `run.sh` | Either delete or make it a thin wrapper around `duckdb -c ".read server/app.sql"`; add post-serve `SET memory_limit`. |
| `schema.sql` | Mark unused-by-boot or fold into ingest; stop dual data models. |

### E2 — Ingest guards (XS)

**File:** `server/app.sql` after `.read server/ingest.sql` / seed.

```sql
SELECT
  CASE WHEN (SELECT count(*) FROM documents) = 0
       THEN error('ingest produced 0 documents — check manifest/identities/PDF basename join')
  END;
```

Plus a diagnostic `SELECT` of manifest rows that failed the join.

### E3 — Export path (S)

**Files:** `server/app.sql`, `server/routes.sql`

1. Change `POST /api/cases/:id/export` to: if `flagged_remaining > 0` then return blocked **without** calling `pdf_redact`; else `run_sql(build_export_sql(cid))` (live), not boot macros.
2. Drop or regenerate `_export_macros.sql` only as a cache, not as source of truth.
3. Return `{exported, blocked, paths[], box_count}` so the UI can toast truth.

### E4 — Decision validation (XS)

**File:** `server/routes.sql` `api_suggestion_decision` (and entity/band variants)

- `WHERE $status IN ('accepted','rejected','pending')` or map pending → undo semantics explicitly.
- Optionally write `action` column equal to status for audit.

### E5 — Close the words API hole (S)

**File:** `server/routes.sql`

```sql
CREATE OR REPLACE ROUTE api_doc_page_words GET '/api/documents/:id/pages/:page/words' AS
SELECT word, x0, y0, x1, y1, font_size, seq
FROM words
WHERE document_id = $id::INTEGER AND page_no = $page::INTEGER
ORDER BY seq;
```

Point `addmissed.js` at that only; delete HTML scrape path once stable.

### E6 — Page raster in generate or boot (S)

**Files:** `scripts/generate-samples.sh` / `samples/gen/generate.sql`, or a `server/raster.sql` step in `app.sql`.

Write `pages/{stem}/p{n}.png` for every ingested page (or first N pages for huge docs). Clear old stems on regen so B7 cannot recur.

### E7 — Home + multi-case (XS)

**File:** `server/routes.sql` L546

```sql
CREATE OR REPLACE ROUTE home GET '/' AS SELECT * FROM render_home();
```

Flesh `home.html` case cards with pending/flagged from a small aggregate (same patterns as `render_case`).

### E8 — FP band policy (S)

**File:** `server/seed.sql` (suggestion CTAS) or `v_suggestions`

```sql
CASE
  WHEN s.flag_tag = 'false_positive' OR e.kind LIKE '%NOT PII%' OR e.kind LIKE 'OFFICER%'
    THEN 'flagged'
  WHEN s.confidence >= 90 THEN 'high'
  ...
END AS band
```

One line of policy prevents bulk-inking “Det. K. Klein” and “Klein Street.”

### E9 — Review UI (S)

**Files:** `static/review.js`, `server/templates/review.html`

1. Show `reason` / `flag_tag` on current mark (why-card from design mockup 03).
2. Treat unknown status as error toast, not silent pending.
3. Surface export blocked **and** disable export button when `flagged_remaining > 0` (client check via `export_plan`).
4. Disable Tera escape for `png_href` or build URL in template from safe parts: `'/pages/' ~ doc.filename ~ '/p' ~ page.page_no ~ '.png'` with verified structure.
5. Queue: prefer **pending flagged first** when band filters allow (risk-first default).

### E10 — Add-missed / bulk shells (S)

**Files:** `static/addmissed.js`, `static/bulk.js`, templates

1. Implement `scope=all` server-side (E feature #7) or hide the control until real.
2. Prefer in-review modal (design) over full navigation to `/ui/*` for less context loss; if keeping multi-page, pass `return=` query and restore cursor.
3. Stop optimistic “painted locally” success language when POST fails (`addmissed.js` L810–816) — it demos FN flow but lies.

### E11 — Search (S)

**File:** `routes.sql` `api_search`

Match `v_grams` on `text_norm` for multi-token queries; keep word substring for single tokens. Caps already at 200 — fine.

### E12 — Audit API shape (XS)

**File:** `routes.sql` `api_case_audit`

Expose `status` from decision log; set `action` to status for decision kinds; `SELECT DISTINCT ON (suggestion_id, ts, status)` or dedupe the UNION that currently double-lists events.

### E13 — Kill export/run free SQL or bind it (S)

**File:** `routes.sql`

Prefer: `POST /export/run` takes **no** client SQL; server only runs `build_export_sql($id)`. If plan preview is needed, return SQL as text for humans but execute only server-built SQL.

### E14 — Code organization (M, non-blocking)

Per `docs/code-quality.md`: split 800-line `routes.sql` into resource files; one boot path; `storage/{input,working,output}` so `exports/decisions` is not mixed with redacted PDFs. Do after B2/B3.

### E15 — Playwright smoke (S)

**File:** `tests/e2e`

One spec: boot assumptions → open case → accept → reject → reload persists → export_plan has boxes after accept → export blocked while flagged pending. Would have caught B1–B3.

---

## Observation log (this session)

| Probe | Result |
|-------|--------|
| Boot binary | `quackapi/build/release/duckdb` v1.5.4; path briefly missing mid-build, then available |
| First boot (desynced samples) | documents=0, still listening |
| Current boot | 4 / 9 / 37 / 22789 / 54 / 968 |
| `GET /` | = `render_case(1)` only |
| `GET /documents/5` | ~226 KB HTML, ~35–43 ms; marks + queue present |
| `GET /api/documents/5/suggestions` | 64 rows; geometry sane (x∈[54,546], y∈[60,728] on 612×792) |
| Accept / reject / re-accept / pending | Persist via decision JSON |
| `status=banana` | Persists |
| Entity accept | Count 129 on entity 6 |
| Band high accept | Works; excludes flagged |
| Manual add | Synthetic id ~1e8–1e9, `source=manual`, born accepted |
| `scope=all` | No fan-out |
| Words API / new page PNG | 404 |
| Old page PNG stem | 200 |
| Export plan vs POST export | Plan live boxes; POST uses empty boot macro |
| Export while blocked | `exported≥1`, file written |
| `export/run?sql=SELECT 1` | 200 |
| Concurrent 12 accepts | 12/12 |
| Search phrase | Multi-word = 0 |
| Memory after serve | 3.7 GiB |

---

## Bottom line

Closure is a **real** review tool on a radical stack, not a clickable mock: keyboard queue, entity bulk, append-only decisions, real PDF coordinates, and a case large enough to stress triage (~600+ suggestions in case 1).  

It is also **one honest export path away from being dangerous**, and **one sample-join desync away from deming empty**. Fix B1–B3 before any reviewer demo; then ship E5–E9 so the UI matches the design story you already wrote in `docs/rationale.md` and `design/`.

The stack bet (DuckDB + quackapi + pdf + tera) is coherent for a single-clerk prototype. It is not the bug. The bugs are **silent data joins**, **stale export macros**, **soft safety gates**, and **policy bands that do not match the FP narrative**.
