-- app.sql — one process: build the FOIA model, register routes, serve.
--
--   build.sql  → domain tables/views from samples/ (no HTTP)
--   routes.sql → CREATE ROUTE (quackapi) + OpenAPI at /docs
--   tests/check.sql reads the same build.sql (make check) — not on this path
--
-- Env: CLOSURE_PORT · CLOSURE_API_KEY (optional)

.read server/build.sql
.read server/routes.sql

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
