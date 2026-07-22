-- app.sql — thin boot.
--   config → extensions → vars → model stack → routes → serve
-- From repo root: duckdb -unsigned closure.db  (see run.sh)

.read server/config.sql

SET memory_limit = '4GB';
SET max_temp_directory_size = '8GB';

.read server/extensions.sql

SET VARIABLE port        = (SELECT value FROM app_config WHERE key = 'port');
SET VARIABLE static_dir  = (SELECT value FROM app_config WHERE key = 'static_dir');
SET VARIABLE samples_dir = (SELECT value FROM app_config WHERE key = 'samples_dir');
SET VARIABLE exports_dir = (SELECT value FROM app_config WHERE key = 'exports_dir');

.read server/model.sql
.read server/routes.sql

SELECT CASE
    WHEN bool_or(estimated_size = 0)
    THEN error('boot integrity failed: empty ' ||
               string_agg(table_name, ',' ORDER BY table_name))
    ELSE 'boot ok'
END
FROM duckdb_tables()
WHERE table_name IN ('cases', 'documents', 'suggestions');

SELECT format('Closure http://127.0.0.1:{}/', getvariable('port')) AS status;

FROM quackapi_serve(
    getvariable('port')::INTEGER,
    static_dir := getvariable('static_dir'),
    memory_limit := '4GB'
);
SELECT sleep_ms(86400000);
