-- hostfs.sql — unmaterialized host tree (re-reads every query).
-- Dir vars required: samples_dir, exports_dir, pages_dir, templates_dir.
--
--   SELECT * FROM v_hostfs WHERE root = 'samples' AND is_file IS TRUE AND ext = '.pdf';
--   SELECT * FROM v_zips;   -- LE case packs (often empty)

CREATE OR REPLACE VIEW v_hostfs AS
SELECT root, path,
       absolute_path(path) AS abs_path,
       file_name(path) AS name,
       file_extension(path) AS ext,
       path_type(path) AS path_type,
       path_exists(path) AS path_exists,
       is_dir(path) AS is_dir,
       is_file(path) AS is_file,
       path_split(path) AS parts,
       file_size(path) AS bytes,
       hsize(file_size(path)) AS size,
       file_last_modified(path) AS modified
FROM (
    SELECT 'samples' AS root, path FROM ls(getvariable('samples_dir'))
    UNION ALL BY NAME
    SELECT 'exports', path FROM ls(getvariable('exports_dir'))
    UNION ALL BY NAME
    SELECT 'pages', path FROM lsr(getvariable('pages_dir'), 2)
    UNION ALL BY NAME
    SELECT 'templates', path FROM ls(getvariable('templates_dir'))
);

-- LE packs on host; zipfs opens members. Empty is fine.
CREATE OR REPLACE VIEW v_zips AS
SELECT root, path AS zip_path, abs_path, name, size, bytes, modified, parts
FROM v_hostfs
WHERE is_file IS TRUE AND ext = '.zip';
