-- routes.sql — product loop. Page HTML in v_* views; routes SELECT/INSERT.
-- OpenAPI: GET /docs · /openapi.json · /redoc (quackapi built-in).
-- Auth: CREATE AUTH closure_api in auth.sql; add REQUIRE closure_api to lock a route.
-- Open APIs: allowlisted relations only (not raw query on any name).

-- ── HTML ───────────────────────────────────────────────────────────────────

CREATE OR REPLACE ROUTE home GET '/' AS
SELECT html FROM v_case_html
WHERE case_id = (SELECT min(case_id) FROM v_case_html);

CREATE OR REPLACE ROUTE case_dash GET '/cases/:id' AS
SELECT html FROM v_case_html WHERE case_id = $id;

CREATE OR REPLACE ROUTE case_stream GET '/cases/:id/stream' AS
SELECT html FROM v_stream_page WHERE case_id = $id;

CREATE OR REPLACE ROUTE case_audit_html GET '/cases/:id/audit' AS
SELECT html FROM v_audit_page WHERE case_id = $id;

CREATE OR REPLACE ROUTE document_review GET '/documents/:id' AS
SELECT html FROM v_review_page WHERE document_id = $id AND page_no = 1;

CREATE OR REPLACE ROUTE document_page GET '/documents/:id/pages/:page' AS
SELECT html FROM v_review_page
WHERE document_id = $id
  AND page_no = least(greatest(try_cast($page AS INTEGER), 1),
                      (SELECT page_count FROM documents WHERE id = $id));

-- ── catalog (relational; allowlist) ────────────────────────────────────────

CREATE OR REPLACE ROUTE api_nav GET '/api/cases/:id/nav' AS
SELECT href, text FROM v_nav WHERE case_id = $id ORDER BY href;

-- Case metrics: tall dims (status × band) + real measures — no count pivots.
CREATE OR REPLACE ROUTE api_case_metrics GET '/api/cases/:id/metrics' AS
SELECT status, band, n, avg_confidence, min_confidence, max_confidence
FROM semantic_view(
    'closure',
    dimensions := ['case_id', 'status', 'band'],
    metrics := ['n', 'avg_confidence', 'min_confidence', 'max_confidence']
)
WHERE case_id = $id
ORDER BY status, band;

CREATE OR REPLACE ROUTE api_cols GET '/api/cols' AS
SELECT * FROM v_cols ORDER BY relation;

CREATE OR REPLACE ROUTE api_cols_one GET '/api/cols/:relation' AS
SELECT * FROM v_cols WHERE relation = $relation;

-- Open only main relations that appear in v_cols.
-- query() rejects subqueries in its args (route binder); $relation is the
-- format arg, allowlist is a post-filter. Identifiers only live in v_cols.
CREATE OR REPLACE ROUTE api_rel GET '/api/rel/:relation' AS
SELECT * FROM query(format('SELECT * FROM {}', $relation))
WHERE $relation IN (SELECT relation FROM v_cols);

CREATE OR REPLACE ROUTE api_summarize GET '/api/summarize/:relation' AS
SELECT * FROM query(format('FROM (SUMMARIZE {})', $relation))
WHERE $relation IN (SELECT relation FROM v_cols);

CREATE OR REPLACE ROUTE api_template_links GET '/api/templates/links' AS
SELECT * FROM v_src_template_links ORDER BY template, line_number;

CREATE OR REPLACE ROUTE api_semantic_yaml GET '/api/config/semantic' AS
SELECT * FROM v_src_semantic_yaml;

-- hostfs / shellfs surfaces (read-only; no raw shell cmd from HTTP)
CREATE OR REPLACE ROUTE api_hostfs GET '/api/hostfs' AS
SELECT * FROM v_hostfs ORDER BY root, path;

CREATE OR REPLACE ROUTE api_zips GET '/api/zips' AS
SELECT * FROM v_zips ORDER BY root, zip_path;

CREATE OR REPLACE ROUTE api_shell_patterns GET '/api/shell/patterns' AS
SELECT * FROM v_shell_patterns ORDER BY kind;

-- dns: hostnames seen in PDF tokens + A records (network on request)
CREATE OR REPLACE ROUTE api_url_hosts GET '/api/url-hosts' AS
SELECT * FROM v_url_hosts ORDER BY token_n DESC, hostname;

-- read_lines + scalarfs: ±3 lines of page text around a suggestion
CREATE OR REPLACE ROUTE api_suggestion_context GET '/api/suggestions/:id/context' AS
SELECT suggestion_id, document_id, page_no, hit_line, line_number, line_text, dist
FROM v_suggestion_line_context
WHERE suggestion_id = $id
ORDER BY line_number;

-- ── writes ─────────────────────────────────────────────────────────────────

CREATE OR REPLACE ROUTE api_suggestion_decision POST '/api/suggestions/:id/decision'
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS INSERT INTO decisions BY NAME
WITH b AS (SELECT uuid()::VARCHAR AS batch_id)
SELECT 'decision' AS kind, t.suggestion_id, $status AS status, $actor AS actor, $reason AS reason,
       now() AS ts, t.document_id, t.case_id, t.text, (SELECT batch_id FROM b) AS batch_id,
       $status || ' — ' || coalesce(t.text, '') AS batch_label, NULL::VARCHAR AS undoes_batch_id
FROM v_decide_targets t
WHERE t.suggestion_id = $id
RETURNING suggestion_id, status;

