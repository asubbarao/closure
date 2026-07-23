-- court.sql — real public court filings, as a relation.
--
-- There is no fetch script. DuckDB is the HTTP client (httpfs read_blob), the
-- checksum (sha256), and the writer — the same three jobs a curl|shasum|jq
-- pipeline would need three tools and a bash loop to do. The source list below
-- IS the data; everything after it is set-based.
--
-- The docket grouping is DECLARED here: we chose these files and already know
-- which matter each belongs to (both Google filings share 1:20-cv-03010).
-- Nothing downstream re-derives it from document text — same rule as _cases in
-- corpus.sql, where case_no is assigned once and carried as a column.
--
-- Opt-in: COURT_DOCS=1 make setup. These carry NO watchlist entries, on
-- purpose. A published opinion has no known-PII list, which is the real cold
-- start a reviewer faces: shape detectors and finetype fire, name matching has
-- nothing seeded, and the missed-redaction queue is what covers the gap.

INSTALL httpfs; LOAD httpfs;

CREATE OR REPLACE TEMP TABLE _court_sources AS
SELECT * FROM (VALUES
    ('court_scotus_galette_v_nj_transit.pdf', '24-1021',
     '9982ca223713d263c2128a81e61fcf7bfe54576a8416affa8f1c92bbdd8d4659',
     'https://www.supremecourt.gov/opinions/25pdf/24-1021_p860.pdf'),
    ('court_scotus_pung_v_isabella_county.pdf', '25-95',
     'd4db4fb7164892957fbf17b98860148e82ee4cbd4269a4a8b283c366dbdd271c',
     'https://www.supremecourt.gov/opinions/25pdf/25-95_dc8e.pdf'),
    ('court_scotus_trump_v_barbara.pdf', '25-365',
     'dccc4217c8590e0768c2af4c3563accb0d51eb0daad73bc61b989bda3ac79b8b',
     'https://www.supremecourt.gov/opinions/25pdf/25-365_4hdj.pdf'),
    ('court_doj_us_v_google_complaint.pdf', '1-20-cv-03010',
     'e9d06d227e14aff439055b55cffe8e721ce3268ab88333c705a998dc0a66db6e',
     'https://www.justice.gov/opa/press-release/file/1328941/download'),
    ('court_doj_us_v_google_sj_opinion.pdf', '1-20-cv-03010',
     'f03a07f08175f4c1f64a047080d702fa4a2bbc89fb47badcafc9901c084a285f',
     'https://www.justice.gov/d9/2023-10/416980.pdf')
) AS t(filename, case_no, want_sha256, url);

-- read_blob takes a path LIST, so the whole set is one scan. A checksum
-- mismatch is a row that fails `verified`, not a file that reaches the corpus.
SET VARIABLE court_urls = (SELECT list(url) FROM _court_sources);

CREATE OR REPLACE TEMP TABLE _court_blobs AS
SELECT s.filename, s.case_no, b.content,
       lower(sha256(b.content)) = lower(s.want_sha256) AS verified
FROM read_blob(getvariable('court_urls')) b
JOIN _court_sources s ON s.url = b.filename;

-- Gate as a relation of failures: error() fires per mismatched checksum, and an
-- empty failure set raises nothing. No count(*) FILTER, no CASE ladder.
SELECT error(format('court.sql: {} failed checksum (got {})', filename,
             lower(sha256(content)))) AS court_fetch
FROM _court_blobs WHERE NOT verified;

SELECT format('court: {} filings verified', count(*)) AS court_fetch
FROM _court_blobs WHERE verified;

-- // hatch: no batch blob writer — one COPY per file. The statements are
-- generated from the relation, not hand-written per document.
COPY (
    SELECT format(
        'COPY (SELECT content FROM _court_blobs WHERE filename = {0}{1}{0}) '
        'TO {0}{2}/{1}{0} (FORMAT BLOB);',
        chr(39), filename, getvariable('samples_dir'))
    FROM _court_blobs WHERE verified ORDER BY filename
) TO '.tmp/write_court.sql' (FORMAT CSV, HEADER false, QUOTE '', ESCAPE '');

.read .tmp/write_court.sql

-- corpus.sql unions this into manifest.json. Same session, so there is no
-- intermediate JSON file to write and read back.
CREATE OR REPLACE TEMP TABLE _court AS
SELECT filename, case_no FROM _court_blobs WHERE verified;
