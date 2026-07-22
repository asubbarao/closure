-- setup.sql — sample corpus (DuckDB spine, part 1).
-- Page PNGs: scripts/setup_pages.sql (same or follow-on session).
-- Entry: scripts/setup.sh
--
-- Knobs (SET VARIABLE before .read):
--   n_cases, docs_per_case, consolidated_pages, reuse_identities, samples_dir
--
-- Host effect via shellfs one-liner (no temp .sh, no bash for-loop).

SET VARIABLE n_cases = coalesce(try_cast(getvariable('n_cases') AS INTEGER), 4);
SET VARIABLE docs_per_case = coalesce(try_cast(getvariable('docs_per_case') AS INTEGER), 2);
SET VARIABLE consolidated_pages = coalesce(try_cast(getvariable('consolidated_pages') AS INTEGER), 110);
SET VARIABLE reuse_identities = coalesce(try_cast(getvariable('reuse_identities') AS INTEGER), 0);
SET VARIABLE samples_dir = coalesce(nullif(cast(getvariable('samples_dir') AS VARCHAR), ''), 'samples');

INSTALL shellfs FROM community; LOAD shellfs;
INSTALL fakeit FROM community; LOAD fakeit;
INSTALL pdf FROM community; LOAD pdf;

-- wipe top-level sample PDFs only (not samples/stress, messy, …)
SELECT content AS host_prep FROM read_text(format(
    'mkdir -p .tmp && rm -f {}/*.pdf |',
    getvariable('samples_dir')
));

.read samples/gen/corpus.sql
