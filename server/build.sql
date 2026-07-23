-- build.sql — construct the model. No HTTP.
--
-- This is the product: raw files → typed views → domain tables. app.sql reads
-- this then serves it over quackapi; tests/check.sql reads this then asserts on
-- it. Someone swapping quackapi for FastAPI+Postgres reuses THIS unchanged — the
-- server is a face over the model, not the model itself.
--
-- Paths:  hostfs discovers on the machine → COPY … TO 'variable:' pins the paths
--         → core.sql reads pathvariable:/zip:// . scalarfs/zipfs stay in-process.

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
