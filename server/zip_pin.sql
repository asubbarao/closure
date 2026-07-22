-- zip_pin.sql — LE case pack: re-pin sample_* from a host .zip via zipfs.
-- Prerequisite: sample_zip_path is a real file (hostfs is_file + file_extension = .zip).
--   SET VARIABLE sample_zip_path = 'uploads/case_2024.zip';  -- or CLOSURE_SAMPLE_ZIP
--   .read server/zip_pin.sql
-- Members become zip://archive/member — pdf_info / read_json / … work on those URIs.
-- Creating zips is shellfs (zip CLI), not zipfs (read-only).

-- archive TOC names are not host paths (hostfs file_extension/file_name → NULL).
-- path_split works as structure; last part is the member base name.
COPY (
    SELECT 'zip://' || getvariable('sample_zip_path') || '/' || file_name AS path
    FROM archive_contents(getvariable('sample_zip_path'))
    WHERE ends_with(list_last(path_split(file_name)), '.pdf')  -- member name (not host path)
    ORDER BY path
) TO 'variable:sample_pdfs' (FORMAT variable, LIST scalar);

COPY (
    SELECT any_value('zip://' || getvariable('sample_zip_path') || '/' || file_name)
    FROM archive_contents(getvariable('sample_zip_path'))
    WHERE list_last(path_split(file_name)) = 'manifest.json'
) TO 'variable:manifest_path' (FORMAT variable);

COPY (
    SELECT any_value('zip://' || getvariable('sample_zip_path') || '/' || file_name)
    FROM archive_contents(getvariable('sample_zip_path'))
    WHERE list_last(path_split(file_name)) = 'watchlist.json'
) TO 'variable:watchlist_path' (FORMAT variable);

SELECT getvariable('sample_zip_path') AS sample_zip,
       len(getvariable('sample_pdfs')) AS pdfs_from_zip;
