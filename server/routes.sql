-- routes.sql — compatibility aggregator (prefer server/app.sql for full boot).
--
-- The monolith was split into server/routes/*.sql + server/pdf_io.sql.
-- This shim keeps `.read server/routes.sql` (e.g. run.sh) working for the
-- HTTP surface. Full boot still needs app.sql for export macro codegen + serve.
--
-- Load order: pdf_io → resource routes. export.sql is included last; without
-- prior export_sql_case_N() macros, export_case_live CREATE may fail — app.sql
-- loads export.sql only after regenerating those macros.

-- config first: routes/decisions.sql consumes cfg_decisions_glob().
.read server/config.sql
.read server/pdf_io.sql
.read server/routes/pages.sql
.read server/routes/documents.sql
.read server/routes/suggestions.sql
.read server/routes/decisions.sql
.read server/routes/search.sql
.read server/routes/meta.sql
-- export.sql intentionally omitted here: requires _export_macros.sql first.
-- app.sql loads it after codegen.
