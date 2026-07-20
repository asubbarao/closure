# Cleanroom vs DuckDB — code reduction comparison

**Date:** 2026-07-20  
**Constraint:** Read-only on both trees. This file is the only write.  
**A:** `/Users/aloksubbarao/personal/closure` — DuckDB + quackapi (`server/*.sql`)  
**B:** `/Users/aloksubbarao/personal/closure-cleanroom/attempt-{1,2,3}` — Next.js/TS + SQLite  

**Question:** Where does A still carry accidental complexity the TS apps avoid, is A actually smaller, and what should A delete/collapse?

---

## 0. Blunt verdict

**A is not smaller.** Not at the full backend, not at the assignment-parity core.

| Surface | LOC | Notes |
|--------|-----|--------|
| **A `server/` SQL (all)** | **~6,850–7,040** | Everything under `server/**/*.sql` |
| **A assignment-ish core** (schema/config/ingest/detect/app + decisions/docs/suggestions/export/pages/history/search/meta) | **~2,800** | Still ~2× any B backend |
| **A advanced extras** (remainder + pdf_io + pdf_store + judge + provenance + geo + triage + related routes) | **~4,000** | Beyond what B even attempted |
| **A frontend** (`static/*.js` + `server/templates/*.html`) | **7,733 + 3,232 ≈ 11k** | Vanilla JS modules + tera HTML |
| **B1 backend+data** (db + repo + types + confidence + API routes; no fixtures/tests) | **1,173** | better-sqlite3 |
| **B2 backend+data** | **1,187** | node:sqlite + separate decisions table |
| **B3 backend+data** | **1,468** | schema string + repo + seed + types + API |
| **B\* full `src/`** (incl. UI + tests + fixtures) | **~4.1–4.3k each** | Entire working product |

Even if you cut every “research module” out of A, the remaining review loop (decide / bulk / history / HTML SSR) is still larger than B’s whole data layer — and B ships a complete assignment product.

The good news: **A’s product ambition is real** (PDF words, detection, OCR, residual FN scan, custody, judge ensemble). The bad news: **half of that ambition is still prototype scaffolding that the cleanrooms prove is optional for the graded loop.**

---

## 1. Scope honesty (do not compare apples to granite)

B was built under a cleanroom prompt that said: *do not over-build; fixture contract; no real ML; PDF parsing optional.*  
A is a platform: live PDF extract → detect → review → redact → export, plus residual FN, judge panel, geo, provenance, OCR, pdf_store lifecycle.

| Capability | A | B1 | B2 | B3 |
|------------|---|----|----|-----|
| Cases / multi-doc review | yes | yes | yes | yes |
| Accept / reject / bulk similar | yes | yes | yes | yes |
| Manual add (FN) | yes | yes | yes | yes |
| Audit trail | yes (JSON shards + views) | yes (table) | yes (table) | yes (table) |
| Confidence bands / triage | yes (heavy) | yes (light) | partial | yes (light) |
| Real PDF word geometry | yes | no (`pages_json` stub) | no | no |
| Live detection pipeline | yes (`detect.sql`) | no (fixtures) | no | no |
| Append-only undo / restore | yes (`history.sql`) | no (mutate status) | no (upsert decision) | no |
| Residual FN scan | yes (`remainder_scan.sql`) | no | no | no |
| Judge ensemble | yes | no | no | no |
| OCR / scan status | yes (`pdf_io.sql`) | no | no | no |
| PDF store lifecycle | yes (`pdf_store.sql`) | no | no | no |
| Chain-of-custody provenance | yes | no | no | no |
| Geo panel | yes | no | no | no |

**Reduction rule for A:** keep platform bets that are load-bearing for *your* thesis; delete or quarantine everything that only exists because “we could.” B is the control group for what “assignment-complete” actually costs.

---

## 2. LOC map — where A is still bloated

### 2.1 Full A `server/` (largest first)

