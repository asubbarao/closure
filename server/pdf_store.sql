-- pdf_store.sql — PDF lifecycle: source / working / export storage layer.
--
-- Purpose: own the on-disk layout and registry for how Closure handles PDFs
-- across three stages (immutable input → regenerable working → final export).
-- Working copies materialize the CURRENT accepted redaction state via pdf_redact
-- (boxes_lit_for_doc from pdf_io). Each working file is name-stamped
-- doc{N}_working{K}.pdf; pdf_revisions + sha256 give verifiable lineage.
--
-- Dependencies: documents, pages, v_suggestions, pdf_io (boxes_lit_for_doc, run_sql).
-- Callers: server/routes/store.sql. Does NOT own final export writes (export route).
-- Must NOT mutate samples/ or documents.source_path.
--
-- Layout (module-owned):
--   data/source/    immutable originals (demo: reference samples/ via registry)
--   data/working/   intermediate redacted working copies + registry JSON events
--   data/export/    target for final exports (compat: live export still uses exports/)
--
-- Mutations: CTAS for source snapshot + decisions-pattern JSON under
-- data/working/registry/ + runtime table pdf_store_events for in-process state.

-- ═══════════════════════════════════════════════════════════════════════════
-- Path macros (foldable roots)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE MACRO cfg_data_root() AS 'data';
CREATE OR REPLACE MACRO cfg_source_root() AS 'data/source';
CREATE OR REPLACE MACRO cfg_working_root() AS 'data/working';
CREATE OR REPLACE MACRO cfg_export_root() AS 'data/export';
CREATE OR REPLACE MACRO cfg_working_registry() AS 'data/working/registry';
-- Compat root still written by routes/export.sql (do not change that file).
CREATE OR REPLACE MACRO cfg_export_compat_root() AS 'exports';

CREATE OR REPLACE MACRO path_working_pdf(did, gen) AS
  cfg_working_root() || '/doc' || cast(did AS VARCHAR) || '_working' || cast(gen AS VARCHAR) || '.pdf';

CREATE OR REPLACE MACRO path_export_pdf(stem) AS
  cfg_export_root() || '/' || stem || '_redacted.pdf';

CREATE OR REPLACE MACRO path_export_compat_pdf(stem) AS
  cfg_export_compat_root() || '/' || stem || '_redacted.pdf';

-- ═══════════════════════════════════════════════════════════════════════════
-- Dir bootstrap (sentinel files; dirs must exist — committed via .gitkeep)
-- ═══════════════════════════════════════════════════════════════════════════

COPY (
    SELECT
        'sentinel' AS kind,
        NULL::INTEGER AS document_id,
        NULL::VARCHAR AS stage,
        NULL::VARCHAR AS path,
        NULL::INTEGER AS gen,
        NULL::VARCHAR AS fingerprint,
        NULL::VARCHAR AS decision_batch,
        NULL::INTEGER AS accepted_count,
        NULL::INTEGER AS pages_redacted,
        NULL::BIGINT AS size_bytes,
        NULL::INTEGER AS revision_count,
        NULL::VARCHAR AS created_ts,
        NULL::VARCHAR AS actor
) TO 'data/working/registry/_sentinel.json' (FORMAT JSON, ARRAY false);

COPY (
    SELECT 'source_root' AS kind, cfg_source_root() AS path, now() AS created_ts
) TO 'data/source/_store_meta.json' (FORMAT JSON, ARRAY false);

COPY (
    SELECT 'export_root' AS kind, cfg_export_root() AS path, now() AS created_ts
) TO 'data/export/_store_meta.json' (FORMAT JSON, ARRAY false);

