-- load_templates.sql — server/templates/*.html → app_templates (pure CTAS).
CREATE OR REPLACE TABLE app_templates AS
SELECT
    regexp_replace(filename, '.*/', '') AS name,
    content
FROM read_text('server/templates/*.html');

SELECT count(*) AS templates_loaded FROM app_templates;
