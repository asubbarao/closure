-- postgres.sql — optional peer store. DuckDB remains the app; Postgres is ATTACH.
--
--   export CLOSURE_POSTGRES='dbname=foia host=127.0.0.1 user=…'
-- Unset → skip (local FOIA box).
--
-- Same SQL app can read/write pg.* when attached — FastAPI+Postgres without the middle tier.

INSTALL postgres; LOAD postgres;

SELECT * FROM query(
    CASE
        WHEN nullif(getenv('CLOSURE_POSTGRES'), '') IS NULL
        THEN 'SELECT ''postgres: skip (CLOSURE_POSTGRES unset)'' AS postgres_status'
        ELSE 'ATTACH ''' || replace(getenv('CLOSURE_POSTGRES'), '''', '''''')
             || ''' AS pg (TYPE POSTGRES);'
             || ' SELECT ''postgres: attached as pg'' AS postgres_status'
    END
);