-- ═══════════════════════════════════════════════════════════════════════════
-- Source stage (CTAS): immutable originals — reference samples/ (never copy-mutate)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE pdf_store_source AS
WITH
blobs AS (
    SELECT
        filename AS source_path,
        sha256(content) AS fingerprint,
        size AS size_bytes,
        last_modified AS source_mtime
    FROM read_blob('samples/*.pdf')
),
revs AS (
    -- Single-rev corpus: size join labels revision_count (see spikes/provenance).
    SELECT
        i.file AS source_path,
        count(*)::INTEGER AS revision_count
    FROM pdf_info('samples/*.pdf') i
    JOIN pdf_revisions('samples/*.pdf') r ON r.size_bytes = i.file_size
    GROUP BY i.file
)
SELECT
    d.id AS document_id,
    d.case_id,
    d.filename,
    'source' AS stage,
    d.source_path AS path,
    0::INTEGER AS gen,
    b.fingerprint,
    NULL::VARCHAR AS decision_batch,
    0::INTEGER AS accepted_count,
    NULL::INTEGER AS pages_redacted,
    b.size_bytes,
    coalesce(r.revision_count, 1)::INTEGER AS revision_count,
    now() AS created_ts,
    'system' AS actor,
    'immutable' AS mutability,
    'references samples/; never mutated by this module' AS note
FROM documents d
JOIN blobs b ON b.source_path = d.source_path
LEFT JOIN revs r ON r.source_path = d.source_path
ORDER BY d.id;

-- ═══════════════════════════════════════════════════════════════════════════
-- Runtime event table (working + cleanup). Boot-empty; mutations via INSERT.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TABLE pdf_store_events (
    document_id INTEGER NOT NULL,
    stage VARCHAR NOT NULL,          -- working | cleanup
    path VARCHAR NOT NULL,
    gen INTEGER NOT NULL,
    fingerprint VARCHAR,
    decision_batch VARCHAR,
    accepted_count INTEGER,
    pages_redacted INTEGER,
    size_bytes BIGINT,
    revision_count INTEGER,
    created_ts TIMESTAMP,
    actor VARCHAR,
    kind VARCHAR NOT NULL,           -- working | cleanup
    PRIMARY KEY (document_id, stage, gen, kind)
);

-- ═══════════════════════════════════════════════════════════════════════════
-- Registry log (decisions pattern): durable JSON under data/working/registry/
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW v_pdf_store_log AS
SELECT
    coalesce(filename, '') AS _file,
    cast(kind AS VARCHAR) AS kind,
    try_cast(document_id AS BIGINT)::INTEGER AS document_id,
    cast(stage AS VARCHAR) AS stage,
    cast(path AS VARCHAR) AS path,
    try_cast(gen AS BIGINT)::INTEGER AS gen,
    cast(fingerprint AS VARCHAR) AS fingerprint,
    cast(decision_batch AS VARCHAR) AS decision_batch,
    try_cast(accepted_count AS BIGINT)::INTEGER AS accepted_count,
    try_cast(pages_redacted AS BIGINT)::INTEGER AS pages_redacted,
    try_cast(size_bytes AS BIGINT) AS size_bytes,
    try_cast(revision_count AS BIGINT)::INTEGER AS revision_count,
    try_cast(created_ts AS TIMESTAMP) AS created_ts,
    cast(actor AS VARCHAR) AS actor
FROM read_json(
    'data/working/registry/*.json',
    format := 'auto',
    ignore_errors := true,
    union_by_name := true,
    filename := true,
    columns := {
        'kind': 'VARCHAR',
        'document_id': 'BIGINT',
        'stage': 'VARCHAR',
        'path': 'VARCHAR',
        'gen': 'BIGINT',
        'fingerprint': 'VARCHAR',
        'decision_batch': 'VARCHAR',
        'accepted_count': 'BIGINT',
        'pages_redacted': 'BIGINT',
        'size_bytes': 'BIGINT',
        'revision_count': 'BIGINT',
        'created_ts': 'VARCHAR',
        'actor': 'VARCHAR'
    }
)
WHERE kind IS NULL OR kind <> 'sentinel';

