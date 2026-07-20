-- reuse_identities.sql — replace _cases/_wits/_offs from samples/identities.json.
-- Invoked ONLY when generate-samples.sh is run with --reuse-identities
-- (and identities.json already exists). Never open this on a fresh clone.
--
-- Expects session variables/tables from generate.sql already loaded:
--   getvariable('samples_dir'), _cfg
-- Overwrites: _cases, _wits, _offs

SELECT CASE
    WHEN (SELECT reuse_identities FROM _cfg) <> 1
    THEN error('reuse_identities.sql loaded but reuse_identities != 1')
    ELSE 'loading identities.json fixture'
END AS reuse_banner;

CREATE OR REPLACE TEMP TABLE _cases AS
SELECT
    row_number() OVER (ORDER BY cast(c.case_no AS VARCHAR))::INT AS cid,
    cast(c.case_no AS VARCHAR) AS case_no,
    cast(c.subject.name AS VARCHAR) AS subject_name,
    regexp_extract(cast(c.subject.name AS VARCHAR), '^(\S+)', 1) AS subject_first,
    regexp_extract(cast(c.subject.name AS VARCHAR), '(\S+)$', 1) AS subject_last,
    cast(c.subject.ssn AS VARCHAR) AS subject_ssn,
    cast(c.subject.dob AS VARCHAR) AS subject_dob,
    cast(c.subject.address AS VARCHAR) AS subject_address,
    cast(c.subject.phone AS VARCHAR) AS subject_phone,
    cast(c.address_parts.house AS VARCHAR) AS house_num,
    cast(c.address_parts.street AS VARCHAR) AS sname,
    cast(c.address_parts.suffix AS VARCHAR) AS suf,
    cast(c.address_parts.city AS VARCHAR) AS city,
    cast(c.address_parts.state AS VARCHAR) AS st,
    cast(c.address_parts.zip AS VARCHAR) AS zip,
    try_cast(regexp_extract(cast(c.fp_citation AS VARCHAR), '(\d+) U\.S\.', 1) AS INT) AS cite_vol,
    try_cast(regexp_extract(cast(c.fp_citation AS VARCHAR), 'U\.S\. (\d+)', 1) AS INT) AS cite_page,
    cast(c.fp_street AS VARCHAR) AS fp_street,
    cast(c.fp_citation AS VARCHAR) AS fp_citation,
    coalesce(cast(c.plants.ssn_spaced AS VARCHAR), replace(cast(c.subject.ssn AS VARCHAR), '-', ' ')) AS ssn_spaced,
    coalesce(cast(c.plants.ssn_dotted AS VARCHAR), replace(cast(c.subject.ssn AS VARCHAR), '-', '.')) AS ssn_dotted,
    coalesce(
        cast(c.plants.phone_dotted AS VARCHAR),
        substr(regexp_replace(cast(c.subject.phone AS VARCHAR), '[^0-9]', '', 'g'), 1, 3) || '.'
            || substr(regexp_replace(cast(c.subject.phone AS VARCHAR), '[^0-9]', '', 'g'), 4, 3) || '.'
            || substr(regexp_replace(cast(c.subject.phone AS VARCHAR), '[^0-9]', '', 'g'), 7, 4)
    ) AS phone_dotted,
    coalesce(cast(c.plants.collateral_name AS VARCHAR), 'Collateral Party') AS collateral_name,
    coalesce(cast(c.plants.collateral_ssn AS VARCHAR), '000-00-0000') AS collateral_ssn,
    coalesce(
        cast(c.plants.collateral_ssn_spaced AS VARCHAR),
        replace(coalesce(cast(c.plants.collateral_ssn AS VARCHAR), '000-00-0000'), '-', ' ')
    ) AS collateral_ssn_spaced
FROM (
    SELECT unnest(cases) AS c
    FROM read_json_auto(getvariable('samples_dir') || '/identities.json')
);

CREATE OR REPLACE TEMP TABLE _wits AS
SELECT
    ca.cid,
    row_number() OVER (PARTITION BY ca.cid ORDER BY w_ord) AS slot,
    cast(w.name AS VARCHAR) AS name,
    cast(w.phone AS VARCHAR) AS phone
FROM (
    SELECT unnest(cases) AS c
    FROM read_json_auto(getvariable('samples_dir') || '/identities.json')
) j
JOIN _cases ca ON ca.case_no = cast(j.c.case_no AS VARCHAR)
CROSS JOIN unnest(j.c.witnesses) WITH ORDINALITY AS u(w, w_ord);

CREATE OR REPLACE TEMP TABLE _offs AS
SELECT
    ca.cid,
    row_number() OVER (PARTITION BY ca.cid ORDER BY o_ord) AS ono,
    cast(o AS VARCHAR) AS officer
FROM (
    SELECT unnest(cases) AS c
    FROM read_json_auto(getvariable('samples_dir') || '/identities.json')
) j
JOIN _cases ca ON ca.case_no = cast(j.c.case_no AS VARCHAR)
CROSS JOIN unnest(j.c.officers) WITH ORDINALITY AS u(o, o_ord);

SELECT CASE
    WHEN (SELECT count(*) FROM _cases) >= 1
    THEN format('roster: {} cases (reused identities.json)', (SELECT count(*) FROM _cases))
    ELSE error('reuse_identities: no cases loaded from identities.json')
END AS reuse_roster_gate;
