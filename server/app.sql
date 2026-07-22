-- app.sql — whole backend (DuckDB + quackapi).
--
-- Path layers:
--   hostfs   unmat views (server/hostfs.sql) — discover with typed path scalars
--   scalarfs pin from those views → pathvariable: / variable: / to_scalarfs_uri
--   zipfs    when LE drops .zip: archive_contents + zip://…/member (v_zips may be empty)
--
-- Case pack (optional): SET sample_zip_path then .read server/zip_pin.sql

.read server/config.sql

SET memory_limit = '4GB';
SET max_temp_directory_size = '8GB';

.read server/extensions.sql

SET VARIABLE port        = (SELECT value FROM app_config WHERE key = 'port');
SET VARIABLE static_dir  = (SELECT value FROM app_config WHERE key = 'static_dir');
SET VARIABLE samples_dir = (SELECT value FROM app_config WHERE key = 'samples_dir');
SET VARIABLE exports_dir = (SELECT value FROM app_config WHERE key = 'exports_dir');
SET VARIABLE pages_dir   = 'pages';
SET VARIABLE templates_dir = 'server/templates';
SET VARIABLE detector_rules_path = 'server/config/detector_rules.json';
SET VARIABLE semantic_yaml_path  = 'server/config/closure_semantic.yaml';

-- Unmat hostfs surface (needs dir variables above)
.read server/hostfs.sql

-- Pin from v_hostfs → pathvariable: readers in core
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
    WHERE is_file(path) IS TRUE AND file_extension(path) = '.zip'
);

.read server/model.sql
.read server/routes.sql

SELECT format('Closure http://127.0.0.1:{}/', getvariable('port')) AS status;

FROM quackapi_serve(
    getvariable('port')::INTEGER,
    static_dir := getvariable('static_dir'),
    memory_limit := '4GB'
);
SELECT sleep_ms(86400000);
