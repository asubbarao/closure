-- 01_identities.sql — pure DuckDB sample-corpus generator for Closure (stage 1: cast).
--
-- Stack (hard rules): DuckDB + community fakeit + community pdf.
-- No Python, no Typst. Invoked only via scripts/generate-samples.sh
-- (which .reads this, then optionally reuse_identities.sql, then 02_corpus.sql).
--
-- Parameters (SET VARIABLE … before .read, or defaults below):
--   n_cases              INT   number of synthetic cases          (default 4)
--   docs_per_case        INT   folder documents per case          (default 2)
--   consolidated_pages   INT   target pages for case-1 consol.    (default 110; 0=skip)
--   reuse_identities     INT   1 = keep samples/identities.json   (default 0)
--   samples_dir          TEXT  output directory                   (default 'samples')
--
-- Writes (via 02_corpus.sql after this stage + optional reuse overlay):
--   {samples_dir}/identities.json   answer-key cast (ingest.sql / seed.sql schema)
--   {samples_dir}/watchlist.json    flat operator watchlist (term/kind/case_no)
--   {samples_dir}/manifest.json     per-PDF ground truth
--   {samples_dir}/*.pdf             police-report narratives (write_pdf)
--   {samples_dir}/messy/*           edge-case PDFs + messy/manifest.json
--
-- FN plants (variant-form PII) and surname FP bait emerge from the roster +
-- rotating _fn_modes — no answer-key file is read at runtime by the app.
-- Does NOT touch samples/stress/ or server/.

INSTALL fakeit FROM community;
INSTALL pdf FROM community;
LOAD fakeit;
LOAD pdf;

-- ── defaults when variables are unset ──────────────────────────────────────
-- Materialize config; also re-export samples_dir as a session variable so table
-- functions (read_pdf_words / pdf_info / write_pdf paths) can use getvariable()
-- — DuckDB rejects subqueries inside table-function arguments.
CREATE OR REPLACE TEMP TABLE _cfg AS
SELECT
    coalesce(try_cast(getvariable('n_cases') AS INTEGER), 4) AS n_cases,
    coalesce(try_cast(getvariable('docs_per_case') AS INTEGER), 2) AS docs_per_case,
    coalesce(try_cast(getvariable('consolidated_pages') AS INTEGER), 110) AS consolidated_pages,
    coalesce(try_cast(getvariable('reuse_identities') AS INTEGER), 0) AS reuse_identities,
    coalesce(nullif(cast(getvariable('samples_dir') AS VARCHAR), ''), 'samples') AS samples_dir;

SET VARIABLE samples_dir = (
    SELECT coalesce(nullif(cast(getvariable('samples_dir') AS VARCHAR), ''), 'samples')
);

SELECT CASE
    WHEN n_cases < 1 THEN error('n_cases must be >= 1')
    WHEN docs_per_case < 1 THEN error('docs_per_case must be >= 1')
    WHEN consolidated_pages < 0 THEN error('consolidated_pages must be >= 0')
    ELSE format(
        'config: n_cases={} docs_per_case={} consolidated_pages={} reuse_identities={} samples_dir={}',
        n_cases, docs_per_case, consolidated_pages, reuse_identities, samples_dir
    )
END AS config_banner
FROM _cfg;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. IDENTITIES (fakeit) — general N-case cast, no case-specific hardcoding
-- ═══════════════════════════════════════════════════════════════════════════

-- Curated US place/street pools (geo-coherent). Indexed by cid modulo length.
CREATE OR REPLACE TEMP TABLE _us_places AS
SELECT * FROM (VALUES
    (1, 'Portland',  'OR', '97205'),
    (2, 'Salem',     'OR', '97301'),
    (3, 'Eugene',    'OR', '97401'),
    (4, 'Bend',      'OR', '97701'),
    (5, 'Gresham',   'OR', '97030'),
    (6, 'Medford',   'OR', '97501'),
    (7, 'Beaverton', 'OR', '97005'),
    (8, 'Hillsboro', 'OR', '97123'),
    (9, 'Spokane',   'WA', '99201'),
    (10,'Boise',     'ID', '83702')
) t(pid, city, st, zip);

CREATE OR REPLACE TEMP TABLE _us_streets AS
SELECT * FROM (VALUES
    (1, 'Maple',      'St'),
    (2, 'Oakwood',    'Dr'),
    (3, 'Industrial', 'Blvd'),
    (4, 'River',      'Rd'),
    (5, 'Cedar',      'Ave'),
    (6, 'Highland',   'Ct'),
    (7, 'Market',     'St'),
    (8, 'Lincoln',    'Ave'),
    (9, 'Summit',     'Way'),
    (10,'Harbor',     'Blvd')
) t(sid, sname, suf);

-- Case scaffold: deterministic case numbers, rotating officer counts & cite vols.
CREATE OR REPLACE TEMP TABLE _case_scaffold AS
SELECT
    cid,
    format('24-{:06d}', 1000 + cid) AS case_no,
    2 + ((cid - 1) % 2) AS n_officers,           -- 2 or 3
    1 + ((cid - 1) % (SELECT count(*) FROM _us_places)) AS place_i,
    1 + ((cid - 1) % (SELECT count(*) FROM _us_streets)) AS street_i,
    350 + (cid * 37) % 200 AS cite_vol,
    40 + (cid * 53) % 500 AS cite_page
FROM generate_series(1, (SELECT n_cases FROM _cfg)) t(cid);

-- Subjects: oversample fakeit draws; keep first structurally-valid SSN + NANP phone.
CREATE OR REPLACE TEMP TABLE _subjects AS
SELECT
    cid, case_no, n_officers, first, last, place_i, street_i, cite_vol, cite_page,
    substr(ssn_raw, 1, 3) || '-' || substr(ssn_raw, 4, 2) || '-' || substr(ssn_raw, 6, 4) AS ssn,
    '(' || substr(ph_raw, 1, 3) || ') ' || substr(ph_raw, 4, 3) || '-' || substr(ph_raw, 7, 4) AS phone,
    strftime(
        DATE '2026-07-17'
            - to_years(25 + (abs(hash(ssn_raw)) % 40)::INT)
            - to_days((abs(hash(ph_raw)) % 364)::INT),
        '%m/%d/%Y'
    ) AS dob,
    house_num, sname, suf, city, st, zip
FROM (
    SELECT *,
        row_number() OVER (PARTITION BY cid ORDER BY attempt) AS rn
    FROM (
        SELECT
            s.cid, s.case_no, s.n_officers, s.place_i, s.street_i, s.cite_vol, s.cite_page,
            gs.attempt,
            fakeit_name_first() AS first,
            fakeit_name_last()  AS last,
            fakeit_person_ssn() AS ssn_raw,
            fakeit_contact_phone() AS ph_raw,
            (100 + (abs(hash(fakeit_uuid_v4())) % 9900))::INT::VARCHAR AS house_num,
            st.sname, st.suf, p.city, p.st, p.zip
        FROM _case_scaffold s
        JOIN _us_places  p  ON p.pid  = s.place_i
        JOIN _us_streets st ON st.sid = s.street_i
        CROSS JOIN generate_series(1, 100) gs(attempt)
    ) raw
    WHERE length(ssn_raw) = 9
      AND substr(ssn_raw, 1, 3) NOT IN ('000', '666')
      AND substr(ssn_raw, 1, 1) <> '9'
      AND substr(ssn_raw, 4, 2) <> '00'
      AND substr(ssn_raw, 6, 4) <> '0000'
      AND length(ph_raw) = 10
      AND substr(ph_raw, 1, 1) BETWEEN '2' AND '9'
      AND substr(ph_raw, 4, 1) BETWEEN '2' AND '9'
) v
WHERE rn = 1;

CREATE OR REPLACE TEMP TABLE _subjects_ok AS
SELECT
    cid, case_no, n_officers, first, last, ssn, phone, dob,
    house_num, sname, suf, city, st, zip, cite_vol, cite_page,
    house_num || ' ' || sname || ' ' || suf || ', ' || city || ', ' || st || ' ' || zip AS address
FROM _subjects;

SELECT CASE
    WHEN (SELECT count(*) FROM _subjects_ok) = (SELECT n_cases FROM _cfg)
    THEN format('subjects ok: {}', (SELECT count(*) FROM _subjects_ok))
    ELSE error('subject draw failed — not enough valid SSN/phone samples; re-run')
END AS subject_gate;

-- False-positive street bait: "<Surname> Street"
CREATE OR REPLACE TEMP TABLE _fp_streets AS
SELECT cid, last || ' Street' AS fp_street
FROM _subjects_ok;

-- Two witnesses per case (validated NANP phones).
CREATE OR REPLACE TEMP TABLE _witnesses AS
SELECT cid, w AS slot,
    first || ' ' || last AS name,
    '(' || substr(ph_raw, 1, 3) || ') ' || substr(ph_raw, 4, 3) || '-' || substr(ph_raw, 7, 4) AS phone
FROM (
    SELECT *,
        row_number() OVER (PARTITION BY cid, w ORDER BY attempt) AS rn
    FROM (
        SELECT s.cid, g.w, gs.attempt,
               fakeit_name_first() AS first, fakeit_name_last() AS last,
               fakeit_contact_phone() AS ph_raw
        FROM _case_scaffold s
        CROSS JOIN generate_series(1, 2) g(w)
        CROSS JOIN generate_series(1, 80) gs(attempt)
    ) raw
    WHERE length(ph_raw) = 10
      AND substr(ph_raw, 1, 1) BETWEEN '2' AND '9'
      AND substr(ph_raw, 4, 1) BETWEEN '2' AND '9'
) v
WHERE rn = 1;

-- Officers. Plant: one officer per case shares the SUBJECT's surname (FP bait).
CREATE OR REPLACE TEMP TABLE _officers AS
SELECT o.cid, o.ono,
    (['Ofc.', 'Det.', 'Sgt.'])[((o.ono - 1) % 3) + 1] || ' '
        || left(o.first, 1) || '. '
        || CASE
            WHEN o.ono = CASE WHEN o.n_officers >= 2 THEN 2 ELSE 1 END
            THEN (SELECT last FROM _subjects_ok WHERE cid = o.cid)
            ELSE o.last
          END
        || ' #' || (1000 + (abs(hash(o.first || o.last || o.ono::TEXT)) % 8999))::TEXT AS officer
FROM (
    SELECT s.cid, s.n_officers, gs.ono,
           fakeit_name_first() AS first,
           fakeit_name_last()  AS last
    FROM _case_scaffold s
    CROSS JOIN generate_series(1, s.n_officers) gs(ono)
) o;

-- Collateral person (NOT on the entity roster) — SSN plant seed matcher will miss.
CREATE OR REPLACE TEMP TABLE _collateral AS
SELECT
    cid,
    first || ' ' || last AS name,
    substr(ssn_raw, 1, 3) || '-' || substr(ssn_raw, 4, 2) || '-' || substr(ssn_raw, 6, 4) AS ssn
FROM (
    SELECT *,
        row_number() OVER (PARTITION BY cid ORDER BY attempt) AS rn
    FROM (
        SELECT s.cid, gs.attempt,
               fakeit_name_first() AS first, fakeit_name_last() AS last,
               fakeit_person_ssn() AS ssn_raw
        FROM _case_scaffold s
        CROSS JOIN generate_series(1, 100) gs(attempt)
    ) raw
    WHERE length(ssn_raw) = 9
      AND substr(ssn_raw, 1, 3) NOT IN ('000', '666')
      AND substr(ssn_raw, 1, 1) <> '9'
      AND substr(ssn_raw, 4, 2) <> '00'
      AND substr(ssn_raw, 6, 4) <> '0000'
) v
WHERE rn = 1;

-- Assembled case roster (used whether we write identities.json or reuse it).
CREATE OR REPLACE TEMP TABLE _fresh_cases AS
SELECT
    s.cid,
    s.case_no,
    s.first || ' ' || s.last AS subject_name,
    s.first AS subject_first,
    s.last AS subject_last,
    s.ssn AS subject_ssn,
    s.dob AS subject_dob,
    s.address AS subject_address,
    s.phone AS subject_phone,
    s.house_num, s.sname, s.suf, s.city, s.st, s.zip,
    s.cite_vol, s.cite_page,
    f.fp_street,
    s.last || ' v. Ohio, ' || s.cite_vol::TEXT || ' U.S. ' || s.cite_page::TEXT || ' (1990)' AS fp_citation,
    replace(s.ssn, '-', ' ') AS ssn_spaced,
    replace(s.ssn, '-', '.') AS ssn_dotted,
    substr(regexp_replace(s.phone, '[^0-9]', '', 'g'), 1, 3) || '.'
        || substr(regexp_replace(s.phone, '[^0-9]', '', 'g'), 4, 3) || '.'
        || substr(regexp_replace(s.phone, '[^0-9]', '', 'g'), 7, 4) AS phone_dotted,
    c.name AS collateral_name,
    c.ssn AS collateral_ssn,
    replace(c.ssn, '-', ' ') AS collateral_ssn_spaced
FROM _subjects_ok s
JOIN _fp_streets f ON f.cid = s.cid
JOIN _collateral c ON c.cid = s.cid;

CREATE OR REPLACE TEMP TABLE _fresh_witnesses AS
SELECT * FROM _witnesses;

CREATE OR REPLACE TEMP TABLE _fresh_officers AS
SELECT * FROM _officers;

-- Roster tables. Default path = fresh fakeit draws.
-- --reuse-identities path: generate-samples.sh .reads samples/gen/reuse_identities.sql
-- AFTER these CREATEs (that file DROP/recreates _cases/_wits/_offs from identities.json).
-- Never call read_json_auto on a missing identities.json (fresh clone has none yet).
CREATE OR REPLACE TEMP TABLE _cases AS
SELECT * FROM _fresh_cases;

CREATE OR REPLACE TEMP TABLE _wits AS
SELECT * FROM _fresh_witnesses;

CREATE OR REPLACE TEMP TABLE _offs AS
SELECT * FROM _fresh_officers;

SELECT CASE
    WHEN (SELECT count(*) FROM _cases) >= 1 THEN format('roster: {} cases (fresh fakeit)', (SELECT count(*) FROM _cases))
    ELSE error('no cases in roster after fakeit draw')
END AS roster_gate;
