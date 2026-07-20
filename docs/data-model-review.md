# Data-model review — Closure

**Date:** 2026-07-19  
**Scope:** `server/schema.sql`, CTAS boot chain (`ingest.sql`, `seed.sql`, `judge.sql`, `remainder_scan.sql`, `provenance.sql`, `pdf_store.sql`), runtime decision log (`exports/decisions/*.json` + folding views in `seed.sql` / `routes/decisions.sql` / `routes/history.sql`), triage funnel (`routes/triage.sql`).  
**Write constraint:** this file only.  
**Frame:** one human clearing **1000+ AI redaction suggestions across 1000+ pages**, via funnel (auto-pass high-confidence + bulk groups → hand-review residual), catching false negatives, with **full audit trail + revert**.

---

## 0. Executive verdict

The core insight is right and should be preserved:

> **Suggestions are structural. Status is a projection of an append-only decision log. Undo is another event.**

That is the right model for legal review throughput + audit. The implementation, however, is a **prototype that outgrew its DDL sketch**:

| Layer | Reality |
|--------|---------|
| `schema.sql` | Early CREATE TABLE sketch (audit_events as status source). **Not the runtime truth.** |
| Boot CTAS | Rebuilds cases/docs/pages/words/entities/suggestions without most FKs/sequences from schema. |
| Runtime truth | `exports/decisions/*.json` → `v_decision_log` → `v_latest_decision` / `v_manual_suggestions` → `v_suggestions`. |
| Side systems | Judge votes, residual FN hits, entity_groups, custody fingerprints, pdf_store registry — each its own grain, loosely coupled. |

**For the singular requirement (funnel + FN catch + audit + revert):** the *event* design works. What does **not** fully hold up is constraints/grain, dual status systems, fragile log projections at scale, and missing first-class objects for batches, actors, policies, and multi-format documents.

**Prototype honesty:** fine for a single-process demo with a few cases and ~1–2k suggestions.  
**Prod-shaped honesty:** keep event-sourcing; formalize the decision schema; add missing keys/indexes; stop dual-writing mental models (`audit_events` vs JSON log); promote residual/judge/grouping into stable, versioned tables.

---

## 1. Schema diagram (as implemented, not as `schema.sql` claims)

### 1.1 Entity-relationship (text)

```
┌─────────────┐
│   cases     │  PK id, UNIQUE case_no
└──────┬──────┘
       │ 1
       │ N
┌──────▼──────┐         ┌──────────────────┐
│  documents  │────────►│ document_custody │  1:1 snapshot (provenance CTAS)
│  PK id      │         │  PK-ish document_id
│  FK case_id │         └──────────────────┘
│  UNIQUE     │
│  filename   │         ┌──────────────────┐
└──────┬──────┘────────►│ pdf_store_source │  stage=source, gen=0
       │                └──────────────────┘
       │ 1
       ├──────────────── pages ────────── PK (document_id, page_no)
       │                   │
       │ 1                 │ (NO FK from words/suggestions → pages)
       │ N                 ▼
       ├──────────────── words ────────── grain (document_id, page_no, seq)
       │                   │                 NO PRIMARY KEY declared
       │                   │
       │                   └──► v_grams (1–4 n-grams, same-line Δy < 2pt)
       │
       │ N
┌──────▼──────────┐      ┌─────────────┐
│  suggestions    │ N──1 │  entities   │  PK id, UNIQUE (case_id, text, kind)
│  PK id          │      │  FK case_id │
│  FK document_id │      └──────▲──────┘
│  entity_id?     │             │
│  source ai|man  │             │
│  confidence     │             │
│  geometry box   │      entity_groups / entity_group_members
└────────┬────────┘      (address_std + person_fuzz bulk groups)
         │
         │ status NOT stored ── projected from decision log
         │
         ▼
┌─────────────────────────────────────────────────────────────┐
│  APPEND-ONLY DECISION LOG  (filesystem, not a table)        │
│  exports/decisions/{dec_,add_}{uuid}.json                    │
│                                                             │
│  kind: decision | added | sentinel                          │
│  batch_id, batch_label, undoes_batch_id  (batch/undo)       │
│  suggestion_id, status, actor, reason, ts, case_id, …       │
└─────────────────────────────────────────────────────────────┘
         │
         ├── v_decision_log          (read_json glob)
         ├── v_latest_decision       (rn=1 per suggestion_id)
         ├── v_manual_suggestions    (kind=added → synthetic rows)
         ├── v_decision_batches      (group by batch_id)
         ├── v_suggestions           (seed ∪ manual + status + band)
         ├── v_suggestions_judged    (+ judge panel)
         └── v_audit                 (audit_events ∪ decision log)

┌─────────────────┐     ┌──────────────────────┐
│  judge_votes     │     │ residual_pii_hits     │  FN candidates
│  3 × suggestion │     │ (NOT suggestions)     │  promote via manual add
└─────────────────┘     └──────────────────────┘

┌─────────────────┐     ┌──────────────────────┐
│ pdf_store_events│     │ data/working/registry │  parallel JSON log
│ working gens    │     │ *.json                │  (same pattern as decisions)
└─────────────────┘     └──────────────────────┘
```

