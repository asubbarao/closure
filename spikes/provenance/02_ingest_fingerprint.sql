-- 02_ingest_fingerprint.sql
-- At INGEST: record each source PDF's content fingerprint + revision count.
-- Proven standalone — does not touch server/*. Run from repo root:
--   duckdb -markdown :memory: < spikes/provenance/02_ingest_fingerprint.sql
--
-- Chain-of-custody claim this step establishes:
--   "When we took custody of source S, its SHA-256 was H and it contained
--    R PDF revisions (startxref/%%EOF generations). Any later byte change
--    or incremental append will fail the recheck in 03_recheck_tamper.sql."

LOAD pdf;

.mode markdown

-- ── helpers (ingest-time macros an agent can lift into server/pdf/) ─────────
-- revision_count for a *literal* path. pdf_revisions rejects column params.
CREATE OR REPLACE MACRO pdf_revision_count(path) AS (
    SELECT count(*)::INTEGER
    FROM query('SELECT * FROM pdf_revisions(''' || replace(path, '''', '''''') || ''')')
);

-- NOTE: the macro above only works when `path` is a constant foldable string
-- at the call site (same constraint as pdf_redact export macros in app.sql).
-- For multi-file ingest we therefore either:
--   (1) UNION ALL known literal paths, or
--   (2) join single-rev size_bytes to pdf_info.file_size (samples corpus).

SELECT '=== 1. Content fingerprint via read_blob (glob OK, has filename) ===' AS section;
CREATE OR REPLACE TABLE ingest_blob AS
SELECT
    filename AS source_path,
    sha256(content) AS source_sha256,
    md5(content) AS source_md5,
    size AS source_size,
    last_modified AS source_mtime
FROM read_blob('samples/*.pdf');

SELECT * FROM ingest_blob ORDER BY source_path;

SELECT '=== 2. pdf_info metadata join ===' AS section;
CREATE OR REPLACE TABLE ingest_info AS
SELECT
    file AS source_path,
    title,
    author,
    creator,
    producer,
    creation_date,
    mod_date,
    page_count,
    is_encrypted,
    is_linearized,
    pdf_version,
    width,
    height,
    file_size,
    pdfa_part,
    pdfa_conformance
FROM pdf_info('samples/*.pdf');

SELECT source_path, producer, pdf_version, page_count, is_encrypted, file_size
FROM ingest_info
ORDER BY source_path;

SELECT '=== 3. revision_count (single-rev join — works for samples/) ===' AS section;
-- All samples/*.pdf are single-revision (is_incremental=false, one row).
-- size_bytes == file_size → join is 1:1.
CREATE OR REPLACE TABLE ingest_revs_samples AS
WITH revs AS (
    SELECT revision_index, startxref_offset, eof_offset, size_bytes, is_incremental
    FROM pdf_revisions('samples/*.pdf')
)
SELECT
    i.source_path,
    count(*)::INTEGER AS source_revision_count,
    max(r.eof_offset)::BIGINT AS source_eof_offset,
    bool_or(r.is_incremental) AS source_has_incremental,
    list(
        struct_pack(
            revision_index := r.revision_index,
            startxref_offset := r.startxref_offset,
            eof_offset := r.eof_offset,
            size_bytes := r.size_bytes,
            is_incremental := r.is_incremental
        )
        ORDER BY r.revision_index
    ) AS source_revision_chain
FROM ingest_info i
JOIN revs r ON r.size_bytes = i.file_size
GROUP BY i.source_path
ORDER BY i.source_path;

SELECT source_path, source_revision_count, source_eof_offset, source_has_incremental
FROM ingest_revs_samples
ORDER BY source_path;

SELECT '=== 4. revision_count via literal path (multi-rev safe) ===' AS section;
-- Pattern for production: one UNION arm per document.source_path (generated
-- at boot the same way export_sql_case_N macros are generated).
CREATE OR REPLACE TABLE ingest_revs_literal AS
SELECT
    'samples/incident_report_2024-001001.pdf' AS source_path,
    count(*)::INTEGER AS source_revision_count,
    max(eof_offset)::BIGINT AS source_eof_offset,
    bool_or(is_incremental) AS source_has_incremental
FROM pdf_revisions('samples/incident_report_2024-001001.pdf')
UNION ALL
SELECT
    'spikes/provenance/fixtures/chain_r3.pdf',
    count(*)::INTEGER,
    max(eof_offset)::BIGINT,
    bool_or(is_incremental)
FROM pdf_revisions('spikes/provenance/fixtures/chain_r3.pdf');

SELECT * FROM ingest_revs_literal ORDER BY source_path;

SELECT '=== 5. Document custody row (the INGEST record) ===' AS section;
CREATE OR REPLACE TABLE document_custody AS
SELECT
    row_number() OVER (ORDER BY b.source_path)::INTEGER AS document_id,
    b.source_path,
    b.source_sha256,
    b.source_md5,
    b.source_size,
    b.source_mtime,
    i.page_count,
    i.producer,
    i.pdf_version,
    i.is_encrypted,
    i.is_linearized,
    i.creation_date,
    i.mod_date,
    r.source_revision_count,
    r.source_eof_offset,
    r.source_has_incremental,
    r.source_revision_chain,
    now() AS ingested_at,
    'system' AS ingested_by
FROM ingest_blob b
JOIN ingest_info i ON i.source_path = b.source_path
JOIN ingest_revs_samples r ON r.source_path = b.source_path;

SELECT
    document_id,
    regexp_replace(source_path, '.*/', '') AS filename,
    source_sha256,
    source_size,
    source_revision_count,
    source_has_incremental,
    producer,
    pdf_version,
    ingested_at
FROM document_custody
ORDER BY document_id;

-- Persist for 03 / 04
COPY document_custody TO 'spikes/provenance/out/document_custody.parquet'
    (FORMAT PARQUET);

SELECT '=== 6. Also fingerprint the multi-rev fixture ===' AS section;
CREATE OR REPLACE TABLE fixture_custody AS
SELECT
    b.filename AS source_path,
    sha256(b.content) AS source_sha256,
    b.size AS source_size,
    (SELECT count(*)::INTEGER
     FROM pdf_revisions('spikes/provenance/fixtures/chain_r3.pdf')) AS source_revision_count,
    (SELECT max(eof_offset)
     FROM pdf_revisions('spikes/provenance/fixtures/chain_r3.pdf')) AS source_eof_offset,
    now() AS ingested_at
FROM read_blob('spikes/provenance/fixtures/chain_r3.pdf') b;

SELECT * FROM fixture_custody;
COPY fixture_custody TO 'spikes/provenance/out/fixture_custody.parquet'
    (FORMAT PARQUET);

SELECT 'ingest fingerprint complete' AS status,
       (SELECT count(*) FROM document_custody) AS sample_docs,
       (SELECT count(*) FROM fixture_custody) AS fixture_docs;
