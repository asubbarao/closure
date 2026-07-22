-- setup_pages.sql — pdf_page_images → pages/<stem>/pN.png (DuckDB spine, part 2).
--
-- Knobs: samples_dir, pages_dir, png_dpi, skip_png
-- pdf: already LOADed (community or PDF_EXTENSION)
--
-- Write path: COPY (FORMAT BLOB) per page (generated → .read, same session).
-- // hatch: shellfs for rm/mkdir only (COPY does not create parent dirs)
-- // hatch: per-page COPY script until pdf_write_page_images(glob, out_dir, dpi)
-- // hatch: community pdf may lack base-14 fonts → tiny blank PNGs; use
--          PDF_EXTENSION=… font-bundled build (setup.sh -unsigned). No pdftoppm.

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
SELECT
    file,
    page,
    png,
    parse_filename(file, true) AS stem
FROM pdf_page_images(
    getvariable('samples_dir') || '/*.pdf',
    dpi := CAST(getvariable('png_dpi') AS INTEGER)
)
WHERE getvariable('skip_png') = 0;

CREATE OR REPLACE TEMP TABLE page_png_stats AS
SELECT
    count(*)::BIGINT AS n_pages,
    count(DISTINCT stem)::BIGINT AS n_stems,
    min(octet_length(png))::BIGINT AS min_bytes,
    max(octet_length(png))::BIGINT AS max_bytes,
    sum(octet_length(png))::BIGINT AS total_bytes
FROM page_pngs;

SELECT * FROM page_png_stats;

SELECT CASE
    WHEN getvariable('skip_png') = 1 THEN 'skip_png=1'
    WHEN (SELECT n_pages FROM page_png_stats) = 0
        THEN error('setup_pages: pdf_page_images returned 0 rows')
    WHEN (SELECT min_bytes FROM page_png_stats) < 100
        THEN error(format(
            'setup_pages: min PNG size {} bytes (< 100) — raster failed',
            (SELECT min_bytes FROM page_png_stats)
        ))
    ELSE format(
        'setup_pages: {} pages / {} stems, {}–{} bytes/png',
        (SELECT n_pages FROM page_png_stats),
        (SELECT n_stems FROM page_png_stats),
        (SELECT min_bytes FROM page_png_stats),
        (SELECT max_bytes FROM page_png_stats)
    )
END AS page_png_ok;

-- mkdir parents via shellfs one-liner (set-based string_agg of stems — no bash for-loop)
SELECT content AS pages_mkdir FROM read_text(
    CASE WHEN getvariable('skip_png') = 1 THEN 'true |'
    ELSE format(
        'rm -rf {0} && mkdir -p {0} {1} |',
        format('''{}''', getvariable('pages_dir')),
        coalesce((
            SELECT string_agg(
                format('''{}/{}''', getvariable('pages_dir'), stem),
                ' ' ORDER BY stem
            )
            FROM (SELECT DISTINCT stem FROM page_pngs) s
        ), '')
    )
    END
);

-- Generate per-page COPY … (FORMAT BLOB); .read immediately (TEMP page_pngs live).
COPY (
    SELECT
        'COPY (SELECT png FROM page_pngs WHERE stem = ''' || stem || ''' AND page = ' ||
        page::VARCHAR || ') TO ''' || getvariable('pages_dir') || '/' || stem || '/p' ||
        page::VARCHAR || '.png'' (FORMAT BLOB);' AS stmt
    FROM page_pngs
    ORDER BY stem, page
) TO '.tmp/write_page_pngs.sql' (FORMAT CSV, HEADER false, QUOTE '', ESCAPE '');

.read .tmp/write_page_pngs.sql

SELECT
    'setup complete' AS status,
    (SELECT count(*) FROM glob(getvariable('samples_dir') || '/*.pdf')) AS pdfs,
    (SELECT n_pages FROM page_png_stats) AS pngs,
    (SELECT min_bytes FROM page_png_stats) AS min_png_bytes,
    getvariable('pages_dir') AS pages_dir;
