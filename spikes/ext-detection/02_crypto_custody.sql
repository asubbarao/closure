-- 02_crypto_custody.sql
-- Spike: community crypto for chain-of-custody + decision-log seals.
-- Run from repo root:
--   duckdb -unsigned -markdown :memory: < spikes/ext-detection/02_crypto_custody.sql
--
-- Context: spikes/provenance already uses core sha256(content) from read_blob.
-- This spike shows what crypto ADDS: multi-algo digests, ordered hash_agg seals,
-- and HMAC over the seal (export-manifest style).
--
-- Proves:
--   1. INSTALL/LOAD crypto FROM community
--   2. crypto_hash('sha2-256', blob) ≡ core sha256(content) (hex)
--   3. blake3 digest available for optional faster fingerprint policy
--   4. crypto_hash_agg ORDER BY over real exports/decisions/*.json
--   5. crypto_hmac over that seal string

INSTALL crypto FROM community;
LOAD crypto;

.mode markdown

SELECT '=== 1. PDF fingerprints: crypto vs core sha256 ===' AS section;

CREATE OR REPLACE TABLE pdf_fps AS
SELECT
    filename AS source_path,
    size AS nbytes,
    sha256(content) AS core_sha256,
    lower(hex(crypto_hash('sha2-256', content))) AS crypto_sha256,
    lower(hex(crypto_hash('blake3', content))) AS crypto_blake3,
    lower(hex(crypto_hash('sha2-256', content))) = sha256(content) AS sha256_match
FROM read_blob('samples/*.pdf');

SELECT source_path, nbytes, core_sha256, crypto_blake3, sha256_match
FROM pdf_fps
ORDER BY source_path;

SELECT
    count(*) AS n_pdfs,
    count(*) FILTER (WHERE sha256_match) AS n_match,
    bool_and(sha256_match) AS all_match
FROM pdf_fps;

SELECT '=== 2. Decision-log ordered chain seal ===' AS section;

-- Live tree often only has exports/decisions/_sentinel.json (demo wipe between runs).
-- Prefer real decision JSON when present; else use schema-faithful synthetic events
-- matching the Closure decision record shape (kind/suggestion_id/status/actor/ts/…).
CREATE OR REPLACE TABLE decision_events AS
WITH from_disk AS (
    SELECT
        filename AS decision_file,
        j.kind::VARCHAR AS kind,
        try_cast(j.suggestion_id AS BIGINT) AS suggestion_id,
        j.status::VARCHAR AS status,
        j.actor::VARCHAR AS actor,
        j.ts::VARCHAR AS ts,
        try_cast(j.document_id AS INTEGER) AS document_id,
        j.text::VARCHAR AS text
    FROM read_json('exports/decisions/*.json', format = 'auto', filename = true) j
    WHERE j.kind IS NOT NULL
      AND j.kind::VARCHAR <> 'sentinel'
      AND j.suggestion_id IS NOT NULL
),
synthetic AS (
    SELECT * FROM (VALUES
        ('synth://1', 'decision', 904::BIGINT, 'accepted', 'A. Reviewer',
         '2026-07-20 01:15:23.347518+00', 5, '300-71-4366'),
        ('synth://2', 'decision', 924::BIGINT, 'accepted', 'A. Reviewer',
         '2026-07-20 01:15:23.340804+00', 5, 'Hilbert Feeney'),
        ('synth://3', 'decision', 932::BIGINT, 'accepted', 'A. Reviewer',
         '2026-07-20 01:15:23.349632+00', 5, '(781) 473-6031'),
        ('synth://4', 'decision', 109::BIGINT, 'rejected', 'A. Reviewer',
         '2026-07-20 01:15:26.632249+00', 3, 'Feeney Street'),
        ('synth://5', 'added', 622287253::BIGINT, 'accepted', 'e2e-runner',
         '2026-07-20 01:15:16.919087+00', 5, 'E2E_MANUAL_SPAN')
    ) t(decision_file, kind, suggestion_id, status, actor, ts, document_id, text)
)
SELECT * FROM from_disk
UNION ALL BY NAME
SELECT * FROM synthetic
WHERE (SELECT count(*) FROM from_disk) = 0;

SELECT count(*) AS n_events,
       bool_or(starts_with(decision_file, 'synth://')) AS used_synthetic
FROM decision_events;

SELECT kind, suggestion_id, status, actor, left(text, 24) AS text_preview
FROM decision_events
ORDER BY ts, suggestion_id;

-- Canonical event line (stable columns — omit free-form reason from seal)
CREATE OR REPLACE TABLE sealed AS
SELECT
    lower(hex(crypto_hash_agg(
        'sha2-256',
        concat_ws(
            '|',
            coalesce(kind, ''),
            coalesce(suggestion_id::VARCHAR, ''),
            coalesce(status, ''),
            coalesce(actor, ''),
            coalesce(ts, ''),
            coalesce(document_id::VARCHAR, '')
        )
        ORDER BY ts, suggestion_id, decision_file
    ))) AS decision_chain_seal,
    count(*)::BIGINT AS event_count
FROM decision_events;

SELECT * FROM sealed;

SELECT '=== 3. HMAC over seal (export-manifest signature shape) ===' AS section;

-- Demo key only — production pulls from env / secret store, never commit.
SELECT
    lower(hex(crypto_hmac(
        'sha2-256',
        'closure-demo-export-key',
        decision_chain_seal
    ))) AS export_manifest_hmac,
    decision_chain_seal,
    event_count
FROM sealed;

SELECT '=== 4. Tamper detect: drop one event → seal changes ===' AS section;

CREATE OR REPLACE TABLE sealed_minus_one AS
SELECT
    lower(hex(crypto_hash_agg(
        'sha2-256',
        concat_ws(
            '|',
            coalesce(kind, ''),
            coalesce(suggestion_id::VARCHAR, ''),
            coalesce(status, ''),
            coalesce(actor, ''),
            coalesce(ts, ''),
            coalesce(document_id::VARCHAR, '')
        )
        ORDER BY ts, suggestion_id, decision_file
    ))) AS seal_minus_one,
    count(*)::BIGINT AS event_count
FROM decision_events
WHERE suggestion_id <> (SELECT min(suggestion_id) FROM decision_events);

SELECT
    s.decision_chain_seal AS full_seal,
    t.seal_minus_one,
    s.event_count AS full_n,
    t.event_count AS minus_one_n,
    s.decision_chain_seal = t.seal_minus_one AS seals_equal_should_be_false
FROM sealed s
CROSS JOIN sealed_minus_one t;

SELECT '=== 5. Integration shape (lift into export / provenance) ===' AS section;
SELECT $$
-- At ingest (alongside core sha256):
--   source_blake3 := lower(hex(crypto_hash('blake3', content)))
-- At export:
--   decision_chain_seal := crypto_hash_agg over decisions ORDER BY ts, id
--   export_hmac := crypto_hmac('sha2-256', signing_key, seal)
-- Write both into export_map / audit_sidecar for recheck.
$$ AS integration_shape;
