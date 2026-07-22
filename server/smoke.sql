-- smoke.sql — schema + product invariants (SQL checks, not a second type system).
-- Run after model load: .read server/smoke.sql
-- Prefer this / dqtest over TS typecheck for the data app.
--
-- Fails hard with error() if broken.

SELECT CASE
    WHEN (SELECT count(*) FROM duckdb_tables() WHERE table_name = 'decisions' AND NOT internal) = 0
    THEN error('smoke: decisions table missing')
    WHEN (SELECT count(*) FROM duckdb_tables() WHERE table_name = 'documents' AND NOT internal) = 0
    THEN error('smoke: documents table missing')
    WHEN (SELECT count(*) FROM duckdb_tables() WHERE table_name = 'suggestions' AND NOT internal) = 0
    THEN error('smoke: suggestions table missing')
    WHEN (SELECT count(*) FROM duckdb_views() WHERE view_name = 'v_suggestions') = 0
    THEN error('smoke: v_suggestions missing')
    WHEN (SELECT count(*) FROM duckdb_views() WHERE view_name = 'v_hostfs') = 0
    THEN error('smoke: v_hostfs missing')
    WHEN (SELECT count(*) FROM cases) = 0
    THEN error('smoke: no cases (manifest/samples empty?)')
    WHEN (SELECT count(*) FROM documents) = 0
    THEN error('smoke: no documents')
    WHEN (SELECT count(*) FROM words) = 0
    THEN error('smoke: no words (pdf extract failed?)')
    WHEN (SELECT count(*) FROM kind_rules) = 0
    THEN error('smoke: kind_rules empty')
    WHEN (SELECT getvariable('sample_pdfs') IS NULL
          OR len(getvariable('sample_pdfs')) = 0)
    THEN error('smoke: sample_pdfs pin empty')
    ELSE format(
        'smoke ok: {} cases, {} docs, {} words, {} suggestions, {} rules',
        (SELECT count(*) FROM cases),
        (SELECT count(*) FROM documents),
        (SELECT count(*) FROM words),
        (SELECT count(*) FROM suggestions),
        (SELECT count(*) FROM kind_rules)
    )
END AS smoke;

-- Export gate relation exists and is boolean-ish
SELECT CASE
    WHEN (SELECT count(*) FROM duckdb_views() WHERE view_name = 'v_export_blocked') = 0
    THEN error('smoke: v_export_blocked missing')
    ELSE 'smoke: export gate present'
END AS smoke_export;