### 1.2 Grain cheat-sheet

| Object | Intended grain | Enforced? |
|--------|----------------|-----------|
| `cases` | one legal matter | PK + UNIQUE `case_no` in schema; CTAS uses `row_number()` |
| `documents` | one source file in a case | PK; UNIQUE `filename` (global, not per-case) |
| `pages` | one page of one document | PK `(document_id, page_no)` |
| `words` | one token on a page | **No PK**; implicit `(document_id, page_no, seq)` |
| `entities` | one canonical PII value per case/kind | UNIQUE `(case_id, canonical_text, kind)` in schema only |
| `suggestions` | one proposed redaction box | PK `id`; geometry + text + optional `entity_id` |
| Decision event | one status (or one manual add) for one suggestion | File row; batch shared via `batch_id` |
| `judge_votes` | one judge × one suggestion | Implicit `(suggestion_id, judge_id)` |
| `residual_pii_hits` | one FN candidate box | Surrogate `id`; not in decision path |
| `entity_groups` | one bulk-judgment group per case | Surrogate `group_id` |
| Working PDF | one generation of redacted working copy | `(document_id, gen)` |
| Custody | one ingest fingerprint per document | `document_id` |

### 1.3 Status / band projection (runtime)

```
suggestions (AI, CTAS)
     ∪
v_manual_suggestions  ← kind='added' rows in decision log
     │
     ▼
v_suggestions.status =
    v_latest_decision.status          -- kind='decision', latest by (ts, _file)
    OR 'accepted' if source=manual    -- if no decision yet
    OR 'pending'  if source=ai

v_suggestions.band =
    high    if confidence ≥ 90
    review  if confidence ≥ 60
    flagged else
    (from seed confidence / manual 99 — NOT from judge panel by default)

v_suggestions_judged.judge_band =
    flagged if panel split|conflict
    high / review from ensemble confidence
```

**Triage auto-pass** (`routes/triage.sql`): pending ∧ confidence ≥ threshold ∧ band ≠ flagged ∧ flag_tag ≠ false_positive.

---

## 2. What holds up

### 2.1 Hierarchy and product shape

`cases → documents → pages/words → suggestions` matches the UI (case dashboard → document review → page boxes). Entities as a **case-scoped catalog** correctly power bulk fan-out (`entity_id` decision, triage groups `e:{id}`). Geometry in **PDF points, top-left** is consistent from `read_pdf_words` through suggestions to `pdf_redact` (single conversion at export).

### 2.2 Append-only decisions (the important part)

Runtime mutations do **not** `UPDATE suggestions SET status`. They `COPY` JSON events. That means:

- Audit trail cannot disagree with “what is accepted” if every consumer goes through the projection.
- Undo / restore append inverse rows with `undoes_batch_id` + batch labels — Google-Docs-style history without destructive rewrite.
- Bulk actions (entity, band, triage high-pass, multi-id) share one `batch_id` → one undo unit.

This is exactly what the singular requirement needs.

### 2.3 Manual adds as first-class log events

`kind='added'` carries full geometry + synthetic `suggestion_id` and folds into `v_suggestions` via `UNION ALL`. Catching FNs does not require mutating the seed CTAS table. Correct for “add missed redaction.”

### 2.4 Funnel surfaces exist

| Funnel stage | Data support |
|--------------|--------------|
| High-conf auto-pass | `confidence` + `band` + `flag_tag` on `v_suggestions`; triage routes |
| Bulk residual groups | entity_id / text+kind `group_key`; also `entity_groups` for address/person variants |
| Hand-review residual | pending − auto-passable |
| FN catch | `residual_pii_hits` over uncovered remainder |
| Audit + revert | `v_decision_batches`, undo/restore routes |

