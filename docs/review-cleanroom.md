# Clean-room review: three AI PDF redaction-review prototypes

**Date:** 2026-07-19  
**Scope:** `/Users/aloksubbarao/personal/closure-cleanroom/attempt-{1,2,3}`  
**Constraint:** Read-only on clean-room apps; write only this file. No main-repo material was copied into the clean-room trees.

All three implement the same take-home brief (`ASSIGNMENT.txt`): keyboard-first AI redaction review for law-enforcement public-records release — false positives/negatives, volume, multi-doc packages, confidence, audit trail. Stack in all cases is TypeScript / Next.js 15 App Router / React 19 / Tailwind / SQLite / Vitest. No real ML or PDF parser; page text is fixture-driven.

---

## Executive ranking

| Rank | Attempt | Verdict in one line |
| ---: | --- | --- |
| **1** | **attempt-2** | Strongest overall product: case-scoped workspace, decision/audit data model, bulk-similar panel with doc/case scope, multi-reviewer, best multi-doc stub. |
| **2** | **attempt-3** | Best FN (select-text) path and always-on audit; text-offset model is closer to real extraction; slightly thinner data model and a few API silent-no-ops. |
| **3** | **attempt-1** | Most complete *legal* review loop (accept → separate **Apply** burn + undo); weaker multi-doc/bulk UX and FN capture. |

**Viable alternative direction:** **attempt-2** (with FN selection + confidence filters stolen from 3 and 1). None is a full replacement for a DuckDB/PDF production app, but attempt-2 is the only one whose interaction model + schema are coherent enough to treat as a UX/architecture north star rather than a grab-bag of ideas.

---

## 1. Does it build / run? (evidence)

Environment: Node **v24.11.0**, macOS. `node_modules` already present in all three.

| Check | attempt-1 | attempt-2 | attempt-3 |
| --- | --- | --- | --- |
| Package manager | npm (`package-lock.json`) | npm | pnpm lock; `pnpm`/`npm` both worked |
| SQLite driver | `better-sqlite3` | `node:sqlite` (experimental) | `node:sqlite` (experimental) |
| Node engines | 20+ (README) | ≥22.5 | ≥22.5 |
| **`npm/pnpm test`** | **24/24 pass** (8 files, ~2.7s) | **18/18 pass** (6 files, ~2.6s) | **23/23 pass** (6 files, ~2.4s) |
| **`npm/pnpm build`** | **OK** Next 15.5.20 | **OK** Next 15.5.20 | **OK** Next 15.5.20 |
| Typecheck / lint | `tsc --noEmit` **OK** | `tsc --noEmit` **OK** | eslint during build **OK** |
| **`npm start` smoke** | `/` 200, `/api/cases` 200, `/review/doc-incident-report` 200 | `/` 200, `/api/cases` 200, `/review/case-1` 200 | `/` 200, `/api/cases` 200, `/cases/case-stub-1` 200 |
| Mutation smoke | PATCH accept/reject/undo; POST apply | decide + re-decide; bulk-decide | decide; manual + bulk-apply (fresh DB) |

### Route surface (from production builds)

- **attempt-1:** case list `/`, review `/review/[documentId]`, APIs for cases, documents, suggestions (+ bulk), apply, audit.
- **attempt-2:** case list `/`, review `/review/[caseId]`, APIs for cases (+ audit), documents, decide, bulk-decide, manual-redactions, reviewers.
- **attempt-3:** case list `/`, review `/cases/[caseId]`, APIs for cases, workspace, decide, bulk, manual, audit.

### Size / structure (rough)

| | attempt-1 | attempt-2 | attempt-3 |
| --- | ---: | ---: | ---: |
| `src` TS/TSX files | 36 | 36 | 38 |
| Lines under `src` | ~4.3k | ~4.2k | ~4.1k |
| Test files | 8 | 6 | 6 |
| Review client JS (build) | ~8.8 kB page | **~21.6 kB** page | ~18.7 kB page |
| Design rationale | `DESIGN.md` | `DESIGN.md` | `DESIGN_RATIONALE.md` |