| File | LOC | Role | vs B |
|------|-----|------|------|
| `remainder_scan.sql` | **1251** | Residual FN + entity_groups | **B has 0.** Biggest single delete/quarantine target |
| `pdf_io.sql` | **611** | OCR + scan fixtures + export SQL builders + **stubs `v_suggestions`** | B has no OCR; export is trivial apply flag |
| `pdf_store.sql` | **528** | source/working/export registry | B: paths in seed JSON |
| `routes/pages.sql` | **512** | SSR HTML via tera macros | B: React pages (~500–800 for workspace) |
| `routes/decisions.sql` | **499** | JSON-log fold + 5× COPY routes | B: one `UPDATE` + one `INSERT audit` |
| `routes/triage.sql` | **376** | Funnel + group bulk | B: bulk-by-`group_key` ~80 lines in repo |
| `provenance.sql` | **339** | Custody fingerprints | B: none |
| `routes/history.sql` | **323** | Undo / restore batches | B: none (rewrites status) |
| `app.sql` | **312** | Boot orchestration | B: `getDb()` + migrate ~40–100 |
| `routes/geo.sql` | **306** | Minimap API | B: none |
| `detect.sql` | **233** | Live detection | B: fixture suggestions |
| `schema.sql` | **205** | DDL sketch | **Not on boot path** (see §3) |
| `judge.sql` | **196** | Confidence ensemble | B: single confidence number |
| `ingest.sql` | **135** | CTAS load | B: seed inserts |
| Remaining routes/config | ~800 | meta, search, store, export, … | B API routes ~200 total |

### 2.2 Fair “backend+data” comparison

**Core review data plane (what B actually implements):**

| | A (approx) | B1 | B2 | B3 |
|--|------------|----|----|-----|
| Schema / types | `schema.sql` 205 + `config` 77 + `sources` 44 — **but schema unused at boot** | `db.ts` 104 | `schema.sql` 99 | `schema.sql.ts` 91 + `types` 243 |
| Repository / projections | `detect` fold + `decisions` views + `history` ≈ **1,000+** | `repository.ts` **642** | `repository.ts` **811** | `repository.ts` **757** |
| HTTP API | `routes/decisions` + docs + suggestions + history + triage ≈ **1,300+** | API routes **214** | **234** | **200** |
| **Subtotal assignment core** | **~2,500–3,000** | **~1,170** | **~1,190** | **~1,470** |

**A extras B never paid for:** ~4,000 LOC (remainder, pdf stack, judge, provenance, geo, store).

### 2.3 Frontend (context only — focus was backend, but A’s UI tax is real)

| | LOC |
|--|-----|
| A `static/*.js` | 7,733 (`review.js` 1,638 alone) |
| A `server/templates/*.html` | 3,232 |
| B1 components (non-test) | ~1,800 |
| B2 components | ~1,500 |
| B3 components | ~1,500 |

B concentrates UX in React components. A pays twice: tera SSR assembly in SQL **and** large vanilla JS controllers.

---

## 3. Boot-path drift — A’s worst accidental complexity

This is not “feature richness.” This is **the tree lying about what runs.**

| Artifact | Booted by `app.sql`? | Reality |
|----------|----------------------|---------|
| `config.sql` | yes | Live knobs |
| `ingest.sql` | yes | CTAS cases/docs/pages/words |
| `pdf_io.sql` | yes | Re-CTAS documents (scan fixtures), OCR path, **replaces `v_suggestions` with empty stub** mid-file |
| **`seed.sql`** | **`.read` at line 109** | **FILE MISSING** — boot is broken or depends on an uncommitted file |
| `judge.sql` | yes | Expects suggestions + `v_suggestions` |
| `remainder_scan.sql` | yes | 1251-line FN pipeline |
| `provenance.sql`, `pdf_store.sql`, all routes | yes | Loaded |
| **`schema.sql`** | **no** | Dead sketch: `v_grams`, `qnorm`, correlated `v_document_stats`, audit-as-status — **not runtime truth** |
| **`detect.sql`** | **no** | Clean detection rewrite exists but is **not wired** into `app.sql` |
| **`sources.sql`** | **no** | Clean raw layer (`v_src_pdf_info`, `v_src_decisions`) — **not wired** |

B never has this class of problem: one `migrate()` / one `schema.sql`, one repository, one seed path.

**Smell name:** *parallel universes* — clean rebuild modules (`detect.sql`, `sources.sql`, slim `ingest.sql`) sit beside the still-running monster path (`seed.sql` ghost + `pdf_io` + `remainder_scan`), while `schema.sql` documents a third mental model (`audit_events` as status source).

