-- setup_pages.sql — sample PDFs → pages/<stem>/pN.png
--
-- Knobs typed at entry (setup.sh). Defaults only if .read alone:
--   samples_dir, pages_dir, png_dpi, skip_png
--
-- Paths: scalarfs pins (pathvariable:) — not string-spliced into TVFs.
-- Discover: hostfs ls + path scalars.
-- Wipe: fixed relative product dir `pages` (matches server/app.sql). Never
--   interpolate a variable into rm -rf — that is the safety model.
-- Effects: shellfs mkdir only (hostfs has no mkdir TVF).
--
-- // hatch: community pdf = scalar pdf_to_png(path, page, dpi); no batch writer
-- // hatch: community pdf may lack base-14 fonts → small blank PNGs

-- Typed defaults only when unset (no try_cast / cast soup).
SET VARIABLE samples_dir = coalesce(getvariable('samples_dir'), 'samples');
SET VARIABLE png_dpi     = coalesce(getvariable('png_dpi'), 100);
SET VARIABLE skip_png    = coalesce(getvariable('skip_png'), 0);
-- Product pin: wipe/write target is always relative `pages` (matches app.sql).
-- Never interpolate a variable into rm -rf.
SET VARIABLE pages_dir = 'pages';

INSTALL hostfs FROM community; LOAD hostfs;
INSTALL shellfs FROM community; LOAD shellfs;
INSTALL scalarfs FROM community; LOAD scalarfs;
INSTALL pdf FROM community; LOAD pdf;

SELECT CASE
    WHEN getvariable('skip_png') = 1 THEN 'skip PNGs (skip_png=1)'
    ELSE format('page PNGs → {}/ (dpi={}, hostfs + scalarfs pin + pdf_to_png)',
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

-- One row per page: read_pdf for page index, scalar pdf_to_png for raster.
CREATE OR REPLACE TEMP TABLE page_pngs AS
SELECT r.filename AS file,
       r.page,
       pdf_to_png(r.filename, r.page::INTEGER, getvariable('png_dpi')) AS png,
       parse_filename(r.filename, true) AS stem
FROM read_pdf('pathvariable:sample_pdfs') r
WHERE getvariable('skip_png') = 0;

CREATE OR REPLACE TEMP TABLE page_png_meta AS
SELECT stem, page, octet_length(png)::BIGINT AS nbytes FROM page_pngs;

SELECT * FROM (SUMMARIZE page_png_meta);

SELECT CASE
    WHEN getvariable('skip_png') = 1 THEN 'skip_png=1'
    WHEN count(*) = 0 THEN error('setup_pages: pdf_to_png returned 0 rows')
    WHEN min(nbytes) < 100 THEN error(format(
        'setup_pages: min PNG size {} bytes (< 100) — raster failed', min(nbytes)))
    ELSE format('setup_pages: {} pages / {} stems, {}–{} bytes/png',
                count(*), count(DISTINCT stem), min(nbytes), max(nbytes))
END AS page_png_ok
FROM page_png_meta;

-- Wipe = fixed relative path only (no variable in rm -rf). Then mkdir stems.
-- // hatch: hostfs has no mkdir TVF — shellfs for the effect.
COPY (
    SELECT line
    FROM (
        SELECT
            ['rm -rf pages && mkdir -p pages']
            || list(
                printf('mkdir -p pages/%s', stem)
                ORDER BY stem
            ) AS cmds
        FROM sample_pdfs
    ) c,
    unnest(c.cmds) WITH ORDINALITY AS u(line, ord)
    ORDER BY ord
) TO '.tmp/mkdir_pages.sh' (FORMAT CSV, HEADER false, QUOTE '', ESCAPE '');

SELECT content AS pages_mkdir
FROM read_text('bash .tmp/mkdir_pages.sh |')
WHERE getvariable('skip_png') = 0;

-- Per-page COPY BLOB under fixed product root pages/
COPY (
    SELECT
        'COPY (SELECT png FROM page_pngs WHERE stem = ''' || stem || ''' AND page = ' ||
        page::VARCHAR || ') TO ''pages/' || stem || '/p' ||
        page::VARCHAR || '.png'' (FORMAT BLOB);' AS stmt
    FROM page_pngs
    ORDER BY stem, page
) TO '.tmp/write_page_pngs.sql' (FORMAT CSV, HEADER false, QUOTE '', ESCAPE '');

.read .tmp/write_page_pngs.sql

SELECT 'setup complete' AS status,
       count(DISTINCT stem)::BIGINT AS stems,
       count(*)::BIGINT AS pngs,
       min(nbytes) AS min_png_bytes,
       getvariable('pages_dir') AS pages_dir
FROM page_png_meta;
