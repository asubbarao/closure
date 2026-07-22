# Closure punch-list (authoritative execution queue)

**Date:** 2026-07-19  
**Owns:** this file only (`docs/punch-list.md`)  
**Sources synthesized:** assignment brief; all of `docs/*`; `tests/e2e/` (specs + README + failed-test error-context); live findings in `sanity-check` / `review-closure`.  
**Cap:** ~40 items. One line each where possible. Duplicates killed; contradictions resolved below.

This is the **single execution queue** for submission polish. Prefer this file over raw review docs when sequencing work.

---

## How to use

| Priority | Meaning |
|----------|---------|
| **P0** | Broken *now* — demo/legal path lies or app can boot empty. Fix before any reviewer sits down. |
| **P1** | Assignment-critical gap or submission surface failure (run story, core UX contract, security footgun). |
| **P2** | Highest-impact features for graded criteria (UX, multi-doc, FP/FN, confidence, audit, code quality). |
| **P3** | Nice polish; do only after P0–P2. |

**Owner-file hints** are starting points, not exclusive locks.

---

## Conflicts resolved (docs disagree → pick a side)

| Topic | Disagreement | Decision + reasoning |
|-------|--------------|----------------------|
| **Corpus / stems** | `sanity-check` saw case `24-000117` / Magnolia Cronin / 11 docs; `review-closure` saw `24-001001` / Klein / 9 docs; page PNGs sometimes match `…-0117`, sometimes `…-001001` | **Truth is “manifest × identities × PDF basename × `pages/{stem}` must be one triad.”** Counts will drift across regenerations; the bug is silent desync (B1) + PNG stem drift (B7), not a fixed case_no. Always regenerate PNGs with the same stems as ingest. |
| **Export “blocked”** | e2e asserts UI disable + `export_plan.blocked`; `review-closure` B3 shows `POST /export` still writes PDFs with `blocked:true` | **Soft API block is a P0 bug.** UI gate is necessary but not sufficient; hard-refuse `pdf_redact` when flagged pending. |
| **Export boxes** | `export_plan` has live boxes; boot macros + `POST /export` use empty `[]` at boot | **Live plan (or rebuild macros per export) is source of truth.** Boot-baked empty macros are a product lie (B2). |
| **“Handles 1 GB PDFs”** | `architecture-thesis` / early stress marketing vs `pdf-stress` / `stress-test` / `backend-oom` | **Page-scoped extract + mid-size CTAS yes; full open of ~709 MiB ≈ RSS ≈ file size, not under `memory_limit`.** Never claim 1 GB interactive open in README. |
| **Add-missed broken?** | API integer coords work; UI drag floats → 422 + optimistic local paint | **UI path is broken for persistence (e2e GAP).** Fix client (floor coords) and/or accept floats in route params; kill “painted locally” success language. |
| **Multi-doc vs multi-case** | Assignment = multi-document packages; home hard-codes case 1 | **Case-internal multi-doc rail is OK for assignment.** Still P1 to wire `render_home()` so four ingested cases are discoverable and README doesn’t imply a single case. |
| **Rewrite in Next/FastAPI?** | Clean-room is safer stack; Closure thesis is DuckDB+quackapi | **Do not rewrite.** Fix run story + export truth + docs. Clean-room steals go into P2 UX only. |
| **`run.sh` vs `app.sql`** | Dual boot; only `app.sql` seeds + post-serve memory raise | **Canonical boot = quackapi duckdb + `.read server/app.sql`.** `run.sh` becomes thin wrapper or dies (code-quality S1). |
| **Officer/street FP band** | Design: FPs need human gate; code: only conf &lt; 60 → flagged; officer/street land in REVIEW and are bulk-eligible | **Promote structural FPs (`flag_tag` / NOT-PII kinds) to FLAGGED or non-bulkable** (review-closure B11 + rationale). |
| **Decision files vs tables** | Event-sourcing story is intentional; scaling doc says JSON glob degrades reads | **Keep file events for demo** if documented; table/log is P3 scale. Don’t dual-document three models in README. |