**Strongest:** **attempt-2** — builds and runs like the others, but the case-level shell, similar-group panel, reviewer switcher, and immutable-suggestion / decision-row schema form a more complete product story for multi-document package review.

---

## 2. BUGS — reproducible defects (ranked by severity)

### attempt-1

| # | Severity | Defect | Where / how |
| ---: | --- | --- | --- |
| 1 | **High (UX)** | **“Similar” badge counts only the current document**, while **B/X bulk is case-wide**. Reviewer can see “2 similar” and then toast “Accepted 4 … (2 in other docs)” — under-promises, then surprises. | `ReviewWorkspace.tsx` `similarCounts` memo over local `suggestions` only; `bulkSimilar` passes all `documents.map(d => d.id)`. |
| 2 | **Medium** | **Manual FN cannot bulk-apply across case.** Draw box → type text → one accepted suggestion on one page. Same name in other docs must be re-added. | `addManualSuggestion` in `src/lib/repository.ts`; no `applyAcrossCase` in `AddRedactionModal.tsx`. |
| 3 | **Medium** | **Draw-to-add does not capture underlying text.** User must retype DOB/phone from the paper — easy to mistype; planted FN workflow is slower than select-text. | `DocumentViewer.tsx` draw handlers → modal `defaultText=""`. |
| 4 | **Medium** | **Bulk audit event attaches a single `documentId` (last processed)** even when updates span many docs. Case-level audit reconstruction is lossy. | `bulkSetStatus` loop overwrites `documentId` then writes one audit row. |
| 5 | **Low** | **Accept advance logic is brittle:** after accept, pending list is rebuilt from stale+mapped state; works via fallbacks but is hard to reason about and can jump selection oddly when filters are on. | `acceptOne` in `ReviewWorkspace.tsx`. |
| 6 | **Low** | **`groupKey` is text-only** (`groupKeyForText`), so the same string in different categories would bulk together incorrectly if categories diverge later. | `src/lib/confidence.ts`. |
| 7 | **Low (env)** | Existing `data/redaction.db` may already contain decisions from prior runs (`pendingCount` ≠ full seed). Fine for demos; confusing for evaluators unless `FORCE_SEED=1 npm run db:seed`. | README documents force seed. |

### attempt-2

| # | Severity | Defect | Where / how |
| ---: | --- | --- | --- |
| 1 | **High (compliance)** | **Decisions are freely overwritable** via `ON CONFLICT DO UPDATE` with **no undo UX and no “locked after apply”**. Smoke: accept then re-decide reject on same id — both succeed and both audit. Legal “who decided” becomes a stack of rewrites without explicit amend flow. | `decideSuggestion` in `src/db/repository.ts`. |
| 2 | **Medium** | **Add-mode text selection bbox is approximate:** first `textBlocks` whose text *includes* the selection; wrong box if the same substring appears twice on a page. | `DocumentCanvas.tsx` `handleMouseUp`. |
| 3 | **Medium** | **No multi-select of heterogeneous suggestions** (only similar-group bulk). Cannot select “all high-conf SSNs on this page” of different strings. | Queue has no checkbox / Space multi-select. |
| 4 | **Medium** | **No confidence-band filter** in the queue (95% vs 60% is visible but you cannot slice the queue by band with 1/2/3). | `SuggestionQueue.tsx` status filter only. |
| 5 | **Low** | **Fixed 612×792 CSS px canvas** does not reflow; small viewports scroll heavily; not responsive. | `DocumentCanvas.tsx` `displayWidth/Height = page.width/height`. |
| 6 | **Low** | **`N` only advances documents** (wraps to first); no keyboard previous-doc (must click rail). | `goNextDocument` / key handler. |
| 7 | **Low** | **`planted_misses` table is seeded but unused by UI/API** — pure evaluation metadata; easy to assume it surfaces somewhere. | `schema.sql`, seed path only. |
| 8 | **Low** | **`node:sqlite` experimental warning** on every worker during build/runtime. | Node built-in. |

