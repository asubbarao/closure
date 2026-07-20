-- 03_recheck_tamper.sql
-- Later re-check: prove source PDF was not altered mid-review.
-- Depends on 02 having written out/*.parquet. Run from repo root:
--   duckdb -markdown :memory: < spikes/provenance/02_ingest_fingerprint.sql
--   duckdb -markdown :memory: < spikes/provenance/03_recheck_tamper.sql
--
-- Legal story: "At time T_recheck we re-hashed every source under custody.
-- Documents whose SHA-256 and revision_count still match the ingest record
-- are unaltered. Any mismatch is a chain-of-custody break."

LOAD pdf;

.mode markdown

CREATE OR REPLACE TABLE document_custody AS
SELECT * FROM read_parquet('spikes/provenance/out/document_custody.parquet');

CREATE OR REPLACE TABLE fixture_custody AS
SELECT * FROM read_parquet('spikes/provenance/out/fixture_custody.parquet');

SELECT '=== A. samples/*.pdf recheck (all should MATCH) ===' AS section;
CREATE OR REPLACE TABLE recheck_samples AS
WITH live_blob AS (
    SELECT filename AS source_path, sha256(content) AS live_sha256, size AS live_size
    FROM read_blob('samples/*.pdf')
),
live_revs AS (
    -- single-rev join (samples only)
    SELECT i.file AS source_path, count(*)::INTEGER AS live_revision_count
    FROM pdf_info('samples/*.pdf') i
    JOIN pdf_revisions('samples/*.pdf') r ON r.size_bytes = i.file_size
    GROUP BY i.file
)
SELECT
    c.document_id,
    c.source_path,
    c.source_sha256 AS ingest_sha256,
    b.live_sha256,
    c.source_revision_count AS ingest_revision_count,
    r.live_revision_count,
    c.source_size AS ingest_size,
    b.live_size,
    (c.source_sha256 = b.live_sha256) AS hash_ok,
    (c.source_revision_count = r.live_revision_count) AS rev_ok,
    (c.source_size = b.live_size) AS size_ok,
    (c.source_sha256 = b.live_sha256
     AND c.source_revision_count = r.live_revision_count
     AND c.source_size = b.live_size) AS custody_ok,
    now() AS rechecked_at
FROM document_custody c
JOIN live_blob b ON b.source_path = c.source_path
JOIN live_revs r ON r.source_path = c.source_path
ORDER BY c.document_id;

SELECT
    document_id,
    regexp_replace(source_path, '.*/', '') AS filename,
    hash_ok,
    rev_ok,
    size_ok,
    custody_ok
FROM recheck_samples
ORDER BY document_id;

SELECT
    count(*) AS n_docs,
    count(*) FILTER (WHERE custody_ok) AS n_ok,
    count(*) FILTER (WHERE NOT custody_ok) AS n_break
FROM recheck_samples;

SELECT '=== B. multi-rev fixture: pristine vs tampered ===' AS section;
-- Ingest recorded chain_r3.pdf. Recheck both pristine and tampered paths.
CREATE OR REPLACE TABLE recheck_fixture AS
SELECT
    f.source_path AS ingest_path,
    f.source_sha256 AS ingest_sha256,
    f.source_revision_count AS ingest_revision_count,
    f.source_size AS ingest_size,
    live.tag,
    live.live_path,
    live.live_sha256,
    live.live_revision_count,
    live.live_size,
    (f.source_sha256 = live.live_sha256) AS hash_ok,
    (f.source_revision_count = live.live_revision_count) AS rev_ok,
    (f.source_size = live.live_size) AS size_ok,
    (f.source_sha256 = live.live_sha256
     AND f.source_revision_count = live.live_revision_count) AS custody_ok
FROM fixture_custody f
CROSS JOIN (
    SELECT
        'pristine' AS tag,
        'spikes/provenance/fixtures/chain_r3.pdf' AS live_path,
        sha256(content) AS live_sha256,
        size AS live_size,
        (SELECT count(*)::INTEGER
         FROM pdf_revisions('spikes/provenance/fixtures/chain_r3.pdf')) AS live_revision_count
    FROM read_blob('spikes/provenance/fixtures/chain_r3.pdf')
    UNION ALL
    SELECT
        'tampered_incremental',
        'spikes/provenance/fixtures/chain_r3_tampered.pdf',
        sha256(content),
        size,
        (SELECT count(*)::INTEGER
         FROM pdf_revisions('spikes/provenance/fixtures/chain_r3_tampered.pdf'))
    FROM read_blob('spikes/provenance/fixtures/chain_r3_tampered.pdf')
) live;

SELECT
    tag,
    ingest_sha256,
    live_sha256,
    ingest_revision_count,
    live_revision_count,
    ingest_size,
    live_size,
    hash_ok,
    rev_ok,
    custody_ok
FROM recheck_fixture
ORDER BY tag;

SELECT '=== C. custody break report (exportable) ===' AS section;
SELECT
    tag,
    CASE
        WHEN custody_ok THEN 'INTACT'
        WHEN NOT hash_ok AND NOT rev_ok THEN 'BREAK: content hash + revision_count both changed'
        WHEN NOT hash_ok THEN 'BREAK: content hash changed'
        WHEN NOT rev_ok THEN 'BREAK: revision_count changed'
        ELSE 'BREAK: unknown'
    END AS custody_status,
    ingest_sha256,
    live_sha256,
    ingest_revision_count,
    live_revision_count
FROM recheck_fixture
ORDER BY tag;

COPY recheck_samples TO 'spikes/provenance/out/recheck_samples.parquet' (FORMAT PARQUET);
COPY recheck_fixture TO 'spikes/provenance/out/recheck_fixture.parquet' (FORMAT PARQUET);

SELECT 'recheck complete' AS status;
