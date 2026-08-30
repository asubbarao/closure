-- routes/meta.sql — live route map from quackapi registry (no hand-maintained list).

CREATE OR REPLACE VIEW v_routes AS
SELECT
    r.name,
    r.method,
    r.pattern,
    r.status,
    r.require_auth,
    NULL::VARCHAR AS source_file,
    NULL::VARCHAR AS description
FROM quackapi_routes() r;

CREATE OR REPLACE ROUTE api_routes GET '/api/routes' AS
SELECT name, method, pattern, status, require_auth, source_file, description
FROM v_routes
ORDER BY pattern, method;