---

## 4. Data model: cleaner or messier?

### 4.1 B models (all messier on audit purity, cleaner on implementability)

**B1** (`attempt-1/src/lib/db.ts`, ~97 lines of DDL):

```
cases → documents (pages_json blob) → suggestions (status column mutable)
                                      → audit_events (append-ish log)
```

- Status lives **on the row** (`pending|accepted|rejected` CHECK).
- Bulk key: `group_key` text (normalized string).
- Geometry: `bbox_json` blob.
- Manual adds: same `suggestions` table, `source='manual'`.
- Decide = `UPDATE suggestions SET status=…` + `INSERT audit_events`.

**B2** (`attempt-2/src/db/schema.sql`, 99 lines) — best of the three:

```
suggestions (immutable-ish facts)
suggestion_decisions (1:1 current decision, ON CONFLICT upsert)
manual_redactions (separate table)
audit_events
planted_misses (eval only)
```

- Separates *proposal* from *decision* (closer to A’s intent).
- Still not event-sourced: re-decide overwrites; no undo stack.
- Explicit `reviewers` table.

**B3** (`attempt-3/src/lib/db/schema.sql.ts`, 91 lines):

```
suggestions (status mutable + similar_key)
manual_redactions
audit_events (target_ids JSON array)
```

- Text offsets instead of bboxes (page text model, not PDF points).
- `similar_key` for bulk — same idea as B1 `group_key`, no entity graph.

### 4.2 A model (cleaner *idea*, messier *implementation*)

**Intent (good):**

> Suggestions are structural. Status is a projection of an append-only decision log. Undo is another event.

**Implementation (messy):**

| Layer | What it claims | What actually happens |
|-------|----------------|----------------------|
| `schema.sql` | `audit_events` drives `v_suggestions.status` via correlated subquery | **Not loaded** |
| Runtime | `exports/decisions/*.json` shards → `v_decision_log` / `v_src_decisions` → `v_latest_decision` / fold → status | Live path; column schemas hand-listed |
| Manual adds | Born as log rows (`kind='added'`), projected via `v_manual_suggestions` | Not first-class rows until folded |
| Batches | `batch_id` / `batch_label` / `undoes_batch_id` + `batch_key()` legacy fallback | ~170 lines of view glue before any route |
| Entities | First-class catalog + `entity_groups` for bulk | Powerful; remainder_scan builds groups in hundreds of lines |
| Words | Real PDF geometry tables | Correct for real redaction; B fakes pages |

**Verdict:**

- **Conceptually A is cleaner** for legal review (append-only, undo, entity-centric bulk).
- **Operationally A is messier** than all three B schemas: dual status systems (table vs JSON log), VARCHAR/INTEGER id casting everywhere, three definitions of `v_suggestions` (`schema.sql`, `detect.sql`, empty stub in `pdf_io.sql`), and decision writes as `COPY … TO 'exports/decisions'` instead of one `INSERT`.

B’s mess is *honest prototype mess* (mutate status, lose history). A’s mess is *distributed systems cosplay inside one DuckDB file*.

---

## 5. Accidental complexity A carries that B avoids

### 5.1 Decision write path = five near-clones

`routes/decisions.sql` (499) + `routes/history.sql` (323) + `routes/triage.sql` (376):

- Single decision COPY
- Entity fan-out COPY
- Band bulk COPY
- Multi-id batch COPY
- Manual add COPY
- Undo COPY
- Restore COPY
- Triage accept-high / group decision COPYs

Each rebuilds: `uuid()` batch_id, `batch_label` CASE soup, `coalesce($actor…)`, column projection, `COPY TO … FILENAME_PATTERN`.

**B equivalent:** one function, ~40 lines:

```ts
// attempt-1 repository.ts — setSuggestionStatus
UPDATE suggestions SET status = ?, applied = 0, updated_at = ? WHERE id = ?
// + writeAudit(...)
```

**Smell:** *macro-by-copy-paste route farm* — file: `server/routes/decisions.sql`, `history.sql`, `triage.sql`.

### 5.2 Status projection is a research paper