### attempt-3

| # | Severity | Defect | Where / how |
| ---: | --- | --- | --- |
| 1 | **High (API)** | **Re-decide on non-pending is a silent success.** Second POST with `status: rejected` after accept returns HTTP 200 with `updated` still `accepted` (UPDATE only `WHERE status = 'pending'`). UI can toast “Rejected” while DB unchanged. | `decideSuggestion` in `src/lib/db/repository.ts`; confirmed via API smoke. |
| 2 | **Medium** | **No undo / no decision amend path.** Once accepted/rejected, only way out is DB reset. | Mutations never set status back to pending. |
| 3 | **Medium** | **Single fixed reviewer** (`meta.current_reviewer`); no switcher — multi-user audit story is incomplete. | `getCurrentReviewer`. |
| 4 | **Medium** | **No confidence-band queue filter** (band shown on badges only). | `SuggestionQueue.tsx`. |
| 5 | **Low** | **Dirty-DB false negative on bulk-apply:** if the email was already manual-redacted, bulk reports `bulkCount: 0` (covered skip). Correct logic, poor UX (no “already covered” message). | `addManualRedaction` `isCovered` / skip original. |
| 6 | **Low** | **Plain-text viewer**, not page-coordinate PDF stand-in — fine for prototype, but overlays are spans not bboxes; harder to port to real PDF.js without a second geometry model. | `DocumentViewer.tsx` + `DocumentPage.textContent`. |
| 7 | **Low** | **`node:sqlite` experimental** same as attempt-2. | |

---

## 3. LIMITATIONS — vs assignment (ranked)

Assignment asks for: main review UI, fast FP reject, FN add, bulk similar, multi-doc, confidence, audit; SQLite OK; hardcoded suggestions OK; design rationale 1-pager; working prototype.

### Shared omissions (all three)

1. **No real PDF** (pdf.js / true page geometry) — expected by brief, but still the largest production gap.
2. **No export** of redacted package + audit CSV/PDF.
3. **No multi-user auth**, roles enforced only as data (attempt-2 has role field but no gates).
4. **Stub scale only** (1 case, 2–3 docs, ~15–23 suggestions) — does not prove 100+ / 50-doc performance.
5. **No high-fidelity external mockups** (Figma/etc.) — design *is* the running UI + `DESIGN*.md` (acceptable if the app is the mockup).

### attempt-1 — what it gets wrong / omits

| Rank | Gap |
| ---: | --- |
| 1 | **Document-primary routing** (`/review/[documentId]`) — case is a sidebar of full navigations, not a single package workspace. |
| 2 | **FN path is draw+type**, not select-text; no case-wide FN bulk. |
| 3 | **No multi-reviewer model** (string actor only). |
| 4 | **Similar grouping is weaker** (text-only key; similar counts not case-wide in UI). |
| 5 | **Two-phase Apply** is powerful but easy to misread as “accept already blacked it out” (accepted = green tint, applied = solid black) — needs stronger copy. |
| 6 | Fixture contract is lighter (no Zod versioned bundle on API path comparable to attempt-2). |

### attempt-2 — what it gets wrong / omits

| Rank | Gap |
| ---: | --- |
| 1 | **No separate “apply/burn” step** — accept immediately paints opaque black; no staging of decisions before irreversible blackout mental model. |
| 2 | **No undo** and decisions overwrite (see bugs). |
| 3 | **No multi-select bulk** for mixed entities. |
| 4 | **No confidence queue filters**. |
| 5 | **FN bbox approximation** weakens trust in where the black bar lands. |
| 6 | Experimental SQLite driver (install is easy; long-term Node API risk). |

### attempt-3 — what it gets wrong / omits

