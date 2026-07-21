-- load_templates.sql — HTML shells → app_templates, then declarative panel mounts.
--
-- Schema (easy to read on review day):
--   app_templates(name, content)  — full pages + panel partials after mount
--   ui_panel_mounts(host, marker, panel) — which panel HTML plugs into which page
--
-- History is not a marker: it injects before </body> + history.js on listed hosts.

CREATE OR REPLACE TABLE app_templates AS
SELECT
    regexp_replace(filename, '.*/', '') AS name,
    content
FROM read_text('server/templates/*.html');

-- Declarative mounts (one row = one string replace). Order is stable for recursion.
-- Markers must match template source exactly (including indent).
CREATE OR REPLACE TABLE ui_panel_mounts AS
SELECT * FROM (VALUES
    ('case.html',   '  <!-- PROVENANCE_MOUNT -->', 'provenance_panel.html'),
    ('case.html',   '  <!-- GEO_MOUNT -->',        'geo_panel.html'),
    ('review.html', '      <!-- TRIAGE_MOUNT -->', 'triage_funnel.html'),
    ('review.html', '      <!-- JUDGE_MOUNT -->',  'judge_panel.html'),
    ('review.html', '    <!-- REMAINDER_MOUNT -->', 'remainder_panel.html')
) AS t(host, marker, panel);

-- Stamp actor, apply mounts (recursive fold), inject history chrome.
CREATE OR REPLACE TABLE app_templates AS
WITH RECURSIVE
base AS (
    SELECT
        name,
        replace(
            content,
            'A. Subbarao',
            (SELECT value FROM app_config WHERE key = 'actor')
        ) AS content
    FROM app_templates
),
steps AS (
    SELECT
        host,
        marker,
        panel,
        row_number() OVER (ORDER BY host, marker) AS step_id
    FROM ui_panel_mounts
),
n_steps AS (
    SELECT coalesce(max(step_id), 0)::BIGINT AS n FROM steps
),
walk AS (
    SELECT 0::BIGINT AS step_id, name, content FROM base
    UNION ALL
    SELECT
        w.step_id + 1,
        w.name,
        CASE
            WHEN w.name = s.host THEN
                replace(
                    w.content,
                    s.marker,
                    coalesce(
                        p.content,
                        '<!-- ' || s.panel || ' missing -->'
                    )
                )
            ELSE w.content
        END
    FROM walk w
    JOIN steps s ON s.step_id = w.step_id + 1
    LEFT JOIN base p ON p.name = s.panel
    WHERE w.step_id < (SELECT n FROM n_steps)
),
mounted AS (
    SELECT name, content
    FROM walk
    WHERE step_id = (SELECT n FROM n_steps)
),
hist AS (
    SELECT
        coalesce(
            (SELECT content FROM base WHERE name = 'history_panel.html'),
            '<!-- history_panel.html missing -->'
        ) || chr(10) ||
        '<script src="/static/history.js"></script>' || chr(10) AS html
),
history_hosts AS (
    SELECT unnest([
        'case.html',
        'review.html',
        'bulk.html',
        'add_missed.html',
        'reject.html'
    ]) AS name
)
SELECT
    m.name,
    CASE
        WHEN h.name IS NOT NULL THEN
            replace(m.content, '</body>', (SELECT html FROM hist) || '</body>')
        ELSE m.content
    END AS content
FROM mounted m
LEFT JOIN history_hosts h ON h.name = m.name;

SELECT count(*) AS templates_loaded FROM app_templates;
SELECT count(*) AS panel_mounts FROM ui_panel_mounts;
