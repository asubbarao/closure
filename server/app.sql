-- app.sql — DuckDB as the app runtime (better FastAPI for data products).
--
-- HTTP:     quackapi (routes, auth, live OpenAPI /docs /openapi.json)
-- Outbound: curl_httpfs (transport) + cache_httpfs (read cache under .tmp/cache_httpfs)
-- Paths:    hostfs → scalarfs pins → pathvariable: / zip://
-- Effects:  shellfs (setup host effects; patterns in shellfs.sql)
-- Checks:   server/smoke.sql (schema invariants — not a second type system)
-- Optional: CLOSURE_API_KEY · CLOSURE_POSTGRES · CLOSURE_SAMPLE_ZIP + zip_pin.sql
--           CLOSURE_REMOTE_PROBE (https URL) warms cache_httpfs at boot

.read server/config.sql

SET memory_limit = '4GB';
SET max_temp_directory_size = '8GB';

.read server/extensions.sql
.read server/auth.sql

SET VARIABLE port        = (SELECT value FROM app_config WHERE key = 'port');
SET VARIABLE static_dir  = (SELECT value FROM app_config WHERE key = 'static_dir');
SET VARIABLE samples_dir = (SELECT value FROM app_config WHERE key = 'samples_dir');
SET VARIABLE exports_dir = (SELECT value FROM app_config WHERE key = 'exports_dir');
SET VARIABLE pages_dir   = 'pages';
SET VARIABLE templates_dir = 'server/templates';
SET VARIABLE detector_rules_path = 'server/config/detector_rules.json';
SET VARIABLE semantic_yaml_path  = 'server/config/closure_semantic.yaml';

.read server/hostfs.sql

COPY (
    SELECT abs_path FROM v_hostfs
    WHERE root = 'samples' AND is_file IS TRUE AND ext = '.pdf'
    ORDER BY path
) TO 'variable:sample_pdfs' (FORMAT variable, LIST scalar);

COPY (
    SELECT any_value(abs_path) FROM v_hostfs
    WHERE root = 'samples' AND is_file IS TRUE AND name = 'manifest.json'
) TO 'variable:manifest_path' (FORMAT variable);

COPY (
    SELECT any_value(abs_path) FROM v_hostfs
    WHERE root = 'samples' AND is_file IS TRUE AND name = 'watchlist.json'
) TO 'variable:watchlist_path' (FORMAT variable);

COPY (
    SELECT abs_path FROM v_hostfs
    WHERE root = 'templates' AND is_file IS TRUE AND ext = '.html'
    ORDER BY path
) TO 'variable:template_files' (FORMAT variable, LIST scalar);

SET VARIABLE sample_zip_path = (
    SELECT absolute_path(path)
    FROM (SELECT nullif(getenv('CLOSURE_SAMPLE_ZIP'), '') AS path)
    WHERE path IS NOT NULL
      AND is_file(path) IS TRUE AND file_extension(path) = '.zip'
);

-- Optional Postgres as peer store (same SQL app)
.read server/postgres.sql

.read server/model.sql
.read server/routes.sql
.read server/smoke.sql

SELECT format(
    'Closure http://127.0.0.1:{}/  openapi=/docs  auth={}',
    getvariable('port'),
    CASE WHEN nullif(getenv('CLOSURE_API_KEY'), '') IS NOT NULL
         THEN 'api_key' ELSE 'open' END
) AS status;

-- Serve: http_client auto → curl_httpfs MultiCurl when LOADed (quackapi default).
FROM quackapi_serve(
    getvariable('port')::INTEGER,
    static_dir := getvariable('static_dir'),
    memory_limit := '4GB',
    http_client := 'auto'
);

-- quackapi may re-apply a low guard; raise again for handlers
SET memory_limit = '4GB';
SET max_temp_directory_size = '8GB';

SELECT sleep_ms(86400000);
