-- routes.sql — compatibility aggregator (prefer server/app.sql for full boot).
-- Spine (sources/ingest/detect) + domain modules must already be loaded.

.read server/routes/pages.sql
.read server/routes/documents.sql
.read server/routes/suggestions.sql
.read server/routes/decisions.sql
.read server/routes/triage.sql
.read server/routes/history.sql
.read server/routes/search.sql
.read server/routes/remainder.sql
.read server/routes/judge.sql
.read server/routes/provenance.sql
.read server/routes/geo.sql
.read server/routes/store.sql
-- export.sql needs _export_macros.sql first (app.sql loads that before export).
.read server/routes/meta.sql
