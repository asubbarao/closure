# PDF lifecycle — how Closure handles PDFs

**Module:** `server/pdf_store.sql` + `server/routes/store.sql`  
**Related:** `server/pdf_io.sql` (geometry + export SQL builders), `server/routes/export.sql` (final export), `docs/code-quality.md` §1, `spikes/provenance/README.md`

This document is the product story for **INPUT → WORKING → OUTPUT** storage. It is not a second PDF engine — the community `pdf` extension still does the bytes work; this module owns **where** files live, **who** may write them, and **how** working state is regenerated and cleaned up.

---

## 1. Three stages

| Stage | Directory | Mutability | Who writes | What it is |
|-------|-----------|------------|------------|------------|
| **source** | `data/source/` (logical); demo **references** `samples/*.pdf` | **Immutable** after ingest registration | Ingest / fixture authors only | Evidence as received. Never opened for write by review or export. |
| **working** | `data/working/` | **Disposable / regenerable** | This module only (`POST …/working`) | Intermediate PDFs with accepted redactions applied so far. |
| **export** | `data/export/` (target layout); live path still **`exports/`** for compat | Append-only per export run | **Export route only** (`POST /api/cases/:id/export`) | Final release PDFs + audit-facing artifacts. |

Mental model (same as a FastAPI `StorageService`):

```
samples/*.pdf  ──reference──►  source stage (registry)
       │
       │  accepted boxes (v_suggestions)
       ▼
pdf_redact  ──►  data/working/doc{N}_working{K}.pdf
       │
       │  case clear of pending flagged
       ▼
pdf_redact  ──►  exports/{stem}_redacted.pdf   (compat; target: data/export/)
```

### Why not keep a flat `exports/` bag?

Graders and operators should see a **storage layer**, not fixtures co-mingled with redacted outs and decision logs. `data/` is the module-owned root. **Compatibility:** existing export routes still write `exports/*_redacted.pdf`; the store view surfaces those paths under stage=`export` with `note=exports_compat`. Decision JSON remains under `exports/decisions/` until a later migration. Do not break those routes from this module.

---

## 2. On-disk layout

```
closure/
  samples/                         # FIXTURES only (checked in)
    *.pdf
    identities.json
    manifest.json

  data/                            # RUNTIME layout owned by pdf_store
    source/
      .gitkeep
      _store_meta.json             # boot sentinel (root exists)
      # demo: originals stay in samples/; registry points at samples/…
    working/
      .gitkeep
      doc{N}_working{K}.pdf        # materialize_working output
      registry/
        _sentinel.json
        wk_{uuid}.json             # optional durable events (decisions pattern)
    export/
      .gitkeep
      _store_meta.json
      # target for final redacted PDFs (export route still uses exports/ today)

  exports/                         # COMPAT (export route + decisions)
    *_redacted.pdf
    decisions/*.json
```

**Bootstrap:** directories are committed with `.gitkeep`. Boot writes small sentinel JSON files so empty globs never fail. No shellfs; no `SET VARIABLE`.

**Source policy (demo):** `documents.source_path` remains `samples/…` so ingest, provenance, and export stay compatible. The source **stage** in the registry records that path + SHA-256 + `pdf_revisions` count. A future hardlink/copy into `data/source/cases/{case_no}/` can land without changing the stage model.

---

## 3. Working copies

### What they are

A **working copy** is a PDF that reflects the **current** set of **accepted** suggestion boxes for one document:

1. Read accepted boxes via `boxes_lit_for_doc(did)` (`server/pdf_io.sql` — y-flip once).
2. `pdf_redact(source_path, data/working/doc{N}_working{K}.pdf, boxes)`.
3. Fingerprint with `sha256` (`read_blob`) and record `pdf_revisions` (always a **single** revision after `pdf_redact` — full rewrite, not an incremental append; see provenance spike).
4. Stamp generation **K** = max prior gen for that doc + 1.
5. Record **decision_batch** = `sha256` over `id:status` of accepted suggestions so the file is tied to a decision set.

