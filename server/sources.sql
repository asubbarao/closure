-- sources.sql — star-first raw layer. NO MACROS. NO parse_filename.
--
-- THE NICE THING:
--   WITH raw AS (SELECT * FROM v_src_…),
--        shape AS (DESCRIBE SELECT * FROM raw),
--        profile AS (SUMMARIZE SELECT * FROM raw)
--   SELECT * FROM raw WHERE …
--
-- Filesystem = hostfs ONLY, and ONLY via the full scalar projection off ls:
--   path, file_name, file_extension, path_split, is_dir, is_file, path_type,
--   hsize(file_size), file_last_modified, absolute_path
-- Never file_name() alone on a random string (returns NULL if path missing).
-- Never path string-hacks. Never parse_filename (core basename tool — not hostfs).
--
-- JSON fields that happen to look like filenames (manifest.files[].filename)
-- are DATA, not paths — leave them alone; do not run hostfs on bare names.
--
-- Path bind rule: table functions reject subqueries. getenv CASE is a scalar.
-- See docs/DATA_MODEL.md. Ext semantics: ext_catalog_clean via quack :9494.

INSTALL hostfs FROM community; LOAD hostfs;

-- samples dir as typed filesystem rows (the inventory).
CREATE OR REPLACE VIEW v_src_samples_fs AS
SELECT
  path,
  file_name(path) AS name,
  file_extension(path) AS ext,
  path_split(path) AS segments,
  is_dir(path) AS is_dir,
  is_file(path) AS is_file,
  path_type(path) AS kind,
  hsize(file_size(path)) AS size,
  file_last_modified(path) AS modified,
  absolute_path(path) AS abs
FROM ls(
  CASE WHEN getenv('CLOSURE_SAMPLES_DIR') IS NOT NULL
        AND length(getenv('CLOSURE_SAMPLES_DIR')) > 0
       THEN getenv('CLOSURE_SAMPLES_DIR')
       ELSE 'samples' END
);

-- PDFs: hostfs inventory × pdf_info dimensions. Natural key = hostfs name (keeps .pdf).
CREATE OR REPLACE VIEW v_src_pdf_info AS
SELECT
  fs.name AS filename,
  fs.path AS source_path,
  fs.abs AS abs_path,
  fs.size AS size_h,
  fs.modified AS file_modified,
  p.* EXCLUDE (file) RENAME (
    width  AS width_pt,
    height AS height_pt
  )
FROM v_src_samples_fs fs
JOIN pdf_info(
  CASE WHEN getenv('CLOSURE_SAMPLES_DIR') IS NOT NULL
        AND length(getenv('CLOSURE_SAMPLES_DIR')) > 0
       THEN getenv('CLOSURE_SAMPLES_DIR')
       ELSE 'samples' END || '/*.pdf'
) p ON absolute_path(p.file) = fs.abs
WHERE fs.is_file
  AND fs.ext = '.pdf';

-- Manifest: star the file (nested files[] stays as the raw object).
CREATE OR REPLACE VIEW v_src_manifest AS
SELECT *
FROM read_json_auto(
  CASE WHEN getenv('CLOSURE_SAMPLES_DIR') IS NOT NULL
        AND length(getenv('CLOSURE_SAMPLES_DIR')) > 0
       THEN getenv('CLOSURE_SAMPLES_DIR')
       ELSE 'samples' END || '/manifest.json'
);

-- Flat file list: star each unnested file struct. filename is already a basename
-- string in the JSON (with .pdf) — not a host path. Do not hostfs it.
CREATE OR REPLACE VIEW v_src_manifest_files AS
SELECT f.*
FROM (
  SELECT unnest(files) AS f
  FROM v_src_manifest
);

-- Watchlist: star the operator feed.
CREATE OR REPLACE VIEW v_src_watchlist AS
SELECT *
FROM read_json_auto(
  CASE WHEN getenv('CLOSURE_SAMPLES_DIR') IS NOT NULL
        AND length(getenv('CLOSURE_SAMPLES_DIR')) > 0
       THEN getenv('CLOSURE_SAMPLES_DIR')
       ELSE 'samples' END || '/watchlist.json'
)
WHERE coalesce(trim(term::VARCHAR), '') <> '';

-- Decision changelog: star the JSON shards.
CREATE OR REPLACE VIEW v_src_decisions AS
SELECT *
FROM read_json_auto(
  CASE WHEN getenv('CLOSURE_EXPORTS_DIR') IS NOT NULL
        AND length(getenv('CLOSURE_EXPORTS_DIR')) > 0
       THEN getenv('CLOSURE_EXPORTS_DIR')
       ELSE 'exports' END || '/decisions/*.json',
  union_by_name := true,
  ignore_errors := false,
  filename := true
)
WHERE kind IS DISTINCT FROM 'sentinel';
