-- model.sql — store → hostfs (unmat) → core → views.
-- hostfs also loaded early in app.sql for path pins; CREATE OR REPLACE is idempotent.
-- No MATERIALIZED VIEW. File readers are unmat opens, not an architecture layer.

.read server/store.sql
.read server/hostfs.sql
.read server/shellfs.sql
.read server/core.sql
.read server/views.sql

SELECT 'model loaded' AS phase;