### 2.5 Provenance / working-copy separation

Source bytes are immutable (`samples/` / `document_custody`). Working copies are regenerable gens with optional registry events. Export is a derived artifact with fingerprints. Decision log has a chain seal (`crypto_hash_agg`). Good legal posture for a prototype.

---

## 3. Rigorous assessment — relationships, keys, grain

### 3.1 `schema.sql` is not the system of record

`schema.sql` documents a design where **`audit_events` is the decision log** and `v_suggestions` projects status from latest `accepted|rejected|undone`. Boot and routes **replaced** that with filesystem JSON:

| Claim in schema | Actual |
|-----------------|--------|
| Status from `audit_events` | Status from `exports/decisions/*.json` |
| `undone` action | Undo writes `status=prior` + `undoes_batch_id`, not `action=undone` |
| Sequences for ids | CTAS `row_number()` / hash for manuals |
| FKs on all children | Dropped on every `CREATE OR REPLACE TABLE` in ingest/seed |

**Impact:** any reader of `schema.sql` alone will design the wrong joins. Treat schema as historical; the folding views + routes are the contract.

### 3.2 Missing / weak keys

| Table | Issue | Severity |
|-------|--------|----------|
| `words` | No `PRIMARY KEY (document_id, page_no, seq)` | Should — dup seq breaks n-grams and context |
| `words` | No FK to `pages` | Should — orphan page_no possible |
| `suggestions` | No FK to `pages` | Should |
| `suggestions` | No CHECK `x0 < x1 AND y0 < y1` | Could |
| `suggestions` | No uniqueness on geometry (same box twice) | Could |
| `audit_events.suggestion_id` | Intentionally no FK; table is mostly dead for status | Must clarify / retire |
| `judge_votes` | No PK `(suggestion_id, judge_id)` | Should |
| `residual_pii_hits` | No link to decision when accepted as manual | Should (provenance of FN promote) |
| `entity_group_members` | No UNIQUE on `(group_id, variant_text)` | Could |
| Decision log | No CHECK on `status` ∈ {accepted,rejected,pending} | Must for prod |
| Decision log | No CHECK on `kind` | Must for prod |

### 3.3 Awkward joins and dual models

1. **Two grouping systems for bulk**  
   - Triage: `e:{entity_id}` or `t:{text}|{kind}` over **pending residual suggestions**.  
   - Remainder: `entity_groups` / `entity_group_members` (addrust + rapidfuzz).  
   They do not share keys. A bulk address group in remainder is not the same object as a triage residual group. Cognitive and API split.

2. **Two confidence systems**  
   - Seed `suggestions.confidence` drives `band` and triage threshold.  
   - `v_judge_panel.confidence` / `judge_band` is parallel and optional.  
   Funnel does not default to judge ensemble → judges can disagree with auto-pass eligibility.

3. **Two audit surfaces**  
   - `audit_events`: boot “ingested” snapshot only (in practice).  
   - Decision log: all human actions.  
   - `v_audit` unions them with different `action` semantics (`ingested` vs `decision`/`added`).  
   Audit UI must special-case `source`.

4. **Two fingerprint stacks**  
   - `provenance.sql`: crypto ext sha2-256 / blake3.  
   - `pdf_store.sql`: core `sha256(content)`.  
   Same bytes, two algo columns — intentional cross-check, but export lineage paths differ (`exports/` vs `data/export/`).

5. **`v_grams` defined twice**  
   `schema.sql` and `ingest.sql` differ slightly on multi-gram y-bounds (`y0` vs `least(y0,…)`). Boot uses ingest. Drift risk if someone reloads schema alone.

### 3.4 Fragility of the append-only projection

These are real failure modes for “1000+ pages / 1000+ suggestions / long review sessions”:

