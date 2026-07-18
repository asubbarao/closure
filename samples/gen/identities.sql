-- identities.sql — generate the synthetic cast for the redaction-review corpus.
--
-- Run:  /opt/homebrew/bin/duckdb :memory: -c ".read samples/gen/identities.sql"
-- Emits: samples/identities.json  (the committed fixture — see WHY below).
--
-- WHY a committed fixture and not on-the-fly generation:
-- fakeit is NOT seedable, so every run draws fresh random people. If the corpus
-- regenerated identities each time, the ground-truth manifest and any tests
-- pinned to specific PII would drift. We therefore generate ONCE, commit
-- identities.json, and have generate.py consume that frozen JSON. Re-running this
-- script intentionally re-rolls the cast (only do that to mint a new fixture).

LOAD fakeit;

-- Case identifiers (not PII, so fixed & deterministic) + officer head-count each.
CREATE TEMP TABLE case_scaffold(cid INT, case_no TEXT, n_officers INT);
INSERT INTO case_scaffold VALUES
  (1, '24-000117', 3),
  (2, '24-000233', 2),
  (3, '24-000312', 3),
  (4, '24-000405', 2);

-- One subject per case. Every fakeit_* call is volatile, so each row draws a
-- distinct person. The raw draws are made in an inner SELECT (row context of the
-- 4 cases) and formatted in the outer SELECT -- doing the draw inside a scalar
-- subquery instead would let DuckDB constant-fold it to ONE value for all rows.
-- Quirks handled here:
--   * fakeit_person_ssn()   -> 9 raw digits, formatted XXX-XX-XXXX
--   * fakeit_contact_phone()-> 10 raw digits, formatted (NNN) NNN-NNNN
--   * address composed from number+name+suffix (fakeit_address_street() emits
--     junk like "481 West Way town"); suffix is lowercase so we initcap it.
CREATE TEMP TABLE subjects AS
SELECT
  cid, case_no, n_officers, first, last,
  substr(ssn_raw,1,3)||'-'||substr(ssn_raw,4,2)||'-'||substr(ssn_raw,6,4) AS ssn,
  '('||substr(ph_raw,1,3)||') '||substr(ph_raw,4,3)||'-'||substr(ph_raw,7,4) AS phone,
  strftime(DATE '2026-07-17'
             - to_years(25 + (random()*40)::INT)
             - to_days((random()*364)::INT), '%m/%d/%Y') AS dob,
  num || ' ' || sname || ' ' || upper(left(suf,1)) || substr(suf,2) || ', '
    || city || ', ' || state || ' ' || zip AS address
FROM (
  SELECT s.cid, s.case_no, s.n_officers,
    fakeit_name_first() AS first, fakeit_name_last() AS last,
    fakeit_person_ssn() AS ssn_raw, fakeit_contact_phone() AS ph_raw,
    fakeit_address_street_number() AS num, fakeit_address_street_name() AS sname,
    fakeit_address_street_suffix() AS suf, fakeit_address_city() AS city,
    fakeit_address_state() AS state, fakeit_address_zip() AS zip
  FROM case_scaffold s
);

-- Two witnesses per case (name + phone). Same inline-draw pattern as subjects.
CREATE TEMP TABLE witnesses AS
SELECT cid,
  first || ' ' || last AS name,
  '('||substr(ph_raw,1,3)||') '||substr(ph_raw,4,3)||'-'||substr(ph_raw,7,4) AS phone
FROM (
  SELECT s.cid, fakeit_name_first() AS first, fakeit_name_last() AS last,
         fakeit_contact_phone() AS ph_raw
  FROM case_scaffold s CROSS JOIN generate_series(1, 2) g(w)
);

-- Officers ("Ofc. F. Lastname #NNNN"). PLANT: for case 1, one officer is given
-- the SUBJECT's exact surname — false-positive bait for a name-based detector.
CREATE TEMP TABLE officers AS
SELECT o.cid,
  (['Ofc.','Det.','Sgt.'])[((o.ono - 1) % 3) + 1] || ' '
    || left(o.first, 1) || '. '
    || CASE WHEN o.cid = 1 AND o.ono = 2
            THEN (SELECT last FROM subjects WHERE cid = 1)  -- surname-sharing plant
            ELSE o.last END
    || ' #' || (1000 + (random()*8999)::INT)::TEXT AS officer
FROM (
  SELECT s.cid, gs.ono,
         fakeit_name_first() AS first,
         fakeit_name_last()  AS last
  FROM case_scaffold s CROSS JOIN generate_series(1, s.n_officers) gs(ono)
) o;

-- Assemble the nested JSON. fp_street / fp_citation are derived from the subject
-- surname so they read as plausible-but-non-PII bait in the narratives.
COPY (
  SELECT to_json({'cases': list(case_obj ORDER BY cid)}) FROM (
    SELECT s.cid,
      {
        'case_no': s.case_no,
        'subject': {'name': s.first || ' ' || s.last, 'ssn': s.ssn,
                    'dob': s.dob, 'address': s.address, 'phone': s.phone},
        'witnesses': (SELECT list({'name': w.name, 'phone': w.phone})
                        FROM witnesses w WHERE w.cid = s.cid),
        'officers':  (SELECT list(o.officer) FROM officers o WHERE o.cid = s.cid),
        'fp_street':   s.last || ' Street',
        'fp_citation': s.last || ' v. Ohio, 494 U.S. 541 (1990)'
      } AS case_obj
    FROM subjects s
  )
) TO 'samples/identities.json' (FORMAT csv, HEADER false, QUOTE '');
