-- 00_setup.sql
-- Spike: finetype (+ quickjs residual) for Closure detection core.
-- Run from repo root:
--   duckdb -unsigned -markdown < spikes/ext-finetype/00_setup.sql
--
-- Installs extensions and builds catalog tables from samples/identities.json
-- plus decoys. Downstream scripts assume these names exist in the same session
-- (or re-create them — each 01_*/02_*/03_* file is self-contained).

INSTALL finetype FROM community;
LOAD finetype;

SELECT finetype_version() AS finetype_version;

-- ── real identity catalog ───────────────────────────────────────────────────
CREATE OR REPLACE TABLE id_cases AS
SELECT unnest(cases) AS c
FROM read_json_auto('samples/identities.json');

CREATE OR REPLACE TABLE phones_catalog AS
SELECT cast(c.subject.phone AS VARCHAR) AS v, 'subject' AS role
FROM id_cases
UNION ALL
SELECT cast(w.phone AS VARCHAR), 'witness'
FROM id_cases, unnest(c.witnesses) AS t(w);

CREATE OR REPLACE TABLE ssns_catalog AS
SELECT cast(c.subject.ssn AS VARCHAR) AS v
FROM id_cases;

CREATE OR REPLACE TABLE dobs_catalog AS
SELECT cast(c.subject.dob AS VARCHAR) AS v
FROM id_cases;

CREATE OR REPLACE TABLE names_catalog AS
SELECT cast(c.subject.name AS VARCHAR) AS v, 'subject' AS role
FROM id_cases
UNION ALL
SELECT cast(w.name AS VARCHAR), 'witness'
FROM id_cases, unnest(c.witnesses) AS t(w);

CREATE OR REPLACE TABLE addrs_catalog AS
SELECT cast(c.subject.address AS VARCHAR) AS v
FROM id_cases;

SELECT 'setup ok' AS status,
       (SELECT count(*) FROM phones_catalog) AS phones,
       (SELECT count(*) FROM ssns_catalog) AS ssns,
       (SELECT count(*) FROM dobs_catalog) AS dobs,
       (SELECT count(*) FROM names_catalog) AS names,
       (SELECT count(*) FROM addrs_catalog) AS addrs;