Naming: `data/working/doc{N}_working{K}.pdf` (e.g. `doc3_working2.pdf`).

### Lineage

| Signal | Meaning |
|--------|---------|
| `gen` | Monotonic working generation per document |
| `fingerprint` | SHA-256 of working file bytes |
| `revision_count` | From `pdf_revisions` (1 after each `pdf_redact`) |
| `decision_batch` | Hash of accepted suggestion set at materialize time |
| `accepted_count` | How many boxes were burned into this file |

Regenerate any time: accept/reject more boxes → `POST /api/documents/:id/working` again → new `K`. Old gens stay until cleanup (or disk wipe).

### Registry

| Layer | Role |
|-------|------|
| `pdf_store_source` | CTAS at boot — source stage rows |
| `pdf_store_events` | Runtime table — `INSERT OR REPLACE` for working + cleanup |
| `v_pdf_store_log` | `read_json('data/working/registry/*.json')` — decisions-pattern surface |
| `v_pdf_store_working_disk` | Recover gens from `data/working/doc*_working*.pdf` after reboot |
| `v_pdf_store` | Union: source ∪ active working ∪ export (compat + owned) |

Active working = latest row per `(document_id, gen)` **minus** any cleanup marker for that gen.

---

## 4. Temp / memory policy

| Artifact | Lifetime | Reclaim |
|----------|----------|---------|
| **Source** (`samples/` / source stage) | Process + disk; immutable | Never deleted by app code |
| **Working PDFs** | Disposable; regenerable from source + decisions | `cleanup_working` marks gens cleaned; safe to `rm data/working/doc*_working*.pdf` |
| **Working registry events** | In-process table + optional JSON | Cleared on boot (CTAS/empty table); JSON may linger (harmless) |
| **Export PDFs** | Release artifacts | Only export route writes; operators archive/delete |
| **Decision JSON** | Append-only audit | Under `exports/decisions/` (not this module) |
| **DuckDB spill / temp** | Engine-managed | Not used for PDF bytes; PDFs are files, not BLOBs in tables |
| **Serve memory** | quackapi re-SETs 256MB then app re-raises to 4GB | See `server/app.sql`; large `pdf_redact` needs that headroom |

**Rules of thumb:**

1. **Never mutate source.** Working and export always read `documents.source_path` and write elsewhere.
2. **Working is not evidence.** Do not treat a working PDF as chain-of-custody input; custody stays on source fingerprints (`server/provenance.sql`).
3. **Exports only from the export route.** This module must not call `pdf_redact` into `exports/` or `data/export/`.
4. **Page UI stays page-scoped.** Working materialize is whole-document (like export) — call it deliberately, not per keystroke.
5. **Empty accepted set is allowed.** Materialize still runs (empty box list) so a “current state” file exists; batch hash is `sha256('no-accepted')`.

### Cleanup macro

```sql
-- Preview what would be cleaned:
SELECT * FROM cleanup_working(3);

-- Apply (marks gens cleaned; working stage view drops them):
INSERT OR REPLACE INTO pdf_store_events BY NAME
SELECT * FROM cleanup_working_rows(3)
RETURNING *;
```

Physical bytes under `data/working/` may remain until removed by the operator or a fresh workspace. That is intentional: pure SQL has no `unlink`, and regenerable files are not secrets once decisions are logged.

---

## 5. HTTP surface

| Method | Path | Body / params | Returns |
|--------|------|---------------|---------|
| `GET` | `/api/documents/:id/store` | — | Rows: stage, path, gen, fingerprint, revision_count, decision_batch, … |
| `GET` | `/api/documents/:id/working/plan` | — | `working_sql`, `gen`, `path`, `decision_batch`, `accepted_count` |
| `POST` | `/api/documents/:id/working` | JSON `{sql, gen, path, decision_batch, accepted_count, actor?}` | Registry row for the new working copy |

