-- server/raw/sources.sql — unmaterialized reads only. No casts. No filters.
-- (Decisions aren't a source: they're a table this app writes — see store.sql.)

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
