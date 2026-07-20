-- provenance.sql — chain-of-custody: crypto-ext fingerprints + live recheck + export lineage.
--
-- Proven patterns from spikes/provenance/{02,03,04,05}_*.sql and
-- spikes/ext-detection/02_crypto_custody.sql.
-- Loaded AFTER ingest (needs documents). Does not mutate samples/ or ingest.sql.
--
-- Fingerprints use community `crypto` (sha2-256 of file bytes via crypto_hash),
-- not core-only sha256 — surfaces at ingest, working-copy, and export stages.
-- Live re-check compares crypto digests; BREAK when any stage hash drifts.

INSTALL crypto FROM community;
LOAD crypto;

-- ═══════════════════════════════════════════════════════════════════════════
-- Ingest-time custody snapshot (immutable for the boot lifetime)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE document_custody AS
WITH
blobs AS (
    SELECT
        filename AS source_path,
        -- crypto-ext digests (hex); primary fingerprint for legal CoC
        lower(hex(crypto_hash('sha2-256', content))) AS source_sha256,
        lower(hex(crypto_hash('blake3', content))) AS source_blake3,
        lower(hex(crypto_hash('sha2-512', content))) AS source_sha512,
        -- core sha256 retained for cross-check (must equal crypto sha2-256)
        sha256(content) AS source_sha256_core,
        size AS source_size,
        last_modified AS source_mtime
    FROM read_blob('samples/*.pdf')
),
-- Single-rev corpus: size_bytes == file_size → 1:1 join (proven for samples/).
revs AS (
    SELECT
        i.file AS source_path,
        count(*)::INTEGER AS source_revision_count,
        max(r.eof_offset)::BIGINT AS source_eof_offset,
        bool_or(r.is_incremental) AS source_has_incremental
    FROM pdf_info('samples/*.pdf') i
    JOIN pdf_revisions('samples/*.pdf') r ON r.size_bytes = i.file_size
    GROUP BY i.file
),
info AS (
    SELECT
        file AS source_path,
        producer,
        pdf_version,
        is_encrypted,
        is_linearized,
        page_count,
        file_size
    FROM pdf_info('samples/*.pdf')
)
SELECT
    d.id AS document_id,
    d.case_id,
    d.filename,
    d.source_path,
    b.source_sha256,
    b.source_blake3,
    b.source_sha512,
    b.source_sha256_core,
    (b.source_sha256 = b.source_sha256_core) AS crypto_core_match,
    b.source_size,
    b.source_mtime,
    r.source_revision_count,
    r.source_eof_offset,
    r.source_has_incremental,
    i.producer,
    i.pdf_version,
    i.is_encrypted,
    i.is_linearized,
    i.page_count,
    'crypto:sha2-256' AS hash_algo,
    now() AS ingested_at,
    'system' AS ingested_by
FROM documents d
JOIN blobs b ON b.source_path = d.source_path
JOIN revs r ON r.source_path = d.source_path
JOIN info i ON i.source_path = d.source_path
ORDER BY d.id;

-- ═══════════════════════════════════════════════════════════════════════════
-- Decision-log ordered chain seal (tamper-evident audit)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW v_decision_chain_seal AS
WITH events AS (
    SELECT
        coalesce(cast(kind AS VARCHAR), '') AS kind,
        try_cast(suggestion_id AS BIGINT) AS suggestion_id,
        coalesce(cast(status AS VARCHAR), '') AS status,
        coalesce(cast(actor AS VARCHAR), '') AS actor,
        coalesce(cast(ts AS VARCHAR), '') AS ts,
        try_cast(document_id AS INTEGER) AS document_id,
        coalesce(filename, '') AS decision_file
    FROM read_json(
        'exports/decisions/*.json',
        format := 'auto',
        ignore_errors := true,
        union_by_name := true,
        filename := true
    )
    WHERE cast(kind AS VARCHAR) IS NOT NULL
      AND cast(kind AS VARCHAR) <> 'sentinel'
      AND try_cast(suggestion_id AS BIGINT) IS NOT NULL
)
SELECT
    lower(hex(crypto_hash_agg(
        'sha2-256',
        concat_ws(
            '|',
            kind,
            coalesce(suggestion_id::VARCHAR, ''),
            status,
            actor,
            ts,
            coalesce(document_id::VARCHAR, '')
        )
        ORDER BY ts, suggestion_id, decision_file
    ))) AS decision_chain_seal,
    count(*)::BIGINT AS event_count
