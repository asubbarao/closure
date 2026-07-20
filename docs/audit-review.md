# Audit trail + revertability — legal defensibility review

**Scope.** Closure’s decision log, batch undo / restore-to-point, and PDF chain-of-custody for law-enforcement redaction review.  
**Sources read.** `server/routes/decisions.sql`, `server/routes/history.sql`, `server/routes/triage.sql`, `server/routes/export.sql`, `server/routes/store.sql`, `server/routes/provenance.sql`, `server/provenance.sql`, `server/pdf_store.sql`, `server/seed.sql` (folding views), `server/schema.sql` / `server/ingest.sql` (`audit_events`), `server/app.sql` (boot + `v_audit`), plus on-disk `exports/decisions/*.json`.  
**Exercise method.** Full `quackapi_serve` boot was **not** required for this review. A partial DuckDB load (ingest → seed → provenance → decisions/history routes) against live `exports/decisions/` was run and inspected. Live corpus snapshot (2026-07-19): **~1,989** decision-log rows, **221** batches, **1** undo batch, **0** custody recheck breaks, **9** export lineage rows, **0** export-kind audit events.

---

## Executive judgment

| Area | Fit for LE chain-of-custody? | One-line |
|------|------------------------------|----------|
| Append-only decision events (status) | **Strong foundation, not court-ready** | Correct event-sourced pattern; mutable filesystem + missing export/actor binding |
| Batch undo / restore | **Operationally good; evidentially incomplete** | Undo appends inverses (never deletes); no stored prior-state on forward events; undo-of-undo not first-class |
| Provenance (source → export) | **Demo-grade CoC** | Crypto digests + live recheck exist; ingest snapshot is **re-derived each boot**, export not sealed to a decision set |
| Overall | **Useful product audit; insufficient legal WORM** | Gaps below are ranked for defensibility, not UX |

The architecture thesis is right: **status is a fold of an append-only log**, so UI state cannot silently diverge from history *while the log is intact*. That is the correct core for redaction review. Legal defensibility fails on **custody of the log itself**, **export sealing**, **identity of the actor**, and **durable ingest fingerprints**.

---

## 1. Append-only decision log

### 1.1 How it works (as implemented)

Runtime mutations do **not** `UPDATE suggestions`. They `COPY … TO 'exports/decisions'` JSON shards (`dec_{uuid}` / `add_{uuid}`), one action per POST, with a shared `batch_id` + `batch_label`.

| Path | Kind | Batched? | Fields written |
|------|------|----------|----------------|
| `POST /api/suggestions/:id/decision` | `decision` | 1-row batch | status, actor, reason, ts, document_id, case_id, text, batch_* |
| `POST /api/entities/:id/decision` | `decision` | N pending, non-flagged | same |
| `POST /api/documents/:id/band/:band/decision` | `decision` | N | same |
| `POST /api/suggestions/batch/decision` | `decision` | N by id list | same |
| `POST /api/documents/:id/add` | `added` | 1 | geometry + text + born `accepted` + scope |
| `POST …/triage/accept-high` | `decision` | all high-conf eligible | reason default auto-pass |
| `POST …/triage/group/decision` | `decision` | residual group − excludes | one batch |
| `POST /api/undo` | `decision` | inverse of one batch | `reason=undo`, `undoes_batch_id`, restored status |
| `POST /api/cases/:id/restore` | `decision` | status rows + marker rows | `reason=restore`, markers carry `undoes_batch_id` |

**Folding.**

- `v_decision_log` — `read_json('exports/decisions/*.json', ignore_errors:=true, …)` (seed defines a thin view; `routes/decisions.sql` replaces it with batch columns).
- `v_latest_decision` — latest `kind='decision'` per `suggestion_id` by `(ts, _file)`.
- `v_manual_suggestions` — latest `kind='added'` per id.
- `v_suggestions` — structural AI rows ∪ manuals; status = latest decision else `manual→accepted` / `ai→pending`.
- `v_decision_batches` — group by `coalesce(batch_id, _file)`; `undone` iff any later row’s `undoes_batch_id` points at the batch.

**Design claim in `schema.sql`** (“decisions are `audit_events` rows”) is **stale**. Runtime truth is the JSON log. `audit_events` is rebuilt at ingest as a **boot-only “ingested” snapshot** per case (`ingest.sql`), not an append stream of accepts/rejects.

### 1.2 What *is* captured well

