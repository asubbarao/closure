-- server/raw/sources.sql — unmaterialized reads only. No casts. No filters.
-- Pin: exports/decisions/_schema.json (from server/decision.schema.json) keeps the
-- decisions glob non-empty on a fresh clone.

CREATE OR REPLACE VIEW v_raw_pdf_info AS
SELECT * FROM pdf_info(getvariable('samples_dir') || '/*.pdf');

CREATE OR REPLACE VIEW v_raw_pdf_pages AS
SELECT * FROM read_pdf(getvariable('samples_dir') || '/*.pdf');

CREATE OR REPLACE VIEW v_raw_pdf_words AS
SELECT * FROM read_pdf_words(getvariable('samples_dir') || '/*.pdf');

CREATE OR REPLACE VIEW v_raw_manifest AS
SELECT * FROM read_json_auto(getvariable('samples_dir') || '/manifest.json');

CREATE OR REPLACE VIEW v_raw_watchlist AS
SELECT * FROM read_json_auto(getvariable('samples_dir') || '/watchlist.json');

CREATE OR REPLACE VIEW v_raw_decisions AS
SELECT *
FROM read_json_auto(
    coalesce(nullif(getenv('CLOSURE_EXPORTS_DIR'), ''), 'exports') || '/decisions/*.json',
    union_by_name := true, filename := true
);