FROM events;

-- ═══════════════════════════════════════════════════════════════════════════
-- Views
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW v_document_custody AS
SELECT
    document_id,
    case_id,
    filename,
    source_path,
    source_sha256,
    source_blake3,
    source_sha512,
    source_sha256_core,
    crypto_core_match,
    source_size,
    source_revision_count,
    source_eof_offset,
    source_has_incremental,
    producer,
    pdf_version,
    is_encrypted,
    is_linearized,
    page_count,
    hash_algo,
    ingested_at,
    ingested_by
FROM document_custody;

-- Live recheck: re-hash samples/*.pdf NOW with crypto and compare to ingest.
-- Glob + join avoids non-literal path binds (pdf_revisions / read_blob gotcha).
CREATE OR REPLACE VIEW v_custody_recheck AS
WITH
live_blob AS (
    SELECT
        filename AS source_path,
        lower(hex(crypto_hash('sha2-256', content))) AS live_sha256,
        lower(hex(crypto_hash('blake3', content))) AS live_blake3,
        size AS live_size
    FROM read_blob('samples/*.pdf')
),
live_revs AS (
    SELECT
        i.file AS source_path,
        count(*)::INTEGER AS live_revision_count
    FROM pdf_info('samples/*.pdf') i
    JOIN pdf_revisions('samples/*.pdf') r ON r.size_bytes = i.file_size
    GROUP BY i.file
)
SELECT
    c.document_id,
    c.case_id,
    c.filename,
    c.source_path,
    c.source_sha256 AS ingest_sha256,
    c.source_blake3 AS ingest_blake3,
    b.live_sha256,
    b.live_blake3,
    c.source_revision_count AS ingest_revision_count,
    r.live_revision_count,
    c.source_size AS ingest_size,
    b.live_size,
    c.hash_algo,
    c.crypto_core_match,
    (c.source_sha256 = b.live_sha256) AS hash_ok,
    (c.source_blake3 = b.live_blake3) AS blake3_ok,
    (c.source_revision_count = r.live_revision_count) AS rev_ok,
    (c.source_size = b.live_size) AS size_ok,
    (c.source_sha256 = b.live_sha256
     AND c.source_size = b.live_size
     AND c.source_revision_count IS NOT DISTINCT FROM r.live_revision_count) AS recheck_ok,
    now() AS rechecked_at
FROM document_custody c
JOIN live_blob b ON b.source_path = c.source_path
-- LEFT: a mid-review byte change can break the single-rev size join
-- (or pdf_revisions on a corrupted body). Still surface the row as BREAK.
LEFT JOIN live_revs r ON r.source_path = c.source_path;

-- Working-copy fingerprints (crypto sha2-256 of data/working/docN_workingK.pdf).
-- Empty glob is avoided when no working files exist by filtering filename shape.
CREATE OR REPLACE VIEW v_working_blobs AS
SELECT
    try_cast(regexp_extract(filename, 'doc(\d+)_working', 1) AS INTEGER) AS document_id,
    try_cast(regexp_extract(filename, '_working(\d+)\.pdf$', 1) AS INTEGER) AS gen,
    filename AS working_path,
    lower(hex(crypto_hash('sha2-256', content))) AS working_sha256,
    lower(hex(crypto_hash('blake3', content))) AS working_blake3,
    size AS working_size,
    last_modified AS working_mtime
FROM read_blob('data/working/*.pdf')
WHERE regexp_matches(filename, 'doc\d+_working\d+\.pdf$');

-- Latest working gen per document (highest gen wins).
CREATE OR REPLACE VIEW v_working_latest AS
SELECT
    document_id,
    gen,
    working_path,
    working_sha256,
    working_blake3,
    working_size,
    working_mtime
FROM (
    SELECT
        *,
        row_number() OVER (
            PARTITION BY document_id
            ORDER BY gen DESC, working_path
        ) AS rn
    FROM v_working_blobs
    WHERE document_id IS NOT NULL
) t
WHERE rn = 1;

-- Export lineage via live crypto hashes of redacted PDFs.
CREATE OR REPLACE VIEW v_export_blobs AS
SELECT
    filename AS export_path,
    lower(hex(crypto_hash('sha2-256', content))) AS export_sha256,
    lower(hex(crypto_hash('blake3', content))) AS export_blake3,
    lower(hex(crypto_hash('md5', content))) AS export_md5,
    size AS export_size,
    last_modified AS exported_at
FROM read_blob('exports/*.pdf')
WHERE position('_redacted.pdf' IN filename) > 0;

CREATE OR REPLACE VIEW v_export_lineage AS
SELECT
    c.document_id,
    c.case_id,
    c.filename,
    c.source_path,
    c.source_sha256,
    c.source_blake3,
    c.source_revision_count,
    c.source_size,
    c.hash_algo,
    c.ingested_at,
    e.export_path,
    e.export_sha256,
    e.export_blake3,
    e.export_md5,
    e.export_size,
    1::INTEGER AS export_revision_count,
    e.exported_at,
    format(
        'Chain of custody: source {} (crypto sha2-256 {}, blake3 {}, {} revision{}, {} bytes) '
        || '→ export {} (crypto sha2-256 {}, blake3 {}, {} revision{}, {} bytes).',
        c.source_path,
        c.source_sha256,
        c.source_blake3,
        c.source_revision_count,
        CASE WHEN c.source_revision_count = 1 THEN '' ELSE 's' END,
        c.source_size,
        e.export_path,
        e.export_sha256,
        e.export_blake3,
        1,
        '',
        e.export_size
    ) AS custody_statement
FROM document_custody c
JOIN v_export_blobs e
  ON e.export_path = 'exports/' || c.filename || '_redacted.pdf';

-- Unified per-document provenance row for the API + panel.
-- source_fingerprint = crypto sha2-256 (primary); blake3 + working + export too.
CREATE OR REPLACE VIEW v_case_provenance AS
SELECT
    r.document_id,
    r.case_id,
    r.filename,
    r.source_path,
    r.ingest_sha256 AS source_fingerprint,
    r.ingest_blake3 AS source_blake3,
    r.hash_algo,
    r.crypto_core_match,
    r.ingest_revision_count AS revision_count,
    r.live_sha256,
    r.live_blake3,
    r.live_revision_count,
    r.ingest_size,
    r.live_size,
    r.hash_ok,
    r.blake3_ok,
    r.rev_ok,
    r.size_ok,
    r.recheck_ok,
    CASE WHEN r.recheck_ok THEN 'INTACT' ELSE 'BREAK' END AS recheck_status,
    r.rechecked_at,
    w.working_path,
    w.working_sha256 AS working_fingerprint,
    w.working_blake3,
    w.gen AS working_gen,
    w.working_size,
    w.working_mtime,
    l.export_path,
    l.export_sha256 AS export_fingerprint,
    l.export_blake3,
    l.export_revision_count,
    l.export_size,
    l.exported_at,
    l.custody_statement,
    (SELECT decision_chain_seal FROM v_decision_chain_seal) AS decision_chain_seal,
    (SELECT event_count FROM v_decision_chain_seal) AS decision_event_count
FROM v_custody_recheck r
LEFT JOIN v_working_latest w ON w.document_id = r.document_id
LEFT JOIN v_export_lineage l ON l.document_id = r.document_id;

SELECT 'provenance loaded' AS phase,
       (SELECT count(*) FROM document_custody) AS custody_docs,
       (SELECT count(*) FILTER (WHERE crypto_core_match) FROM document_custody) AS crypto_match_n,
       (SELECT count(*) FROM v_working_blobs) AS working_blobs_n,
       (SELECT count(*) FROM v_export_blobs) AS export_blobs_n;