| Risk | Mechanism | Effect |
|------|-----------|--------|
| **Glob re-read every query** | `read_json('exports/decisions/*.json')` in `v_decision_log` | Status projection cost grows with file count; scaling notes already flag this |
| **`ignore_errors := true`** | Malformed JSON silently dropped | Silent audit holes |
| **Latest-decision tie-break** | `ORDER BY ts DESC, _file DESC` | Clock skew / same-ts races; `_file` is path not causal order |
| **Manual id space** | `1000000 + abs(hash(...)) % 1e9` | Collision with AI ids if seed grows past 1e6, or between two manuals |
| **Batch split across files** | `FILE_SIZE_BYTES '100KB'` + `FILENAME_PATTERN` | Rows still share `batch_id` (good) but ops tooling that globs files ≠ batches |
| **Undo of `kind=added`** | Prior status defaults to `pending`; row still in `v_manual_suggestions` | “Deleted” add becomes pending box, not removed — may be intended, undocumented |
| **Restore marker rows** | Reuse first suggestion_id as carrier for `undoes_batch_id` markers | Pollutes per-suggestion history |
| **Undone detection** | `EXISTS` any later event with `undoes_batch_id = batch` | Double-undo / re-undo semantics are ad hoc |
| **No actor identity** | Free-text `actor` | Multi-reviewer audit is not joinable |
| **Remainder cover uses pending+accepted** | Rejected boxes still “cover” remainder if status pending was wrong? Cover = accepted\|pending; rejected text is scanned again — good for FN. Pending cover hides remainder under undecided boxes — intentional funnel choice but means residual scan depends on decision state **at boot**, not live (CTAS tables) |

**Critical prototype vs live gap:** `residual_pii_hits`, `_cover_boxes`, `judge_votes` are **boot CTAS**. After a long review session, remainder and judges are **stale** until reboot. Decision status is live (JSON), detection side tables are not. For “catch FNs while reviewing,” this is a product-model bug.

### 3.5 Normalization issues

| Smell | Detail |
|-------|--------|
| **Kind as encoding** | `PERSON · SUBJECT`, `OFFICER · NOT SUBJECT PII` smuggle role + policy into one VARCHAR. Filters use `starts_with` / `position('PERSON' IN kind)`. |
| **flag_tag vs kind** | FP bait uses both `flag_tag='false_positive'` and kind containing `NOT PII`. Triage hard-codes both. |
| **documents.width_pt/height_pt** | Document-level; pages can differ (rare). Redundant with `pages`. |
| **Denormalized decision payload** | Events store `text`, `document_id`, `case_id` — good for audit immutability; bad if geometry of AI suggestion later “fixed” (log won’t match). Correct for audit, document it. |
| **entities from answer key only** | Runtime discovery (OCR names, residual) does not insert entities; only optional `entity_id` on residual hits. Bulk entity fan-out cannot cover pure residuals without promote path. |

### 3.6 Indexes (none)

No indexes beyond PKs (and words has no PK). At demo scale OK. At 1000+ pages × dense words:

- `v_grams` over words  
- remainder cover anti-join boxes  
- `v_document_stats` (many correlated subqueries on `v_suggestions`)  
- triage residual group self-join  

all become full scans. **Should** add indexes (or materialize status) before claiming page-scale interactivity.

---

## 4. Future needs — absorb or change?

| Need | Absorbs cleanly? | Notes |
|------|------------------|--------|
| **Multi-reviewer (actor / assignment)** | **No** | `actor VARCHAR` free text. No users, roles, locks, assignment of docs/pages/bands. Concurrent two reviewers: last event wins; no conflict policy. |
| **Document batches / folders** | **Partial** | Only `case_id`. No folder, intake batch, or “production set” between case and document. |
| **OCR-sourced words** | **No** | `words` has no `source` (`pdf_text` \| `ocr` \| `html`), no confidence, no engine version. OCR enrich (if any) must be an external table or columns. |
| **Non-PDF (HTML/XML webbed)** | **No** | Geometry contract is PDF points; export is `pdf_redact`. Spike maps HTML to fake boxes (char offsets). Need `documents.media_type` + redaction backend per type. |
| **Redaction categories / policies** | **No** | Free-form `kind` + triage hard-codes. No policy version, statute tag, or “must redact / optional / never”. |
| **Export versioning** | **Partial** | Path overwrite `exports/{stem}_redacted.pdf`; fingerprints change; no `export_id` / version number / “which decision_batch produced this export”. `decision_batch_for_doc` hashes accepted ids but is not stored on export lineage rows as first-class version. |

---

## 5. Ranked concrete schema changes

Convention: DDL sketches are **CTAS-friendly** where noted. Prototype can keep JSON log; prod should materialize or dual-write a table.

### MUST (correctness / audit integrity / funnel truth)

#### M1. Declare the decision log schema as the contract (and stop lying in `schema.sql`)

Either (A) materialize events, or (B) freeze a typed view + JSON schema both routes write.

