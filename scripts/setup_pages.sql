-- setup_pages.sql — pdf_page_images → pages/<stem>/pN.png
--
-- Knobs: samples_dir, pages_dir, png_dpi, skip_png
-- // hatch: per-page COPY BLOB until pdf_write_page_images(glob, out_dir, dpi)
-- // hatch: community pdf may lack base-14 fonts → small blank PNGs; PDF_EXTENSION= font build

SET VARIABLE samples_dir = coalesce(nullif(cast(getvariable('samples_dir') AS VARCHAR), ''), 'samples');
SET VARIABLE pages_dir = coalesce(nullif(cast(getvariable('pages_dir') AS VARCHAR), ''), 'pages');
SET VARIABLE png_dpi = coalesce(try_cast(getvariable('png_dpi') AS INTEGER), 100);
SET VARIABLE skip_png = coalesce(try_cast(getvariable('skip_png') AS INTEGER), 0);

INSTALL shellfs FROM community; LOAD shellfs;

SELECT CASE
    WHEN getvariable('skip_png') = 1 THEN 'skip PNGs (skip_png=1)'
    ELSE format('page PNGs → {}/ (dpi={}, pdf_page_images + COPY FORMAT BLOB)',
                getvariable('pages_dir'), getvariable('png_dpi'))
END AS step;

CREATE OR REPLACE TEMP TABLE page_pngs AS
SELECT file, page, png, parse_filename(file, true) AS stem
FROM pdf_page_images(
    getvariable('samples_dir') || '/*.pdf',
    dpi := CAST(getvariable('png_dpi') AS INTEGER)
)
WHERE getvariable('skip_png') = 0;

-- size grain only (no BLOB in SUMMARIZE)
CREATE OR REPLACE TEMP TABLE page_png_meta AS
SELECT stem, page, octet_length(png)::BIGINT AS nbytes FROM page_pngs;

SELECT * FROM (SUMMARIZE page_png_meta);

-- one-pass gate (aggs on the grain — no scalar subquery laundry)
SELECT CASE
    WHEN getvariable('skip_png') = 1 THEN 'skip_png=1'
    WHEN count(*) = 0 THEN error('setup_pages: pdf_page_images returned 0 rows')
    WHEN min(nbytes) < 100 THEN error(format(
        'setup_pages: min PNG size {} bytes (< 100) — raster failed', min(nbytes)))
    ELSE format('setup_pages: {} pages / {} stems, {}–{} bytes/png',
                count(*), count(DISTINCT stem), min(nbytes), max(nbytes))
END AS page_png_ok
FROM page_png_meta;

-- mkdir: pure shellfs string (dirs from samples/*.pdf — same stems as page_pngs).
-- No nested SELECT inside the TVF arg.
SELECT content AS pages_mkdir
FROM read_text(format(
    'rm -rf {0} && mkdir -p {0} && for f in {1}/*.pdf; do [ -f "$f" ] && mkdir -p {0}/$(basename "$f" .pdf); done |',
    format('''{}''', getvariable('pages_dir')),
    format('''{}''', getvariable('samples_dir'))
))
WHERE getvariable('skip_png') = 0;

-- per-page COPY BLOB script, then .read (TEMP page_pngs still live)
COPY (
    SELECT
        'COPY (SELECT png FROM page_pngs WHERE stem = ''' || stem || ''' AND page = ' ||
        page::VARCHAR || ') TO ''' || getvariable('pages_dir') || '/' || stem || '/p' ||
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
