-- routes/provenance.sql — chain-of-custody HTTP surface.
--
-- GET /api/cases/:id/provenance
--   Per document: source fingerprint (crypto sha2-256), blake3, revision_count,
--   recheck_ok (live crypto digests still match ingest), working-copy fingerprint
--   when present, export lineage, decision-chain seal.
--
-- GET /api/cases/:id/provenance/recheck
--   Same rows (live re-hash on each request via views) — used by panel Re-check.
--
-- Dependencies: server/provenance.sql (document_custody, v_case_provenance).

CREATE OR REPLACE ROUTE api_case_provenance GET '/api/cases/:id/provenance' AS
SELECT
    document_id,
    case_id,
    filename,
    source_path,
    source_fingerprint,
    source_blake3,
    hash_algo,
    crypto_core_match,
    revision_count,
    live_sha256,
    live_blake3,
    live_revision_count,
    ingest_size,
    live_size,
    hash_ok,
    blake3_ok,
    rev_ok,
    size_ok,
    recheck_ok,
    recheck_status,
    rechecked_at,
    working_path,
    working_fingerprint,
    working_blake3,
    working_gen,
    working_size,
    export_path,
    export_fingerprint,
    export_blake3,
    export_revision_count,
    export_size,
    exported_at,
    custody_statement,
    decision_chain_seal,
    decision_event_count
FROM v_case_provenance
WHERE case_id = $id::INTEGER
ORDER BY document_id;

-- Explicit re-check alias (panel "Re-check" can hit either; views re-hash live).
CREATE OR REPLACE ROUTE api_case_provenance_recheck GET '/api/cases/:id/provenance/recheck' AS
SELECT
    document_id,
    case_id,
    filename,
    source_path,
    source_fingerprint,
    source_blake3,
    hash_algo,
    crypto_core_match,
    revision_count,
    live_sha256,
    live_blake3,
    live_revision_count,
    ingest_size,
    live_size,
    hash_ok,
    blake3_ok,
    rev_ok,
    size_ok,
    recheck_ok,
    recheck_status,
    rechecked_at,
    working_path,
    working_fingerprint,
    working_blake3,
    working_gen,
    working_size,
    export_path,
    export_fingerprint,
    export_blake3,
    export_revision_count,
    export_size,
    exported_at,
    custody_statement,
    decision_chain_seal,
    decision_event_count
FROM v_case_provenance
WHERE case_id = $id::INTEGER
ORDER BY document_id;

-- Single-document custody (case filter via join).
CREATE OR REPLACE ROUTE api_doc_provenance GET '/api/documents/:id/provenance' AS
SELECT
    document_id,
    case_id,
    filename,
    source_path,
    source_fingerprint,
    source_blake3,
    hash_algo,
    crypto_core_match,
    revision_count,
    live_sha256,
    live_blake3,
    live_revision_count,
    ingest_size,
    live_size,
    hash_ok,
    blake3_ok,
    rev_ok,
    size_ok,
    recheck_ok,
    recheck_status,
    rechecked_at,
    working_path,
    working_fingerprint,
    working_blake3,
    working_gen,
    working_size,
    export_path,
    export_fingerprint,
    export_blake3,
    export_revision_count,
    export_size,
    exported_at,
    custody_statement,
    decision_chain_seal,
    decision_event_count
FROM v_case_provenance
WHERE document_id = $id::INTEGER;
