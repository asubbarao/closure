-- app.sql — composition root (extensions, config, module load, serve).
-- From repo root: duckdb -unsigned closure.db -c ".read server/app.sql"
-- Knobs: app_config / CLOSURE_* env (see server/config.sql).

.read server/config.sql

SET max_temp_directory_size = '8GB';

INSTALL pdf FROM community; LOAD pdf;
INSTALL tera FROM community; LOAD tera;
INSTALL rapidfuzz FROM community; LOAD rapidfuzz;
INSTALL crypto FROM community; LOAD crypto;
INSTALL finetype FROM community; LOAD finetype;
INSTALL us_address_standardizer FROM community; LOAD us_address_standardizer;

-- quackapi-built duckdb carries the extension; fails if routes missing.
SELECT format('quackapi present — {} routes pre-registered', count(*)) AS quackapi_gate
FROM quackapi_routes();

-- quackapi_serve re-sets memory to 256MB; re-raise after serve below.
SET memory_limit = '4GB';
SET max_memory = '4GB';
SET threads = 4;

SET VARIABLE port        = (SELECT value FROM app_config WHERE key = 'port');
SET VARIABLE static_dir  = (SELECT value FROM app_config WHERE key = 'static_dir');
SET VARIABLE samples_dir = (SELECT value FROM app_config WHERE key = 'samples_dir');
SET VARIABLE exports_dir = (SELECT value FROM app_config WHERE key = 'exports_dir');

-- Decision-log sentinel pins VARCHAR id types for read_json_auto.
COPY (
    SELECT
        'sentinel' AS kind,
        NULL::VARCHAR AS suggestion_id,
        NULL::VARCHAR AS status,
        NULL::VARCHAR AS actor,
        NULL::VARCHAR AS reason,
        NULL::VARCHAR AS ts,
        NULL::VARCHAR AS document_id,
        NULL::INTEGER AS page_no,
        NULL::DOUBLE AS x0,
        NULL::DOUBLE AS y0,
        NULL::DOUBLE AS x1,
        NULL::DOUBLE AS y1,
        NULL::VARCHAR AS text,
        NULL::VARCHAR AS context,
        NULL::INTEGER AS confidence,
        NULL::VARCHAR AS flag_tag,
        NULL::VARCHAR AS source,
        NULL::VARCHAR AS entity_id,
        NULL::VARCHAR AS case_id,
        NULL::VARCHAR AS batch_id,
        NULL::VARCHAR AS batch_label,
        NULL::VARCHAR AS undoes_batch_id
) TO 'exports/decisions/_sentinel.json' (FORMAT JSON, ARRAY false);

-- Domain modules (order matters).
.read server/ids.sql
.read server/sources.sql
.read server/ingest.sql
.read server/pdf_io.sql
.read server/detect.sql
.read server/judge.sql
.read server/remainder_scan.sql

SELECT 'boot orphan diagnostics' AS phase, *
FROM v_ingest_orphans
ORDER BY kind, name;

SELECT CASE
    WHEN (SELECT count(*) FROM documents) = 0
      OR (SELECT count(*) FROM suggestions) = 0
    THEN error(
        'boot integrity failed: documents=' ||
        (SELECT count(*) FROM documents) ||
        ' suggestions=' ||
        (SELECT count(*) FROM suggestions) ||
        ' cases=' ||
        (SELECT count(*) FROM cases) ||
        ' — sample triad desync (manifest.json × identities.json case_no × samples/*.pdf). ' ||
        'orphans: ' ||
        coalesce(
            (SELECT string_agg(kind || ':' || name, ', ' ORDER BY kind, name)
             FROM v_ingest_orphans),
            '(none listed)'
        )
    )
    ELSE 'boot integrity ok'
END AS boot_integrity;

.read server/load_templates.sql
.read server/provenance.sql

-- Mount panel partials; stamp CLOSURE_ACTOR into template default actor literal.
CREATE OR REPLACE TABLE app_templates AS
WITH base AS (
    SELECT
        name,
        replace(content, 'A. Subbarao', (SELECT value FROM app_config WHERE key = 'actor')) AS content
    FROM app_templates
),
prov AS (
    SELECT content FROM base WHERE name = 'provenance_panel.html'
),
geo AS (
    SELECT content FROM base WHERE name = 'geo_panel.html'
),
judge AS (
    SELECT content FROM base WHERE name = 'judge_panel.html'
),
remainder AS (
    SELECT content FROM base WHERE name = 'remainder_panel.html'
),
triage AS (
    SELECT content FROM base WHERE name = 'triage_funnel.html'
),
hist AS (
    SELECT content FROM base WHERE name = 'history_panel.html'
),
hist_mount AS (
    SELECT
        coalesce((SELECT content FROM hist), '<!-- history_panel.html missing -->') ||
        chr(10) || '<script src="/static/history.js"></script>' || chr(10) AS html
)
SELECT
    b.name,
    CASE
        WHEN b.name = 'case.html' THEN
            replace(
                replace(
                    replace(
                        b.content,
                        '<!-- PROVENANCE_MOUNT -->',
                        coalesce((SELECT content FROM prov), '<!-- PROVENANCE_MOUNT missing -->')
                    ),
                    '<!-- GEO_MOUNT -->',
                    coalesce((SELECT content FROM geo), '<!-- GEO_MOUNT missing -->')
                ),
                '</body>',
                (SELECT html FROM hist_mount) || '</body>'
            )
        WHEN b.name = 'review.html' THEN
            replace(
                replace(
                    replace(
                        replace(
                            b.content,
                            '<!-- TRIAGE_MOUNT -->',
                            coalesce((SELECT content FROM triage), '<!-- TRIAGE_MOUNT missing -->')
                        ),
                        '<!-- JUDGE_MOUNT -->',
                        coalesce((SELECT content FROM judge), '<!-- JUDGE_MOUNT missing -->')
                    ),
                    '<!-- REMAINDER_MOUNT -->',
                    coalesce((SELECT content FROM remainder), '<!-- REMAINDER_MOUNT missing -->')
                ),
                '</body>',
                (SELECT html FROM hist_mount) || '</body>'
            )
        -- Decision shells owned by UX polish: surface History / undo entry point
        WHEN b.name IN ('bulk.html', 'add_missed.html', 'reject.html') THEN
            replace(
                b.content,
                '</body>',
                (SELECT html FROM hist_mount) || '</body>'
            )
        ELSE b.content
    END AS content
FROM base b;

.read server/pdf_store.sql
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
.read server/routes/export.sql
.read server/routes/meta.sql

SELECT 'boot summary' AS phase,
       (SELECT count(*) FROM cases) AS cases,
       (SELECT count(*) FROM documents) AS documents,
       (SELECT count(*) FROM words) AS words,
       (SELECT count(*) FROM entities) AS entities,
       (SELECT count(*) FROM suggestions) AS suggestions,
       (SELECT count(*) FROM v_routes) AS routes;

SELECT d.filename, count(s.id) AS suggestions
FROM documents d
LEFT JOIN suggestions s ON s.document_id = d.id
GROUP BY d.filename
ORDER BY d.filename;

FROM quackapi_serve(getvariable('port')::INTEGER, static_dir := getvariable('static_dir'));

SET memory_limit = '4GB';
SET max_memory = '4GB';

SELECT format(
           'Closure ready at http://127.0.0.1:{}/ — Ctrl-C to stop',
           (SELECT value FROM app_config WHERE key = 'port')
       ) AS status,
       current_setting('memory_limit') AS memory_limit,
       current_setting('max_memory') AS max_memory;
SELECT sleep_ms(86400000);
