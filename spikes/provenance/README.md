# Spike: PDF chain-of-custody (`pdf_revisions` + fingerprints)

Isolated evaluation of the DuckDB community **`pdf`** extension’s document-audit
surface for Closure’s legal chain-of-custody story. **Owns only**
`spikes/provenance/**`. Does **not** modify `server/`, `samples/`, or routes.

## Prerequisites

```text
DuckDB ≥ 1.5.4 with community pdf (this machine: v1.5.4 quackapi build)
INSTALL pdf FROM community; LOAD pdf;
Python 3 + pypdf (only to rebuild multi-rev fixtures)
```

From **repo root**:

```bash
# Rebuild incremental-update fixtures (optional; committed fixtures exist)
python3 spikes/provenance/fixtures/build_chain.py

duckdb -markdown :memory: < spikes/provenance/01_pdf_revisions_probe.sql
duckdb -markdown :memory: < spikes/provenance/02_ingest_fingerprint.sql
duckdb -markdown :memory: < spikes/provenance/03_recheck_tamper.sql
duckdb -markdown :memory: < spikes/provenance/04_export_lineage.sql
# 05 is documentation-only (integration shapes)
```

Captured run logs and tables land in `spikes/provenance/out/`.

---

## 1. What `pdf_revisions` returns (real output)

### Schema (DESCRIBE)

| Column | Type | Meaning |
|--------|------|---------|
| `revision_index` | `INTEGER` | 0-based generation index |
| `startxref_offset` | `BIGINT` | Byte offset of this generation’s `startxref` |
| `eof_offset` | `BIGINT` | Byte offset of this generation’s `%%EOF` |
| `size_bytes` | `BIGINT` | **Rev 0:** full file size. **Later revs:** *delta* size only |
| `is_incremental` | `BOOLEAN` | `false` for rev 0; `true` for appended generations |

**Signature:** `pdf_revisions(VARCHAR [, password VARCHAR])` only.

### Gotchas (proven)

| Constraint | Evidence |
|------------|----------|
| No `VARCHAR[]` overload | Binder error on list arg |
| No lateral / column params | `pdf_revisions(f)` from a table fails: “only supports literals” |
| Glob returns **no `file` column** | `SELECT * FROM pdf_revisions('samples/*.pdf')` → 5 cols only |
| Size join works for **single-rev** corpora | `JOIN pdf_info … ON file_size = size_bytes` |
| Multi-rev needs **literal path** per file | UNION ALL / boot-generated macros (same as export) |
| `sum(size_bytes) = max(eof_offset) = file size` | Proven on `chain_r3.pdf` |
| Full rewrite ≠ incremental | `pdf_watermark` / `pdf_redact` → single rev 0, new bytes |

### samples/*.pdf (all single-revision)

Every sample is one generation (`revision_index=0`, `is_incremental=false`).
Labeled via size join (representative rows from a successful local run):

| file | revision_index | startxref_offset | eof_offset | size_bytes | is_incremental |
|------|---------------:|-----------------:|-----------:|-----------:|----------------|
| `samples/arrest_report_2024-001003.pdf` | 0 | 16083 | 16442 | 16442 | false |
| `samples/incident_report_2024-001001.pdf` | 0 | 16139 | 16498 | 16498 | false |
| `samples/witness_statement_2024-001003B.pdf` | 0 | 16393 | 16752 | 16752 | false |
| … (all 9 samples: one row each) | 0 | … | = size | = size | false |

Full labeled dump: `out/samples_revisions_labeled.csv`.

### Multi-rev fixture (`fixtures/chain_r3.pdf`)

Built with `pypdf.PdfWriter(fileobj=…, incremental=True)` — true PDF append
updates (`/Prev` chain). **Exact** `pdf_revisions` output:

| revision_index | startxref_offset | eof_offset | size_bytes | is_incremental |
|---------------:|-----------------:|-----------:|-----------:|----------------|
| 0 | 16139 | 16498 | **16498** (original body) | false |
| 1 | 16651 | 16843 | **345** (delta) | true |
| 2 | 16996 | 17188 | **345** (delta) | true |
| 3 | 17341 | 17533 | **345** (delta) | true |