A folds latest decision with `arg_max` / batch views / manual UNION / band CASE.  
B stores status on the row (or 1:1 decision table).

For a take-home demo, B is right. For production legal audit, A’s *intent* is right — but A should implement it as **one table `decision_events` inside DuckDB**, not a JSON shard glob with explicit `columns := {…}` maps and sentinel files.

**Smell:** *filesystem as WAL* — `exports/decisions/*.json` + `v_decision_log` hand schema in `routes/decisions.sql:22–84`.

### 5.3 `remainder_scan.sql` is a second product

1,251 lines: address canonicalize, name variant pairs, entity_groups, cover masks, 1–8 grams, regex + rapidfuzz + finetype + addrust residual merge, re-CTAS of `entity_group_members`.

B’s FN handling: **a modal that inserts one (or bulk text-match) redaction.** That is the assignment.

**Smell:** *spike promoted to boot path* — loaded unconditionally in `app.sql:111`.

### 5.4 `pdf_io.sql` fights ingest and stubs the view contract

- Re-creates `documents` / `pages` / `words` to attach scan fixtures and OCR.
- Defines `v_suggestions AS … WHERE false` so export macros can bind before seed — then real view must be recreated later.
- Owner comment in-file: *“NOT GOING TO READ THIS FILE… 300–400 LINES TOO LONG.”*

**Smell:** *service file that redefines the world* — should be thin export helpers only.

### 5.5 HTML rendered in SQL

`routes/pages.sql` (512): `render_case`, `render_document`, `render_audit` — large tera context assembly (doc lists, suggestion queues, stats) inside SQL macros.

B: API returns JSON; React renders. ~10-line route handlers.

**Smell:** *SSR logic in the database* — every UI field change edits SQL.

### 5.6 Dead / contradictory schema artifacts

- `schema.sql`: `v_grams` (n-gram lead windows), `qnorm`, correlated `v_document_stats` — owner already marked `#delete` / antipattern.
- `detect.sql` rebuilds cleaner versions of the same views — not booted.
- Multiple `v_suggestions` creators = “which one is live?” depends on last `.read` that succeeded.

**Smell:** *schema as historical fiction*.

### 5.7 What B carries that A avoids (vice versa)

| B accidental / weak | A advantage |
|---------------------|-------------|
| Mutable status loses true amend history (B1/B3); B2 upsert still no undo | Event intent + undo/restore |
| `pages_json` / fake canvas — no real redact geometry | Real word boxes + `pdf_redact` |
| Fixture-only detection | Generic detect stack (when wired) |
| ~600–800 line repository still has repeated mapper/SQL noise | Set-based bulk in pure SQL *can* be denser **if** you stop cloning routes |
| No entity model (string `group_key` only) | `entities` + entity fan-out is the right bulk primitive |

A is not “worse at everything.” A is **worse at knowing when to stop.**

---

## 6. Patterns in A worth deleting / collapsing

| # | File | Smell | Collapse to |
|---|------|-------|-------------|
| 1 | `remainder_scan.sql` | Spike-as-product | **Off boot path** → `server/experimental/`; keep one residual API stub or delete |
| 2 | `routes/decisions.sql` + history + triage COPYs | Clone farm | **One** `append_decisions(rows)` macro + thin routes; or table `decision_events` + INSERT |
| 3 | `exports/decisions/*.json` fold | Filesystem WAL | DuckDB table `decision_events` (still append-only); optional export dump |
| 4 | `schema.sql` | Dead parallel model | Delete or rewrite as the **only** DDL that boot applies; kill `v_grams` / correlated stats |
| 5 | `pdf_io.sql` empty `v_suggestions` | View stub dance | Define export macros without needing the view at create time; don’t REPLACE live views with null shells |
| 6 | `pdf_store.sql` | Lifecycle cosplay | Paths on `documents` + one working-copy table; drop 5 registry views until needed |
| 7 | `routes/pages.sql` | SSR in SQL | Static HTML shells + JSON APIs only (B pattern); kill `render_*` mega-macros |
| 8 | `routes/geo.sql` + `provenance.sql` + `judge.sql` | Feature density | Panel modules **optional** `.read` behind flag; not default boot |
| 9 | `entity_groups` machinery in remainder | Graph for bulk | Port B’s `group_key` / `similar_key` string for bulk; keep entities for catalog only |
| 10 | `app.sql` missing `seed.sql`, skips `detect.sql` | Boot lies | Single linear boot: config → sources → ingest → detect → routes → serve |

