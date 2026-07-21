-- pdf_store.sql — PDF lifecycle: source / working / export.
-- Two tables + views. No macros. document_id VARCHAR (uuid).
-- Paths: data/working/doc{id}_working{gen}.pdf. Depends on: documents, pages, v_suggestions.

CREATE OR REPLACE TABLE pdf_store_source AS
SELECT cast(d.id AS VARCHAR) AS document_id, d.case_id, d.filename,
       'source' AS stage, d.source_path AS path, 0::INTEGER AS gen,
       b.fingerprint, cast(NULL AS VARCHAR) AS decision_batch,
       0::INTEGER AS accepted_count, cast(NULL AS INTEGER) AS pages_redacted,
       b.size_bytes, 1::INTEGER AS revision_count, now() AS created_ts,
       'system' AS actor, 'immutable' AS mutability,
       'references samples/; never mutated by this module' AS note
FROM documents d
JOIN (
    SELECT filename AS source_path, sha256(content) AS fingerprint, size AS size_bytes
    FROM read_blob(
        coalesce(nullif(cast(getvariable('samples_dir') AS VARCHAR), ''), 'samples') || '/*.pdf'
    )
) b ON b.source_path = d.source_path;

CREATE OR REPLACE TABLE pdf_store_events (
    document_id VARCHAR NOT NULL,
    stage VARCHAR NOT NULL,
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
    kind VARCHAR NOT NULL,
    PRIMARY KEY (document_id, stage, gen, kind)
);