| Rank | Gap |
| ---: | --- |
| 1 | **Text-stand-in only** — least “PDF-like” of the three; multi-column / form layouts not representable. |
| 2 | **No apply/burn staging**. |
| 3 | **No undo**; re-decide API lies (bug). |
| 4 | **No reviewer switcher**. |
| 5 | **No dedicated similar-groups explorer** (only Shift+A/R + per-row “+N similar” badge) — harder to browse all groups in a case. |
| 6 | Design doc is stronger than attempt-1/2 on visual system, but home page is more marketing than ops queue. |

### Feature coverage matrix

| Assignment need | attempt-1 | attempt-2 | attempt-3 |
| --- | :---: | :---: | :---: |
| Queue + doc context | ✅ | ✅ | ✅ |
| Fast reject FP | ✅ A/R | ✅ A/R | ✅ A/R |
| Add FN | ✅ draw | ✅ select text | ✅ select text (best) |
| Bulk similar | ✅ B/X case-wide | ✅ panel doc/case | ✅ Shift+A/R + multi-select |
| Multi-document | ✅ sidebar links | ✅ rail + N (best stub: 3 docs) | ✅ sidebar + N/P |
| Confidence display | ✅ % + band + **filters** | ✅ % + band | ✅ % + band |
| Audit trail | ✅ panel (doc-filtered) | ✅ tab | ✅ always-on pane |
| Design rationale | ✅ | ✅ | ✅ |
| Tests | ✅ strongest count | ✅ | ✅ |

---

## 4. TOP FEATURES — best ideas across the three (steal list, ranked)

1. **Immutable suggestions + `suggestion_decisions` table (attempt-2)**  
   AI proposals never mutate; decisions are separate rows with actor + time. Best compliance story and easiest to explain in audit. Files: `src/db/schema.sql`, `decideSuggestion` / `bulkDecideByGroup`.

2. **Case-scoped workspace + dedicated Similar panel with doc vs case scope (attempt-2)**  
   Right rail tabs: Similar / Audit / Keys; bulk buttons “Accept all in case” vs “Accept in this doc”. Files: `BulkSimilarPanel.tsx`, `listSimilarGroups`, `ReviewWorkspace.tsx`.

3. **Native text selection → FN dialog → exact-string bulk-apply across case (attempt-3)**  
   Maps directly to how records officers think (“select the email, redact everywhere”). Offset search + skip-if-covered + auto-accept pending exact match. Files: `DocumentViewer.tsx` `handleMouseUp`, `addManualRedaction` in `repository.ts`, `ManualRedactionDialog.tsx`.

4. **Two-phase Accept vs Apply burn (attempt-1)**  
   Triage freely; Enter/`apply` commits blackouts (`applied=1`). Matches legal “nothing is final until burn.” Files: `applyRedactions` in `repository.ts`, `api/redactions/apply`, overlay classes in `globals.css` / `DocumentViewer.tsx`.

5. **Confidence-band queue filters + keyboard 1/2/3 (attempt-1)**  
   Clear high-conf first, park low-conf for careful review. Files: `SuggestionQueue.tsx`, `confidence.ts`, keyboard handler in `ReviewWorkspace.tsx`.

6. **Multi-select heterogeneous bulk bar (attempt-3; also attempt-1 Space)**  
   Select arbitrary pending items → floating Accept/Reject N. Complements similar-key bulk. Files: `BulkActionBar.tsx`, Space/S toggle.

7. **Reviewer switcher + roles (attempt-2)**  
   Audit is only as good as actor identity. Files: `reviewers` table, header `<select data-testid="reviewer-select">`.

8. **Versioned FixtureBundle + Zod (attempt-2) / JSON Schema (attempt-3)**  
   Drop-in real data without rewriting seed code. Files: `src/data/contract.ts`, `data/fixture.schema.json`, loaders.

9. **Undo to pending (attempt-1)**  
   `U` key + audit `reset_pending`. Essential for high-volume error recovery.

10. **Always-visible live audit stream (attempt-3)**  
    Bottom of right column; no tab switch to see “what just happened.”

