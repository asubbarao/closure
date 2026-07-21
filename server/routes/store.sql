-- routes/store.sql — PDF store status + working plan/materialize (thin over pdf_store).
-- document ids are VARCHAR uuid. PARAM sql stays foldable (quackapi constraint).
-- Plans are VIEWs (v_pdf_store / v_working_plans); routes filter WHERE col = $id.

CREATE OR REPLACE ROUTE api_doc_store GET '/api/documents/:id/store' AS
SELECT
    document_id, case_id, filename, stage, path, gen, fingerprint,
    decision_batch, accepted_count, pages_redacted, size_bytes,
    revision_count, created_ts, actor, mutability, note
FROM v_pdf_store
WHERE document_id = $id
ORDER BY CASE stage WHEN 'source' THEN 0 WHEN 'working' THEN 1 WHEN 'export' THEN 2 ELSE 3 END,
         coalesce(gen, 0), created_ts;

CREATE OR REPLACE ROUTE api_doc_working_plan GET '/api/documents/:id/working/plan' AS
SELECT document_id, gen, path, decision_batch, working_sql
FROM v_working_plans
WHERE document_id = $id;

-- Body/query: sql, gen, path, decision_batch, accepted_count, actor.
-- POST body: sql=<working_plan.working_sql>. Guard keeps $sql to a single
-- SELECT shape (same foldable query() pattern as export POST).
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
    $decision_batch AS decision_batch,
    $accepted_count AS accepted_count,
    r.pages AS pages_redacted,
    cast(NULL AS BIGINT) AS size_bytes,
    1 AS revision_count,
    now() AS created_ts,
    $actor AS actor,
    'working' AS kind
FROM query(CASE WHEN starts_with($sql, 'SELECT ') AND position(';' IN $sql) = 0
                THEN $sql
                ELSE 'SELECT NULL::INTEGER AS pages LIMIT 0'
           END) r
RETURNING
    document_id, stage, path, gen, fingerprint, decision_batch,
    accepted_count, pages_redacted, size_bytes, revision_count, created_ts, actor, kind;
