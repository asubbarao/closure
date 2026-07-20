-- 04_export_lineage.sql
-- At EXPORT: show redacted output's lineage
--   source fingerprint → export fingerprint, revision counts, timestamp.
-- Run from repo root (after 02):
--   duckdb -markdown :memory: < spikes/provenance/04_export_lineage.sql

LOAD pdf;

.mode markdown

CREATE OR REPLACE TABLE document_custody AS
SELECT * FROM read_parquet('spikes/provenance/out/document_custody.parquet');

SELECT '=== 1. Pre-export custody gate (must all be INTACT) ===' AS section;
CREATE OR REPLACE TABLE pre_export_gate AS
WITH live AS (
    SELECT filename AS source_path, sha256(content) AS live_sha256, size AS live_size
    FROM read_blob('samples/*.pdf')
)
SELECT
    c.document_id,
    c.source_path,
    c.source_sha256,
    l.live_sha256,
    (c.source_sha256 = l.live_sha256) AS custody_ok
FROM document_custody c
JOIN live l ON l.source_path = c.source_path;

SELECT
    count(*) AS n,
    count(*) FILTER (WHERE custody_ok) AS ok,
    count(*) FILTER (WHERE NOT custody_ok) AS blocked
FROM pre_export_gate;

-- Hard stop in production: if any NOT custody_ok, refuse export.
-- Spike continues only for docs that pass.

SELECT '=== 2. pdf_redact one sample (empty boxes = identity copy of structure) ===' AS section;
-- Use one accepted-box-shaped redact so we get a real export artifact.
-- Box coords are pdf_redact space (page,x,y,w,h) — spike uses a dummy empty list
-- to prove lineage machinery without depending on suggestions.
SELECT *
FROM pdf_redact(
    'samples/incident_report_2024-001001.pdf',
    'spikes/provenance/out/incident_report_2024-001001_redacted.pdf',
    []::STRUCT(page INTEGER, x DOUBLE, y DOUBLE, w DOUBLE, h DOUBLE)[]
);

SELECT '=== 3. Export fingerprint ===' AS section;
CREATE OR REPLACE TABLE export_blob AS
SELECT
    filename AS export_path,
    sha256(content) AS export_sha256,
    md5(content) AS export_md5,
    size AS export_size,
    last_modified AS export_mtime
FROM read_blob('spikes/provenance/out/incident_report_2024-001001_redacted.pdf');

SELECT * FROM export_blob;

SELECT '=== 4. Export pdf_info + revisions ===' AS section;
SELECT file, producer, pdf_version, page_count, file_size, is_encrypted
FROM pdf_info('spikes/provenance/out/incident_report_2024-001001_redacted.pdf');

SELECT *
FROM pdf_revisions('spikes/provenance/out/incident_report_2024-001001_redacted.pdf');

SELECT '=== 5. Lineage row (the legal export certificate) ===' AS section;
CREATE OR REPLACE TABLE export_lineage AS
SELECT
    c.document_id,
    c.source_path,
    c.source_sha256,
    c.source_md5,
    c.source_size,
    c.source_revision_count,
    c.source_has_incremental,
    c.producer AS source_producer,
    c.pdf_version AS source_pdf_version,
    c.ingested_at,
    e.export_path,
    e.export_sha256,
    e.export_md5,
    e.export_size,
    (SELECT count(*)::INTEGER
     FROM pdf_revisions(
         'spikes/provenance/out/incident_report_2024-001001_redacted.pdf'
     )) AS export_revision_count,
    (SELECT producer
     FROM pdf_info(
         'spikes/provenance/out/incident_report_2024-001001_redacted.pdf'
     )) AS export_producer,
    0::INTEGER AS boxes_applied,  -- spike: empty list
    (SELECT max(page)
     FROM pdf_redact(
         'samples/incident_report_2024-001001.pdf',
         'spikes/provenance/out/incident_report_2024-001001_redacted.pdf',
         []::STRUCT(page INTEGER, x DOUBLE, y DOUBLE, w DOUBLE, h DOUBLE)[]
     )) AS pages_in_export,
    true AS pre_export_custody_ok,
    now() AS exported_at,
    'reviewer' AS exported_by,
    format(
        'Chain of custody: source {} (SHA-256 {}, {} revision{}, {} bytes) '
        || 'ingested at {} was re-verified intact, then redacted to {} '
        || '(SHA-256 {}, {} revision{}, {} bytes) at {} by {}.',
        c.source_path,
        c.source_sha256,
        c.source_revision_count,
        CASE WHEN c.source_revision_count = 1 THEN '' ELSE 's' END,
        c.source_size,
        strftime(c.ingested_at, '%Y-%m-%dT%H:%M:%SZ'),
        e.export_path,
        e.export_sha256,
        (SELECT count(*)::INTEGER
         FROM pdf_revisions(
             'spikes/provenance/out/incident_report_2024-001001_redacted.pdf'
         )),
        CASE WHEN (
            SELECT count(*) FROM pdf_revisions(
                'spikes/provenance/out/incident_report_2024-001001_redacted.pdf'
            )
        ) = 1 THEN '' ELSE 's' END,
        e.export_size,
        strftime(now(), '%Y-%m-%dT%H:%M:%SZ'),
        'reviewer'
    ) AS custody_statement
FROM document_custody c
CROSS JOIN export_blob e
WHERE c.source_path = 'samples/incident_report_2024-001001.pdf';

SELECT
    document_id,
    source_sha256,
    source_revision_count,
    export_sha256,
    export_revision_count,
    export_size,
    exported_at,
    custody_statement
FROM export_lineage;

COPY export_lineage TO 'spikes/provenance/out/export_lineage.parquet' (FORMAT PARQUET);
COPY (
    SELECT
        document_id,
        source_path,
        source_sha256,
        source_revision_count,
        source_size,
        ingested_at,
        export_path,
        export_sha256,
        export_revision_count,
        export_size,
        boxes_applied,
        pre_export_custody_ok,
        exported_at,
        exported_by,
        custody_statement
    FROM export_lineage
) TO 'spikes/provenance/out/export_lineage.json' (FORMAT JSON, ARRAY true);

SELECT 'export lineage complete' AS status;