```sql
-- Preferred prod shape: append-only TABLE (still CTAS-loadable from JSON for migration)
CREATE TABLE IF NOT EXISTS decision_events (
    event_id        VARCHAR PRIMARY KEY,          -- uuid
    batch_id        VARCHAR NOT NULL,
    batch_label     VARCHAR,
    undoes_batch_id VARCHAR,                      -- null unless undo/restore marker
    kind            VARCHAR NOT NULL
                    CHECK (kind IN ('decision', 'added', 'export', 'ingest')),
    suggestion_id   BIGINT NOT NULL,
    status          VARCHAR                       -- null for non-decision kinds
                    CHECK (status IS NULL OR status IN ('accepted', 'rejected', 'pending')),
    actor_id        VARCHAR NOT NULL,             -- FK actors later; not free-form forever
    reason          VARCHAR,
    ts              TIMESTAMPTZ NOT NULL,
    case_id         INTEGER NOT NULL,
    document_id     INTEGER NOT NULL,
    -- payload snapshot for audit (immutable)
    text            VARCHAR,
    page_no         INTEGER,
    x0 DOUBLE, y0 DOUBLE, x1 DOUBLE, y1 DOUBLE,
    entity_id       INTEGER,
    source          VARCHAR CHECK (source IS NULL OR source IN ('ai', 'manual')),
    scope           VARCHAR,                      -- add-missed scope
    prev_status     VARCHAR,                      -- optional: explicit undo payload
    meta            JSON                          -- escape hatch
);

CREATE INDEX idx_decision_suggestion_ts ON decision_events (suggestion_id, ts DESC);
CREATE INDEX idx_decision_batch ON decision_events (batch_id);
CREATE INDEX idx_decision_case_ts ON decision_events (case_id, ts DESC);
```

**Reason:** projection is the product. An untyped JSON glob with `ignore_errors` is not an audit trail under scrutiny. Keep file mirror for durability if desired (`COPY` out), but query a table.

**Prototype compromise:** keep JSON; add CHECK-equivalent validation route + drop `ignore_errors` in prod boots.

#### M2. Fix `v_suggestions` status projection to one ordered event model

```sql
CREATE OR REPLACE VIEW v_latest_decision AS
SELECT * EXCLUDE (rn)
FROM (
    SELECT
        suggestion_id,
        status,
        actor_id AS actor,
        reason,
        ts,
        batch_id,
        row_number() OVER (
            PARTITION BY suggestion_id
            ORDER BY ts DESC, event_id DESC   -- causal id, not _file path
        ) AS rn
    FROM decision_events
    WHERE kind = 'decision'
) z WHERE rn = 1;
```

**Reason:** `_file` tie-break and missing `event_id` make undo/restore and concurrent POSTs fragile.

#### M3. Manual suggestion id allocation (no hash collisions)

```sql
CREATE SEQUENCE IF NOT EXISTS seq_manual_suggestion START 1_000_000_000;
-- on add: nextval('seq_manual_suggestion')
-- AI seed: 1 .. N via row_number or seq_suggestion
```

**Reason:** hash `% 1e9` collides with large seeds and with itself. Manual and AI namespaces must be disjoint and unique under `UNION ALL`.

#### M4. Primary key + page FK on words; page FK on suggestions

```sql
-- After CTAS load (or in CTAS):
CREATE OR REPLACE TABLE words AS
SELECT … FROM …;
-- Enforce grain:
ALTER TABLE words ADD PRIMARY KEY (document_id, page_no, seq);
-- DuckDB: or recreate with PRIMARY KEY in CREATE TABLE + INSERT

-- Logical (if ALTER limited): at least UNIQUE INDEX
CREATE UNIQUE INDEX uq_words ON words (document_id, page_no, seq);
CREATE INDEX idx_words_page ON words (document_id, page_no);

-- suggestions
CREATE INDEX idx_sugg_doc_page ON suggestions (document_id, page_no);
-- Application check: page exists
-- FOREIGN KEY (document_id, page_no) REFERENCES pages(document_id, page_no)
```

**Reason:** n-grams, context windows, and remainder anti-joins assume unique ordered tokens.

#### M5. Live remainder / cover vs boot snapshot

```sql
-- Replace boot-only _cover_boxes with a VIEW over v_suggestions
CREATE OR REPLACE VIEW v_cover_boxes AS
SELECT id AS suggestion_id, document_id, page_no, x0, y0, x1, y1
FROM v_suggestions
WHERE status IN ('accepted', 'pending');

-- Residual hits: either
--  (a) on-demand macro residual_scan(case_id) AS TABLE …, or
--  (b) incremental table residual_pii_hits + refresh route after decision batches
```

