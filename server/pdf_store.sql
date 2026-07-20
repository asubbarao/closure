-- pdf_store.sql — PDF lifecycle: source / working / export.
--
-- Two tables + ONE unmaterialized view. No cfg_* macros, no cast soup, no
-- registry JSON log views. scalarfs captures accepted boxes as a native list
-- for pdf_redact; working_plan embeds that list as a foldable literal so the
-- HTTP plan→POST path stays self-contained (variables do not span requests).
--
-- document_id is VARCHAR (uuid). Paths: data/working/doc{id}_working{gen}.pdf
-- Route shapes: document_store / working_plan keys unchanged (SCHEMA_CONTRACT).
-- Depends on: documents, pages, v_suggestions. Does NOT write exports/.

INSTALL scalarfs FROM community;
LOAD scalarfs;

-- Store roots are committed layout LITERALS (data/working, data/export,
-- exports): the write side (COPY TO) only accepts grammar literals, so a
-- variable read side would be fake flexibility — and route bind cannot see
-- SET VARIABLEs anyway (getvariable binds NULL inside CREATE ROUTE handlers).

-- ── tables ──────────────────────────────────────────────────────────────────

-- Immutable source stage: references samples/ (never copy-mutate).
CREATE OR REPLACE TABLE pdf_store_source AS
SELECT
    cast(d.id AS VARCHAR) AS document_id,
    d.case_id,
    d.filename,
    'source' AS stage,
    d.source_path AS path,
    0::INTEGER AS gen,
    b.fingerprint,
    cast(NULL AS VARCHAR) AS decision_batch,
    0::INTEGER AS accepted_count,
    cast(NULL AS INTEGER) AS pages_redacted,
    b.size_bytes,
    1::INTEGER AS revision_count,
    now() AS created_ts,
    'system' AS actor,
    'immutable' AS mutability,
    'references samples/; never mutated by this module' AS note
FROM documents d
JOIN (
    SELECT filename AS source_path, sha256(content) AS fingerprint, size AS size_bytes
    FROM read_blob(
        coalesce(nullif(cast(getvariable('samples_dir') AS VARCHAR), ''), 'samples') || '/*.pdf'
    )
) b ON b.source_path = d.source_path;

-- Mutable working + cleanup events (boot-empty; INSERT OR REPLACE at runtime).
CREATE OR REPLACE TABLE pdf_store_events (
    document_id VARCHAR NOT NULL,
    stage VARCHAR NOT NULL,            -- working | cleanup
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
    kind VARCHAR NOT NULL,             -- working | cleanup
    PRIMARY KEY (document_id, stage, gen, kind)
);

-- ── ONE view: unified store (source ∪ active working ∪ export) ──────────────

CREATE OR REPLACE VIEW v_pdf_store AS
WITH
working_raw AS (
    SELECT cast(document_id AS VARCHAR) AS document_id, path, gen, fingerprint,
           decision_batch, accepted_count, pages_redacted, size_bytes,
           revision_count, created_ts, actor, 0 AS src_rank
    FROM pdf_store_events
    WHERE kind = 'working' AND stage = 'working'
    UNION ALL BY NAME
    SELECT
        regexp_extract(filename, 'doc(.+)_working\d+\.pdf$', 1) AS document_id,
        filename AS path,
        try_cast(regexp_extract(filename, '_working(\d+)\.pdf$', 1) AS INTEGER) AS gen,
        sha256(content) AS fingerprint,
        cast(NULL AS VARCHAR) AS decision_batch,
        cast(NULL AS INTEGER) AS accepted_count,
        cast(NULL AS INTEGER) AS pages_redacted,
        size AS size_bytes,
        1::INTEGER AS revision_count,
        try_cast(last_modified AS TIMESTAMP) AS created_ts,
        'disk' AS actor,
        1 AS src_rank
    FROM read_blob('data/working' || '/*.pdf')
    WHERE regexp_matches(filename, 'doc.+_working\d+\.pdf$')
),
cleaned AS (
    SELECT cast(document_id AS VARCHAR) AS document_id, gen
    FROM pdf_store_events
    WHERE kind = 'cleanup' OR stage = 'cleanup'
),
working_live AS (
    SELECT document_id, gen,
           arg_max(path, src_rank * -1) AS path,
           arg_max(fingerprint, src_rank * -1) AS fingerprint,
           arg_max(decision_batch, src_rank * -1) AS decision_batch,
           arg_max(accepted_count, src_rank * -1) AS accepted_count,
           arg_max(pages_redacted, src_rank * -1) AS pages_redacted,
           arg_max(size_bytes, src_rank * -1) AS size_bytes,
           arg_max(revision_count, src_rank * -1) AS revision_count,
           arg_max(created_ts, src_rank * -1) AS created_ts,
           arg_max(actor, src_rank * -1) AS actor
    FROM working_raw
    WHERE document_id IS NOT NULL AND gen IS NOT NULL AND path IS NOT NULL
    GROUP BY document_id, gen
),
export_blobs AS (
    SELECT filename AS path, sha256(content) AS fingerprint, size AS size_bytes,
           last_modified AS created_ts
    FROM read_blob('exports' || '/*_redacted.pdf')
    UNION ALL BY NAME
    SELECT filename AS path, sha256(content) AS fingerprint, size AS size_bytes,
           last_modified AS created_ts
    FROM read_blob('data/export' || '/*_redacted.pdf')
)
SELECT document_id, case_id, filename, stage, path, gen, fingerprint,
       decision_batch, accepted_count, pages_redacted, size_bytes,
       revision_count, created_ts, actor, mutability, note
