-- config.sql — app_config(key, value, source). CLOSURE_<KEY> env overrides default.

CREATE OR REPLACE TABLE app_config AS
SELECT key,
       coalesce(nullif(getenv('CLOSURE_' || upper(key)), ''), dflt) AS value,
       CASE WHEN nullif(getenv('CLOSURE_' || upper(key)), '') IS NOT NULL
            THEN 'env' ELSE 'default' END AS source
FROM (VALUES
    ('port', '8117'),
    ('static_dir', '.'),
    ('samples_dir', 'samples'),
    ('exports_dir', 'exports'),
    ('actor', coalesce(nullif(getenv('USER'), ''), 'reviewer'))
    -- tera template_path is a binder constant in routes/views
    -- (not app_config): 'server/templates/**/*.html'
) AS t(key, dflt);

SELECT CASE
    WHEN try_cast((SELECT value FROM app_config WHERE key = 'port') AS INTEGER) IS NULL
    THEN error('CLOSURE_PORT not an integer')
    ELSE 'config ok'
END AS config_gate;