```text
revision_count = 4
sum(size_bytes) = 17533 = final file size = max(eof_offset)
```

Progression:

| file | %%EOF count | revision_count |
|------|------------:|---------------:|
| `chain_r0.pdf` | 1 | 1 |
| `chain_r1.pdf` | 2 | 2 |
| `chain_r2.pdf` | 3 | 3 |
| `chain_r3.pdf` | 4 | 4 |
| `chain_r3_tampered.pdf` | 5 | 5 |

### Full rewrite vs incremental

```sql
SELECT pdf_watermark('samples/incident_report_….pdf', 'out/watermark_rewrite.pdf', '…');
SELECT * FROM pdf_revisions('out/watermark_rewrite.pdf');
-- → one row: revision_index=0, is_incremental=false, new smaller size
```

`pdf_redact` behaves the same: export is a **new** single-rev PDF (Haru
producer), not an append onto the source.

---

## 2. Other audit-ish extension surfaces

| Function | Role for custody | On samples/*.pdf |
|----------|------------------|------------------|
| **`pdf_info`** | Identity meta + `file_size`, `page_count`, `producer`, `pdf_version`, `is_encrypted`, `is_linearized`, `creation_date`, `mod_date`, PDFA fields | Useful — store at ingest |
| **`read_pdf_meta`** | Lighter meta (title/author/pages/version/encrypted) | Overlaps `pdf_info`; less complete |
| **`pdf_signatures`** | Crypto integrity (`verified`, `covers_whole_file`, signer, time) | 0 rows (samples unsigned) |
| **`pdf_annotations`** | Sticky notes / links (PII may hide here) | 0 rows |
| **`pdf_form_fields`** | AcroForm `/V` (not cleared by word-box redact) | 0 rows |
| **`pdf_attachments`** / **`pdf_outline`** | Embedded files / bookmarks | 0 rows |

**`pdf_info` columns (full):**  
`file, title, author, subject, keywords, creator, producer, creation_date,
mod_date, page_count, is_encrypted, is_linearized, pdf_version, width, height,
file_size, pdfa_part, pdfa_conformance`.

Sample incident report meta:

```text
producer=Haru Free PDF Library 2.4.4  pdf_version=1.3  pages=3
encrypted=false  linearized=false  size=16498  dates=NULL
```

**Content fingerprint (not in pdf ext — core DuckDB):**

```sql
SELECT filename, sha256(content), size
FROM read_blob('samples/*.pdf');
-- incident_report → f825ef8061daa32acf153c765d7d0c64248dcab1af7dc8eb500bff4292d2d2a9
```

`read_blob` columns: `filename, content, size, last_modified`. Glob works and
**includes** `filename` (unlike `pdf_revisions` glob).

---

## 3. Proven SQL: ingest fingerprint

See **`02_ingest_fingerprint.sql`**. Core molecule:

```sql
LOAD pdf;

-- Content hash (glob OK)
CREATE TABLE ingest_blob AS
SELECT
    filename AS source_path,
    sha256(content) AS source_sha256,
    md5(content) AS source_md5,
    size AS source_size,
    last_modified AS source_mtime
FROM read_blob('samples/*.pdf');

-- Metadata
CREATE TABLE ingest_info AS
SELECT file AS source_path, producer, pdf_version, page_count,
       is_encrypted, is_linearized, file_size, creation_date, mod_date
FROM pdf_info('samples/*.pdf');

-- Revision count for single-rev corpus (size join)
CREATE TABLE ingest_revs AS
SELECT
    i.source_path,
    count(*)::INTEGER AS source_revision_count,
    max(r.eof_offset)::BIGINT AS source_eof_offset,
    bool_or(r.is_incremental) AS source_has_incremental
FROM ingest_info i
JOIN pdf_revisions('samples/*.pdf') r ON r.size_bytes = i.file_size
GROUP BY i.source_path;

-- Custody row = hash + rev count + meta + timestamp
CREATE TABLE document_custody AS
SELECT b.*, i.producer, i.pdf_version, i.is_encrypted,
       r.source_revision_count, r.source_eof_offset, r.source_has_incremental,
       now() AS ingested_at, 'system' AS ingested_by
FROM ingest_blob b
JOIN ingest_info i USING (source_path)
JOIN ingest_revs r USING (source_path);
```

**Multi-rev path (literal only):**

```sql
SELECT 'spikes/provenance/fixtures/chain_r3.pdf' AS source_path,
       count(*)::INTEGER AS source_revision_count
FROM pdf_revisions('spikes/provenance/fixtures/chain_r3.pdf');
-- → 4
```

**Folded-constant macro** (works when path is a string literal at call site):

```sql
CREATE OR REPLACE MACRO pdf_revision_count(path) AS (
    SELECT count(*)::INTEGER
    FROM query('SELECT * FROM pdf_revisions(''' || replace(path, '''', '''''') || ''')')
);
SELECT pdf_revision_count('spikes/provenance/fixtures/chain_r3.pdf');  -- 4
```

Proven result (fixture):

| source_path | source_sha256 (prefix) | size | revs |
|-------------|------------------------|-----:|-----:|
| `fixtures/chain_r3.pdf` | `33ef4744e5427812…` | 17533 | 4 |

---

## 4. Proven SQL: recheck / tamper detect

See **`03_recheck_tamper.sql`**.

```sql
-- Live re-hash + compare to ingest record
SELECT
    c.source_path,
    c.source_sha256 AS ingest_sha256,
    sha256(b.content) AS live_sha256,
    c.source_revision_count AS ingest_revs,
    live_revs,
    (c.source_sha256 = sha256(b.content)) AS hash_ok,
    (c.source_revision_count = live_revs) AS rev_ok
FROM document_custody c
JOIN read_blob(...) b ON ...
```

### Real results

**samples/*.pdf after ingest:** 9/9 `custody_ok = true`.

**Multi-rev fixture:**

| tag | ingest sha256 | live sha256 | revs in→live | custody |
|-----|---------------|-------------|-------------:|---------|
| pristine `chain_r3.pdf` | `33ef4744…` | `33ef4744…` | 4 → 4 | **INTACT** |
| tampered (one more incremental save) | `33ef4744…` | `8a93769a…` | 4 → 5 | **BREAK: hash + revision_count both changed** |

An incremental mid-review edit always moves **both** signals. A full rewrite
would change the hash (and usually reset `revision_count` to 1). Either way the
gate fails.

---

## 5. Proven SQL: export lineage

See **`04_export_lineage.sql`**.

Flow:

1. **Pre-export custody gate** — recheck all sources; block if any break.
2. **`pdf_redact(source, export_path, boxes)`** — produce redacted bytes.
3. **Fingerprint export** — `sha256` + `pdf_revisions` + `pdf_info`.
4. **Emit lineage certificate** — source → export + timestamps + human statement.

### Real lineage row (incident report, empty box list)

| field | value |
|-------|--------|
| `source_path` | `samples/incident_report_2024-001001.pdf` |
| `source_sha256` | `f825ef8061daa32acf153c765d7d0c64248dcab1af7dc8eb500bff4292d2d2a9` |
| `source_revision_count` | 1 |
| `source_size` | 16498 |
| `export_path` | `spikes/provenance/out/incident_report_2024-001001_redacted.pdf` |
| `export_sha256` | `425df750f4886e389d723d2f119f43371617da40f28c62d9b4e4366dde3f8b14` |
| `export_revision_count` | 1 |
| `export_size` | 5743 |
| `export_producer` | Haru Free PDF Library 2.4.4 |

**Custody statement (emitted):**

> Chain of custody: source samples/incident_report_2024-001001.pdf (SHA-256
> f825ef80…, 1 revision, 16498 bytes) ingested at 2026-07-20T01:09:07Z was
> re-verified intact, then redacted to
> spikes/provenance/out/incident_report_2024-001001_redacted.pdf (SHA-256
> 425df750…, 1 revision, 5743 bytes) at 2026-07-20T01:09:07Z by reviewer.

Artifacts: `out/export_lineage.parquet`, `out/export_lineage.json`.

---

## 6. How a later agent wires this into routes

Full copy-paste shapes: **`05_integration_shapes.sql`** (block comment). Summary:

### Schema

```text
documents += source_sha256, source_md5, source_revision_count,
             source_eof_offset, source_has_incremental,
             producer, pdf_version, is_encrypted, is_linearized, ingested_at

export_lineage (
  id, case_id, document_id,
  source_path, source_sha256, source_revision_count, source_size,
  export_path, export_sha256, export_revision_count, export_size,
  boxes_applied, pre_export_custody_ok,
  exported_at, exported_by, custody_statement
)
```

### Ingest (`server/ingest.sql`)

Extend the existing `documents` CTAS:

- `read_blob('samples/*.pdf')` → hashes  
- `pdf_info` → producer / version / flags (already half-there)  
- `pdf_revisions` size-join for single-rev samples; for multi-rev, generate
  per-path UNION like `export_sql_case_N` macros in `app.sql`

### Views

| View | Purpose |
|------|---------|
| `v_document_custody` | Ingest snapshot per document |
| `v_custody_recheck` | Live `read_blob` hash vs ingest; `custody_ok` |
| `v_export_lineage` | Certificates newest-first |

### Routes

| Method | Path | Returns |
|--------|------|---------|
| GET | `/api/cases/:id/custody` | All docs in case + live recheck (`custody_ok`) |
| GET | `/api/documents/:id/custody` | One doc ingest fingerprint + recheck |
| GET | `/api/cases/:id/lineage` | All `export_lineage` rows for case |
| GET | `/api/documents/:id/lineage` | Lineage for one document |

Prefer **case-level** recheck (glob + join) over per-id `read_blob(column)` —
table functions often reject non-literal paths (same class of bug as
`pdf_revisions`).

### Export path changes

Wrap existing `export_case_exec` / `api_case_export` / `export/run`:

```text
1. SELECT * FROM v_custody_recheck WHERE case_id = :id AND NOT custody_ok
2. If any → { blocked: true, reason: 'custody_break', breaks: [...] }
3. Else run pdf_redact as today (build_export_sql)
4. INSERT export_lineage rows (literal paths / generated macros)
5. Response adds: custody_breaks, lineage[]
```

Isolate PDF calls under `server/pdf/custody.sql` per `docs/code-quality.md`
(sole owners of `pdf_revisions` / `read_blob` hash / `pdf_info` for custody).

### Response shape sketch

```json
{
  "exported": 3,
  "blocked": false,
  "flagged_remaining": 0,
  "custody_breaks": 0,
  "lineage": [
    {
      "document_id": 5,
      "source_sha256": "f825ef80…",
      "source_revision_count": 1,
      "export_sha256": "425df750…",
      "export_revision_count": 1,
      "exported_at": "2026-07-20T01:09:07Z",
      "custody_statement": "Chain of custody: source … → export …"
    }
  ]
}
```

---

## Files

| Path | Role |
|------|------|
| `01_pdf_revisions_probe.sql` | Schema, samples, multi-rev, watermark, sibling audits |
| `02_ingest_fingerprint.sql` | Proven ingest custody CTAS → `out/document_custody.parquet` |
| `03_recheck_tamper.sql` | Intact samples + pristine/tampered fixture proof |
| `04_export_lineage.sql` | Gate + `pdf_redact` + lineage certificate |
| `05_integration_shapes.sql` | Schema / view / route / macro shapes for wiring |
| `fixtures/build_chain.py` | Rebuild multi-rev + tampered PDFs |
| `fixtures/chain_r*.pdf` | Incremental revision ladder |
| `out/*` | Run logs, parquet/json certificates, CSVs |

## Verdict

| Question | Answer |
|----------|--------|
| Does `pdf_revisions` work for CoC? | **Yes** — enumerates startxref/%%EOF generations; delta sizes + `is_incremental` are exact |
| Enough alone? | **No** — pair with `sha256(read_blob)` for content integrity; rev count catches append-only edits even when you also hash |
| samples/*.pdf? | All single-rev (count=1); still record hash + count at ingest |
| Export? | Always new bytes + usually rev_count=1; lineage links source fingerprint → export fingerprint + timestamps |
| Wire ready? | Yes — `05_integration_shapes.sql` + proven 02/03/04 SQL; no server edits in this spike |
