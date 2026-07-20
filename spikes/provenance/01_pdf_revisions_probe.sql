-- 01_pdf_revisions_probe.sql
-- What does pdf_revisions return? Run from repo root.
--   duckdb -markdown :memory: < spikes/provenance/01_pdf_revisions_probe.sql
--
-- Schema (proven via DESCRIBE):
--   revision_index   INTEGER   -- 0-based; 0 = original full body
--   startxref_offset BIGINT    -- byte offset of this revision's startxref
--   eof_offset       BIGINT    -- byte offset of this revision's %%EOF
--   size_bytes       BIGINT    -- rev0: full size; later: DELTA size only
--   is_incremental   BOOLEAN   -- false for rev0, true for appended revs
--
-- Gotchas (proven):
--   * Signature: pdf_revisions(VARCHAR [, password VARCHAR]) only.
--   * No VARCHAR[] overload; no lateral column params (literal path/glob only).
--   * Glob 'samples/*.pdf' returns rows WITHOUT a file column — join via
--     size_bytes = pdf_info.file_size works only for single-revision files.
--   * sum(size_bytes) == final file size; max(eof_offset) == final file size.
--   * pdf_watermark / pdf_redact / full rewrite → single rev0 (new file).
--   * True incremental save (pypdf incremental=True) → multi-row chain.

LOAD pdf;

.mode markdown

SELECT '=== A. schema ===' AS section;
DESCRIBE SELECT * FROM pdf_revisions('samples/incident_report_2024-001001.pdf');

SELECT '=== B. samples/*.pdf (one rev each, no file col on glob) ===' AS section;
SELECT * FROM pdf_revisions('samples/*.pdf') ORDER BY size_bytes;

-- Recover paths for single-rev corpus by joining to pdf_info.file_size.
SELECT '=== C. samples labeled via size join (single-rev only) ===' AS section;
WITH revs AS (
    SELECT * FROM pdf_revisions('samples/*.pdf')
),
info AS (
    SELECT file, file_size, producer, pdf_version, page_count
    FROM pdf_info('samples/*.pdf')
)
SELECT
    i.file,
    r.revision_index,
    r.startxref_offset,
    r.eof_offset,
    r.size_bytes,
    r.is_incremental,
    i.producer,
    i.pdf_version,
    i.page_count
FROM revs r
JOIN info i ON i.file_size = r.size_bytes
ORDER BY i.file, r.revision_index;

SELECT '=== D. incremental chain fixture (chain_r3.pdf) ===' AS section;
SELECT *
FROM pdf_revisions('spikes/provenance/fixtures/chain_r3.pdf')
ORDER BY revision_index;

SELECT '=== E. size math on multi-rev ===' AS section;
SELECT
    count(*) AS revision_count,
    max(revision_index) + 1 AS revision_count_alt,
    sum(size_bytes) AS sum_size_bytes,
    max(eof_offset) AS final_eof_offset,
    bool_or(is_incremental) AS has_incremental,
    count(*) FILTER (WHERE is_incremental) AS incremental_steps
FROM pdf_revisions('spikes/provenance/fixtures/chain_r3.pdf');

SELECT '=== F. progression r0→r3 revision counts ===' AS section;
SELECT 'chain_r0' AS file, count(*) AS revision_count
FROM pdf_revisions('spikes/provenance/fixtures/chain_r0.pdf')
UNION ALL
SELECT 'chain_r1', count(*)
FROM pdf_revisions('spikes/provenance/fixtures/chain_r1.pdf')
UNION ALL
SELECT 'chain_r2', count(*)
FROM pdf_revisions('spikes/provenance/fixtures/chain_r2.pdf')
UNION ALL
SELECT 'chain_r3', count(*)
FROM pdf_revisions('spikes/provenance/fixtures/chain_r3.pdf')
UNION ALL
SELECT 'chain_r3_tampered', count(*)
FROM pdf_revisions('spikes/provenance/fixtures/chain_r3_tampered.pdf')
ORDER BY file;

SELECT '=== G. full rewrite (watermark) is NOT incremental ===' AS section;
SELECT pdf_watermark(
    'samples/incident_report_2024-001001.pdf',
    'spikes/provenance/out/watermark_rewrite.pdf',
    'PROVENANCE-SPIKE'
) AS written;
SELECT * FROM pdf_revisions('spikes/provenance/out/watermark_rewrite.pdf');

SELECT '=== H. sibling audit surfaces on samples ===' AS section;
SELECT 'pdf_signatures' AS surface, count(*)::BIGINT AS n
FROM pdf_signatures('samples/*.pdf')
UNION ALL
SELECT 'pdf_annotations', count(*) FROM pdf_annotations('samples/*.pdf')
UNION ALL
SELECT 'pdf_form_fields', count(*) FROM pdf_form_fields('samples/*.pdf')
UNION ALL
SELECT 'pdf_attachments', count(*) FROM pdf_attachments('samples/*.pdf')
UNION ALL
SELECT 'pdf_outline', count(*) FROM pdf_outline('samples/*.pdf');

SELECT '=== I. pdf_info fields (metadata for custody record) ===' AS section;
SELECT
    file,
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
FROM pdf_info('samples/incident_report_2024-001001.pdf');

SELECT '=== J. read_pdf_meta (lighter meta) ===' AS section;
SELECT * FROM read_pdf_meta('samples/incident_report_2024-001001.pdf');