- **Who / what / when (operational):** every decision row carries free-text `actor`, target `status`, `ts`, `suggestion_id`, sample `text`, `document_id` / `case_id`, optional `reason`, and `batch_id`.
- **Bulk = one reversible unit:** triage auto-pass, entity fan-out, band bulk, multi-id batch, and residual group decisions all mint **one** `batch_id` for all rows of that action.
- **Undo does not delete:** inverse rows are appended; original batch remains on disk and is marked `undone` via pointer.
- **Live corpus check:** all decision rows in the partial exercise had a non-null `batch_id` (legacy `_file` fallback still exists in the fold for pre-versioning shards). Observed undo: one batch undid “Accepted — Bergstrom v. Ohio,” restoring `pending` with `reason=undo`.

### 1.3 Paths that mutate status *without* a durable decision record

| Mutation | Audited in decision log? | Notes |
|----------|---------------------------|--------|
| Accept / reject / pending (all decision routes) | **Yes** | COPY only |
| Manual add | **Yes** (`kind=added`) | Born accepted; undo sets status pending, does **not** remove the add event |
| Triage auto-pass / group | **Yes** | Large NDJSON files (e.g. 1102-line auto-pass shard) |
| Undo / restore | **Yes** | Append inverse |
| **Export redacted PDF** | **No** | `routes/export.sql` runs `pdf_redact` only; `actor` param is unused for logging; **0** export-kind rows in live log |
| Working-copy materialize | **Partial / ephemeral** | `INSERT` into `pdf_store_events` (wiped each boot); **no** `COPY` to `data/working/registry/` on the live POST path |
| Boot reseed of `suggestions` / words | **N/A / risk** | Structural catalog re-derived; status overlay depends on stable suggestion ids |
| Direct FS edit of `exports/decisions/*` or samples | **Bypasses app** | Full rewrite/delete capability |

There is **no server path that UPDATEs a suggestion’s status in-table**. The residual risk is **unlogged side effects** (export, working PDF) and **log mutability**, not silent SQL updates.

### 1.4 Ways to lose or rewrite history

1. **Filesystem is the store.** Anyone with write access to `exports/decisions/` can delete, edit, or swap JSON. App has no HMAC, signature, or WORM mount.
2. **`ignore_errors := true` on `read_json`.** Corrupt / partial shards are **silently dropped** from the fold — history can shrink without an error surface.
3. **`COPY … OVERWRITE_OR_IGNORE`** with uuid filenames is collision-safe in practice; it is **not** a guarantee against deliberate overwrite of a known path.
4. **Boot does not archive the log**; e2e docs even recommend deleting non-sentinel decision files for a clean suite — operationally easy to erase evidence.
5. **`v_decision_chain_seal` is a recomputed aggregate hash**, not a stored per-event hash chain. Recomputing after deletion yields a *new* seal with no “break” flag unless an external prior seal was retained.
6. **API audit double-count risk:** `v_audit` already unions decision log; `GET /api/cases/:id/audit` unions `v_audit` **and** `v_decision_log` again → duplicate rows for court-facing export of the HTML/API log. Also **LIMIT 500** truncates large cases.

### 1.5 Prior-state on forward events

Forward decision rows store **new** `status` only. They do **not** store `prior_status` / before-image.

Undo reconstructs prior by scanning earlier decision rows for that `suggestion_id` outside the undone batch (`history.sql` `priors` CTE), defaulting to `'pending'`. That is correct *if the log is complete*, but:

- The fact of “was accepted → became rejected” is **inferable**, not **self-describing** on the reject event.
- A missing intermediate file can cause undo to restore the wrong prior.
- Court packages usually want **from → to** on each event without requiring a full replay engine.

---

## 2. Revert model

### 2.1 What exists

| Capability | Implementation | Append-only? |
|------------|----------------|--------------|
| Batch undo (latest forward batch) | `POST /api/undo` | Yes — inverse decisions + `undoes_batch_id` |
| Peek undo target | `GET /api/undo/status` | Read-only |
| Google-Docs-style timeline | `GET /api/cases/:id/history` via `v_decision_batches` | Read-only |
| Restore to batch (undo everything after) | `POST /api/cases/:id/restore` | Yes — status inverses + marker rows per after-batch |
| UI | `static/history.js` + history panel (Ctrl/Cmd+Z) | Client only |

