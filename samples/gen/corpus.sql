-- corpus.sql — sample PDFs + watchlist + identities (NOT the audit trail).
-- Audit = exports/decisions/*.json only; this file never writes decisions.
--
-- Vars: n_cases, docs_per_case, consolidated_pages, reuse_identities, samples_dir
-- Out:  identities.json, watchlist.json, manifest.json, *.pdf

INSTALL fakeit FROM community; LOAD fakeit;
INSTALL pdf FROM community; LOAD pdf;

-- Knobs typed by setup.sh / setup.sql. Read as-is (no try_cast).
CREATE OR REPLACE TEMP TABLE _cfg AS
SELECT
    getvariable('n_cases') AS n_cases,
    getvariable('docs_per_case') AS docs_per_case,
    getvariable('consolidated_pages') AS consolidated_pages,
    getvariable('reuse_identities') AS reuse,
    getvariable('samples_dir') AS dir;

-- ── cast: fakeit draw  OR  identities.json ────────────────────────────────

CREATE OR REPLACE TEMP TABLE _cases AS
SELECT
    gs.cid,
    format('24-{:06d}', 1000 + gs.cid) AS case_no,
    fakeit_name_first() AS subject_first,
    fakeit_name_last() AS subject_last,
    fakeit_person_ssn() AS subject_ssn,
    format('{:02d}/{:02d}/{}', 1 + abs(hash(gs.cid::VARCHAR)) % 12,
        1 + abs(hash(gs.cid::VARCHAR || 'd')) % 28,
        1965 + abs(hash(gs.cid::VARCHAR || 'y')) % 35) AS subject_dob,
    fakeit_address_street_number() || ' ' || fakeit_address_street_name() || ', '
        || fakeit_address_city() || ', ' || fakeit_address_state_abr() || ' '
        || fakeit_address_zip() AS subject_address,
    fakeit_contact_phone_formatted() AS subject_phone,
    '' AS fp_street,
    '' AS fp_citation
FROM generate_series(1, (SELECT n_cases FROM _cfg)) gs(cid)
WHERE (SELECT reuse FROM _cfg) = 0;

-- single draw for first/last then compose name + FP bait
CREATE OR REPLACE TEMP TABLE _cases AS
SELECT cid, case_no, subject_first, subject_last,
    subject_first || ' ' || subject_last AS subject_name,
    subject_ssn, subject_dob, subject_address, subject_phone,
    subject_last || ' Street' AS fp_street,
    subject_last || ' v. Ohio' AS fp_citation
FROM _cases
WHERE (SELECT reuse FROM _cfg) = 0
UNION ALL BY NAME
SELECT
    row_number() OVER (ORDER BY c.case_no)::INTEGER AS cid,
    c.case_no::VARCHAR AS case_no,
    split_part(c.subject.name::VARCHAR, ' ', 1) AS subject_first,
    list_extract(string_split(c.subject.name::VARCHAR, ' '), -1) AS subject_last,
    c.subject.name::VARCHAR AS subject_name,
    c.subject.ssn::VARCHAR AS subject_ssn,
    c.subject.dob::VARCHAR AS subject_dob,
    c.subject.address::VARCHAR AS subject_address,
    c.subject.phone::VARCHAR AS subject_phone,
    c.fp_street::VARCHAR AS fp_street,
    c.fp_citation::VARCHAR AS fp_citation
FROM (SELECT unnest(cases) AS c FROM read_json_auto(getvariable('samples_dir') || '/identities.json'))
WHERE (SELECT reuse FROM _cfg) = 1;

CREATE OR REPLACE TEMP TABLE _wits AS
SELECT c.cid, s.slot,
    fakeit_name_first() || ' ' || fakeit_name_last() AS name,
    fakeit_contact_phone_formatted() AS phone
FROM _cases c, generate_series(1, 2) s(slot)
WHERE (SELECT reuse FROM _cfg) = 0
UNION ALL BY NAME
SELECT ca.cid, ord::INTEGER AS slot, w.name::VARCHAR AS name, w.phone::VARCHAR AS phone
FROM (SELECT unnest(cases) AS c FROM read_json_auto(getvariable('samples_dir') || '/identities.json')) j
JOIN _cases ca ON ca.case_no = j.c.case_no
CROSS JOIN unnest(j.c.witnesses) WITH ORDINALITY AS t(w, ord)
WHERE (SELECT reuse FROM _cfg) = 1;

CREATE OR REPLACE TEMP TABLE _offs AS
SELECT o.cid, o.ono,
    (['Ofc.', 'Det.', 'Sgt.'])[o.ono] || ' ' || left(o.fn, 1) || '. '
        || CASE WHEN o.is_reporting THEN o.subject_last ELSE o.ln END
        || ' #' || (1000 + abs(hash(o.cid::VARCHAR || o.ono::VARCHAR)) % 8999)::VARCHAR AS officer,
    o.is_reporting, o.is_investigating, o.is_reporting AS is_fp_surname
FROM (
    SELECT c.cid, c.subject_last, n.ono, n.n,
        fakeit_name_first() AS fn, fakeit_name_last() AS ln,
        (n.ono = least(2, n.n)) AS is_reporting,
        (n.ono = n.n) AS is_investigating
    FROM _cases c
    CROSS JOIN LATERAL (
        SELECT gs.ono, 2 + ((c.cid - 1) % 2) AS n
        FROM generate_series(1, 2 + ((c.cid - 1) % 2)) gs(ono)
    ) n
) o
WHERE (SELECT reuse FROM _cfg) = 0
UNION ALL BY NAME
SELECT ca.cid,
       ord::INTEGER AS ono,
       o.name::VARCHAR AS officer,
       o.is_reporting,
       o.is_investigating,
       o.is_fp_surname
FROM (SELECT unnest(cases) AS c FROM read_json_auto(getvariable('samples_dir') || '/identities.json')) j
JOIN _cases ca ON ca.case_no = j.c.case_no
CROSS JOIN unnest(j.c.officers) WITH ORDINALITY AS t(o, ord)
WHERE (SELECT reuse FROM _cfg) = 1;

SELECT CASE WHEN (SELECT count(*) FROM _cases) = 0 THEN error('empty cast')
    WHEN (SELECT count(*) FILTER (WHERE is_reporting) FROM _offs) <> (SELECT count(*) FROM _cases)
    THEN error('one is_reporting officer per case')
    ELSE format('cast {} cases', (SELECT count(*) FROM _cases)) END AS cast_ok;

-- ── docs + PDFs ───────────────────────────────────────────────────────────

CREATE OR REPLACE TEMP TABLE _docs AS
WITH stems AS (
    SELECT * FROM (VALUES
        (0,'incident_report','Incident Report'),(1,'interview_transcript','Interview Transcript'),
        (2,'arrest_report','Arrest Report'),(3,'witness_statement','Witness Statement'),
        (4,'case_summary','Case Summary'),(5,'evidence_log','Evidence Log'),
        (6,'property_receipt','Property Receipt'),(7,'supplemental_report','Supplemental Report')
    ) t(i, stem, title)
),
base AS (
    SELECT c.*, rep.officer AS reporting, inv.officer AS investigating,
           w0.name AS w0n, w0.phone AS w0p, w1.name AS w1n, w1.phone AS w1p
    FROM _cases c
    JOIN _offs rep ON rep.cid = c.cid AND rep.is_reporting
    JOIN _offs inv ON inv.cid = c.cid AND inv.is_investigating
    JOIN _wits w0 ON w0.cid = c.cid AND w0.slot = 1
    JOIN _wits w1 ON w1.cid = c.cid AND w1.slot = 2
)
SELECT b.cid, b.case_no, g.slot, st.stem, st.title,
    format('{}_20{}-{}.pdf', st.stem, split_part(b.case_no, '-', 1),
        split_part(b.case_no, '-', 2) || CASE WHEN g.slot = 1 THEN '' ELSE chr((64 + g.slot)::INTEGER) END
    ) AS filename,
    format(E'{}\nCase {}\nReporting: {}\nInvestigating: {}\n'
        || E'Subject: {} DOB {} SSN {} Address {} Phone {}\n'
        || E'Witnesses: {} ({}); {} ({}). Near {}. Cite {}.\n{}',
        st.title, b.case_no, b.reporting, b.investigating,
        b.subject_name, b.subject_dob, b.subject_ssn, b.subject_address, b.subject_phone,
        b.w0n, b.w0p, b.w1n, b.w1p, b.fp_street, b.fp_citation,
        repeat('Case narrative for redaction review. ', 10)
    ) AS body
FROM base b
CROSS JOIN generate_series(1, (SELECT docs_per_case FROM _cfg)) g(slot)
JOIN stems st ON st.i = ((b.cid - 1) * (SELECT docs_per_case FROM _cfg) + (g.slot - 1)) % 8
UNION ALL BY NAME
-- BY NAME matches on column name: every column here must carry the alias it
-- has above, or it lands as NULL (that was the null-filename manifest row).
SELECT b.cid, b.case_no, 0 AS slot,
    'consolidated_case_file' AS stem, 'Consolidated Case File' AS title,
    format('consolidated_case_file_20{}-{}.pdf',
        split_part(b.case_no, '-', 1), split_part(b.case_no, '-', 2)) AS filename,
    format(E'Consolidated Case File\nCase {}\nReporting: {}\n'
        || E'Subject {} SSN {} Phone {}\nWitnesses {} / {}\nStreet {} Cite {}\n{}',
        b.case_no, b.reporting, b.subject_name, b.subject_ssn, b.subject_phone,
        b.w0n, b.w1n, b.fp_street, b.fp_citation,
        -- 68 of these sentences fill one page at write_pdf's default layout,
        -- so the knob means what it says: consolidated_pages = actual pages.
        repeat(format(E'{} logged contact with {} ({}). ', b.reporting, b.subject_name, b.subject_ssn),
            greatest(20, (SELECT consolidated_pages FROM _cfg) * 68))
    ) AS body
FROM base b
WHERE b.cid = (SELECT min(cid) FROM _cases) AND (SELECT consolidated_pages FROM _cfg) > 0;

SELECT write_pdf(body, getvariable('samples_dir') || '/' || filename) AS path, filename
FROM _docs;

-- ── real court documents ──────────────────────────────────────────────────
-- samples/gen/court.sql fetches + verifies public federal filings into this
-- same directory, and populates _court in this same session (COURT_DOCS=1).
-- When it did not run, _court stays empty and the corpus is the generated one
-- alone — so this is IF NOT EXISTS, never CREATE OR REPLACE.
CREATE TEMP TABLE IF NOT EXISTS _court (filename VARCHAR, case_no VARCHAR);

-- ── artifacts (still not audit) ───────────────────────────────────────────

COPY (
    SELECT to_json({'cases': list({
        'case_no': c.case_no,
        'subject': {'name': c.subject_name, 'ssn': c.subject_ssn, 'dob': c.subject_dob,
                    'address': c.subject_address, 'phone': c.subject_phone},
        'witnesses': (SELECT list({'name': w.name, 'phone': w.phone} ORDER BY w.slot)
                      FROM _wits w WHERE w.cid = c.cid),
        'officers': (SELECT list({'name': o.officer, 'is_reporting': o.is_reporting,
            'is_investigating': o.is_investigating, 'is_fp_surname': o.is_fp_surname}
            ORDER BY o.ono) FROM _offs o WHERE o.cid = c.cid),
        'fp_street': c.fp_street, 'fp_citation': c.fp_citation
    } ORDER BY c.cid)}) FROM _cases c
) TO (getvariable('samples_dir') || '/identities.json') (FORMAT csv, HEADER false, QUOTE '');

COPY (
    SELECT case_no, term, kind FROM (
        SELECT case_no, subject_name AS term, 'PERSON · SUBJECT' AS kind FROM _cases
        UNION ALL SELECT c.case_no, w.name, 'PERSON · WITNESS' FROM _wits w JOIN _cases c USING (cid)
        UNION ALL SELECT c.case_no, o.officer, 'OFFICER · NOT SUBJECT PII' FROM _offs o JOIN _cases c USING (cid)
        UNION ALL SELECT case_no, fp_street, 'STREET NAME · NOT PII' FROM _cases
        UNION ALL SELECT case_no, fp_citation, 'CITATION · NOT PII' FROM _cases
    )
) TO (getvariable('samples_dir') || '/watchlist.json') (FORMAT json, ARRAY true);

COPY (
    SELECT to_json({'files': list({'filename': filename, 'case_no': case_no}
        ORDER BY case_no, filename)})
    FROM (SELECT filename, case_no FROM _docs UNION ALL SELECT filename, case_no FROM _court)
) TO (getvariable('samples_dir') || '/manifest.json') (FORMAT csv, HEADER false, QUOTE '');

SELECT 'corpus done' AS status, (SELECT count(*) FROM _cases) AS cases,
       (SELECT count(*) FROM _docs) + (SELECT count(*) FROM _court) AS docs;
