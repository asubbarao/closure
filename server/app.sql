-- app.sql — composition root for Closure (database + HTTP + templates).
--
-- Run from repo root (preferred — set env, then):
--   DUCKDB_BIN="${DUCKDB_BIN:-$HOME/personal/quackapi/build/release/duckdb}"
--   rm -f closure.db closure.db.wal
--   "$DUCKDB_BIN" -unsigned closure.db -c ".read server/app.sql"
-- All knobs are env-overridable rows of app_config (server/config.sql):
--   CLOSURE_PORT / CLOSURE_STATIC_DIR / CLOSURE_SAMPLES_DIR / CLOSURE_EXPORTS_DIR
--   / CLOSURE_DECISIONS_GLOB / CLOSURE_QUACKAPI_EXT / CLOSURE_ACTOR
--
-- This file is ONLY the boot orchestration: extensions, config, module load
-- order, boot-integrity asserts, serve. Domain logic lives in sibling modules.
--
-- All derived tables are CREATE OR REPLACE CTAS — re-run is always clean.
-- No shellfs. No INSERT for setup. No cfg_* macros: app_config is the single
-- config relation; boot SETs variables FROM it and modules getvariable() them
-- (constant-foldable in table-function positions, unlike a subquery).
-- Export boxes are built LIVE at request time (no boot-baked macros).

-- ═══════════════════════════════════════════════════════════════════════════
-- Config relation (must load before anything that consumes it)
-- ═══════════════════════════════════════════════════════════════════════════

.read server/config.sql

-- ═══════════════════════════════════════════════════════════════════════════
-- Extensions + runtime config
-- ═══════════════════════════════════════════════════════════════════════════

-- Resource ceiling: DuckDB's stock max_temp_directory_size is "90% of available
-- disk space" — an unbounded query may legally fill the disk with spill files.
-- Cap it so a runaway query FAILS at the ceiling instead (not a timeout).
SET max_temp_directory_size = '8GB';

-- Extensions required by domain modules (must load before .read of modules that
-- use them — modules may re-INSTALL/LOAD idempotently).
INSTALL pdf FROM community;
LOAD pdf;
INSTALL tera FROM community;
LOAD tera;
INSTALL rapidfuzz FROM community;
LOAD rapidfuzz;
INSTALL crypto FROM community;
LOAD crypto;
INSTALL finetype FROM community;
LOAD finetype;
INSTALL us_address_standardizer FROM community;
LOAD us_address_standardizer;

-- quackapi presence gate. LOAD accepts only a string literal, so the extension
-- path cannot come from app_config here; instead the quackapi-built duckdb
-- binary carries the extension statically, and a generic binary preloads it
-- via the boot command (path from app_config key quackapi_ext / env):
--   "$DUCKDB_BIN" -unsigned closure.db -cmd "LOAD '$QUACKAPI_EXT';" -c ".read server/app.sql"
-- When neither holds this SELECT fails loudly at bind (quackapi_routes missing).
SELECT format('quackapi present — {} routes pre-registered', count(*)) AS quackapi_gate
FROM quackapi_routes();

-- Runtime headroom for pdf_redact + large review pages.
-- NOTE: quackapi_serve() forcibly re-SETs memory_limit TO '256MB' in
-- ApplyServeResourceGuards (see quackapi_extension.cpp). That is why OOM
-- errors report "~244.1 MiB used" — DuckDB's effective cap under 256MB after
-- internal reservations, NOT a httplib cap and NOT a per-connection limit.
-- memory_limit/max_memory are database-global buffer-pool settings; we raise
-- them again immediately after serve starts (below).
SET memory_limit = '4GB';
SET max_memory = '4GB';
SET threads = 4;

-- Config → variables: the ONE hop from the app_config relation to the
-- constant-foldable form table functions and serve args require. Modules
-- consume getvariable('…'); nothing re-reads env and nothing re-commits a
-- default — app_config stays the single source.
SET VARIABLE port        = (SELECT value FROM app_config WHERE key = 'port');
SET VARIABLE static_dir  = (SELECT value FROM app_config WHERE key = 'static_dir');
SET VARIABLE samples_dir = (SELECT value FROM app_config WHERE key = 'samples_dir');
SET VARIABLE exports_dir = (SELECT value FROM app_config WHERE key = 'exports_dir');

-- ═══════════════════════════════════════════════════════════════════════════
-- Working-dir bootstrap (decision log sentinel; empty glob would error)
-- ═══════════════════════════════════════════════════════════════════════════

-- COPY TO targets are grammar literals. Decision writes + reads both use
-- exports/decisions under the default layout (see sources.sql getenv fold).
-- Sentinel pins VARCHAR types for id columns (never INTEGER — that poisoned
-- read_json_auto inference for live UUID string ids).
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

-- ═══════════════════════════════════════════════════════════════════════════
-- Domain modules (order matters)
-- ═══════════════════════════════════════════════════════════════════════════

-- Durable id contract (docs), then sources, then load/detect.
.read server/ids.sql
-- Source files: pdf_info + decision log (changelog). Not "the orthogonal model."
.read server/sources.sql
.read server/ingest.sql
-- OCR / scan-status enrich (must run before detect so OCR words participate
-- in suggestion CTAS). See docs/scanned-docs.md.
.read server/pdf_io.sql
.read server/detect.sql
.read server/judge.sql
.read server/remainder_scan.sql

-- Boot integrity (P0-1): refuse hollow boots; print triad orphans first.
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

-- Chain-of-custody: ingest fingerprints + recheck/lineage views (after documents).
.read server/provenance.sql

-- Mount panel partials into host templates (markers in case.html / review.html).
-- History panel: inject before </body> + script (no host-template edit required).
-- Geo minimap: inject at GEO_MOUNT on case dashboard (script is inside geo_panel.html).
CREATE OR REPLACE TABLE app_templates AS
-- base also stamps the reviewer identity: templates commit the default actor
-- literal, swapped here for app_config.actor (CLOSURE_ACTOR) at load time.
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

-- Audit trail = the append-only decision log itself; its only projection
-- (v_audit) lives beside its consumers in routes/pages.sql.

-- PDF lifecycle: data/{source,working,export} layout + working-copy registry
.read server/pdf_store.sql

-- HTTP surface by resource
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
-- PDF lifecycle routes: plan is bind-safe; POST query($sql) matches export.
.read server/routes/store.sql

-- Export routes: live boxes at request time (no boot-baked export_sql_case_N).
.read server/routes/export.sql

-- Routes map: v_routes over quackapi_routes() + GET /api/routes (must be last
-- so every declaration above is already in the registry it introspects).
.read server/routes/meta.sql

-- ═══════════════════════════════════════════════════════════════════════════
-- Boot summary + serve
-- ═══════════════════════════════════════════════════════════════════════════

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

-- Serve args must be constant-foldable at bind (the binder rejects subqueries
-- in table functions); getvariable() folds, and the variables came from
-- app_config above.
FROM quackapi_serve(getvariable('port')::INTEGER, static_dir := getvariable('static_dir'));

-- Re-raise after quackapi's serve-time 256MB resource guard (must be AFTER serve).
SET memory_limit = '4GB';
SET max_memory = '4GB';

SELECT format(
           'Closure ready at http://127.0.0.1:{}/ — Ctrl-C to stop',
           (SELECT value FROM app_config WHERE key = 'port')
       ) AS status,
       current_setting('memory_limit') AS memory_limit,
       current_setting('max_memory') AS max_memory;
SELECT sleep_ms(86400000);