---

## 7. Genuinely good ideas in B worth porting to A

1. **`group_key` / `similar_key` as a stored column on suggestions**  
   B1 `groupKeyForText`, B3 `similarKeyFor` — bulk is `WHERE group_key = ? AND status = 'pending'`.  
   A’s entity fan-out is better for multi-doc identity, but **surface strings still need a cheap key** without building `entity_groups` CTAS.

2. **Workspace payload endpoint**  
   B3 `GET /api/workspace` — one round-trip: case + docs + suggestions + progress + audit.  
   A fans many routes per page paint (`pages.sql` SSR + several APIs). Collapse review bootstrap.

3. **Thin API routes, fat repository**  
   B route files are 10–45 lines. A’s “repository” is scattered across views + COPY routes.  
   Port the *shape*: `routes/*.sql` should only be `SELECT * FROM api_decide(...)`.

4. **Fixture / seed contract isolation**  
   B: `fixtures/contract.ts` + stub; app does not invent corpus shape at runtime.  
   A is mid-migration (good: `sources.sql` refuses identities unpivot) but still boots research detectors. Keep that discipline; finish it.

5. **Status CHECK on a real column for *current* projection cache**  
   Even if events are source of truth, B’s `status` column makes UI queries trivial.  
   A can keep append-only events **and** maintain `suggestions.current_status` as a denormalized cache updated on write — kills expensive fold views on every page load.

6. **Separate `manual_redactions` table (B2/B3)** *or* first-class rows (B1) — not log-only ghosts  
   A’s manual-as-`kind='added'` log projection is clever and painful. Prefer INSERT into `suggestions` with `source='manual'` + one audit/decision event.

7. **B2’s `suggestion_decisions` 1:1 table** as the *current* decision, with optional history table  
   Cheaper than JSON shards; cleaner than overwriting status without audit (B1). Hybrid: `decision_events` (append) + `suggestion_current` (view or table).

---

## 8. Top 10 reduction opportunities for A (ranked)

Impact = LOC removed × complexity removed × how little it hurts the graded demo.