**Undo is itself audited** (`reason='undo'`, batch_label `Undid: …`, `undoes_batch_id` set). Original batch files remain.

### 2.2 Reconstructability

| Question | Answer |
|----------|--------|
| Full timeline of batches? | **Yes**, if JSON shards intact — ordered by `ts`, `batch_id` |
| Exact status set at time T? | **Yes in principle** — fold `kind=decision` with `ts ≤ T` (and `_file` tie-break); manuals from `added` ≤ T |
| Exact redacted PDF bytes at time T? | **No** — export is live `pdf_redact` of current accepted set; historical exports are not versioned with decision seals |
| Point-in-time without the fold engine? | Weak — need DuckDB views or equivalent replay |

### 2.3 Edge cases

| Case | Behavior | Defensibility note |
|------|----------|--------------------|
| **Undo after export** | Undo changes status fold; **exported PDF is not recalled or re-hashed into the decision log**. Stale redacted file remains under `exports/*_redacted.pdf`. | Court sees an export that may no longer match “current” accepted set; no event ties “this PDF was issued under batch X” |
| **Concurrent decisions** | No optimistic concurrency, no locks, no CAS on suggestion status. Two POSTs both append; latest `(ts,_file)` wins. | Last-writer-wins without conflict record; multi-reviewer LE workflow unsafe |
| **Undo of an undo** | Undo targets `NOT is_undo AND NOT undone` only — **undo batches are not undo targets**. Re-apply requires a new accept/reject. | Timeline remains append-only; redo is a new forward event (good), but no explicit “redo” linking to the undone batch |
| **Restore markers** | Restore emits extra decision rows reusing one suggestion_id from the restored set purely to stamp `undoes_batch_id` on after-batches | Pollutes that suggestion’s event stream; chain seal counts markers as events |
| **Undo of bulk (e.g. 1102 auto-pass)** | One inverse batch restoring each id’s prior (usually pending) | Correct batch semantics; large inverse files; works if priors resolve |
| **Undo of manual add** | Writes `decision` with prior default `pending`; `added` row remains | Box still exists as manual/pending (not “un-created”); appropriate for audit, easy to misread as “still accepted” if UI only shows manuals |
| **Same-ms timestamps** | Bulk rows share one `now()`; order uses `_file` | Stable only while filenames preserved |

### 2.4 Verdict on revert

Product-quality **batch undo + restore-to-point** is real and correctly non-destructive. For legal CoC it is **incomplete** until (a) prior-state is stored on every forward event, (b) export is a sealed, versioned artifact linked to a decision-set hash, and (c) undo-after-export is an explicit supervised event (invalidate / re-export).

---

## 3. Provenance (source PDF + export lineage)

### 3.1 What exists (good bones)

From `server/provenance.sql` + routes:

- **Ingest custody table** `document_custody`: crypto `sha2-256`, `blake3`, `sha2-512`, core `sha256` cross-check, size, mtime, PDF revision count / eof, producer, page count, `ingested_at`, `ingested_by='system'`.
- **Live recheck** `v_custody_recheck`: re-hash `samples/*.pdf` now; `recheck_ok` / `BREAK`.
- **Working + export blobs** hashed; `v_export_lineage` builds a human `custody_statement` (source → `exports/{filename}_redacted.pdf` by naming convention).
- **`v_decision_chain_seal`**: ordered aggregate `crypto_hash_agg(sha2-256)` over kind|suggestion_id|status|actor|ts|document_id.
- Panel/API: `GET /api/cases/:id/provenance` (+ recheck alias).

Partial exercise: **0** custody breaks, **9** export lineage rows (matches redacted PDFs present).

### 3.2 Does it prove the source was not altered mid-review?

**Only for the lifetime of a single process boot, and only if samples/ are not replaced then re-booted.**

Critical defect: `document_custody` is `CREATE OR REPLACE` **from current `samples/*.pdf` bytes at every boot**. There is no durable off-DB custody record of the *first* ingest hash. Sequence:

1. Boot → custody hash = H1.  
2. Attacker replaces sample PDF with H2.  
3. Live recheck → **BREAK** (good).  
4. Attacker reboots app → custody re-snapshotted to H2 → recheck **INTACT** (bad). Historical H1 is gone.

Also: source stage “immutability” is a **convention** (`pdf_store` notes reference `samples/`; nothing seals or copies-to-WORM). Demo layout, not evidence locker.

