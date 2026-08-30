-- setup_pages.sql — sample PDFs → pages/<stem>/pN.png
--
-- setup creates files under pages/<stem>/ where stem = basename without .pdf.
-- App serves /pages/<stem>/pN.png (parse_filename(filename, true) in v_page_nav).
--
-- Raster: host pdftoppm (poppler) — community pdf_page_images often emits blank
-- tiles when base-14 fonts are missing on the box. Same stem layout either way.

SET VARIABLE samples_dir = coalesce(getvariable('samples_dir'), 'samples');
SET VARIABLE png_dpi     = coalesce(getvariable('png_dpi'), 100);
SET VARIABLE skip_png    = coalesce(getvariable('skip_png'), 0);
SET VARIABLE pages_dir   = 'pages';

INSTALL hostfs FROM community; LOAD hostfs;
INSTALL shellfs FROM community; LOAD shellfs;

SELECT CASE
    WHEN getvariable('skip_png') = 1 THEN 'skip PNGs (skip_png=1)'
    ELSE format('page PNGs → {}/<stem>/pN.png (dpi={}, pdftoppm)',
                getvariable('pages_dir'), getvariable('png_dpi'))
END AS step;

CREATE OR REPLACE TEMP TABLE sample_pdfs AS
SELECT path,
       absolute_path(path) AS abs_path,
       file_name(path) AS name,
       parse_filename(path, true) AS stem
FROM ls(getvariable('samples_dir'))
WHERE is_file(path) IS TRUE AND file_extension(path) = '.pdf';

SELECT count(*)::BIGINT AS n_sample_pdfs FROM sample_pdfs;

-- Wipe fixed product dir only (no variable in rm -rf).
COPY (
    SELECT line FROM (
        SELECT ['rm -rf pages && mkdir -p pages'] AS cmds
    ) c, unnest(c.cmds) AS u(line)
    WHERE getvariable('skip_png') = 0
) TO '| bash' (FORMAT CSV, HEADER false, QUOTE '', ESCAPE '');

-- One pdftoppm per sample; rename p-001.png / p-1.png → p1.png (product URL).
COPY (
    SELECT format(
        'mkdir -p pages/{0} && pdftoppm -png -r {1} {2} pages/{0}/p && '
        || 'for f in pages/{0}/p-*.png pages/{0}/p*.png; do '
        || '[ -f "$f" ] || continue; '
        || 'base=$(basename "$f" .png); '
        || 'n=$(echo "$base" | sed -E "s/^p-?0*//"); '
        || '[ -z "$n" ] && n=0; '
        || 'mv "$f" pages/{0}/p${{n}}.png; '
        || 'done',
        stem, getvariable('png_dpi')::INTEGER, abs_path)
    FROM sample_pdfs
    WHERE getvariable('skip_png') = 0
    ORDER BY path
) TO '| bash' (FORMAT CSV, HEADER false, QUOTE '', ESCAPE '');

CREATE OR REPLACE TEMP TABLE page_png_meta AS
SELECT parse_filename(path, true) AS stem,
       try_cast(replace(file_name(path), '.png', '') AS INTEGER) AS page,
       path AS out_path,
       file_size(path)::BIGINT AS nbytes
FROM lsr('pages', 2)
WHERE is_file(path) IS TRUE AND file_extension(path) = '.png'
  AND getvariable('skip_png') = 0;

SELECT CASE
    WHEN getvariable('skip_png') = 1 THEN 'skip_png=1'
    WHEN count(*) = 0 THEN error('setup_pages: no PNGs under pages/')
    WHEN min(nbytes) < 1000 THEN error(format(
        'setup_pages: min PNG size {} bytes — still blank (pdftoppm/fonts?)', min(nbytes)))
    ELSE format('setup_pages: {} pages / {} stems, {}–{} bytes/png',
                count(*), count(DISTINCT stem), min(nbytes), max(nbytes))
END AS page_png_ok
FROM page_png_meta;

SELECT 'setup complete' AS status,
       count(DISTINCT stem)::BIGINT AS stems,
       count(*)::BIGINT AS pngs,
       min(nbytes) AS min_png_bytes,
       getvariable('pages_dir') AS pages_dir
FROM page_png_meta;
