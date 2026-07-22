-- setup.sql — sample corpus (DuckDB spine, part 1).
-- Page PNGs: scripts/setup_pages.sql (same or follow-on session).
-- Entry: scripts/setup.sh — sets typed knobs before .read.
--
-- Knobs (already typed at entry; defaults only if unset):
--   n_cases, docs_per_case, consolidated_pages, reuse_identities, samples_dir
--
-- Host effect via shellfs one-liner (no temp .sh, no bash for-loop).

-- Typed defaults only when unset — no try_cast soup.
SET VARIABLE n_cases = coalesce(getvariable('n_cases'), 4);
SET VARIABLE docs_per_case = coalesce(getvariable('docs_per_case'), 2);
SET VARIABLE consolidated_pages = coalesce(getvariable('consolidated_pages'), 110);
SET VARIABLE reuse_identities = coalesce(getvariable('reuse_identities'), 0);
SET VARIABLE samples_dir = coalesce(getvariable('samples_dir'), 'samples');

INSTALL shellfs FROM community; LOAD shellfs;
INSTALL fakeit FROM community; LOAD fakeit;
INSTALL pdf FROM community; LOAD pdf;

-- wipe top-level sample PDFs only (not samples/stress, messy, …)
-- product default dir; rm -f (files) not rm -rf
SELECT content AS host_prep FROM read_text(
    printf('mkdir -p .tmp && rm -f %s/*.pdf |', getvariable('samples_dir'))
);

.read samples/gen/corpus.sql