CREATE OR REPLACE VIEW v_pdf_store AS
WITH working_raw AS (
    SELECT cast(document_id AS VARCHAR) AS document_id, path, gen, fingerprint,
           decision_batch, accepted_count, pages_redacted, size_bytes,
           revision_count, created_ts, actor, 0 AS src_rank
    FROM pdf_store_events WHERE kind = 'working' AND stage = 'working'
    UNION ALL BY NAME
    SELECT regexp_extract(filename, 'doc(.+)_working\d+\.pdf$', 1) AS document_id,
           filename AS path,
           try_cast(regexp_extract(filename, '_working(\d+)\.pdf$', 1) AS INTEGER) AS gen,
           sha256(content) AS fingerprint,
           cast(NULL AS VARCHAR) AS decision_batch,
           cast(NULL AS INTEGER) AS accepted_count,
           cast(NULL AS INTEGER) AS pages_redacted,
           size AS size_bytes, 1::INTEGER AS revision_count,
           try_cast(last_modified AS TIMESTAMP) AS created_ts,
           'disk' AS actor, 1 AS src_rank
    FROM read_blob('data/working/*.pdf')
    WHERE regexp_matches(filename, 'doc.+_working\d+\.pdf$')
),
cleaned AS (
    SELECT cast(document_id AS VARCHAR) AS document_id, gen
    FROM pdf_store_events WHERE kind = 'cleanup' OR stage = 'cleanup'
),
working_live AS (
    SELECT document_id, gen,
           unnest(arg_min(struct_pack(path, fingerprint, decision_batch, accepted_count,
                                      pages_redacted, size_bytes, revision_count,
                                      created_ts, actor), src_rank))
    FROM working_raw
    WHERE document_id IS NOT NULL AND gen IS NOT NULL AND path IS NOT NULL
    GROUP BY document_id, gen
),
export_blobs AS (
    SELECT filename AS path, sha256(content) AS fingerprint, size AS size_bytes,
           last_modified AS created_ts
    FROM read_blob('exports/*_redacted.pdf')
    UNION ALL BY NAME
    SELECT filename AS path, sha256(content) AS fingerprint, size AS size_bytes,
           last_modified AS created_ts
    FROM read_blob('data/export/*_redacted.pdf')
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
       w.created_ts, w.actor, 'regenerable' AS mutability, 'data/working' AS note
FROM working_live w
JOIN documents d ON cast(d.id AS VARCHAR) = w.document_id
LEFT JOIN cleaned c ON c.document_id = w.document_id AND c.gen = w.gen
WHERE c.gen IS NULL
UNION ALL BY NAME
SELECT cast(d.id AS VARCHAR) AS document_id, d.case_id, d.filename,
       'export' AS stage, e.path, cast(NULL AS INTEGER) AS gen, e.fingerprint,
       cast(NULL AS VARCHAR) AS decision_batch,
       cast(NULL AS INTEGER) AS accepted_count,
       cast(NULL AS INTEGER) AS pages_redacted,
       e.size_bytes, 1::INTEGER AS revision_count, e.created_ts,
       'export_route' AS actor, 'append_only' AS mutability,
       CASE WHEN starts_with(e.path, 'data/export') THEN 'data/export' ELSE 'exports_compat' END AS note
FROM documents d
JOIN export_blobs e
  ON e.path = 'exports/' || d.filename || '_redacted.pdf'
  OR e.path = 'data/export/' || d.filename || '_redacted.pdf';

-- Consumer: /api/documents/:id/working/plan. Geometry: y = height_pt - y1.
CREATE OR REPLACE VIEW v_working_plans AS
WITH gens AS (
    SELECT cast(document_id AS VARCHAR) AS document_id, gen FROM pdf_store_events
    UNION ALL
    SELECT regexp_extract(filename, 'doc(.+)_working\d+\.pdf$', 1),
           try_cast(regexp_extract(filename, '_working(\d+)\.pdf$', 1) AS INTEGER)
    FROM read_blob('data/working/*.pdf')
    WHERE regexp_matches(filename, 'doc.+_working\d+\.pdf$')
),
next_gen AS (
    SELECT document_id, coalesce(max(gen), 0) + 1 AS gen
    FROM gens WHERE document_id IS NOT NULL AND gen IS NOT NULL GROUP BY document_id
),
boxes AS (
    SELECT s.document_id,
           list(struct_pack(page := s.page_no::INTEGER, x := s.x0::DOUBLE,
                            y := (p.height_pt - s.y1)::DOUBLE,
                            w := (s.x1 - s.x0)::DOUBLE, h := (s.y1 - s.y0)::DOUBLE)
                ORDER BY s.page_no, s.id) AS boxes
    FROM v_suggestions s
    JOIN pages p ON cast(p.document_id AS VARCHAR) = s.document_id AND p.page_no = s.page_no
    WHERE s.status = 'accepted'
    GROUP BY s.document_id
),
batches AS (
    SELECT s.document_id,
           sha256(string_agg(format('{}:{}', s.id, s.status), '|' ORDER BY s.id)) AS decision_batch
    FROM v_suggestions s WHERE s.status = 'accepted' GROUP BY s.document_id
)
SELECT cast(d.id AS VARCHAR) AS document_id,
       coalesce(g.gen, 1) AS gen,
       format('data/working/doc{}_working{}.pdf', d.id, coalesce(g.gen, 1)) AS path,
       coalesce(bt.decision_batch, sha256('no-accepted')) AS decision_batch,
       coalesce(bx.boxes, []) AS boxes,
       format(
           'SELECT count(*)::INTEGER AS pages FROM pdf_redact(''{}'', ''{}'', {}::STRUCT(page INTEGER, x DOUBLE, y DOUBLE, w DOUBLE, h DOUBLE)[])',
           d.source_path,
           format('data/working/doc{}_working{}.pdf', d.id, coalesce(g.gen, 1)),
           cast(coalesce(bx.boxes, []) AS VARCHAR)
       ) AS working_sql
FROM documents d
LEFT JOIN next_gen g ON g.document_id = cast(d.id AS VARCHAR)
LEFT JOIN boxes bx ON bx.document_id = cast(d.id AS VARCHAR)
LEFT JOIN batches bt ON bt.document_id = cast(d.id AS VARCHAR);

SELECT 'pdf_store loaded' AS phase,
       (SELECT count(*) FROM pdf_store_source) AS source_rows,
       'data/working' AS working_root;