11. **Segmented text-mark rendering with overlap priority (attempt-3)**  
    Active > selected > pending > accepted > manual. File: `segmentText` in `DocumentViewer.tsx`.

12. **Progress per document in left rail (all; polish in 1 & 2)**  
    Pending left + % bar — case package glanceability.

13. **Shift-modifier for “apply to similar” on the primary decision keys (attempt-3)**  
    Muscle memory: A accept one, Shift+A accept family — no mode switch.

14. **Planted FP/FN documentation in fixture meta (all; richest in 2)**  
    `plantedAsFalsePositive`, `plantedMisses`, evaluator notes — makes demos honest.

---

## 5. ENHANCEMENTS — concrete improvements for the strongest (attempt-2)

Ranked by impact / effort:

1. **Add a staging/apply step (from attempt-1)**  
   Keep decisions as accept/reject; only `applied` manuals + accepted decisions render solid black; add “Commit blackouts” with audit `redaction.apply`. Prevents accidental public-looking previews.

2. **Fix decision amend policy**  
   Either: (a) disallow overwrite unless `status === pending` and return 409; or (b) explicit undo that inserts a compensating audit event and deletes/clears decision. Smoke currently allows silent legal history rewrites.

3. **Port select-text FN + exact occurrence search (from attempt-3)**  
   Replace `DocumentCanvas` “first block containing text” with either character offsets inside text blocks or measured DOM range → bbox. Then reuse `findTextOnDocument` for case-wide apply (already partially there).

4. **Add confidence filters + sort (from attempt-1)**  
   High-first pending queue; chips ≥85 / 60–84 / &lt;60; keys `1` `2` `3`.

5. **Multi-select + floating bulk bar (from attempt-3)**  
   Orthogonal to similar groups: select mixed pending IDs → bulk decide by id list (API already has bulk by group; add `ids[]` path or reuse decide loop).

6. **Keyboard: previous document, undo, page keys already exist**  
   Add `Shift+N` or `P` for prev doc; `U` for undo; ensure `B` focuses bulk *and* can one-shot accept/reject focused group with confirm.

7. **Case-level suggestion queue mode (optional)**  
   Toggle “this doc” vs “whole package” so 50 docs don’t require N-hopping for one entity (entity dossier is called out in DESIGN as future work — ship a thin version).

8. **Virtualize queue + similar groups** for 100+ rows (react-window or native CSS).

9. **Swap `node:sqlite` → `better-sqlite3` or Turso** before any deploy; keep repository API.

10. **Surface planted-miss counts in a supervisor “missed scan” checklist** after pending hits zero (assignment cares about FN assurance).

11. **A11y:** announce queue position (“3 of 40 pending”) on J/K; focus management when modal opens.

12. **Tests:** add API integration tests for re-decide 409, bulk case scope, manual applyAcrossCase coordinates (repo tests exist; extend).

---

## Per-attempt capsule

### attempt-1 — “Burn after triage”

- **Core model:** Queue-first, document-anchored; accept/reject/undo; **Enter applies** blackouts.
- **DB:** `better-sqlite3`; mutable `suggestions.status` + `applied` flag; audit_events.
- **UX strengths:** Confidence filters, undo, apply step, solid paper viewer with % bboxes, keyboard cheatsheet.
- **UX weaknesses:** Full page hop between docs; FN draw+type; similar counts lie about case scope.
- **Best steal:** apply/burn + undo + confidence filters.

### attempt-2 — “Case package workstation” ★ strongest

- **Core model:** One case workspace; rail + canvas + queue + similar/audit/help; A/R; M add mode; N next doc.
- **DB:** Cleanest schema — reviewers, immutable suggestions, `suggestion_decisions`, `manual_redactions`, `planted_misses`, rich audit JSON details.
- **UX strengths:** BulkSimilarPanel with scope, reviewer switcher, entity chips, multi-doc progress, apply-across-case manuals.
- **UX weaknesses:** No undo/apply staging; no multi-select; bbox guess on FN; experimental SQLite.
- **Best steal:** whole shell + schema + similar groups UI.