| Rank | Opportunity | Est. LOC out | Risk to demo | Why |
|------|-------------|--------------|--------------|-----|
| **1** | **Quarantine `remainder_scan.sql` (+ `routes/remainder.sql` + remainder panel)** | **~1,400** | Low if UI panel optional | B proves FN catch = manual add modal. Largest single file. |
| **2** | **Collapse decision path: table INSERT, not JSON COPY farm** | **~600–900** across decisions/history/triage | Medium (rewrite) | Biggest *structural* win; enables simple undo later |
| **3** | **Stop SSR assembly in `routes/pages.sql`** — static shells + JSON | **~400–500** SQL + simpler templates | Medium | Matches B; unblocks static JS cleanup |
| **4** | **Wire one boot path: drop ghost `seed.sql`; load `sources`→`ingest`→`detect`; delete dead `schema` cruft** | **~200 dead + cognitive** | High if wrong order | Without this, every other cleanup is guesswork |
| **5** | **Slash `pdf_io.sql` to export boxes + optional OCR** — no view stubs, no document re-CTAS | **~300–400** | Medium | Owner already marked it too long |
| **6** | **`pdf_store.sql` → minimal or experimental/** | **~500** | Low for demo | B has no lifecycle registry |
| **7** | **Make judge/geo/provenance opt-in modules** | **~700–900** | Low | Not in assignment core; keep as showcase flags |
| **8** | **Deduplicate batch_label / meta CTE** into one macro used by all decision routes | **~150–250** | Low | Pure hygiene even before table migration |
| **9** | **Replace entity_groups CTAS with `similar_key` column** (port B) for bulk UI | **~300** if remainder stays | Low | Bulk without graph rebuild |
| **10** | **Kill `schema.sql` fantasy views (`v_grams`, correlated stats) or make schema the only DDL** | **~100 + clarity** | Low | Stops agents/humans implementing the wrong model |

**If you only do three things:** (1) remainder off boot, (2) one real boot line, (3) decision events as a table with one write macro.

**Theoretical post-cut A backend:** ~2,000–2,500 LOC of honest SQL for real PDF review — still larger than B (~1,200) because real geometry + detection cost real lines, but no longer 6–7k of platform sprawl.

---

## 9. File-cited smell board (quick scan)

| Location | Smell |
|----------|--------|
| `server/app.sql:109` | `.read server/seed.sql` — **file does not exist** |
| `server/app.sql` load list | Does **not** `.read` `schema.sql`, `detect.sql`, `sources.sql` |
| `server/schema.sql:101–198` | Parallel `v_suggestions` / `v_grams` / antipattern stats — unused |
| `server/schema.sql` inline `#` notes | Author already sentenced `v_grams`, correlated stats to death — **execute the sentence** |
| `server/detect.sql:177–197` | Cleaner `v_suggestions` — not booted |
| `server/pdf_io.sql:499–520` | Empty `v_suggestions` stub replaces live contract |
| `server/pdf_io.sql:23` | Author: too long / too many views |
| `server/routes/decisions.sql:22–84` | Hand-rolled `columns :=` map for JSON log |
| `server/routes/decisions.sql:119–140` | `batch_label` CASE explosion |
| `server/routes/decisions.sql:182–310` | Clone decision routes |
| `server/routes/history.sql:34–100+` | Undo as multi-CTE COPY with correlated prior status |
| `server/remainder_scan.sql` | Entire file: second detector product |
| `server/routes/pages.sql:44–493` | HTML context built in SQL |
| B1 `repository.ts:423–438` | Counter-example: decide in ~15 lines |
| B2 `schema.sql` + `suggestion_decisions` | Counter-example: 99-line honest schema |
| B3 `similar_key` + bulk UPDATE | Counter-example: bulk without entity graph |

---

## 10. Is A “actually smaller now”?

**No.**

| Claim | Reality |
|-------|---------|
| “DuckDB SQL is denser so A will be smaller” | Density helps *inside* a query. A still has **more modules, more dual paths, more UI surfaces**. |
| “We rebuilt clean/short” | `detect.sql` (233) + slim `ingest.sql` (135) + `sources.sql` (44) **are** short — but they are **not the running system**. Running system still pulls remainder/pdf/judge/geo/history monoliths. |
| “B is bloated by Next/React” | B full `src/` is ~4.2k including UI+tests. **A server alone is ~7k; A UI alone is ~11k.** |

**Where A is still bloated (priority order):**  
(1) remainder_scan, (2) decision/history/triage COPY+JSON machinery, (3) pdf_io+pdf_store, (4) pages SSR, (5) optional panels (judge/geo/provenance), (6) boot-path / schema drift.

**Where A is legitimately larger than B and should stay larger:**  
real PDF words, detection, export redaction geometry, and (if you keep it) a *simple* append-only decision table.

---

## 11. Recommended reduction sequence (no code in this pass)

1. **Inventory boot:** make `app.sql` `.read` only files that exist; print the graph.  
2. **Park research:** `remainder_scan`, `geo`, `provenance`, `judge`, `pdf_store` → `server/experimental/` or `IF cfg_flag`.  
3. **Canonical data plane:** `sources → ingest → detect → decision_events table → v_suggestions` (one definition).  
4. **Delete `schema.sql` fiction** or replace it with that plane’s DDL.  
5. **One write macro** for decisions; thin routes.  
6. **Port `similar_key` + workspace JSON** from B for bulk/UI.  
7. **SSR last:** only after API is stable, strip `render_*` toward static shells.

---

## 12. One-line summaries

- **A vs B size:** A backend ~6–7× B backend; A is not the small one.  
- **A data model:** better thesis, worse schema discipline; B is boring and shippable.  
- **Biggest A cut:** `remainder_scan.sql` off the boot path.  
- **Biggest A redesign:** stop using JSON files as the decision log; one append-only table + optional cache column.  
- **Best B port:** `similar_key` + thin routes + workspace payload + manual as real rows.  
- **Non-negotiable A keep:** real PDF geometry and a single detection path — that is the product difference, not 1,200 lines of residual n-grams.
