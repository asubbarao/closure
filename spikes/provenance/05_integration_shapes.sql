-- 05_integration_shapes.sql
-- READY-TO-INTEGRATE shapes for a later agent. NOT executed against the live
-- server schema (this spike owns only spikes/provenance/**). Copy/adapt into:
--   server/schema.sql   — columns + tables
--   server/ingest.sql   — custody CTAS
--   server/routes.sql   — views + CREATE ROUTE
--   server/app.sql      — export gate + lineage after pdf_redact
--
-- This file is documentation-as-SQL: safe to read; do not .read into production
-- without the schema migration step.

/*
══════════════════════════════════════════════════════════════════════════════
A. SCHEMA DELTAS (server/schema.sql)
══════════════════════════════════════════════════════════════════════════════

-- On documents: custody fields recorded at ingest (immutable after insert).
ALTER TABLE documents ADD COLUMN IF NOT EXISTS source_sha256 VARCHAR;
ALTER TABLE documents ADD COLUMN IF NOT EXISTS source_md5 VARCHAR;
ALTER TABLE documents ADD COLUMN IF NOT EXISTS source_revision_count INTEGER;
ALTER TABLE documents ADD COLUMN IF NOT EXISTS source_eof_offset BIGINT;
ALTER TABLE documents ADD COLUMN IF NOT EXISTS source_has_incremental BOOLEAN;
ALTER TABLE documents ADD COLUMN IF NOT EXISTS producer VARCHAR;
ALTER TABLE documents ADD COLUMN IF NOT EXISTS pdf_version VARCHAR;
ALTER TABLE documents ADD COLUMN IF NOT EXISTS is_encrypted BOOLEAN;
ALTER TABLE documents ADD COLUMN IF NOT EXISTS is_linearized BOOLEAN;
ALTER TABLE documents ADD COLUMN IF NOT EXISTS ingested_at TIMESTAMP DEFAULT now();

-- Optional full revision chain (LIST of STRUCTs) for deep forensics UI.
-- ALTER TABLE documents ADD COLUMN IF NOT EXISTS source_revision_chain JSON;

-- Export certificates (one row per successful export of a document).
CREATE TABLE IF NOT EXISTS export_lineage (
    id                      INTEGER PRIMARY KEY DEFAULT nextval('seq_audit'),
    case_id                 INTEGER NOT NULL REFERENCES cases(id),
    document_id             INTEGER NOT NULL REFERENCES documents(id),
    source_path             VARCHAR NOT NULL,
    source_sha256           VARCHAR NOT NULL,
    source_revision_count   INTEGER NOT NULL,
    source_size             BIGINT NOT NULL,
    export_path             VARCHAR NOT NULL,
    export_sha256           VARCHAR NOT NULL,
    export_revision_count   INTEGER NOT NULL,
    export_size             BIGINT NOT NULL,
    boxes_applied           INTEGER NOT NULL DEFAULT 0,
    pre_export_custody_ok   BOOLEAN NOT NULL,
    exported_at             TIMESTAMP NOT NULL DEFAULT now(),
    exported_by             VARCHAR NOT NULL DEFAULT 'reviewer',
    custody_statement       VARCHAR NOT NULL
);

-- Widen audit_events.action CHECK to allow custody events if desired:
--   'custody_ok', 'custody_break', 'export_lineage'
-- Or keep using existing 'ingested' / 'exported' and put details in target/reason.

══════════════════════════════════════════════════════════════════════════════
B. INGEST (server/ingest.sql) — extend documents CTAS
══════════════════════════════════════════════════════════════════════════════

-- After existing pdf_info CTE, add blob + revs. Pattern proven in 02_*.sql:

CREATE OR REPLACE TABLE documents AS
WITH
manifest AS ( ... existing ... ),
pdf_info AS (
    SELECT
        regexp_replace(file, '.*/', '') AS basename,
        page_count, width, height, file_size, file AS full_path,
        producer, pdf_version, is_encrypted, is_linearized,
        creation_date, mod_date
    FROM pdf_info('samples/*.pdf')
),
blobs AS (
    SELECT
        regexp_replace(filename, '.*/', '') AS basename,
        filename AS full_path,
        sha256(content) AS source_sha256,
        md5(content) AS source_md5,
        size AS source_size
    FROM read_blob('samples/*.pdf')
),
-- Single-rev corpus join (samples/). For multi-rev sources, generate
-- per-path UNION ALL of pdf_revisions('literal') like export macros.
revs AS (
    SELECT
        i.basename,
        count(*)::INTEGER AS source_revision_count,
        max(r.eof_offset)::BIGINT AS source_eof_offset,
        bool_or(r.is_incremental) AS source_has_incremental
    FROM pdf_info i
    JOIN pdf_revisions('samples/*.pdf') r ON r.size_bytes = i.file_size
    GROUP BY i.basename
)
SELECT
    row_number() OVER (ORDER BY m.stem)::INTEGER AS id,
    ca.id AS case_id,
    m.stem AS filename,
    'samples/' || m.filename AS source_path,
    i.page_count::INTEGER AS page_count,
    i.width::DOUBLE AS width_pt,
    i.height::DOUBLE AS height_pt,
    i.file_size::BIGINT AS file_size,
    b.source_sha256,
    b.source_md5,
    r.source_revision_count,
    r.source_eof_offset,
    r.source_has_incremental,
    i.producer,
    i.pdf_version,
    i.is_encrypted,
    i.is_linearized,
    now() AS ingested_at
