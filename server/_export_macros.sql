-- _export_macros.sql — RETIRED (P0-2).
--
-- Previously held boot-baked export_sql_case_N() macros with empty box
-- arrays that never refreshed mid-session. Export now builds pdf_redact
-- SQL LIVE from accepted suggestions via build_export_sql(cid) in
-- server/pdf_io.sql, invoked by export_case_live in routes/export.sql.
--
-- This file is kept as a no-op so any stale .read does not fail boot.
SELECT 'export macros retired — live build_export_sql at request time' AS note;
