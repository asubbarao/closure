-- config.sql — ONE config relation; every knob derives from it.
--
-- CONFIGURATION IS A RELATION YOU QUERY. app_config(key, value, source) is the
-- single declarative surface. Each row obeys one env-override rule:
-- CLOSURE_<KEY> wins when set and non-empty, else the committed default.
--
-- Two consumption shapes (both derive from the same cfg_* macros — no drift):
--   * plain SQL (messages, template stamping) → scalar subquery on app_config
--   * table-function args / quackapi_serve()  → cfg_* macro. The getenv() CASE
--     folds to a constant at bind; scalar subqueries are rejected there
--     ("Binder Error: Table function cannot contain subqueries").
-- The macros are the wall-crossers for literal-only argument positions; each
-- default is written exactly once, in its macro. Loaded FIRST by app.sql.

-- NULL-retaining override rule: unset/empty env keeps the default; defaults
-- are never NULL, so config values are always concrete.
CREATE OR REPLACE MACRO cfg_env(env_name, dflt) AS
    CASE
        WHEN getenv(env_name) IS NOT NULL AND length(getenv(env_name)) > 0
        THEN getenv(env_name)
        ELSE dflt
    END;

CREATE OR REPLACE MACRO cfg_port()        AS cfg_env('CLOSURE_PORT', '8117');
CREATE OR REPLACE MACRO cfg_static_dir()  AS cfg_env('CLOSURE_STATIC_DIR', '.');
CREATE OR REPLACE MACRO cfg_samples_dir() AS cfg_env('CLOSURE_SAMPLES_DIR', 'samples');
CREATE OR REPLACE MACRO cfg_exports_dir() AS cfg_env('CLOSURE_EXPORTS_DIR', 'exports');

-- Read-side glob for the append-only decision log. COPY TO write targets are
-- grammar literals (no expressions) and stay on the default layout; overriding
-- this redirects READS only (e.g. replaying a copied log).
CREATE OR REPLACE MACRO cfg_decisions_glob() AS
    cfg_env('CLOSURE_DECISIONS_GLOB', cfg_exports_dir() || '/decisions/*.json');

-- Documented default for the boot wrapper only: LOAD accepts a string literal,
-- and the quackapi-built duckdb binary carries the extension statically —
-- app.sql never LOADs a hardcoded path (it asserts presence instead).
CREATE OR REPLACE MACRO cfg_quackapi_ext() AS
    cfg_env('CLOSURE_QUACKAPI_EXT',
            '/Users/aloksubbarao/personal/quackapi/build/release/extension/quackapi/quackapi.duckdb_extension');

-- 'Reviewing as' identity: stamped into templates at load (see app.sql mount).
CREATE OR REPLACE MACRO cfg_actor() AS cfg_env('CLOSURE_ACTOR', 'A. Subbarao');

-- The relation. Values call the macros above (single source of defaults);
-- source records which side of the override rule fired, per row.
CREATE OR REPLACE TABLE app_config AS
WITH resolved AS (
    SELECT unnest([
        {'key': 'port',           'value': cfg_port()},
        {'key': 'static_dir',     'value': cfg_static_dir()},
        {'key': 'samples_dir',    'value': cfg_samples_dir()},
        {'key': 'exports_dir',    'value': cfg_exports_dir()},
        {'key': 'decisions_glob', 'value': cfg_decisions_glob()},
        {'key': 'quackapi_ext',   'value': cfg_quackapi_ext()},
        {'key': 'actor',          'value': cfg_actor()}
    ], recursive := true)
)
SELECT
    key,
    value,
    CASE
        WHEN getenv('CLOSURE_' || upper(key)) IS NOT NULL
         AND length(getenv('CLOSURE_' || upper(key))) > 0
        THEN 'env'
        ELSE 'default'
    END AS source
FROM resolved;

SELECT 'app config' AS phase, key, value, source
FROM app_config
ORDER BY key;

-- Validation tail: refuse to boot toward a non-numeric port.
SELECT CASE
    WHEN try_cast((SELECT value FROM app_config WHERE key = 'port') AS INTEGER) IS NULL
    THEN error(format(
        'CLOSURE_PORT is not an integer: {}',
        (SELECT value FROM app_config WHERE key = 'port')
    ))
    ELSE format('config ok — port {}', (SELECT value FROM app_config WHERE key = 'port'))
END AS config_gate;