**Reason:** FN catcher that freezes at boot fails the singular requirement mid-session.

#### M6. Retire or demote `audit_events` as status authority

- Keep `audit_events` only for system lifecycle (`ingested`, `exported`) **or** fold those into `decision_events.kind`.
- Rewrite `schema.sql` header to match JSON/table event log.
- `v_audit` should be a thin union over one event model.

**Reason:** dual sources of truth guarantee drift.

---

### SHOULD (throughput, multi-user prep, operability)

#### S1. First-class `decision_batches` table (or materialized view)

```sql
CREATE OR REPLACE TABLE decision_batches AS  -- maintained on write, or MV
SELECT
    batch_id,
    min(ts) AS ts_start,
    max(ts) AS ts_end,
    any_value(actor_id) AS actor_id,
    any_value(batch_label) AS label,
    any_value(case_id) AS case_id,
    count(*)::INTEGER AS event_count,
    bool_or(undoes_batch_id IS NOT NULL) AS is_undo,
    max(undoes_batch_id) AS undoes_batch_id
FROM decision_events
GROUP BY batch_id;

-- undone? separate projection:
CREATE OR REPLACE VIEW v_batch_undone AS
SELECT b.batch_id,
       EXISTS (
         SELECT 1 FROM decision_events e
         WHERE e.undoes_batch_id = b.batch_id
       ) AS undone
FROM decision_batches b;
```

**Reason:** history/undo already re-aggregates from the log every request.

#### S2. Actors + optional assignment (multi-reviewer)

