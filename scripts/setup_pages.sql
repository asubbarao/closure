-- setup_pages.sql — sample PDFs → pages/<stem>/pN.png
--
-- Knobs typed at entry (setup.sh). Defaults only if .read alone:
--   samples_dir, pages_dir, png_dpi, skip_png
--
-- Paths: scalarfs pins (pathvariable:) — not string-spliced into TVFs.
-- Discover: hostfs ls + path scalars.
-- Wipe: fixed relative product dir `pages` (matches server/app.sql). Never
--   interpolate a variable into rm -rf — that is the safety model.
--
-- Page rasters: pdf_write_page_images (pdf ≥ 0.7.7 / community 0.8.0) — one
-- TVF writes out_dir/<stem>/p{N}.png with bundled base-14 fonts. No per-page
-- pdf_to_png + COPY BLOB loop, no pdftoppm.

-- Typed defaults only when unset (no try_cast / cast soup).
SET VARIABLE samples_dir = coalesce(getvariable('samples_dir'), 'samples');
SET VARIABLE png_dpi     = coalesce(getvariable('png_dpi'), 100);
SET VARIABLE skip_png    = coalesce(getvariable('skip_png'), 0);
-- Product pin: wipe/write target is always relative `pages` (matches app.sql).
SET VARIABLE pages_dir = 'pages';

INSTALL hostfs FROM community; LOAD hostfs;
INSTALL shellfs FROM community; LOAD shellfs;
INSTALL scalarfs FROM community; LOAD scalarfs;
INSTALL pdf FROM community; LOAD pdf;

SELECT CASE
    WHEN getvariable('skip_png') = 1 THEN 'skip PNGs (skip_png=1)'
    ELSE format('page PNGs → {}/<stem>/pN.png (dpi={}, pdf_write_page_images)',
                getvariable('pages_dir'), getvariable('png_dpi'))
END AS step;

-- Typed sample PDF inventory (hostfs path scalars — never ends_with/LIKE)
CREATE OR REPLACE TEMP TABLE sample_pdfs AS
SELECT path,
       absolute_path(path) AS abs_path,
       file_name(path) AS name,
       parse_filename(path, true) AS stem
FROM ls(getvariable('samples_dir'))
WHERE is_file(path) IS TRUE AND file_extension(path) = '.pdf';

SELECT count(*)::BIGINT AS n_sample_pdfs FROM sample_pdfs;

-- scalarfs: path list is data; readers take the literal scheme pathvariable:…
COPY (
    SELECT abs_path FROM sample_pdfs ORDER BY path
) TO 'variable:sample_pdfs' (FORMAT variable, LIST scalar);

-- Wipe = fixed relative path only (no variable in rm -rf).
-- pdf_write_page_images creates pages/<stem>/ itself.
COPY (
    SELECT line
    FROM (
        SELECT ['rm -rf pages && mkdir -p pages'] AS cmds
    ) c,
    unnest(c.cmds) WITH ORDINALITY AS u(line, ord)
    WHERE getvariable('skip_png') = 0
    ORDER BY ord
) TO '| bash' (FORMAT CSV, HEADER false, QUOTE '', ESCAPE '');

-- One TVF: all samples → pages/<stem>/p{N}.png (bundled base-14 fonts).
CREATE OR REPLACE TEMP TABLE page_png_meta AS
SELECT parse_filename(file, true) AS stem,
       page,
       out_path,
       bytes::BIGINT AS nbytes
FROM pdf_write_page_images(
    'pathvariable:sample_pdfs',
    getvariable('pages_dir'),
    dpi := getvariable('png_dpi')::INTEGER
)
WHERE getvariable('skip_png') = 0;

SELECT * FROM (SUMMARIZE page_png_meta);

SELECT CASE
    WHEN getvariable('skip_png') = 1 THEN 'skip_png=1'
    WHEN count(*) = 0 THEN error('setup_pages: pdf_write_page_images returned 0 rows')
    WHEN min(nbytes) < 100 THEN error(format(
        'setup_pages: min PNG size {} bytes (< 100) — raster failed (fonts?)', min(nbytes)))
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