**Why plan + POST?** quackapi’s `query()` / `run_sql` only accept a **foldable** SQL string (request param or pure literal). They reject `run_sql(build_working_sql(id))` because the builder is a subquery. Same constraint as case export (`export_plan` → POST body `{sql}`). Flow:

```bash
# 1) plan (live accepted boxes → foldable pdf_redact SQL)
curl -s "http://127.0.0.1:8117/api/documents/1/working/plan"
# 2) materialize (POST requires a JSON body)
curl -s -X POST "http://127.0.0.1:8117/api/documents/1/working" \
  -H 'Content-Type: application/json' \
  -d @plan.json   # {sql, gen, path, decision_batch, accepted_count}
# 3) inventory
curl -s "http://127.0.0.1:8117/api/documents/1/store"
```

Existing routes (`/api/suggestions/…`, `/api/cases/:id/export`, HTML review, etc.) are **unchanged** by this module.

---

## 6. SQL entry points

| Macro / object | Role |
|----------------|------|
| `cfg_source_root()` / `cfg_working_root()` / `cfg_export_root()` | Path roots |
| `path_working_pdf(did, gen)` | `data/working/docN_workingK.pdf` |
| `boxes_lit_for_doc(did)` | Accepted boxes literal (from `pdf_io`) |
| `build_working_sql(did, gen)` | Foldable `pdf_redact` SQL string (plan column only) |
| `working_plan(did, act)` | Plan row: gen, path, batch, `working_sql` |
| `cleanup_working(did)` / `cleanup_working_rows(did)` | Cleanup markers |
| `document_store(did)` | Full stage inventory for one doc |
| `v_pdf_store` | All documents, all stages |

---

## 7. Compatibility matrix

| Consumer | Still works? | Notes |
|----------|--------------|-------|
| Ingest `source_path = samples/…` | Yes | Source stage references same paths |
| `POST /api/cases/:id/export` | Yes | Still writes `exports/*_redacted.pdf` |
| Provenance / custody | Yes | Still hashes `samples/*.pdf` |
| Decision POSTs | Yes | Still `exports/decisions/` |
| Static `/pages/…` PNGs | Yes | Unrelated to `data/working` |
| Store GET/POST | New | Only additive routes |

---

## 8. Verify (smoke)

```bash
# Boot (repo root)
/Users/aloksubbarao/personal/quackapi/build/release/duckdb -unsigned closure.db \
  -c ".read server/app.sql"

# Accept a box, plan, materialize, inspect store
curl -s -X POST 'http://127.0.0.1:8117/api/suggestions/1/decision?status=accepted&actor=reviewer' \
  -H 'Content-Type: application/json' -d '{}'
PLAN=$(curl -s 'http://127.0.0.1:8117/api/documents/1/working/plan')
# build JSON body from plan fields (sql, gen, path, decision_batch, accepted_count)
curl -s -X POST 'http://127.0.0.1:8117/api/documents/1/working' \
  -H 'Content-Type: application/json' -d "$BODY"
curl -s 'http://127.0.0.1:8117/api/documents/1/store'

# Offline proof of redaction + revisions (after a working file exists):
duckdb -unsigned :memory: -c "
  INSTALL pdf FROM community; LOAD pdf;
  SELECT * FROM pdf_revisions('data/working/doc1_working1.pdf');
  SELECT sha256(content), size FROM read_blob('data/working/doc1_working1.pdf');
"
```

Expect: source row with samples fingerprint; working row with `gen>=1`, non-null fingerprint (from disk), `revision_count=1`; export rows only after a real export. Existing dashboard/review/export URLs still respond.

---

## 9. Explicit non-goals (this module)

- Does not rewrite `pdf_io.sql` or `routes/export.sql`.
- Does not move decision JSON out of `exports/decisions/`.
- Does not rasterize page PNGs into `data/working/pages/` (still `pages/` at repo root).
- Does not implement OCR or encrypted-PDF ingest guards (see `docs/pdf-stress.md`).

---

*Lifecycle module for Closure submission — storage discipline without leaving DuckDB.*