-- ═══════════════════════════════════════════════════════════════════════════
-- Export stage (derived from disk — compat exports/ + target data/export/)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW v_pdf_store_export AS
WITH
compat AS (
    SELECT
        filename AS path,
        sha256(content) AS fingerprint,
        size AS size_bytes,
        last_modified AS created_ts
    FROM read_blob('exports/*_redacted.pdf')
),
owned AS (
    SELECT
        filename AS path,
        sha256(content) AS fingerprint,
        size AS size_bytes,
        last_modified AS created_ts
    FROM read_blob('data/export/*_redacted.pdf')
),
all_exports AS (
    SELECT * FROM compat
    UNION ALL BY NAME
    SELECT * FROM owned
)
SELECT
    d.id AS document_id,
    d.case_id,
    d.filename,
    'export' AS stage,
    e.path,
    NULL::INTEGER AS gen,
    e.fingerprint,
    NULL::VARCHAR AS decision_batch,
    NULL::INTEGER AS accepted_count,
    NULL::INTEGER AS pages_redacted,
    e.size_bytes,
    1::INTEGER AS revision_count,  -- pdf_redact always full rewrite (single rev)
    e.created_ts,
    'export_route' AS actor,
    'append_only' AS mutability,
    CASE
        WHEN position('data/export/' IN e.path) = 1 THEN 'data/export'
        ELSE 'exports_compat'
    END AS note
FROM documents d
JOIN all_exports e
  ON e.path = path_export_compat_pdf(d.filename)
  OR e.path = path_export_pdf(d.filename);

-- ═══════════════════════════════════════════════════════════════════════════
-- Working stage: events table ∪ JSON log; cleanup excludes gens
-- ═══════════════════════════════════════════════════════════════════════════

-- Disk recovery: working PDFs survive reboot even if the events table is empty.
CREATE OR REPLACE VIEW v_pdf_store_working_disk AS
SELECT
    try_cast(regexp_extract(filename, 'doc(\d+)_working', 1) AS INTEGER) AS document_id,
    'working' AS stage,
    filename AS path,
    try_cast(regexp_extract(filename, '_working(\d+)\.pdf$', 1) AS INTEGER) AS gen,
    sha256(content) AS fingerprint,
    NULL::VARCHAR AS decision_batch,
    NULL::INTEGER AS accepted_count,
    NULL::INTEGER AS pages_redacted,
    size AS size_bytes,
    1::INTEGER AS revision_count,
    try_cast(last_modified AS TIMESTAMP) AS created_ts,
    'disk' AS actor,
    'working' AS kind,
    'disk' AS log_source
FROM read_blob('data/working/*.pdf')
WHERE regexp_matches(filename, 'doc\d+_working\d+\.pdf$');

CREATE OR REPLACE VIEW v_pdf_store_working_raw AS
SELECT
    document_id,
    stage,
    path,
    gen,
    fingerprint,
    decision_batch,
    accepted_count,
    pages_redacted,
    size_bytes,
    revision_count,
    created_ts,
    actor,
    kind,
    'events' AS log_source
FROM pdf_store_events
WHERE kind = 'working' AND stage = 'working'
UNION ALL BY NAME
SELECT
    document_id,
    coalesce(stage, 'working') AS stage,
    path,
    gen,
    fingerprint,
    decision_batch,
    accepted_count,
    pages_redacted,
    size_bytes,
    revision_count,
    created_ts,
    actor,
    kind,
    'json' AS log_source
FROM v_pdf_store_log
WHERE kind = 'working'
UNION ALL BY NAME
SELECT
    document_id,
    stage,
    path,
    gen,
    fingerprint,
    decision_batch,
    accepted_count,
    pages_redacted,
    size_bytes,
    revision_count,
    created_ts,
    actor,
    kind,
    log_source
FROM v_pdf_store_working_disk;

CREATE OR REPLACE VIEW v_pdf_store_cleanup AS
SELECT document_id, gen, created_ts, actor, 'events' AS log_source
FROM pdf_store_events
WHERE kind = 'cleanup' OR stage = 'cleanup'
UNION ALL BY NAME
SELECT document_id, gen, created_ts, actor, 'json' AS log_source
FROM v_pdf_store_log
WHERE kind = 'cleanup' OR stage = 'cleanup';

