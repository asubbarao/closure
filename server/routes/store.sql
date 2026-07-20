-- routes/store.sql — PDF store status + working plan/materialize (thin over pdf_store).
-- document ids are VARCHAR uuid. PARAM sql stays foldable (quackapi constraint).

CREATE OR REPLACE ROUTE api_doc_store GET '/api/documents/:id/store' AS
SELECT
    document_id, case_id, filename, stage, path, gen, fingerprint,
    decision_batch, accepted_count, pages_redacted, size_bytes,
    revision_count, created_ts, actor, mutability, note
FROM document_store($id);

CREATE OR REPLACE ROUTE api_doc_working_plan GET '/api/documents/:id/working/plan' AS
SELECT
    document_id, gen, path, decision_batch, accepted_count, working_sql, actor
FROM working_plan($id, 'planner');

-- Body/query: sql, gen, path, decision_batch, accepted_count, actor.
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
    $id AS document_id,
    'working' AS stage,
    $path AS path,
    $gen AS gen,
    cast(NULL AS VARCHAR) AS fingerprint,
    coalesce($decision_batch, '') AS decision_batch,
    coalesce($accepted_count, 0) AS accepted_count,
    r.pages AS pages_redacted,
    cast(NULL AS BIGINT) AS size_bytes,
    1 AS revision_count,
    now() AS created_ts,
    coalesce($actor, 'reviewer') AS actor,
    'working' AS kind
FROM run_sql($sql) r
RETURNING
    document_id, stage, path, gen, fingerprint, decision_batch,
    accepted_count, pages_redacted, size_bytes, revision_count, created_ts, actor, kind;
