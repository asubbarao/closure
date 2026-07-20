-- 01_address_parse.sql
-- Spike: us_address_standardizer for Closure detection / entity quality.
-- Run from repo root:
--   duckdb -unsigned -markdown :memory: < spikes/ext-detection/01_address_parse.sql
--
-- Proves:
--   1. INSTALL/LOAD from community on v1.5.4
--   2. addrust_parse splits roster-style full addresses into components
--   3. Street-only FP bait (e.g. "Feeney Street") is distinguishable from full addresses
--   4. A residual-scan gate: flag only when house number + (city OR zip) present

INSTALL us_address_standardizer FROM community;
LOAD us_address_standardizer;

.mode markdown

SELECT '=== 1. Roster subject addresses (identities.json) ===' AS section;

CREATE OR REPLACE TABLE roster_addrs AS
SELECT
    c.case_no,
    c.subject.address AS raw_address,
    c.address_parts.house AS fixture_house,
    c.address_parts.street AS fixture_street,
    c.address_parts.suffix AS fixture_suffix,
    c.address_parts.city AS fixture_city,
    c.address_parts.state AS fixture_state,
    c.address_parts.zip AS fixture_zip,
    addrust_parse(c.subject.address) AS parsed
FROM (
    SELECT unnest(cases) AS c
    FROM read_json('samples/identities.json', format = 'auto')
);

SELECT
    case_no,
    raw_address,
    parsed.street_number AS street_number,
    parsed.street_name AS street_name,
    parsed.suffix AS suffix,
    parsed.city AS city,
    parsed.state AS state,
    parsed.zip AS zip,
    -- fixture alignment (suffix may expand ST→STREET)
    (parsed.street_number = fixture_house) AS house_ok,
    (parsed.zip = fixture_zip) AS zip_ok,
    (parsed.state = fixture_state) AS state_ok
FROM roster_addrs
ORDER BY case_no;

SELECT '=== 2. FP street bait vs full address gate ===' AS section;

CREATE OR REPLACE TABLE probe AS
SELECT text, addrust_parse(text) AS p
FROM (VALUES
    ('6396 Maple St, Portland, OR 97205'),
    ('Feeney Street'),
    ('Schmidt Street'),
    ('Doyle Street'),
    ('Langworth Street'),
    ('123 N Main St Apt 4, Springfield IL 62704'),
    ('PO Box 442, Austin TX 78701'),
    ('Hilbert Feeney'),           -- person name: should not look like full address
    ('300-71-4366')               -- SSN: should not look like address
) t(text);

SELECT
    text,
    p.street_number,
    p.street_name,
    p.suffix,
    p.city,
    p.state,
    p.zip,
    p.po_box,
    -- Detection gate for remainder_scan-style "possible ADDRESS miss"
    -- (street house# + locality) OR po_box + locality
    (
        (
            p.street_number IS NOT NULL
            AND (p.city IS NOT NULL OR p.zip IS NOT NULL)
        )
        OR (
            p.po_box IS NOT NULL
            AND (p.city IS NOT NULL OR p.zip IS NOT NULL)
        )
    ) AS flag_full_address,
    -- Street-name-only (surname + Street) → prior: keep / NOT PII bait
    (
        p.street_number IS NULL
        AND p.suffix IS NOT NULL
        AND p.city IS NULL
        AND p.zip IS NULL
        AND p.po_box IS NULL
    ) AS looks_like_street_fp_bait
FROM probe;

SELECT '=== 3. Mechanism to lift into remainder_scan / entities ===' AS section;
SELECT $$
-- On ADDRESS entity rows or multi-token remainder n-grams:
WITH p AS (
  SELECT *, addrust_parse(text) AS a FROM residual_candidates
)
SELECT document_id, page, text, a
FROM p
WHERE (
    (a.street_number IS NOT NULL AND (a.city IS NOT NULL OR a.zip IS NOT NULL))
    OR (a.po_box IS NOT NULL AND (a.city IS NOT NULL OR a.zip IS NOT NULL))
);
-- Optional: PAGC path after SELECT load_us_address_data();
-- standardize_address('us_lex','us_gaz','us_rules', line1, line2)
$$ AS integration_shape;