---

## P0 — Bugs (broken now, with repro pointers)

1. **Silent empty app on sample triad desync** — `manifest.json` × `identities.json` case_no × `samples/*.pdf` basenames INNER-join can yield `documents=0` / `suggestions=0` while serve still “ready.” **Repro:** boot with mismatched stems (observed: `cases=4, documents=0`). **Fix:** fail boot + print orphan diagnostics. Sources: `review-closure` B1, `sanity-check`. Owners: `server/ingest.sql`, `server/app.sql`.

2. **Primary export inks nothing** — `POST /api/cases/:id/export` runs boot-baked `export_sql_case_N()` with empty box arrays; mid-session accepts never refresh macros. **Repro:** accept boxes → `GET …/export_plan` shows live SQL with boxes; `server/_export_macros.sql` still `[]`; POST export `exported:1` with blank redaction. Sources: `review-closure` B2, `sanity-check` §export. Owners: `server/app.sql`, `server/routes.sql` (`export_case_live` / `build_export_sql`).

3. **Export “blocked” is soft** — `flagged_remaining > 0` still runs `pdf_redact` on unflagged docs and writes files. **Repro:** POST export while flagged pending → `{blocked:true, exported:≥1}` + file under `exports/`. Sources: `review-closure` B3, e2e `07` (UI only). Owners: `server/routes.sql` `export_case_exec` / `export_case_live`; UI toast copy.

4. **Add-missed UI does not persist** — drag posts float `x0/y0/x1/y1` → quackapi **422** integer type_error; UI paints “born accepted” locally. **Repro:** `tests/e2e/specs/03-add-missed.spec.ts` UI test; error-context toast `type_error` on `query.x1`. Integer + JSON `{}` API path works (sibling test). Sources: e2e 03 + `test-results/…/error-context.md`, `review-closure` E10. Owners: `static/addmissed.js`; optionally `routes.sql` param types.

---

## P1 — Must-fix before submission (assignment-critical)

5. **Rewrite `README.md` to match reality** — drop lies about empty suggestions, `mutate.sh`, `shellfs`, missing `export_case.sh` / `render_static.sql`; document quackapi binary, decision JSON, routes, honest PDF limits. Sources: `sanity-check`, `code-quality` S3, `review-closure` L9. Owner: `README.md`.

6. **Single boot path + post-serve memory raise everywhere** — quackapi stomps `memory_limit=256MB` (~244.1 MiB); without post-serve `SET 4GB`, review/export OOM. `app.sql` raises; **`run.sh` does not**. Sources: `backend-oom-and-fastapi`, `scaling-and-limits`, `code-quality` S1/S9. Owners: `server/app.sql`, `run.sh` → `scripts/boot.sh`.

7. **No absolute home paths in graded tree** — `/Users/aloksubbarao/personal/quackapi/...` in `app.sql` / docs / e2e README. Require `DUCKDB_BIN` / `QUACKAPI_EXT` (or documented relative). Sources: `code-quality` S2, `sanity-check` #1. Owners: `server/app.sql`, `run.sh`, `tests/e2e/README.md`.

8. **Boot integrity asserts** — after ingest/seed: `error()` if `documents=0` or `suggestions=0` when fixtures exist. Sources: `review-closure` #2 / E2. Owner: `server/app.sql`.

9. **Page PNGs for every ingested stem** — canvas `src=/pages/{filename}/pN.png` 404 when `pages/` lags sample regen (half-product: floating boxes on blank). **Repro:** open doc whose stem ≠ dirs under `pages/`. Sources: `review-closure` B7, `sanity-check` #5. Owners: `scripts/generate-samples.sh` / raster step; `pages/`.

10. **Wire multi-case home** — `GET /` is `render_case(1)`; `render_home()` + `home.html` unused; cases 2–4 orphaned. Sources: `review-closure` B9, `code-quality` S6, assignment multi-doc. Owner: `server/routes.sql` ~L546, `server/templates/home.html`.

