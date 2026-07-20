-- Spike: ggsql for dashboard charts (status counts, series)
-- Requires DuckDB >= v1.5.4. Headless-friendly: suppress browser open.
-- Run:
--   GGSQL_NO_OPEN_BROWSER=1 duckdb -unsigned -markdown < spikes/ext-platform/02_ggsql.sql

INSTALL ggsql FROM community;
LOAD ggsql;

-- Output modes: silent | url | spec | html
SET ggsql_output = 'spec';

CREATE OR REPLACE VIEW series AS
SELECT i AS x, (i * i) AS y FROM range(10) t(i);

-- WORKS: numeric line chart — full series embedded in vega-lite JSON
SELECT json_array_length(
  json_extract(
    ggsql('SELECT * FROM series VISUALISE x, y DRAW line'),
    '$.data.values'
  )
) AS n_points_in_spec;  -- expect 10

SET ggsql_output = 'url';
SELECT ggsql('SELECT * FROM series VISUALISE x, y DRAW line') AS plot_url;
-- → http://127.0.0.1:<ephemeral>/#plot/<uuid>  (in-process HTTP, not quackapi)

SET ggsql_output = 'html';
SELECT length(ggsql('SELECT * FROM series VISUALISE x, y DRAW line')) AS html_bytes;
-- ~830KB self-contained HTML — too heavy as a per-request dashboard widget

-- DOES NOT WORK for Closure dashboard status bars:
-- categorical VISUALISE status, n DRAW bar collapses to a dummy count (n_rows),
-- not per-status n values.
SET ggsql_output = 'spec';
CREATE OR REPLACE VIEW dash_status AS
SELECT * FROM (VALUES
  ('accept', 42),
  ('reject', 11),
  ('pending', 27)
) t(status, n);

SELECT json_extract(
  ggsql('SELECT * FROM dash_status VISUALISE status, n DRAW bar'),
  '$.data'
) AS categorical_bar_data;
-- observed: single value with __ggsql_stat_dummy / count=3 — not a status bar chart
