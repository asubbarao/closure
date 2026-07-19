-- load_templates.sql — pull server/templates/*.html into app_templates.
DELETE FROM app_templates;
INSERT INTO app_templates (name, content)
SELECT regexp_replace(filename, '.*/', ''), content
FROM read_text('server/templates/*.html');
SELECT count(*) AS templates_loaded FROM app_templates;