11. **Implement words API (or drop scrape)** — README + `addmissed.js` call `/api/documents/:id/words` (and page-scoped); both **404**; HTML scrape fallback is brittle. Sources: `review-closure` B8/E5, `sanity-check` #8. Owner: `server/routes.sql`; trim `static/addmissed.js`.

12. **`scope=all` server fan-out for add-missed** — client sends `scope=all|one`; server stores flag and creates **one** synthetic suggestion (no case-wide match). Violates design/rationale FN story. Sources: `review-closure` B6, `rationale`, `ux-review` §FN, design 04. Owner: `routes.sql` `api_document_add`.

13. **Constrain decision `status` enum** — free text (`banana`) persists and corrupts progress UI. Allow `accepted|rejected|pending` only. Sources: `review-closure` B4. Owner: `routes.sql` decision macros.

14. **Kill or bind `POST …/export/run?sql=`** — arbitrary `run_sql($sql)` (SELECT 1 works). Demo footgun if port exposed. Sources: `review-closure` B5, `code-quality` M7, `quackapi-feasibility`. Owner: `routes.sql` — execute only server-built `build_export_sql`.

15. **Export UX honesty** — when blocked, say so; never toast success on empty boxes / partial write; return `{exported, blocked, flagged_remaining, box_count}`. Sources: `sanity-check` must-fix #6, `review-closure` E3. Owners: routes + `static/dashboard.js` / templates.

16. **Structural FP band gating** — officer / street / citation FPs sit in REVIEW (conf 60–89) and are entity/band bulk-eligible; design says hard human gate. Force `flagged` or `bulk_eligible=false` for `flag_tag` / NOT-PII kinds. Sources: `review-closure` B11/E8, `rationale`, `ux-review`. Owner: `server/seed.sql` / `v_suggestions` band CASE.

17. **Document decision-log mutation model in 60s** — append-only `exports/decisions/*.json` + projection is intentional event sourcing under single-SELECT handlers; README must not describe a third outdated model. Sources: `sanity-check`, `scaling-and-limits`, `rationale`. Owners: `README.md`, `docs/rationale.md` (if touch).

18. **Minimal automated smoke** — e2e tree exists but isn’t a submission gate; need SQL/curl smoke: non-empty ingest, accept → status, export_plan boxes after accept, export hard-block when flagged. Sources: `sanity-check` big #5, `code-quality` S12, `review-closure` E15, e2e README. Owners: `tests/sql/` or `scripts/smoke.sh`; keep `tests/e2e/`.

19. **Design rationale 1-pager submission-ready** — assignment Part 3; `docs/rationale.md` exists — ensure it is the submitted artifact and matches shipped UX (bands, entity bulk, export block, no overclaim on ML/OCR). Source: assignment. Owner: `docs/rationale.md` (+ link from README).

---

## P2 — Top features (highest impact on graded criteria)

20. **Why-card on canvas for FLAGGED/REVIEW** — seed already has `reason` / `flag_tag`; review UI barely shows them. Assignment FP story. Sources: `ux-review` §3, `rationale`, `review-closure` #9/E9. Owners: `static/review.js`, `server/templates/review.html`.

21. **Reject-all-matching as first-class FP path** — match-panel + prefilled audit reason (design 03); e2e covers `/ui/reject` — ensure inline `r` path is equally trustworthy. Sources: `ux-review`, e2e 02, design. Owners: `static/reject.js`, `review.js`, routes entity/text bulk.

22. **Adjudication / “Resolve N flagged” mode** — filter queue to flagged only, pin why-card, step next on decide (judge panel without full navigation). Sources: `ux-review` §5, `detection-design` panel_signal. Owners: `review.js`, optional `judge.sql` wire-up.