FROM manifest m
JOIN cases ca ON ca.case_no = m.case_no
JOIN pdf_info i ON i.basename = m.filename
JOIN blobs b ON b.basename = m.filename
JOIN revs r ON r.basename = m.filename;

-- Enrich the existing ingested audit_events target string with hashes:
--   format('{} docs · custody: {}', n, list of short hashes)

══════════════════════════════════════════════════════════════════════════════
C. VIEWS
══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW v_document_custody AS
SELECT
    d.id AS document_id,
    d.case_id,
    d.filename,
    d.source_path,
    d.source_sha256,
    d.source_revision_count,
    d.source_has_incremental,
    d.file_size,
    d.producer,
    d.pdf_version,
    d.is_encrypted,
    d.ingested_at
FROM documents d;

-- Live recheck against bytes on disk (read-only). Call from API / pre-export.
CREATE OR REPLACE VIEW v_custody_recheck AS
WITH live AS (
    SELECT
        filename AS source_path,
        sha256(content) AS live_sha256,
        size AS live_size
    FROM read_blob(
        -- production: prefer list of documents.source_path; glob OK for samples
        'samples/*.pdf'
    )
)
SELECT
    d.id AS document_id,
    d.case_id,
    d.filename,
    d.source_path,
    d.source_sha256 AS ingest_sha256,
    l.live_sha256,
    d.source_revision_count AS ingest_revision_count,
    -- live revision_count: prefer per-doc literal macro; single-rev join below
    d.file_size AS ingest_size,
    l.live_size,
    (d.source_sha256 = l.live_sha256) AS hash_ok,
    (d.file_size = l.live_size) AS size_ok,
    (d.source_sha256 = l.live_sha256 AND d.file_size = l.live_size) AS custody_ok,
    now() AS rechecked_at
FROM documents d
JOIN live l ON l.source_path = d.source_path;

CREATE OR REPLACE VIEW v_export_lineage AS
SELECT * FROM export_lineage ORDER BY exported_at DESC, id DESC;

══════════════════════════════════════════════════════════════════════════════
D. ROUTE SHAPES (server/routes.sql) — CREATE ROUTE fragments
══════════════════════════════════════════════════════════════════════════════

-- GET /api/documents/:id/custody
-- One document's ingest fingerprint + live recheck.
CREATE OR REPLACE ROUTE api_doc_custody GET '/api/documents/:id/custody' AS
SELECT
    d.id AS document_id,
    d.case_id,
    d.filename,
    d.source_path,
    d.source_sha256,
    d.source_revision_count,
    d.source_has_incremental,
    d.file_size,
    d.producer,
    d.pdf_version,
    d.is_encrypted,
    d.ingested_at,
    (SELECT sha256(content) FROM read_blob(d.source_path)) AS live_sha256,
    -- NOTE: read_blob(column) may also reject non-literals in some builds.
    -- If so, use the case-level recheck view filtered by id, or generate
    -- per-doc macros at boot (same pattern as export_sql_case_N).
    (d.source_sha256 = (SELECT sha256(content) FROM read_blob(d.source_path))) AS custody_ok
FROM documents d
WHERE d.id = $id::INTEGER;

-- Safer case-level recheck (glob + join, no column-param table functions):
CREATE OR REPLACE ROUTE api_case_custody GET '/api/cases/:id/custody' AS
SELECT *
FROM v_custody_recheck
WHERE case_id = $id::INTEGER
ORDER BY document_id;

-- GET /api/cases/:id/lineage  — all export certificates for a case
CREATE OR REPLACE ROUTE api_case_lineage GET '/api/cases/:id/lineage' AS
SELECT
    id,
    document_id,
    source_path,
    source_sha256,
    source_revision_count,
    export_path,
    export_sha256,
    export_revision_count,
    boxes_applied,
    pre_export_custody_ok,
    exported_at,
    exported_by,
    custody_statement
