-- build.sql — model only (no HTTP). Paths: hostfs → scalarfs pins → core.

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
SET VARIABLE judges_path = 'server/config/judges.json';

.read server/hostfs.sql

-- Pack pins: manifest + watchlist + every PDF named in the pack + templates.
COPY (
    SELECT any_value(abs_path) FROM v_hostfs
    WHERE root = 'samples' AND is_file IS TRUE AND name = 'manifest.json'
) TO 'variable:manifest_path' (FORMAT variable);
COPY (
    SELECT any_value(abs_path) FROM v_hostfs
    WHERE root = 'samples' AND is_file IS TRUE AND name = 'watchlist.json'
) TO 'variable:watchlist_path' (FORMAT variable);
COPY (
    SELECT h.abs_path
    FROM v_hostfs h
    JOIN (
        SELECT fe.filename
        FROM (SELECT unnest(files) AS fe FROM read_json_auto(getvariable('manifest_path')))
        WHERE fe.filename IS NOT NULL
    ) man ON man.filename = h.name
    WHERE h.root = 'samples' AND h.is_file IS TRUE AND h.ext = '.pdf'
    ORDER BY h.path
) TO 'variable:sample_pdfs' (FORMAT variable, LIST scalar);
COPY (
    SELECT abs_path FROM v_hostfs
    WHERE root = 'templates' AND is_file IS TRUE AND ext = '.html' ORDER BY path
) TO 'variable:template_files' (FORMAT variable, LIST scalar);

.read server/model.sql