-- Latest working row per (document_id, gen), excluding cleaned gens.
-- Fingerprint/size: prefer event/json, fall back to on-disk blob (authoritative
-- after pdf_redact; events may store NULL fingerprint at insert time).
CREATE OR REPLACE VIEW v_pdf_store_working AS
WITH ranked AS (
    SELECT
        *,
        row_number() OVER (
            PARTITION BY document_id, gen
            ORDER BY
                CASE log_source WHEN 'events' THEN 0 WHEN 'json' THEN 1 ELSE 2 END,
                coalesce(created_ts, TIMESTAMP '1970-01-01') DESC
        ) AS rn
    FROM v_pdf_store_working_raw
    WHERE document_id IS NOT NULL AND gen IS NOT NULL AND path IS NOT NULL
),
disk_fp AS (
    SELECT path, fingerprint, size_bytes, created_ts
    FROM v_pdf_store_working_disk
)
SELECT
    w.document_id,
    d.case_id,
    d.filename,
    'working' AS stage,
    w.path,
    w.gen,
    coalesce(w.fingerprint, df.fingerprint) AS fingerprint,
    w.decision_batch,
    w.accepted_count,
    w.pages_redacted,
    coalesce(w.size_bytes, df.size_bytes) AS size_bytes,
    coalesce(w.revision_count, 1)::INTEGER AS revision_count,
    coalesce(w.created_ts, df.created_ts) AS created_ts,
    w.actor,
    'regenerable' AS mutability,
    'data/working' AS note
FROM ranked w
JOIN documents d ON d.id = w.document_id
LEFT JOIN disk_fp df ON df.path = w.path
WHERE w.rn = 1
  AND NOT EXISTS (
      SELECT 1
      FROM v_pdf_store_cleanup c
      WHERE c.document_id = w.document_id
        AND c.gen = w.gen
  );

-- Unified store projection (all stages).
CREATE OR REPLACE VIEW v_pdf_store AS
SELECT
    document_id, case_id, filename, stage, path, gen, fingerprint,
    decision_batch, accepted_count, pages_redacted, size_bytes,
    revision_count, created_ts, actor, mutability, note
FROM pdf_store_source
UNION ALL BY NAME
SELECT
    document_id, case_id, filename, stage, path, gen, fingerprint,
    decision_batch, accepted_count, pages_redacted, size_bytes,
    revision_count, created_ts, actor, mutability, note
FROM v_pdf_store_working
UNION ALL BY NAME
SELECT
    document_id, case_id, filename, stage, path, gen, fingerprint,
    decision_batch, accepted_count, pages_redacted, size_bytes,
    revision_count, created_ts, actor, mutability, note
FROM v_pdf_store_export;

-- Per-document store snapshot (API shape).
CREATE OR REPLACE MACRO document_store(did) AS TABLE
SELECT
    document_id,
    case_id,
    filename,
    stage,
    path,
    gen,
    fingerprint,
    decision_batch,
    accepted_count,
    pages_redacted,
    size_bytes,
    revision_count,
    created_ts,
    actor,
    mutability,
    note
FROM v_pdf_store
WHERE document_id = did
ORDER BY
    CASE stage WHEN 'source' THEN 0 WHEN 'working' THEN 1 WHEN 'export' THEN 2 ELSE 3 END,
    coalesce(gen, 0),
    created_ts;

-- ═══════════════════════════════════════════════════════════════════════════
-- Working materialization helpers
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE MACRO next_working_gen(did) AS (
    SELECT coalesce(max(g), 0) + 1
    FROM (
        SELECT gen AS g FROM v_pdf_store_working_raw WHERE document_id = did
        UNION ALL
        SELECT gen AS g FROM v_pdf_store_cleanup WHERE document_id = did
        UNION ALL
        SELECT 0 AS g
    ) z
);