### 3.3 Does it tie redacted output to its source *and* to the review decisions?

| Link | Present? | Quality |
|------|----------|---------|
| Source path ↔ export path by filename | Yes | Naming convention only |
| Source digest ↔ export digest in one statement | Yes | Textual `custody_statement` |
| Export ↔ **accepted decision set** / `decision_batch` | **No** | `v_pdf_store_export.decision_batch` is always NULL; export route does not record accepted-id hash |
| Export ↔ decision chain seal at export time | **No** | Seal is live global recompute, not snapshotted into export metadata |
| Export event in decision log (who exported when) | **No** | See §1.3 |
| Working gen ↔ `decision_batch_for_doc` | Planned in macros | Working POST may leave fingerprint NULL; events table not durable |

`decision_batch_for_doc` (sha256 of accepted id:status list) is the right primitive for sealing an export — it is **not written** into the export lineage today.

### 3.4 Decision chain seal limits

- Global (all cases), not per-case / per-export.
- Omits `batch_id`, `reason`, `undoes_batch_id`, geometry, confidence.
- Not a **hash chain** (no `prev_hash` on each event).
- Not persisted; cannot detect “seal was X yesterday.”
- Still useful as a **session integrity check**, not as courtroom Merkle evidence.

---

## 4. Ranked gaps + concrete fixes

### P0 — Chain of custody breakers