### attempt-3 — “Select and strike”

- **Core model:** Text-offset document; select span to FN; Shift for similar; multi-select bar; always-on audit.
- **DB:** Mutable suggestion status; manuals with origin_id for bulk provenance; fixture JSON schema + optional `data/fixture.json`.
- **UX strengths:** Best FN; polished home; lucide iconography; peer “+N similar” badges; case bulk-apply of exact strings (verified on fresh DB: email → 2 manuals, bulkCount 1).
- **UX weaknesses:** Silent re-decide; no undo; no reviewer switcher; least PDF-like viewer.
- **Best steal:** selection-based FN + bulk exact match + multi-select bar + live audit.

---

## Verdict

**Viable alternative direction:** **attempt-2**. It is the only clean-room build that feels like a *case package product* rather than a single-document tool with extras. Schema and bulk-similar UX match the multi-file law-enforcement problem statement better than the others. attempt-3 is a close second for interaction quality on false negatives. attempt-1 is the best teacher for **legal finality** (apply + undo) but is not the shell to fork.

### Top 3–5 ideas to port into the DuckDB main app

1. **Case-level similar-group bulk with explicit doc vs package scope** (attempt-2 `BulkSimilarPanel` + `similar_group_key` / `listSimilarGroups`) — highest leverage on 10–50 doc packages.  
2. **Immutable detection rows + append-only decisions/audit** (attempt-2 schema split) — map cleanly onto DuckDB tables and time-travel.  
3. **Select-text (or PDF text-layer) FN → exact-string bulk apply across package** (attempt-3) — primary weapon against false negatives.  
4. **Staged accept vs commit/apply blackout** (attempt-1) — keep triage reversible; burn is a deliberate action with audit.  
5. **Confidence-band queue filters + multi-select bulk for mixed items** (attempt-1 filters + attempt-3 multi-select) — volume handling when entities are not identical strings.

**Honorable mention:** Reviewer identity switcher (attempt-2) and always-on audit stream (attempt-3).

---

## Evidence appendix (commands)

```text
# All from clean-room roots; Node v24.11.0
attempt-1: npm test → 24 passed; npm run build → OK; npm run lint (tsc) → OK
attempt-2: npm test → 18 passed; npm run build → OK; npm run lint (tsc) → OK
attempt-3: pnpm test → 23 passed; pnpm build → OK

# Smoke (production start on ports 3101–3103)
GET / → 200; GET /api/cases → 200; review routes → 200
A1: PATCH /api/suggestions/:id reject/pending; POST /api/redactions/apply
A2: POST /api/suggestions/:id/decide (accept then reject overwrite); bulk-decide
A3: POST decide; POST /api/redactions/manual bulkApply case (fresh DB: created 2, bulkCount 1)
```

### Key files cited

| Area | attempt-1 | attempt-2 | attempt-3 |
| --- | --- | --- | --- |
| Brief / design | `ASSIGNMENT.txt`, `DESIGN.md` | same + `DESIGN.md` | `DESIGN_RATIONALE.md` |
| Domain | `src/lib/types.ts`, `confidence.ts` | `src/data/contract.ts` | `src/lib/types.ts` |
| DB | `src/lib/db.ts`, `repository.ts` | `src/db/schema.sql`, `repository.ts` | `src/lib/db/schema.sql.ts`, `repository.ts` |
| Workspace UI | `src/components/ReviewWorkspace.tsx` | same name | same name |
| Viewer | `DocumentViewer.tsx` | `DocumentCanvas.tsx` | `DocumentViewer.tsx` |
| Bulk | `BulkActionBar.tsx` + bulk API | `BulkSimilarPanel.tsx` | `BulkActionBar.tsx` + Shift decide |
| Fixture | `src/lib/fixtures/stub.ts` | `src/data/fixtures/stub.ts` | `src/lib/fixtures/stub.ts` + `data/fixture.schema.json` |