FROM pdf_store_source
UNION ALL BY NAME
SELECT w.document_id, d.case_id, d.filename,
       'working' AS stage, w.path, w.gen, w.fingerprint, w.decision_batch,
       w.accepted_count, w.pages_redacted, w.size_bytes,
       coalesce(w.revision_count, 1)::INTEGER AS revision_count,
       w.created_ts, w.actor, 'regenerable' AS mutability,
       'data/working' AS note
FROM working_live w
JOIN documents d ON cast(d.id AS VARCHAR) = w.document_id
LEFT JOIN cleaned c ON c.document_id = w.document_id AND c.gen = w.gen
WHERE c.gen IS NULL
UNION ALL BY NAME
SELECT cast(d.id AS VARCHAR) AS document_id, d.case_id, d.filename,
       'export' AS stage, e.path,
       cast(NULL AS INTEGER) AS gen, e.fingerprint,
       cast(NULL AS VARCHAR) AS decision_batch,
       cast(NULL AS INTEGER) AS accepted_count,
       cast(NULL AS INTEGER) AS pages_redacted,
       e.size_bytes, 1::INTEGER AS revision_count, e.created_ts,
       'export_route' AS actor, 'append_only' AS mutability,
       CASE WHEN starts_with(e.path, 'data/export')
            THEN 'data/export' ELSE 'exports_compat' END AS note
FROM documents d
JOIN export_blobs e
  ON e.path = 'exports' || '/' || d.filename || '_redacted.pdf'
  OR e.path = 'data/export' || '/' || d.filename || '_redacted.pdf';

-- ── macros kept for routes/store.sql (parameterized, reused) ────────────────

-- GET /api/documents/:id/store
CREATE OR REPLACE MACRO document_store(did) AS TABLE
SELECT document_id, case_id, filename, stage, path, gen, fingerprint,
       decision_batch, accepted_count, pages_redacted, size_bytes,
       revision_count, created_ts, actor, mutability, note
FROM v_pdf_store
WHERE document_id = cast(did AS VARCHAR)
ORDER BY CASE stage WHEN 'source' THEN 0 WHEN 'working' THEN 1 WHEN 'export' THEN 2 ELSE 3 END,
         coalesce(gen, 0), created_ts;

-- Accepted boxes → STRUCT[] (y-flip once: words top-left, pdf_redact bottom-left).
-- Same list shape as: COPY (...) TO 'variable:accepted_boxes' (FORMAT variable, LIST rows)
-- then pdf_redact(src, dst, getvariable('accepted_boxes')).
CREATE OR REPLACE MACRO accepted_boxes(did) AS (
    SELECT coalesce(
        list(
            struct_pack(
                page := s.page_no::INTEGER,
                x    := s.x0::DOUBLE,
                y    := (p.height_pt - s.y1)::DOUBLE,
                w    := (s.x1 - s.x0)::DOUBLE,
                h    := (s.y1 - s.y0)::DOUBLE
            )
            ORDER BY s.page_no, s.id
        ),
        []::STRUCT(page INTEGER, x DOUBLE, y DOUBLE, w DOUBLE, h DOUBLE)[]
    )
    FROM v_suggestions s
    JOIN pages p
      ON cast(p.document_id AS VARCHAR) = s.document_id
     AND p.page_no = s.page_no
    WHERE s.document_id = cast(did AS VARCHAR) AND s.status = 'accepted'
);

