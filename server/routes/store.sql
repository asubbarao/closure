-- routes/store.sql — PDF lifecycle HTTP surface (store status + materialize working).
--
-- Purpose: thin controllers over server/pdf_store.sql macros.
-- Dependencies: pdf_store (document_store, working_plan, cleanup_working_rows),
--               pdf_io (run_sql, boxes_lit_for_doc — used inside plan SQL).
--
-- GET  /api/documents/:id/store         → stages + fingerprints + revisions
-- GET  /api/documents/:id/working/plan  → working_sql + gen/path/batch (bind-safe)
-- POST /api/documents/:id/working       → run foldable working_sql + registry row
--
-- quackapi: query()/run_sql only accept foldable SQL strings — never
-- run_sql(build_working_sql(id)) or run_sql((SELECT …)). Same constraint as
-- export_plan → POST export with body {sql}. POST requires JSON body.

-- Store inventory for one document (source ∪ working ∪ export).
CREATE OR REPLACE ROUTE api_doc_store GET '/api/documents/:id/store' AS
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
FROM document_store($id::INTEGER);

-- Plan: live accepted boxes → foldable pdf_redact SQL + registry metadata.
CREATE OR REPLACE ROUTE api_doc_working_plan GET '/api/documents/:id/working/plan' AS
SELECT
    document_id,
    gen,
    path,
    decision_batch,
    accepted_count,
    working_sql,
    actor
FROM working_plan($id::INTEGER, 'planner');

-- Materialize: execute plan SQL (PARAM sql) and insert registry event.
-- Body JSON: {"sql":"<working_sql from plan>", "gen":N, "path":"...", ...}
-- Or query params: ?sql=...&gen=...&path=...&decision_batch=...&accepted_count=...
CREATE OR REPLACE ROUTE api_doc_working POST '/api/documents/:id/working'
  PARAM actor VARCHAR DEFAULT 'reviewer'
  PARAM sql VARCHAR
  PARAM gen INTEGER
  PARAM path VARCHAR
  PARAM decision_batch VARCHAR DEFAULT ''
  PARAM accepted_count INTEGER DEFAULT 0
AS
INSERT OR REPLACE INTO pdf_store_events BY NAME
SELECT
    $id::INTEGER AS document_id,
    'working' AS stage,
    $path::VARCHAR AS path,
    $gen::INTEGER AS gen,
    NULL::VARCHAR AS fingerprint,
    -- $param coalesce: explicit JSON null binds NULL past the PARAM DEFAULT;
    -- '' / 0 are the registry's stated "no batch / none" values.
    coalesce($decision_batch::VARCHAR, '') AS decision_batch,
    coalesce($accepted_count::INTEGER, 0) AS accepted_count,
    r.pages AS pages_redacted,
    NULL::BIGINT AS size_bytes,
    1::INTEGER AS revision_count,
    now() AS created_ts,
    coalesce($actor::VARCHAR, 'reviewer') AS actor,
    'working' AS kind
FROM run_sql($sql::VARCHAR) r
RETURNING
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
    kind;