-- Fingerprint of the current accepted-decision set (batch this working copy reflects).
CREATE OR REPLACE MACRO decision_batch_for_doc(did) AS (
    SELECT coalesce(
        sha256(string_agg(
            cast(s.id AS VARCHAR) || ':' || s.status,
            '|'
            ORDER BY s.id
        )),
        sha256('no-accepted')
    )
    FROM v_suggestions s
    WHERE s.document_id = did AND s.status = 'accepted'
);

CREATE OR REPLACE MACRO accepted_count_for_doc(did) AS (
    SELECT count(*)::INTEGER
    FROM v_suggestions s
    WHERE s.document_id = did AND s.status = 'accepted'
);

-- Foldable pdf_redact SQL for one document → data/working/docN_workingK.pdf
-- Scalar (SELECT … FROM documents): safe as a *column* in a plan row.
-- NOT safe inside run_sql(build_working_sql(...)) — query() forbids subqueries.
-- Execution path: working_plan → run_sql($sql) with the returned working_sql.
CREATE OR REPLACE MACRO build_working_sql(did, gen) AS (
    SELECT
        'SELECT count(*)::INTEGER AS pages FROM pdf_redact(''' ||
        d.source_path || ''', ''' || path_working_pdf(did, gen) || ''', ' ||
        boxes_lit_for_doc(did) || ')'
    FROM documents d
    WHERE d.id = did
);

-- Plan row for materialize (bind-safe: no run_sql). Caller POSTs working_sql
-- back as a foldable $sql param (same pattern as export_plan → export).
CREATE OR REPLACE MACRO working_plan(did, act) AS TABLE
WITH g AS (
    SELECT next_working_gen(did) AS gen
)
SELECT
    did AS document_id,
    g.gen,
    path_working_pdf(did, g.gen) AS path,
    decision_batch_for_doc(did) AS decision_batch,
    accepted_count_for_doc(did) AS accepted_count,
    build_working_sql(did, g.gen) AS working_sql,
    coalesce(act, 'reviewer') AS actor
FROM g;

-- Materialize execution lives in routes/store.sql as:
--   INSERT … SELECT … FROM run_sql($sql::VARCHAR)
-- with metadata from working_plan (gen/path/batch). Do not wrap build_working_sql
-- inside run_sql — query() rejects subquery arguments (export uses the same rule).

-- ═══════════════════════════════════════════════════════════════════════════
-- Cleanup: working copies are disposable / regenerable
-- ═══════════════════════════════════════════════════════════════════════════

-- Rows that would be inserted to mark working gens as cleaned (no source/export touch).
CREATE OR REPLACE MACRO cleanup_working_rows(did) AS TABLE
SELECT
    w.document_id,
    'cleanup' AS stage,
    w.path,
    w.gen,
    w.fingerprint,
    w.decision_batch,
    w.accepted_count,
    w.pages_redacted,
    w.size_bytes,
    w.revision_count,
    now() AS created_ts,
    'system' AS actor,
    'cleanup' AS kind
FROM v_pdf_store_working w
WHERE w.document_id = did;

-- cleanup_working(did): mark all active working gens cleaned and return them.
-- Physical PDF bytes are left in place (regenerable; safe to rm data/working/doc*_working*.pdf).
-- Apply pattern (also used by routes/store.sql):
--   INSERT OR REPLACE INTO pdf_store_events BY NAME
--   SELECT * FROM cleanup_working_rows(did)
--   RETURNING *;
CREATE OR REPLACE MACRO cleanup_working(did) AS TABLE
SELECT * FROM cleanup_working_rows(did);

SELECT 'pdf_store loaded' AS phase,
       (SELECT count(*) FROM pdf_store_source) AS source_rows,
       (SELECT count(*) FROM v_pdf_store) AS store_rows,
       cfg_working_root() AS working_root,
       cfg_export_root() AS export_root;