-- GET /api/documents/:id/working/plan — foldable working_sql for POST …/working.
-- box list is embedded as cast(STRUCT[] AS VARCHAR); same list handable via
-- COPY (…) TO 'variable:accepted_boxes' (FORMAT variable, LIST rows) + getvariable.
CREATE OR REPLACE MACRO working_plan(did, act) AS TABLE
WITH
plan AS (
    SELECT
        cast(did AS VARCHAR) AS document_id,
        (
            SELECT coalesce(max(g), 0) + 1
            FROM (
                SELECT gen AS g FROM pdf_store_events
                WHERE cast(document_id AS VARCHAR) = cast(did AS VARCHAR)
                UNION ALL
                SELECT try_cast(regexp_extract(filename, '_working(\d+)\.pdf$', 1) AS INTEGER)
                FROM read_blob('data/working' || '/*.pdf')
                WHERE position('doc' || cast(did AS VARCHAR) || '_working' IN filename) > 0
                UNION ALL
                SELECT 0
            ) z
        ) AS gen,
        accepted_boxes(did) AS box_list,
        coalesce(
            (SELECT sha256(string_agg(s.id || ':' || s.status, '|' ORDER BY s.id))
             FROM v_suggestions s
             WHERE s.document_id = cast(did AS VARCHAR) AND s.status = 'accepted'),
            sha256('no-accepted')
        ) AS decision_batch,
        (SELECT count(*)::INTEGER FROM v_suggestions s
         WHERE s.document_id = cast(did AS VARCHAR) AND s.status = 'accepted') AS accepted_count
)
SELECT
    p.document_id,
    p.gen,
    'data/working' || '/doc' || p.document_id
        || '_working' || cast(p.gen AS VARCHAR) || '.pdf' AS path,
    p.decision_batch,
    p.accepted_count,
    'SELECT count(*)::INTEGER AS pages FROM pdf_redact(''' || d.source_path || ''', '''
        || 'data/working' || '/doc' || p.document_id
        || '_working' || cast(p.gen AS VARCHAR) || '.pdf'', '
        || cast(p.box_list AS VARCHAR)
        || '::STRUCT(page INTEGER, x DOUBLE, y DOUBLE, w DOUBLE, h DOUBLE)[])' AS working_sql,
    coalesce(act, 'reviewer') AS actor
FROM documents d
JOIN plan p ON p.document_id = cast(d.id AS VARCHAR);

-- Cleanup markers (INSERT OR REPLACE INTO pdf_store_events BY NAME SELECT * FROM …).
CREATE OR REPLACE MACRO cleanup_working_rows(did) AS TABLE
SELECT document_id, 'cleanup' AS stage, path, gen, fingerprint, decision_batch,
       accepted_count, pages_redacted, size_bytes, revision_count,
       now() AS created_ts, 'system' AS actor, 'cleanup' AS kind
FROM v_pdf_store
WHERE stage = 'working' AND document_id = cast(did AS VARCHAR);

-- Prove scalarfs: capture empty box list into a typed variable (LIST rows).
COPY (
    SELECT 0::INTEGER AS page, 0.0::DOUBLE AS x, 0.0::DOUBLE AS y,
           0.0::DOUBLE AS w, 0.0::DOUBLE AS h
    WHERE false
) TO 'variable:accepted_boxes_empty' (FORMAT variable, LIST rows);

SELECT 'pdf_store loaded' AS phase,
       (SELECT count(*) FROM pdf_store_source) AS source_rows,
       (SELECT count(*) FROM v_pdf_store) AS store_rows,
       typeof(getvariable('accepted_boxes_empty')) AS scalarfs_boxes_type,
       'data/working' AS working_root;