23. **Wire `judge.sql` + `remainder_scan.sql` into boot** — modules exist, not `.read` from `app.sql`; residual PII rail + split/conflict → flagged strengthens FN/confidence story. Sources: `detection-design` §3, `code-quality` M6. Owners: `server/app.sql`, `judge.sql`, `remainder_scan.sql`, review UI.

24. **Keyboard page-level + stay-on-page HIGH bulk** — page nav that re-anchors queue; “accept all high on this page” without leaving canvas. Sources: `ux-review` keyboard, `review-closure` #10. Owner: `static/review.js` (band API exists).

25. **Entity bulk with instance exceptions** — design: accept entity case-wide but click through near-matches (Det. X vs subject). Today: all non-flagged pending for `entity_id`. Sources: `ux-review`, `review-cleanroom` steal #1–2, `review-closure` #6. Owners: `static/bulk.js`, entity decision API.

26. **Audit action = accepted|rejected|undone (not opaque `decision`)** — legal storytelling; dedupe concurrent duplicate audit rows. Sources: `review-closure` B12/E12, assignment audit. Owners: decision COPY shape, `v_audit`, `api_case_audit`.

27. **Phrase / n-gram search** — single-token substring only; multi-word subject names return 0. Sources: `review-closure` B10/E11. Owner: `routes.sql` `api_search`.

28. **In-workspace modals for reject / add-missed / bulk** — full `/ui/*` navigations cause context loss; design mockups are overlays. Sources: `sanity-check` #9, `ux-review` modal, design HTML. Owners: templates + JS (or `return=` restore if multi-page kept).

29. **Actor / reviewer picker** — hard-coded `A. Subbarao`; clean-room attempt-2 pattern. Sources: `review-cleanroom` #7, `sanity-check` #12, `review-closure` #13. Owner: boot JSON + JS header select.

30. **Confidence legend + risk-first default sort** — explain bands; default queue flagged → review → high. Sources: `ux-review`, `review-closure` #14, e2e 06. Owner: `review.js` / queue render.

31. **PDF service boundary + INPUT/WORKING/OUTPUT layout** — isolate `pdf_*` calls; stop co-mingling fixtures, decisions, redacted outs, 700 MB stress. Graders notice organization. Sources: `code-quality` §1–2 M1/M4. Owners: new `server/pdf/*`, `storage/`, ingest/export paths.

32. **Split `routes.sql` monolith + one config package** — resource files + `config/paths.sql` / env.example; no dual `schema.sql` vs CTAS. Sources: `code-quality` M2/M8/S7. Owners: `server/routes.sql`, `schema.sql`, `ingest.sql`.

33. **Corrupt/encrypted PDF isolation at ingest** — one bad glob member aborts all; pre-`pdf_info` per file / quarantine. Sources: `pdf-stress` F1–F6, `code-quality` L2. Owner: `server/ingest.sql` (+ future `pdf/guards.sql`).

34. **Hard file-size guard for interactive open/export** — refuse when `file_size` ≫ host budget (guard on **bytes**, not DuckDB pool). Sources: `pdf-stress` S7, `backend-oom`, `scaling-and-limits`. Owner: pdf guards + export/UI banner.

35. **Focus traps + Enter-to-confirm on panels** — keyboard-first discipline for reject/add/bulk. Sources: `ux-review` §C1. Owners: shell JS files.

---

## P3 — Nice-to-have

36. **Strip debug `proof` CTE surnames** (`Yasmine|Nienow|…`) — leftover demo, empty on current corpus. Sources: `review-closure` B15, `code-quality` S4. Owner: `routes.sql` `render_document`.

37. **Tera-escaped `png_href` (`&#x2F;`)** — usually works in browsers; fix for strict clients / debuggability. Sources: `review-closure` B14. Owner: `render_document` / template.

38. **Friendlier 404/422 for missing case/doc** — today opaque Tera “variable not found.” Sources: `review-closure` B13. Owner: render macros.

39. **Decisions → table or compacted log** — JSON file explosion slows `v_suggestions` under concurrent HTML (measured). Sources: `scaling-and-limits` §3. Owner: seed/routes decision path.