```sql
CREATE TABLE actors (
    actor_id   VARCHAR PRIMARY KEY,   -- uuid or email
    display_name VARCHAR NOT NULL,
    role       VARCHAR NOT NULL CHECK (role IN ('reviewer', 'lead', 'auditor', 'system'))
);

CREATE TABLE review_assignments (
    assignment_id INTEGER PRIMARY KEY,
    case_id       INTEGER NOT NULL REFERENCES cases(id),
    document_id   INTEGER REFERENCES documents(id),  -- null = whole case
    actor_id      VARCHAR NOT NULL REFERENCES actors(actor_id),
    scope         VARCHAR NOT NULL DEFAULT 'case'
                  CHECK (scope IN ('case', 'document', 'band', 'page_range')),
    band          VARCHAR,            -- optional
    page_from     INTEGER,
    page_to       INTEGER,
    status        VARCHAR NOT NULL DEFAULT 'open'
                  CHECK (status IN ('open', 'done', 'released')),
    assigned_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**Reason:** free-text actor cannot support handoff, dual control, or “who auto-passed high band.”

#### S3. Normalize entity kind / policy

```sql
CREATE TABLE redaction_categories (
    category_id VARCHAR PRIMARY KEY,  -- 'SSN', 'PERSON', 'ADDRESS', …
    label       VARCHAR NOT NULL,
    default_disposition VARCHAR NOT NULL
        CHECK (default_disposition IN ('must_redact', 'review', 'usually_keep')),
    policy_version INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE entities (
    id             INTEGER PRIMARY KEY,
    case_id        INTEGER NOT NULL REFERENCES cases(id),
    canonical_text VARCHAR NOT NULL,
    category_id    VARCHAR NOT NULL REFERENCES redaction_categories(category_id),
    role           VARCHAR,  -- SUBJECT | WITNESS | OFFICER | …
    is_pii         BOOLEAN NOT NULL DEFAULT true,
    UNIQUE (case_id, canonical_text, category_id, coalesce(role, ''))
);
```

**Reason:** stringly kinds block policy versioning and stable triage rules.

#### S4. Materialize suggestion status for query performance

```sql
-- On each decision batch write (or periodic):
CREATE OR REPLACE TABLE suggestion_status AS
SELECT s.id AS suggestion_id,
       coalesce(ld.status,
         CASE s.source WHEN 'manual' THEN 'accepted' ELSE 'pending' END) AS status,
       ld.batch_id AS last_batch_id,
       ld.ts AS last_decision_ts
FROM (SELECT id, source FROM suggestions
      UNION ALL BY NAME
      SELECT id, source FROM v_manual_suggestions) s
LEFT JOIN v_latest_decision ld ON ld.suggestion_id = s.id;

CREATE UNIQUE INDEX uq_sugg_status ON suggestion_status (suggestion_id);
```

**Reason:** `v_document_stats` and triage currently re-fold the entire log per query. At 1000+ pages this dominates latency before PDF I/O does.

#### S5. Unify triage groups with `entity_groups`

```sql
-- suggestions.entity_id → entity_group_members.entity_id → group_id
-- triage group_key becomes 'g:' || group_id when member, else text fallback
ALTER TABLE suggestions ADD COLUMN group_id INTEGER;  -- nullable, filled by CTAS join
```

**Reason:** one bulk unit for “Hilbert Feeney” + OCR variant + residual spelling.

#### S6. Word source / OCR columns

```sql
ALTER TABLE words ADD COLUMN layer VARCHAR NOT NULL DEFAULT 'pdf_text'
  CHECK (layer IN ('pdf_text', 'ocr', 'html', 'xml', 'manual'));
ALTER TABLE words ADD COLUMN ocr_confidence DOUBLE;  -- null if pdf_text
ALTER TABLE words ADD COLUMN engine VARCHAR;         -- e.g. tesseract/version
```

**Reason:** scanned docs are first-class in product; remainder scan must know which layer produced tokens.

#### S7. Document media type + redaction backend

```sql
ALTER TABLE documents ADD COLUMN media_type VARCHAR NOT NULL DEFAULT 'application/pdf';
ALTER TABLE documents ADD COLUMN redaction_backend VARCHAR NOT NULL DEFAULT 'pdf_redact'
  CHECK (redaction_backend IN ('pdf_redact', 'html_mask', 'xml_mask', 'none'));
-- Geometry interpretation documented per backend (points vs char offsets)
```

**Reason:** webbed spike proved detection works; export path must branch.

#### S8. Export versions

```sql
CREATE TABLE export_versions (
    export_id       VARCHAR PRIMARY KEY,
    document_id     INTEGER NOT NULL REFERENCES documents(id),
    case_id         INTEGER NOT NULL,
    path            VARCHAR NOT NULL,
    fingerprint     VARCHAR NOT NULL,       -- crypto sha2-256
    decision_seal   VARCHAR,               -- hash of accepted set
    decision_batch_snapshot VARCHAR,       -- or list of batch_ids included
    actor_id        VARCHAR NOT NULL,
    created_ts      TIMESTAMPTZ NOT NULL,
    notes           VARCHAR
);
```

**Reason:** overwrite-only exports cannot answer “what did we release on date D?”

#### S9. Indexes for the hot paths

```sql
CREATE INDEX idx_sugg_entity ON suggestions (entity_id);
CREATE INDEX idx_sugg_doc_conf ON suggestions (document_id, confidence);
CREATE INDEX idx_sugg_doc_page ON suggestions (document_id, page_no);
CREATE INDEX idx_entities_case ON entities (case_id);
```

---

### COULD (nice, later, or prod-only)

#### C1. Folders / intake batches

```sql
CREATE TABLE document_folders (
    folder_id INTEGER PRIMARY KEY,
    case_id   INTEGER NOT NULL REFERENCES cases(id),
    name      VARCHAR NOT NULL,
    parent_id INTEGER REFERENCES document_folders(folder_id)
);
ALTER TABLE documents ADD COLUMN folder_id INTEGER REFERENCES document_folders(folder_id);
ALTER TABLE documents ADD COLUMN intake_batch_id VARCHAR;
```

#### C2. Suggestion ↔ word span link

```sql
CREATE TABLE suggestion_spans (
    suggestion_id INTEGER NOT NULL,
    document_id   INTEGER NOT NULL,
    page_no       INTEGER NOT NULL,
    start_seq     INTEGER NOT NULL,
    n_tokens      INTEGER NOT NULL,
    PRIMARY KEY (suggestion_id)
);
```

**Reason:** seed already has `start_seq` / `n_tokens` in hits then drops them. Restoring the link helps re-context and remainder cover without geometry-only overlap.

#### C3. Persist judge votes with model version

```sql
ALTER TABLE judge_votes ADD COLUMN model_version VARCHAR NOT NULL DEFAULT 'sql-ensemble-v1';
ALTER TABLE judge_votes ADD COLUMN computed_at TIMESTAMPTZ NOT NULL DEFAULT now();
-- PK (suggestion_id, judge_id, model_version)
```

#### C4. Soft-delete / hide for undone manuals

```sql
-- status='void' for reversed manual adds, excluded from v_suggestions base
CHECK (status IN ('accepted', 'rejected', 'pending', 'void'))
```

#### C5. Optimistic concurrency for multi-reviewer

```sql
-- decision write includes expected_status; reject if latest differs
expected_status VARCHAR  -- on write request, not stored long-term
```

#### C6. Case-level policy bind

```sql
ALTER TABLE cases ADD COLUMN policy_id VARCHAR;
ALTER TABLE cases ADD COLUMN policy_version INTEGER;
```

---

## 6. Prototype vs production (honest split)

| Concern | Prototype (keep) | Production (change) |
|---------|------------------|---------------------|
| Decision storage | JSON files under `exports/decisions/` | Table `decision_events` + optional file mirror |
| Boot CTAS | Full rebuild of corpus tables | Incremental ingest; don’t wipe decisions |
| Judges / remainder | Boot CTAS | On-demand macros or incremental refresh |
| Constraints | Implicit grain | PK/FK/CHECK + tests |
| Actor | Display string | `actors` + authn outside DuckDB |
| Concurrency | Single process OK | Don’t multi-process-write same `closure.db`; or move events to Postgres |
| Scale of status fold | Fine at ~1–2k suggestions / ~100 JSON files | Materialize status; cap glob / partition by case_id |
| Non-PDF | Spike only | `media_type` + backend |
| Schema.sql | Update or delete | Must match runtime |

**DuckDB-specific:** CTAS + views + `COPY` to JSON is a strong prototype pattern. The mistake is treating the early `CREATE TABLE` sketch as finished design while the real system grew event columns (`batch_id`, undo) only in routes.

---

## 7. Mapping to the singular requirement

| Requirement | Current support | Gap |
|-------------|-----------------|-----|
| Clear 1000+ suggestions fast | Triage auto-pass + group decision + entity/band bulk | Status fold + stale remainder at scale; no materialization |
| Funnel: high-conf then residual groups | Implemented in `routes/triage.sql` | Dual confidence (seed vs judge); dual group models |
| Catch false negatives | `remainder_scan.sql` + manual add | Boot-stale; residuals not full suggestions; no entity promote |
| Full audit trail | Decision JSON + batch labels + chain seal | Untyped JSON, ignore_errors, dual audit_events |
| Revert | Undo last batch + restore-to-batch | Marker-row pollution; prior_status inference; no `void` for adds |

**Bottom line:** keep event-sourced status and batch undo. **Must** formalize the log, stabilize ids, fix live FN/cover, and make `schema.sql` tell the truth. **Should** add actors/assignments, categories/policies, status materialization, export versions, and OCR/media columns before multi-reviewer or multi-format claims. Everything else is could.

---

## 8. Suggested migration order (if implementing)

1. **M6 + rewrite schema comments** (stop dual mental models) — docs + dead code.  
2. **M3 manual ids** — small route change, high collision payoff.  
3. **M1 decision_events table dual-write** (COPY JSON *and* INSERT) — zero UX change.  
4. **M2 projection on event_id** — history/undo safety.  
5. **S4 materialize status** — funnel performance.  
6. **M5 live remainder view/macro** — FN correctness mid-session.  
7. **M4 keys/indexes** — grain safety.  
8. **S3 categories, S2 actors, S8 exports** — product expansion.

---

## 9. Source map (what was reviewed)

| File | Role in model |
|------|----------------|
| `server/schema.sql` | Original DDL + stale status projection |
| `server/ingest.sql` | CTAS cases/docs/pages/words/entities + `v_grams` |
| `server/seed.sql` | CTAS suggestions + decision-log views + `v_suggestions` |
| `server/judge.sql` | `judge_votes` / panel / `v_suggestions_judged` |
| `server/remainder_scan.sql` | Cover mask, residual hits, entity_groups |
| `server/provenance.sql` | Custody fingerprints + chain seal |
| `server/pdf_store.sql` | Source/working/export registry |
| `server/routes/decisions.sql` | Live log schema + batch writes |
| `server/routes/history.sql` | Undo/restore append semantics |
| `server/routes/triage.sql` | Funnel math + group decision |
| `server/app.sql` | `v_audit` union |
| `exports/decisions/*.json` | Runtime event examples (`batch_id`, `undoes_batch_id`) |
| `spikes/web-ingest/README.md` | Non-PDF geometry contract gap |

---

*End of data-model review.*
