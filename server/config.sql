-- config.sql — ONE config relation; every knob derives from it.
--
-- CONFIGURATION IS A RELATION YOU QUERY. app_config(key, value, source) is the
-- single declarative surface. Each row obeys one env-override rule:
-- CLOSURE_<KEY> wins when set and non-empty, else the committed default.
--
-- NO MACROS. Two consumption shapes:
--   * plain SQL (messages, template stamping) → scalar subquery on app_config
--   * table-function args / quackapi_serve()  → those positions reject
--     subqueries at bind ("Table function cannot contain subqueries"), so each
--     such call site inlines the same bare CASE getenv('CLOSURE_<KEY>') … END,
--     which folds to a constant. The default literal is therefore committed
--     twice — once here (the record) and once at the fold-only call site (the
--     wire); grep CLOSURE_ to see every pair.

CREATE OR REPLACE TABLE app_config AS
WITH defaults AS (
    SELECT unnest([
        {'key': 'port',        'dflt': '8117'},
        {'key': 'static_dir',  'dflt': '.'},
        {'key': 'samples_dir', 'dflt': 'samples'},
        {'key': 'exports_dir', 'dflt': 'exports'},
        -- Read-side glob for the append-only decision log. COPY TO write
        -- targets are grammar literals (no expressions) and stay on the
        -- default layout; this follows an overridden exports_dir unless
        -- overridden itself.
        {'key': 'decisions_glob',
         'dflt': CASE WHEN getenv('CLOSURE_EXPORTS_DIR') IS NOT NULL
                       AND length(getenv('CLOSURE_EXPORTS_DIR')) > 0
                      THEN getenv('CLOSURE_EXPORTS_DIR') || '/decisions/*.json'
                      ELSE 'exports/decisions/*.json'
                 END},
        -- Documented default for the boot wrapper only: the quackapi-built
        -- duckdb binary carries the extension statically; app.sql asserts
        -- presence instead of LOADing a hardcoded path. Default assumes the
        -- sibling-checkout layout (../quackapi next to this repo); run.sh
        -- resolves and exports the absolute path via CLOSURE_QUACKAPI_EXT.
        {'key': 'quackapi_ext',
         'dflt': '../quackapi/build/release/extension/quackapi/quackapi.duckdb_extension'},
        -- 'Reviewing as' identity, stamped into templates at load (app.sql
        -- mount replaces __ACTOR__ / __ACTOR_INITIALS__). No user login —
        -- the OS user is the reviewer unless CLOSURE_ACTOR says otherwise.
        {'key': 'actor',
         'dflt': CASE WHEN getenv('USER') IS NOT NULL
                       AND length(getenv('USER')) > 0
                      THEN getenv('USER')
                      ELSE 'reviewer'
                 END}
    ], recursive := true)
)
SELECT
    key,
    CASE WHEN getenv('CLOSURE_' || upper(key)) IS NOT NULL
          AND length(getenv('CLOSURE_' || upper(key))) > 0
         THEN getenv('CLOSURE_' || upper(key))
         ELSE dflt
    END AS value,
    CASE WHEN getenv('CLOSURE_' || upper(key)) IS NOT NULL
          AND length(getenv('CLOSURE_' || upper(key))) > 0
         THEN 'env'
         ELSE 'default'
    END AS source
FROM defaults;

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