| # | Gap | Concrete fix |
|---|-----|--------------|
| P0-1 | **Ingest fingerprint not durable** (rebuilt each boot) | On first ingest (or once per document), `COPY` custody rows to e.g. `exports/custody/{doc_id}_{sha256}.json` **or** append-only table that is never `CREATE OR REPLACE` from live bytes. Boot loads sealed snapshot; recheck compares live vs **sealed**, never vs re-read “ingest.” |
| P0-2 | **Export not audited / not sealed** | On successful `pdf_redact`, append `kind='exported'` rows (or one batch) with: actor, ts, case_id, per-doc `source_sha256`, `export_sha256`, `accepted_set_hash` (`decision_batch_for_doc`), `decision_chain_seal` snapshot, output path. Fail closed if source recheck is BREAK. |
| P0-3 | **Decision log not tamper-evident / WORM** | Store log on append-only volume **or** after each batch append `prev_seal` + per-batch `batch_seal` file; nightly external notarization (timestamped hash to independent store). Drop `ignore_errors` for production reads (or quarantine bad files with alert). |
| P0-4 | **Actor is client free-text** (live actors include `probe`, `stress*`, `v`) | Authenticated session → server-side actor (badge # / UPN). Reject missing auth in production. Optional dual-control for export. |

### P1 — Reconstructability & undo correctness under scrutiny

| # | Gap | Concrete fix |
|---|-----|--------------|
| P1-1 | No **prior_status** on forward events | On every decision write, join current fold status into `prior_status` (and optional `prior_batch_id`). Undo becomes verify-and-append, not rediscover. |
| P1-2 | Undo after export silent | If any `kind=exported` exists after the undone batch for overlapping docs, append `export_invalidated` (or block undo until supervisor confirms) and require re-export. |
| P1-3 | Restore marker rows reuse a real suggestion_id | Emit `kind='batch_marker'` (excluded from status fold) with only `undoes_batch_id` / batch metadata. |
| P1-4 | Concurrent multi-reviewer races | Per-suggestion expected_status / version in POST; reject stale writes with conflict event logged. |
| P1-5 | Working registry not durable | Mirror working POST to `COPY` JSON under `data/working/registry/` with post-redact fingerprint (hash the file after `pdf_redact`, not NULL). |

### P2 — Court presentation & ops

| # | Gap | Concrete fix |
|---|-----|--------------|
| P2-1 | `GET …/audit` doubles decision rows + LIMIT 500 | Single source (`v_decision_log` + ingest events only); cursor/pagination; export full log as signed JSONL/PDF package. |
| P2-2 | Stale `audit_events` / schema docs | Either retire table language or dual-write for real; document JSON log as SoT in schema comments. |
| P2-3 | Chain seal too weak / global | Per-case seal; include batch_id + undoes; store seal at export. |
| P2-4 | Suggestion id stability across seed versions | Persist suggestion ids with content-addressed keys (doc, page, bbox, text hash); freeze AI catalog version id on case. |
| P2-5 | Empty `exports/audit_sidecar.jsonl` | Wire or remove; do not imply a sidecar that is not written. |

### P3 — Hardening polish

| # | Gap | Concrete fix |
|---|-----|--------------|
| P3-1 | Undo-of-undo only via new forward decision | Optional explicit redo linking `redoes_batch_id`. |
| P3-2 | Manual add “undo” leaves pending manual | Document as intentional; UI label “removed from redaction set” vs “delete miss.” |
| P3-3 | Export path only under `exports/` compat | Single canonical export root + registry row. |

---

## 5. What a court / compliance reviewer would want that is missing

Beyond engineering gaps, a FOIA / discovery / internal affairs / judicial in camera reviewer typically asks for a **self-contained evidence package**. Closure does not yet emit one.

1. **Identity assurance** — authenticated reviewer, agency, role; not spoofable `actor` query params.  
2. **WORM or independently timestamped audit** — proof the log was not edited after the fact (RFC 3161 timestamp, object-lock bucket, or hash posted to external system).  
3. **Sealed source exhibit** — byte-identical original with hash taken at intake and **never** recomputed as “ground truth.”  
4. **Sealed production exhibit** — each released redacted PDF with hash, linked to (source hash, accepted-set hash, decision-log seal, exporter, timestamp).  
5. **From→to decision records** — prior status, reason codes from a controlled vocabulary (statutory exemption, non-PII, etc.), not only free text.  
6. **Completeness certificate** — “all AI suggestions dispositioned; residual false-negative scan run; flagged cleared” as a signed case gate before export (triage funnel helps operationally; it is not a signed certificate).  
7. **Export recall / supersession** — if review continues after production, a record that production #1 is superseded by #2.  
8. **Access audit** — who *viewed* unredacted pages (not only who decided); often required for sensitive LE files.  
9. **Time sync** — NTP-backed timestamps; explicit timezone; no ambiguous local clocks.  
10. **Retention & legal hold** — policy that decision JSON + custody + exports cannot be wiped by test harness or boot scripts.  
11. **Human-readable audit export** — paginated, non-duplicated, complete (not LIMIT 500), with batch grouping matching the History UI.  
12. **Separation of duties (optional but expected in many agencies)** — different actors for bulk auto-pass vs final export certification.

---

## 6. What is already in good shape (do not regress)

1. **Event-sourced status** — fold of latest decision; no dual-write status column to drift.  
2. **Batch as the undo atom** — bulk triage / entity / band / multi-id share one `batch_id`.  
3. **Undo/restore append inverses** — never delete historical decision files.  
4. **Flagged hard-block on export** — fail-closed when flagged remain pending (`export_case_live` / plan).  
5. **Crypto multi-hash + live BREAK recheck** — right shape for mid-session tamper detection *within a boot*.  
6. **Manual adds in the same log** — false-negative catches are first-class events (`kind=added`).  
7. **History API + UI** — batch list, undo, restore-to-point match the “Google Docs versions” mental model reviewers need for high-volume funnel work.

---

## 7. Minimal “legal MVP” path (suggested order)

1. **Durable custody file per document** at first ingest (P0-1).  
2. **`kind=exported` batch** with source/export/accepted-set hashes (P0-2).  
3. **`prior_status` on every decision** (P1-1).  
4. **Server-side authenticated actor** (P0-4).  
5. **Per-batch seal + external hash log** (P0-3 lite).  
6. Fix audit API dedupe/pagination; ship a **case evidence ZIP** (custody + decisions JSONL + redacted PDFs + seals).

Until (1)–(4) land, describe Closure’s trail as an **operational review log with cryptographic fingerprints**, not as a **chain-of-custody system of record**.

---

## 8. Evidence from this review session

| Check | Result |
|-------|--------|
| Decision mutation surface | All status mutations via `COPY` to `exports/decisions` |
| Export audit rows | **0** (`export_kind_n = 0`) |
| Undo batches in live log | **1** undo, **1** undone forward batch |
| Files with `prior_*` fields | **0** |
| Custody recheck breaks | **0** (all INTACT at exercise time) |
| Export lineage rows | **9** |
| `document_custody` durability | Boot-scoped CTAS only |
| Working registry durable writes on POST | Not observed (in-memory `pdf_store_events` only) |
| Full HTTP boot | Not required; partial load exercised folds/seals/lineage |

---

*Review date: 2026-07-19. Scope: audit + revert + provenance for legal defensibility only; not a full security penetration test.*
