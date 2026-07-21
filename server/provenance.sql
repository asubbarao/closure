-- provenance.sql — chain-of-custody: crypto fingerprints + export lineage.
-- After ingest. Builds on v_src_decisions. Extensions: crypto, pdf.
-- UI (provenance_panel): source_fingerprint, recheck_ok, revision_count,
-- export_fingerprint/path/exported_at, live_sha256, filename, source_path.

CREATE OR REPLACE TABLE document_custody AS
WITH blobs AS (
    SELECT filename AS source_path,
           lower(hex(crypto_hash('sha2-256', content))) AS source_sha256,
           lower(hex(crypto_hash('blake3', content))) AS source_blake3,
           sha256(content) AS source_sha256_core,
           size AS source_size
    FROM read_blob('samples/*.pdf')
),
revs AS (
    SELECT i.file AS source_path, count(*)::INTEGER AS source_revision_count
    FROM pdf_info('samples/*.pdf') i
    JOIN pdf_revisions('samples/*.pdf') r ON r.size_bytes = i.file_size
    GROUP BY i.file
)
SELECT d.id AS document_id, d.case_id, d.filename, d.source_path,
       b.source_sha256, b.source_blake3,
       (b.source_sha256 = b.source_sha256_core) AS crypto_core_match,
       b.source_size, r.source_revision_count,
       'crypto:sha2-256' AS hash_algo, now() AS ingested_at
FROM documents d
JOIN blobs b ON b.source_path = d.source_path
JOIN revs r ON r.source_path = d.source_path;

-- Unified API: /api/cases/:id/provenance[/recheck], /api/documents/:id/provenance.
CREATE OR REPLACE VIEW v_case_provenance AS
WITH live AS (
    SELECT filename AS source_path,
           lower(hex(crypto_hash('sha2-256', content))) AS live_sha256,
           lower(hex(crypto_hash('blake3', content))) AS live_blake3,
           size AS live_size
    FROM read_blob('samples/*.pdf')
),
live_revs AS (
    SELECT i.file AS source_path, count(*)::INTEGER AS live_revision_count
    FROM pdf_info('samples/*.pdf') i
    JOIN pdf_revisions('samples/*.pdf') r ON r.size_bytes = i.file_size
    GROUP BY i.file
),
working AS (
    SELECT document_id, max(gen) AS gen,
           arg_max(working_path, gen) AS working_path,
           arg_max(working_sha256, gen) AS working_sha256,
           arg_max(working_blake3, gen) AS working_blake3,
           arg_max(working_size, gen) AS working_size
    FROM (
        SELECT regexp_extract(filename, 'doc(.+)_working(\d+)\.pdf$', 1) AS document_id,
               try_cast(regexp_extract(filename, 'doc(.+)_working(\d+)\.pdf$', 2) AS INTEGER) AS gen,
               filename AS working_path,
               lower(hex(crypto_hash('sha2-256', content))) AS working_sha256,
               lower(hex(crypto_hash('blake3', content))) AS working_blake3,
               size AS working_size
        FROM read_blob('data/working/*.pdf')
        WHERE regexp_matches(filename, 'doc.+_working\d+\.pdf$')
    )
    WHERE document_id IS NOT NULL AND gen IS NOT NULL
    GROUP BY document_id
),
exports AS (
    SELECT filename AS export_path,
           lower(hex(crypto_hash('sha2-256', content))) AS export_sha256,
           lower(hex(crypto_hash('blake3', content))) AS export_blake3,
           size AS export_size, last_modified AS exported_at
    FROM read_blob('exports/*.pdf')
    WHERE position('_redacted.pdf' IN filename) > 0
),
seal AS (
    SELECT lower(hex(crypto_hash_agg(
               'sha2-256',
               concat_ws('|', kind, suggestion_id, status, actor,
                         cast(ts AS VARCHAR), document_id)
               ORDER BY cast(ts AS VARCHAR), suggestion_id
           ))) AS decision_chain_seal,
           count(*)::BIGINT AS decision_event_count
    FROM v_src_decisions WHERE suggestion_id IS NOT NULL
)
SELECT c.document_id, c.case_id, c.filename, c.source_path,
       c.source_sha256 AS source_fingerprint, c.source_blake3, c.hash_algo, c.crypto_core_match,
       c.source_revision_count AS revision_count,
       live.live_sha256, live.live_blake3, live_revs.live_revision_count,
       c.source_size AS ingest_size, live.live_size,
       (c.source_sha256 = live.live_sha256) AS hash_ok,
       (c.source_blake3 = live.live_blake3) AS blake3_ok,
       (c.source_revision_count IS NOT DISTINCT FROM live_revs.live_revision_count) AS rev_ok,
       (c.source_size = live.live_size) AS size_ok,
       (c.source_sha256 = live.live_sha256 AND c.source_size = live.live_size
        AND c.source_revision_count IS NOT DISTINCT FROM live_revs.live_revision_count) AS recheck_ok,
       CASE WHEN c.source_sha256 = live.live_sha256 AND c.source_size = live.live_size
             AND c.source_revision_count IS NOT DISTINCT FROM live_revs.live_revision_count
            THEN 'INTACT' ELSE 'BREAK' END AS recheck_status,
       now() AS rechecked_at,
       working.working_path, working.working_sha256 AS working_fingerprint,
       working.working_blake3, working.gen AS working_gen, working.working_size,
       exports.export_path, exports.export_sha256 AS export_fingerprint, exports.export_blake3,
       CASE WHEN exports.export_path IS NOT NULL THEN 1 END AS export_revision_count,
       exports.export_size, exports.exported_at,
       CASE WHEN exports.export_path IS NOT NULL THEN format(
           'Chain of custody: source {} (sha2-256 {}, {}) → export {} (sha2-256 {}, {}).',
           c.source_path, c.source_sha256, c.source_size,
           exports.export_path, exports.export_sha256, exports.export_size
       ) END AS custody_statement,
       seal.decision_chain_seal, seal.decision_event_count
FROM document_custody c
JOIN live ON live.source_path = c.source_path
LEFT JOIN live_revs ON live_revs.source_path = c.source_path
LEFT JOIN working ON working.document_id = c.document_id
LEFT JOIN exports ON exports.export_path = 'exports/' || c.filename || '_redacted.pdf'
, seal;

SELECT 'provenance loaded' AS phase,
       (SELECT count(*) FROM document_custody) AS custody_docs;
