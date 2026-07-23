-- app.sql — DuckDB as the app runtime (better FastAPI for data products).
--
-- Build:    server/build.sql (raw files → typed views → domain tables; no HTTP)
-- HTTP:     quackapi (routes, auth, live OpenAPI /docs /openapi.json)
-- Outbound: curl_httpfs (transport) + cache_httpfs (read cache under .tmp/cache_httpfs)
-- Paths:    hostfs → scalarfs pins → pathvariable: / zip://
-- Effects:  shellfs (setup host effects; patterns in shellfs.sql)
-- Checks:   tests/check.sql (dqtest — declarative invariants, run by `make check`,
--           over the same server/build.sql model; NOT in the serve path)
-- Optional: CLOSURE_API_KEY · CLOSURE_POSTGRES · CLOSURE_SAMPLE_ZIP + zip_pin.sql
--           CLOSURE_REMOTE_PROBE (https URL) warms cache_httpfs at boot

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