40. **OCR / form / annotation residual paths** — image-only scans silent zero words; form `/V` and annotation text survive box redact. Out of assignment MVP; document as limits. Sources: `pdf-stress` F3/F9/F10, `rationale` MVP vs ideal, `detection-design`. Owners: README limits; later `pdf` OCR + form flatten.

41. **Sample corpus realism regen** (NANP/SSN/addresses via fakeit+standardizer) — proposal only; do not regen without approval. Source: `data-improvements`. Owner: `samples/gen/` (later).

42. **HTML/XML ingest via webbed/crawler** — spike only; not submission path. Source: `web-extensions-usage`. Owner: `spikes/web-ingest/` (leave).

43. **quackapi ext: configurable serve memory + binary FileResponse** — upstream; app already post-SETs memory. Sources: `quackapi-feasibility` P0/P1. Owner: quackapi repo (not Closure tree).

---

## Explicit non-goals (do not spend submission time)

- Rewrite Closure in Next.js / FastAPI “to look normal” (`sanity-check`, `code-quality` §4.4).
- Real LLM APIs or production multi-tenant auth/SaaS (`scaling-and-limits`, assignment).
- Expanding stress monsters into the demo serve path (`code-quality`, `pdf-stress`).
- Claiming full 1 GB PDF interactive handling without page-scoping (`stress-test`, `pdf-stress`).
- Implementing clean-room attempt-1 two-phase Apply/burn unless export story is already solid (`review-cleanroom` — optional later).

---

## Suggested execution order (tight)

```
P0-1 boot asserts (empty app)
P0-2 + P0-3 export live boxes + hard block
P0-4 add-missed float/422 + no optimistic lie
P1-5..7 README + single boot + no absolute paths + memory raise
P1-9 page PNGs aligned to stems
P1-10 multi-case home
P1-11..12 words API + scope=all
P1-13..16 status enum, export/run bind, export copy, FP bands
P1-18 smoke gate
then P2 why-card / reject-all / judge+remainder wire / keyboard bulk
then P2 structure (pdf/ + routes split) if time
```

**If only three ship before a human opens the laptop:** (1) export truth + hard block, (2) boot asserts + honest README/boot path, (3) page PNGs + add-missed persistence.

---

## Source index

| Doc / artifact | Role in this list |
|----------------|-------------------|
| `Alok_FDE_…Assignment.txt` | Graded requirements (review UX, bulk, multi-doc, confidence, audit, prototype, rationale) |
| `docs/review-closure.md` | Primary bug catalog B1–B16 + feature ranks |
| `docs/sanity-check.md` | Live route/mutation confirmation + submission surface |
| `docs/code-quality.md` | Structure / boot / paths / PDF layout punch items |
| `docs/backend-oom-and-fastapi.md` | 256 MB serve stomp root cause |
| `docs/scaling-and-limits.md` | OLTP myth vs real ceilings; decision-file read cost |
| `docs/pdf-stress.md` / `stress-test.md` | PDF failure modes + size-guard rules |
| `docs/ux-review.md` / `rationale.md` / `design/*` | Interaction model + FP/FN intent |
| `docs/detection-design.md` | judge + remainder_scan wire-up |
| `docs/review-cleanroom.md` | Steal list (schema/bulk/FN/reviewer) — features only |
| `docs/quackapi-feasibility.md` | Stack feasibility + ext gaps (mostly non-Closure) |
| `docs/data-improvements.md` | Corpus regen (P3 / deferred) |
| `docs/web-extensions-usage.md` / `duckdb-webapp-extensions.md` | Extension survey — non-goals for demo path |
| `docs/architecture-thesis.md` | Positioning; claims tempered by stress docs |
| `tests/e2e/specs/01–07` + README + failed add-missed result | Assignment flow coverage + confirmed UI GAP |

---

*End of punch-list. Update this file when an item ships or a conflict reopens; keep ≤~40 live items.*