CREATE OR REPLACE ROUTE api_entity_decision POST '/api/entities/:id/decision'
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS INSERT INTO decisions BY NAME
WITH b AS (SELECT uuid()::VARCHAR AS batch_id)
SELECT 'decision' AS kind, t.suggestion_id, $status AS status, $actor AS actor, $reason AS reason,
       now() AS ts, t.document_id, t.case_id, t.text, (SELECT batch_id FROM b) AS batch_id,
       $status || ' entity — ' || coalesce(t.entity_text, t.text, '') AS batch_label,
       NULL::VARCHAR AS undoes_batch_id
FROM v_decide_targets t
WHERE t.entity_id = $id AND t.status = 'pending' AND t.band <> 'flagged'
RETURNING suggestion_id, status;

CREATE OR REPLACE ROUTE api_doc_band_decision POST '/api/documents/:id/band/:band/decision'
  PARAM status VARCHAR PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT ''
AS INSERT INTO decisions BY NAME
WITH b AS (SELECT uuid()::VARCHAR AS batch_id)
SELECT 'decision' AS kind, t.suggestion_id, $status AS status, $actor AS actor,
       coalesce(nullif($reason, ''), 'bulk band ' || $band) AS reason,
       now() AS ts, t.document_id, t.case_id, t.text, (SELECT batch_id FROM b) AS batch_id,
       $status || ' band ' || $band AS batch_label, NULL::VARCHAR AS undoes_batch_id
FROM v_decide_targets t
WHERE t.document_id = $id AND t.status = 'pending' AND t.band = $band AND $band <> 'flagged'
RETURNING suggestion_id, status;

CREATE OR REPLACE ROUTE api_case_accept_high POST '/api/cases/:id/accept-high'
  PARAM threshold INTEGER DEFAULT 90 GE 0 LE 100
  PARAM actor VARCHAR DEFAULT 'reviewer'
AS INSERT INTO decisions BY NAME
WITH b AS (SELECT uuid()::VARCHAR AS batch_id)
SELECT 'decision' AS kind, t.suggestion_id, 'accepted' AS status, $actor AS actor,
       'accept high ≥' || $threshold::VARCHAR AS reason,
       now() AS ts, t.document_id, t.case_id, t.text, (SELECT batch_id FROM b) AS batch_id,
       'Accepted high' AS batch_label, NULL::VARCHAR AS undoes_batch_id
FROM v_decide_targets t
WHERE t.case_id = $id AND t.status = 'pending' AND t.confidence >= $threshold
  AND t.band <> 'flagged' AND t.flag_tag <> 'false_positive'
RETURNING suggestion_id, status;

CREATE OR REPLACE ROUTE api_document_add POST '/api/documents/:id/add'
  PARAM page INTEGER PARAM x0 DOUBLE PARAM y0 DOUBLE PARAM x1 DOUBLE PARAM y1 DOUBLE
  PARAM text VARCHAR PARAM kind VARCHAR DEFAULT 'MANUAL'
  PARAM actor VARCHAR DEFAULT 'reviewer' PARAM reason VARCHAR DEFAULT 'missed by AI'
AS INSERT INTO decisions BY NAME
WITH b AS (SELECT uuid()::VARCHAR AS batch_id, uuid()::VARCHAR AS suggestion_id)
SELECT 'added' AS kind, b.suggestion_id, $id AS document_id, $page::INTEGER AS page_no,
       ($x0, $y0, $x1, $y1)::bbox AS bbox, $text AS text, coalesce($text, '') AS context,
       99 AS confidence, $kind AS flag_tag, coalesce($reason, 'manual add') AS reason,
       NULL::VARCHAR AS entity_id, 'manual' AS source, 'accepted' AS status,
       $actor AS actor, now() AS ts,
       (SELECT case_id FROM documents WHERE id = $id) AS case_id,
       'one' AS scope, b.batch_id,
       'Added missed — ' || coalesce($text, '') AS batch_label, NULL::VARCHAR AS undoes_batch_id
FROM b
RETURNING suggestion_id, status;

CREATE OR REPLACE ROUTE api_undo POST '/api/undo'
  PARAM actor VARCHAR DEFAULT 'reviewer' PARAM case_id VARCHAR DEFAULT ''
AS INSERT INTO decisions BY NAME
WITH target AS (
    SELECT arg_max(batch_id, ts) AS batch_id, arg_max(label, ts) AS label
    FROM v_decision_batches
    WHERE undoes_batch_id IS NULL
      AND ($case_id IN ('', '0') OR case_id = $case_id)
),
b AS (SELECT uuid()::VARCHAR AS batch_id)
SELECT 'decision' AS kind, h.suggestion_id,
       coalesce(lag(h.status) OVER (PARTITION BY h.suggestion_id ORDER BY h.event_ts), 'pending') AS status,
       $actor AS actor, 'undo' AS reason, now() AS ts,
       h.document_id, h.case_id, h.text, (SELECT batch_id FROM b) AS batch_id,
       'Undo — ' || coalesce(t.label, t.batch_id) AS batch_label,
       t.batch_id AS undoes_batch_id
FROM v_history_events h
JOIN target t ON h.batch_id = t.batch_id
WHERE h.kind = 'decision'
RETURNING suggestion_id, status;

CREATE OR REPLACE ROUTE api_case_export POST '/api/cases/:id/export' AS
SELECT p.document_id, p.out_path,
       (SELECT count(*)::INTEGER
        FROM pdf_redact(p.source_path, p.out_path, p.boxes)) AS pages
FROM v_export_plans p
WHERE p.case_id = $id AND NOT p.blocked AND len(p.boxes) > 0;