FROM export_lineage
WHERE case_id = $id::INTEGER
ORDER BY exported_at DESC, id DESC;

-- GET /api/documents/:id/lineage
CREATE OR REPLACE ROUTE api_doc_lineage GET '/api/documents/:id/lineage' AS
SELECT *
FROM export_lineage
WHERE document_id = $id::INTEGER
ORDER BY exported_at DESC;

══════════════════════════════════════════════════════════════════════════════
E. EXPORT GATE + LINEAGE WRITE (wrap existing export path)
══════════════════════════════════════════════════════════════════════════════

-- Before running build_export_sql / pdf_redact:
--   1. SELECT * FROM v_custody_recheck WHERE case_id = :cid AND NOT custody_ok
--   2. If any rows → return { blocked: true, reason: 'custody_break', breaks: [...] }
--   3. Else run pdf_redact as today
--   4. For each exported file, INSERT into export_lineage:

-- INSERT INTO export_lineage (
--   case_id, document_id, source_path, source_sha256, source_revision_count,
--   source_size, export_path, export_sha256, export_revision_count, export_size,
--   boxes_applied, pre_export_custody_ok, exported_by, custody_statement
-- )
-- SELECT
--   d.case_id, d.id, d.source_path, d.source_sha256, d.source_revision_count,
--   d.file_size,
--   'exports/' || d.filename || '_redacted.pdf',
--   (SELECT sha256(content) FROM read_blob('exports/' || d.filename || '_redacted.pdf')),
--   (SELECT count(*)::INTEGER FROM pdf_revisions('exports/' || d.filename || '_redacted.pdf')),
--   (SELECT size FROM read_blob('exports/' || d.filename || '_redacted.pdf')),
--   :boxes_applied, true, :actor,
--   format('Chain of custody: source {} (SHA-256 {}, {} rev) → export {} (SHA-256 {}) at {}',
--          d.source_path, d.source_sha256, d.source_revision_count,
--          'exports/' || d.filename || '_redacted.pdf',
--          (SELECT sha256(content) FROM read_blob(...)),
--          now())
-- FROM documents d WHERE d.id = :did;

-- Because pdf_revisions / read_blob often need literal paths, generate
-- lineage SQL at the same time as export_sql_case_N() macros:

-- CREATE OR REPLACE MACRO lineage_sql_case_N() AS
--   'INSERT INTO export_lineage ... SELECT ... FROM read_blob(''exports/foo_redacted.pdf'') ...';

-- Extend export_case_exec / export_case_live response shape:
-- {
--   exported: N,
--   blocked: bool,
--   flagged_remaining: N,
--   custody_breaks: N,          -- NEW
--   export_sql: '...',
--   lineage: [ { document_id, source_sha256, export_sha256, custody_statement } ]
-- }

══════════════════════════════════════════════════════════════════════════════
F. PDF HELPER MACROS (server/pdf/custody.sql — sole call sites)
══════════════════════════════════════════════════════════════════════════════

-- Isolate extension calls per docs/code-quality.md:
CREATE OR REPLACE MACRO pdf_source_fingerprint(path) AS TABLE
SELECT
    filename AS source_path,
    sha256(content) AS source_sha256,
    md5(content) AS source_md5,
    size AS source_size,
    last_modified AS source_mtime
FROM read_blob(path);

CREATE OR REPLACE MACRO pdf_revision_rows(path) AS TABLE
SELECT * FROM pdf_revisions(path);

CREATE OR REPLACE MACRO pdf_revision_count_lit(path) AS (
    SELECT count(*)::INTEGER FROM pdf_revisions(path)
);

CREATE OR REPLACE MACRO pdf_info_row(path) AS TABLE
SELECT * FROM pdf_info(path);

══════════════════════════════════════════════════════════════════════════════
G. CONSTRAINTS THE INTEGRATING AGENT MUST RESPECT
══════════════════════════════════════════════════════════════════════════════

1. pdf_revisions(path) — path MUST be a string literal (or foldable constant).
   No LATERAL, no column bind, no VARCHAR[].
2. Glob multi-file pdf_revisions returns NO file column; join by size_bytes only
   safe when every file has exactly one revision.
3. Multi-rev sources: generate per-path SQL (export-macro pattern) or call once
   per document with a literal.
4. sha256(content) FROM read_blob is the content fingerprint; revision_count is
   independent signal (incremental append changes both).
5. pdf_redact / watermark / encrypt rewrite → export almost always rev_count=1
   and a NEW sha256 (lineage links old→new; does not preserve source revs).
6. Pre-export recheck is mandatory for the legal story; do not skip on error.
7. This spike does not modify server/; wire via a deliberate schema migration.

*/
SELECT '05_integration_shapes.sql is documentation-only; see block comment.' AS note;
