-- Shared-surname officer required on every case (data contract for FP bait).
SELECT CASE
    WHEN (
        SELECT count(*) FROM _cases c
        WHERE NOT EXISTS (
            SELECT 1 FROM _offs o
            WHERE o.cid = c.cid
              AND position(c.subject_last IN o.officer) > 0
        )
    ) = 0
    THEN 'officer surname plant ok'
    ELSE error('every case must plant one officer sharing the subject surname')
END AS officer_plant_gate;

-- Witness0 dotted phone helper per case.
CREATE OR REPLACE TEMP TABLE _plants AS
SELECT
    c.cid,
    c.ssn_spaced,
    c.ssn_dotted,
    c.phone_dotted,
    substr(regexp_replace(w.phone, '[^0-9]', '', 'g'), 1, 3) || '.'
        || substr(regexp_replace(w.phone, '[^0-9]', '', 'g'), 4, 3) || '.'
        || substr(regexp_replace(w.phone, '[^0-9]', '', 'g'), 7, 4) AS witness0_phone_dotted,
    c.collateral_name,
    c.collateral_ssn,
    c.collateral_ssn_spaced,
    -- misspelled witness0 surname (drop interior letter)
    regexp_extract(w.name, '^(\S+)', 1) || ' ' ||
        CASE
            WHEN length(regexp_extract(w.name, '(\S+)$', 1)) >= 4
            THEN left(regexp_extract(w.name, '(\S+)$', 1), 2)
                 || substr(regexp_extract(w.name, '(\S+)$', 1), 4)
            ELSE regexp_extract(w.name, '(\S+)$', 1)
        END AS witness0_misspelled
FROM _cases c
JOIN _wits w ON w.cid = c.cid AND w.slot = 1;

-- ── write identities.json ──────────────────────────────────────────────────
-- Always write from the in-memory roster so reuse=1 re-emits the loaded fixture
-- (never COPY an empty result set over a committed identities.json).
COPY (
    SELECT to_json({'cases': list(case_obj ORDER BY cid)})
    FROM (
        SELECT
            c.cid,
            {
                'case_no': c.case_no,
                'subject': {
                    'name': c.subject_name,
                    'ssn': c.subject_ssn,
                    'dob': c.subject_dob,
                    'address': c.subject_address,
                    'phone': c.subject_phone
                },
                'address_parts': {
                    'house': c.house_num,
                    'street': c.sname,
                    'suffix': c.suf,
                    'city': c.city,
                    'state': c.st,
                    'zip': c.zip
                },
                'witnesses': (
                    SELECT list({'name': w.name, 'phone': w.phone} ORDER BY w.slot)
                    FROM _wits w WHERE w.cid = c.cid
                ),
                'officers': (
                    SELECT list(o.officer ORDER BY o.ono)
                    FROM _offs o WHERE o.cid = c.cid
                ),
                'fp_street': c.fp_street,
                'fp_citation': c.fp_citation,
                'plants': {
                    'ssn_spaced': p.ssn_spaced,
                    'ssn_dotted': p.ssn_dotted,
                    'phone_dotted': p.phone_dotted,
                    'witness0_phone_dotted': p.witness0_phone_dotted,
                    'collateral_name': p.collateral_name,
                    'collateral_ssn': p.collateral_ssn,
                    'collateral_ssn_spaced': p.collateral_ssn_spaced
                },
                'field_tags': {
                    'name': 'identity.person.full_name',
                    'ssn': 'SSN',
                    'dob': 'datetime.date.iso',
                    'address': 'geography.address.full_address',
                    'phone': 'identity.person.phone_number'
                }
            } AS case_obj
        FROM _cases c
        JOIN _plants p ON p.cid = c.cid
    )
) TO (getvariable('samples_dir') || '/identities.json') (FORMAT csv, HEADER false, QUOTE '');

SELECT CASE
    WHEN (SELECT reuse_identities FROM _cfg) = 1 THEN 'identities.json re-emitted from loaded fixture'
    ELSE 'identities.json written from fakeit'
END AS identities_status;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. DOCUMENT PLAN — general types, rotating FN plants (not case-hardcoded)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TEMP TABLE _doc_types AS
SELECT * FROM (VALUES
    (0, 'incident_report',       'Incident Report',              'Investigation',          'This incident report documents the initial response and investigation.'),
    (1, 'supplemental_report',   'Supplemental Report',          'Follow-up',               'This supplemental report memorializes follow-up investigation.'),
    (2, 'interview_transcript',  'Interview Transcript',         'Interview',               'This transcript summarizes a recorded interview.'),
    (3, 'case_summary',          'Case Summary for Prosecution', 'Summary',                 'This summary is prepared for prosecutorial review.'),
    (4, 'arrest_report',         'Arrest Report',                'Custody',                 'This arrest report documents a custodial arrest and booking.'),
    (5, 'witness_statement',     'Witness Statement',            'Statement',               'This document records a sworn witness statement.'),
    (6, 'evidence_log',          'Evidence Log',                 'Evidence',                'This evidence log accompanies the master case file.'),
    (7, 'property_receipt',      'Property Receipt',             'Property',                'This property receipt accompanies the master case file.')
) t(type_i, stem, title, classification, lead);

-- FN modes cycle across docs so the corpus always exercises spaced/dotted plants.
CREATE OR REPLACE TEMP TABLE _fn_modes AS
SELECT * FROM (VALUES
    (0, 'canonical',            false, false, false, false),
    (1, 'spaced_ssn',           true,  false, false, false),
    (2, 'dotted_ssn',           false, true,  false, false),
    (3, 'dotted_phone',         false, false, true,  false),
    (4, 'dotted_phone_misspell',false, false, true,  true),
    (5, 'collateral_ssn',       false, false, false, false)
) t(mode_i, mode_name, use_spaced_ssn, use_dotted_ssn, use_dotted_phone, use_misspell);
-- collateral flag is separate: mode 5

CREATE OR REPLACE TEMP TABLE _doc_plan AS
SELECT
    row_number() OVER (ORDER BY c.cid, slot)::INT AS doc_id,
    c.cid,
    c.case_no,
    slot,
    dt.stem,
    dt.title,
    dt.classification,
    dt.lead,
    -- filename: {stem}_20{YY}-{seq}{optional letter}.pdf
    format(
        '{}_20{}-{}{}.pdf',
        dt.stem,
        split_part(c.case_no, '-', 1),
        split_part(c.case_no, '-', 2),
        CASE WHEN slot = 1 THEN '' ELSE chr((64 + slot)::INTEGER) END
    ) AS filename,
    fm.mode_name,
    fm.use_spaced_ssn,
    fm.use_dotted_ssn,
    fm.use_dotted_phone,
    fm.use_misspell,
    (fm.mode_name = 'collateral_ssn') AS use_collateral
FROM _cases c
CROSS JOIN generate_series(1, (SELECT docs_per_case FROM _cfg)) g(slot)
JOIN _doc_types dt
  ON dt.type_i = ((c.cid - 1) * (SELECT docs_per_case FROM _cfg) + (slot - 1)) % 8
JOIN _fn_modes fm
  ON fm.mode_i = ((c.cid - 1) * (SELECT docs_per_case FROM _cfg) + (slot - 1)) % 6;

-- Optional consolidated multi-page file for the first case (bulk-review fuel).
INSERT INTO _doc_plan BY NAME
SELECT
    ((SELECT coalesce(max(doc_id), 0) FROM _doc_plan) + 1)::INT AS doc_id,
    c.cid,
    c.case_no,
    0 AS slot,
    'consolidated_case_file' AS stem,
    'Consolidated Case File' AS title,
    'Full File' AS classification,
    'Daily activity log consolidating the master case file.' AS lead,
    format(
        'consolidated_case_file_20{}-{}.pdf',
        split_part(c.case_no, '-', 1),
        split_part(c.case_no, '-', 2)
    ) AS filename,
    'canonical' AS mode_name,
    false AS use_spaced_ssn,
    false AS use_dotted_ssn,
    false AS use_dotted_phone,
    false AS use_misspell,
    false AS use_collateral
FROM _cases c
WHERE c.cid = (SELECT min(cid) FROM _cases)
  AND (SELECT consolidated_pages FROM _cfg) > 0;

SELECT format('document plan: {} files', count(*)) AS plan_status FROM _doc_plan;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. NARRATIVE BODY LINES (PII + FP bait + FN plants embedded in prose)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TEMP TABLE _doc_ctx AS
SELECT
    d.*,
    c.subject_name, c.subject_ssn, c.subject_dob, c.subject_address, c.subject_phone,
    c.subject_last, c.fp_street, c.fp_citation,
    p.ssn_spaced, p.ssn_dotted, p.phone_dotted, p.witness0_phone_dotted,
    p.collateral_name, p.collateral_ssn, p.collateral_ssn_spaced, p.witness0_misspelled,
    w0.name AS w0_name, w0.phone AS w0_phone,
    w1.name AS w1_name, w1.phone AS w1_phone,
    (
        SELECT o.officer FROM _offs o
        WHERE o.cid = c.cid AND position(c.subject_last IN o.officer) > 0
        ORDER BY o.ono LIMIT 1
    ) AS shared_officer,
    (SELECT o.officer FROM _offs o WHERE o.cid = c.cid ORDER BY o.ono DESC LIMIT 1) AS invest_officer,
    CASE
        WHEN d.use_spaced_ssn THEN p.ssn_spaced
        WHEN d.use_dotted_ssn THEN p.ssn_dotted
        ELSE c.subject_ssn
    END AS ssn_written,
    CASE WHEN d.use_dotted_phone THEN p.phone_dotted ELSE c.subject_phone END AS subj_phone_written,
    CASE WHEN d.use_misspell THEN p.witness0_misspelled ELSE w0.name END AS w0_name_written,
    CASE WHEN d.use_dotted_phone THEN p.witness0_phone_dotted ELSE w0.phone END AS w0_phone_written
FROM _doc_plan d
JOIN _cases c ON c.cid = d.cid
JOIN _plants p ON p.cid = d.cid
JOIN _wits w0 ON w0.cid = d.cid AND w0.slot = 1
JOIN _wits w1 ON w1.cid = d.cid AND w1.slot = 2;

-- Standard 10-section report (folder docs). Each section is multiple paragraphs
-- so write_pdf paginates to ~several pages and FN strings appear mid-document.
CREATE OR REPLACE TEMP TABLE _body_lines AS
SELECT doc_id, filename, line_no, body
FROM (
    SELECT
        x.doc_id,
        x.filename,
        gs.line_no,
        CASE gs.line_no
            WHEN 1 THEN format('CITY POLICE DEPARTMENT — {}', x.title)
            WHEN 2 THEN format('Case number: {}   Classification: {}', x.case_no, x.classification)
            WHEN 3 THEN format('Reporting officer: {}', x.shared_officer)
            WHEN 4 THEN 'SYNOPSIS'
            WHEN 5 THEN format(
                '{} The subject of this report is {} (DOB {}), whose residence of record is {}. This document supplements the master case file under number {} and is subject to redaction review prior to any release under public-records request.',
                x.lead, x.subject_name, x.subject_dob, x.subject_address, x.case_no
            )
            WHEN 6 THEN format(
                'The reporting officer, {}, was dispatched and assumed primary responsibility for the investigation described herein.',
                x.shared_officer
            )
            WHEN 7 THEN 'COMPLAINANT AND REPORTING PARTY'
            WHEN 8 THEN format(
                'Dispatch received a call for service at the location described below. On arrival, the reporting officer made contact with {} and confirmed identity by state-issued identification. No discrepancy was noted between the identification presented and department records.',
                x.subject_name
            )
            WHEN 9 THEN format(
                'A secondary caller, later identified as witness {}, remained on scene and was reachable by telephone at {} for follow-up.',
                x.w0_name_written, x.w0_phone_written
            )
            WHEN 10 THEN 'SUBJECT IDENTIFICATION'
            WHEN 11 THEN format(
                'Full name: {}. Date of birth: {}. The subject provided a social security number of {}, which the reporting officer recorded for the case file. Address of record at the time of contact was verified as {}. Contact telephone {}.',
                x.subject_name, x.subject_dob, x.ssn_written, x.subject_address, x.subj_phone_written
            )
            WHEN 12 THEN format(
                'Physical descriptors and photographs are retained in the evidence management system and are not reproduced in this narrative. The subject identifiers above ({}, {}) are flagged as confidential.',
                x.subject_name, x.ssn_written
            )
            WHEN 13 THEN 'NARRATIVE — INITIAL CONTACT'
            WHEN 14 THEN format(
                'Responding units located the involved parties near the intersection of {} and 9th Avenue. The area was well lit and foot traffic was light. {} was cooperative during the initial contact and made no spontaneous statements at that time.',
                x.fp_street, x.subject_name
            )
            WHEN 15 THEN format(
                'The reporting officer advised {} of the nature of the complaint. A canvass of {} produced no additional physical evidence. The scene was photographed and released without further incident.',
                x.subject_name, x.fp_street
            )
            WHEN 16 THEN 'WITNESS STATEMENTS'
            WHEN 17 THEN format(
                'Witness 1 — {}, telephone {} — provided a recorded statement describing the sequence of events consistent with the physical evidence. The witness was cooperative and agreed to be contacted for any subsequent proceedings.',
                x.w0_name_written, x.w0_phone_written
            )
            WHEN 18 THEN format(
                'Witness 2 — {}, telephone {} — corroborated the account in relevant part. Both witnesses were advised of the confidentiality of their contact information under department policy.',
                x.w1_name, x.w1_phone
            )
            WHEN 19 THEN 'EVIDENCE AND PROPERTY'
            WHEN 20 THEN format(
                'Items recovered were photographed, tagged, and entered into the property room under the master case number {}. Chain of custody was maintained by the reporting officer and the assigned evidence technician.',
                x.case_no
            )
            WHEN 21 THEN format(
                'A property receipt was issued to {} at {}. No items of apparent evidentiary value were released at the scene.',
                x.subject_name, x.subject_address
            )
            WHEN 22 THEN CASE WHEN x.use_collateral THEN format(
                'A sealed envelope recovered from the scene bore a handwritten note naming {} with a social security number of {}. That individual is not a party to this case; the number is retained for cross-reference only and is subject to redaction prior to any public release.',
                x.collateral_name, x.collateral_ssn_spaced
            ) ELSE 'No collateral identifiers were recovered at the scene beyond those already listed.' END
            WHEN 23 THEN 'LEGAL REVIEW AND SUPPRESSION'
            WHEN 24 THEN format(
                'Prior to the interview, counsel for the subject raised the applicability of {}, with respect to the scope of the search and the sequence of questioning. The reporting officer noted the objection on the record.',
                x.fp_citation
            )
            WHEN 25 THEN format(
                'The evidence was preserved for suppression review and no dispositive ruling was made in the field. The citation to {} is reproduced here for the reviewing prosecutor reference only.',
                x.fp_citation
            )
            WHEN 26 THEN 'FOLLOW-UP INVESTIGATION'
            WHEN 27 THEN format(
                'Detective {} conducted follow-up on the leads developed above, including a return visit to {} and a telephone re-interview of {} at {}. No new subjects were identified.',
                x.invest_officer, x.subject_address, x.w0_name_written, x.w0_phone_written
            )
            WHEN 28 THEN format(
                'The subject, {} (DOB {}), was determined to be the sole party of interest at the conclusion of the follow-up phase.',
                x.subject_name, x.subject_dob
            )
            WHEN 29 THEN 'OFFICER OBSERVATIONS'
            WHEN 30 THEN format(
                'Throughout the contact, {} remained calm and responsive. The reporting officer observed no indications of impairment or medical distress. Body-worn camera footage was activated and retained.',
                x.subject_name
            )
            WHEN 31 THEN 'These observations are the reporting officer own and are offered to assist the reviewing authority in weighing the statements above.'
            WHEN 32 THEN 'DISPOSITION AND CERTIFICATION'
            WHEN 33 THEN format(
                'This matter remains open pending prosecutorial review. All PII pertaining to {} (SSN {}, DOB {}, {}) and to the named witnesses is designated confidential and must be redacted before release.',
                x.subject_name, x.ssn_written, x.subject_dob, x.subject_address
            )
            WHEN 34 THEN format(
                'Certified by {} as true and accurate to the best of the officer knowledge under case {}.',
                x.shared_officer, x.case_no
            )
            -- Extra narrative mass so write_pdf paginates to multi-page folder docs
            -- (review UI and bulk flows need more than a single screen of words).
            WHEN 35 THEN format(
                'ADDENDUM A — TIMELINE. On the date of report the subject {} was contacted at {}. Identifiers on file include SSN {} and telephone {}. Witness {} ({}) and witness {} ({}) remain available for follow-up.',
                x.subject_name, x.subject_address, x.ssn_written, x.subj_phone_written,
                x.w0_name_written, x.w0_phone_written, x.w1_name, x.w1_phone
            )
            WHEN 36 THEN format(
                'ADDENDUM B — SCENE CANVASS. Units walked {} and adjacent blocks. No additional video was recovered. The citation {} was noted in the legal review package for the prosecutor.',
                x.fp_street, x.fp_citation
            )
            WHEN 37 THEN format(
                'ADDENDUM C — RECORDS CHECK. A records check on {} (DOB {}) returned no active warrants at the time of this writing. Address verification remained {}.',
                x.subject_name, x.subject_dob, x.subject_address
            )
            WHEN 38 THEN format(
                'ADDENDUM D — CHAIN OF CUSTODY. Evidence tags for case {} were initialed by {}. Property associated with {} was sealed and logged.',
                x.case_no, x.shared_officer, x.subject_name
            )
            WHEN 39 THEN format(
                'ADDENDUM E — CONTACT LOG. Attempted contact with {} at {} on two occasions. Messages left. Subject phone on file: {}.',
                x.w0_name_written, x.w0_phone_written, x.subj_phone_written
            )
            WHEN 40 THEN format(
                'ADDENDUM F — SUPERVISOR REVIEW. Supervisor notes that FP bait strings such as {} and the surname-sharing officer {} must be reviewed carefully before any public release of this report under case {}.',
                x.fp_street, x.shared_officer, x.case_no
            )
            WHEN 41 THEN format(
                'ADDENDUM G — CLOSING. End of narrative for {}. Subject {} / SSN {} / DOB {} / {} remains the focus of this file. Certified page block continues below as required by policy.',
                x.case_no, x.subject_name, x.ssn_written, x.subject_dob, x.subject_address
            )
            WHEN 42 THEN format(
                'ADDENDUM H — INDEX. Cross-references: subject {}; witnesses {}; {}; officer of record {}; legal cite {}.',
                x.subject_name, x.w0_name_written, x.w1_name, x.shared_officer, x.fp_citation
            )
            ELSE NULL
        END AS body
    FROM _doc_ctx x
    CROSS JOIN generate_series(1, 42) gs(line_no)
    WHERE x.stem <> 'consolidated_case_file'
) t
WHERE body IS NOT NULL;

-- Consolidated daily-activity log.
-- Target ≈ consolidated_pages letter pages. Empirically, one dense entry with
-- the padding below yields ~1.0–1.05 pages/entry under write_pdf (libharu), so
-- emit consolidated_pages entries → ~110 pages when consolidated_pages=110.
INSERT INTO _body_lines BY NAME
SELECT
    x.doc_id AS doc_id,
    x.filename AS filename,
    (e.entry - 1) * 3 + ln.n AS line_no,
    CASE ln.n
        WHEN 1 THEN format('DAILY ACTIVITY LOG — ENTRY {:03d} — CASE {}', e.entry, x.case_no)
        WHEN 2 THEN format(
            'On this date the reporting officer {} {} The activity pertains to the subject {} (DOB {}) of {}. '
            || 'Subject identifiers on file: name {}; SSN {}; date of birth {}; address {}. '
            || 'Witness of record {} remains reachable at {}. '
            || 'The reporting officer also noted FP bait location {} and legal reference {}. '
            || repeat(
                'Continuing activity narrative for bulk-review page mass under the master case file. ',
                30
            )
            || 'Entry certified for case {}.',
            x.shared_officer,
            (['reviewed body-worn camera footage and logged timestamps against the incident timeline.',
              'attempted telephone contact with the witness of record and left a callback message.',
              'prepared a supplemental evidence inventory for the assigned prosecutor.',
              'conducted a records check and confirmed the subject identifiers below.',
              'canvassed the area of the original contact for additional camera coverage.',
              'coordinated with the evidence technician on chain-of-custody documentation.',
              'drafted correspondence to counsel regarding the pending suppression question.',
              'updated the case management system and reconciled report numbering.'
             ])[1 + ((e.entry - 1) % 8)],
            x.subject_name, x.subject_dob, x.subject_address,
            x.subject_name, x.subject_ssn, x.subject_dob, x.subject_address,
            x.w0_name, x.w0_phone,
            x.fp_street, x.fp_citation,
            x.case_no
        )
        WHEN 3 THEN format(
            'Follow-up notes for entry {:03d}: no additional investigative activity beyond the contact above. '
            || 'Officer of record {} / subject {} / SSN {} / phone {}. '
            || repeat(
                'Policy 4.12 log line retained for redaction review surface page density. ',
                26
            )
            || 'End of entry {:03d}.',
            e.entry, x.shared_officer, x.subject_name, x.subject_ssn, x.subject_phone, e.entry
        )
    END AS body
FROM _doc_ctx x
CROSS JOIN generate_series(1, (SELECT consolidated_pages FROM _cfg)) e(entry)
CROSS JOIN generate_series(1, 3) ln(n)
WHERE x.stem = 'consolidated_case_file';

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. WRITE PDFs via write_pdf (libharu)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TEMP TABLE _written AS
SELECT
    d.doc_id,
    d.filename,
    d.case_no,
    d.mode_name,
    d.use_spaced_ssn,
    d.use_dotted_ssn,
    d.use_dotted_phone,
    d.use_misspell,
    d.use_collateral,
    write_pdf(
        -- Pad paragraphs so libharu paginates folder reports across multiple
        -- letter pages (short bare lines collapse into 1–2 pages).
        (SELECT string_agg(
            CASE
                WHEN length(b.body) < 80 THEN b.body  -- keep short headers tight
                ELSE b.body || ' '
                    || repeat(
                        'Continuing narrative for the case file redaction review surface. ',
                        3
                    )
            END,
            chr(10) ORDER BY b.line_no
         )
         FROM _body_lines b WHERE b.doc_id = d.doc_id),
        getvariable('samples_dir') || '/' || d.filename
    ) AS path
FROM _doc_plan d;

SELECT format('wrote {} PDFs', count(*)) AS pdf_status FROM _written;
SELECT
    regexp_replace(file, '.*/', '') AS filename,
    page_count AS pages,
    file_size
FROM pdf_info(getvariable('samples_dir') || '/*.pdf')
ORDER BY 1;

-- Consolidated must land near the configured page target (throughput demo fuel).
SELECT CASE
    WHEN (SELECT consolidated_pages FROM _cfg) = 0 THEN 'consolidated skipped'
    WHEN (
        SELECT page_count
        FROM pdf_info(getvariable('samples_dir') || '/*.pdf')
        WHERE position('consolidated_case_file' IN regexp_replace(file, '.*/', '')) > 0
        LIMIT 1
    ) IS NULL
    THEN error('consolidated_case_file PDF missing after write_pdf')
    WHEN (
        SELECT page_count
        FROM pdf_info(getvariable('samples_dir') || '/*.pdf')
        WHERE position('consolidated_case_file' IN regexp_replace(file, '.*/', '')) > 0
        LIMIT 1
    ) < cast((SELECT consolidated_pages FROM _cfg) * 0.85 AS INTEGER)
    THEN error(format(
        'consolidated page_count too low: got {}, want ~{} (raise entry padding)',
        (SELECT page_count FROM pdf_info(getvariable('samples_dir') || '/*.pdf')
         WHERE position('consolidated_case_file' IN regexp_replace(file, '.*/', '')) > 0
         LIMIT 1),
        (SELECT consolidated_pages FROM _cfg)
    ))
    ELSE format(
        'consolidated page_count ok: {} (target ~{})',
        (SELECT page_count FROM pdf_info(getvariable('samples_dir') || '/*.pdf')
         WHERE position('consolidated_case_file' IN regexp_replace(file, '.*/', '')) > 0
         LIMIT 1),
        (SELECT consolidated_pages FROM _cfg)
    )
END AS consolidated_page_gate;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. FALSE-NEGATIVE PLANTS + page locate via read_pdf_words
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE TEMP TABLE _fn_raw AS
SELECT w.doc_id, w.filename, w.case_no, fn.type, fn.text, fn.why, fn.canonical
FROM _written w
JOIN _doc_ctx x ON x.doc_id = w.doc_id
CROSS JOIN LATERAL (
    SELECT * FROM (
        SELECT 'spaced_ssn' AS type, x.ssn_spaced AS text,
               'SSN written with spaces evades a dash-delimited SSN / roster exact match' AS why,
               x.subject_ssn AS canonical
        WHERE x.use_spaced_ssn
        UNION ALL
        SELECT 'dotted_ssn', x.ssn_dotted,
               'SSN written with dots (XXX.XX.XXXX) evades dash-delimited matcher',
               x.subject_ssn
        WHERE x.use_dotted_ssn
        UNION ALL
        SELECT 'dotted_phone', x.witness0_phone_dotted,
               'Phone written with dots (NNN.NNN.NNNN) evades (NNN) NNN-NNNN roster match',
               x.w0_phone
        WHERE x.use_dotted_phone
        UNION ALL
        SELECT 'dotted_phone', x.phone_dotted,
               'Subject phone in dotted form; seed matcher targets parenthesized format',
               x.subject_phone
        WHERE x.use_dotted_phone
        UNION ALL
        SELECT 'misspelled_witness', x.witness0_misspelled,
               'surname typo never matches the canonical name list',
               x.w0_name
        WHERE x.use_misspell
        UNION ALL
        SELECT 'collateral_ssn', x.collateral_ssn_spaced,
               'Real-looking SSN for a non-roster person; entity list has no match target',
               x.collateral_ssn
        WHERE x.use_collateral
    )
) fn;

-- Locate first page where planted text appears.
-- Strategy: materialize words once (OCR off — digital libharu text layer only),
-- join page text with position(); avoid O(n^k) token self-joins.
CREATE OR REPLACE TEMP TABLE _all_words AS
SELECT
    regexp_replace(w.filename, '.*/', '') AS basename,
    w.page,
    regexp_replace(w.word, '[.,;:)]+$', '') AS tok,
    w.y0, w.x0
FROM read_pdf_words(
    getvariable('samples_dir') || '/*.pdf',
    auto_ocr := false,
    ocr := false
) w;

CREATE OR REPLACE TEMP TABLE _page_text AS
SELECT
    basename,
    page,
    string_agg(tok, ' ' ORDER BY round(y0, 1), x0, tok) AS page_text
FROM _all_words
GROUP BY basename, page;

CREATE OR REPLACE TEMP TABLE _fn_pages AS
SELECT
    f.doc_id,
    f.filename,
    f.case_no,
    f.type,
    f.text,
    f.why,
    f.canonical,
    min(p.page)::INT AS page
FROM _fn_raw f
JOIN _page_text p
  ON p.basename = f.filename
 AND position(f.text IN p.page_text) > 0
GROUP BY f.doc_id, f.filename, f.case_no, f.type, f.text, f.why, f.canonical;

-- Fail hard if any plant is missing from PDF words.
SELECT CASE
    WHEN (SELECT count(*) FROM _fn_raw) = 0 THEN 'no FN plants (canonical-only corpus)'
    WHEN (SELECT count(*) FROM _fn_raw f
          LEFT JOIN _fn_pages p ON p.doc_id = f.doc_id AND p.type = f.type AND p.text = f.text
          WHERE p.page IS NULL) = 0
    THEN format('FN plants located: {}', (SELECT count(*) FROM _fn_pages))
    ELSE error(format(
        'planted false_negatives not found via read_pdf_words: {}',
        (SELECT string_agg(f.filename || ':' || f.text, ', ')
         FROM _fn_raw f
         LEFT JOIN _fn_pages p ON p.doc_id = f.doc_id AND p.type = f.type AND p.text = f.text
         WHERE p.page IS NULL)
    ))
END AS fn_gate;

SELECT filename, type, text, page FROM _fn_pages ORDER BY filename, type, text;

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. MANIFEST (schema-compatible with existing ground-truth consumers)
-- ═══════════════════════════════════════════════════════════════════════════

COPY (
    SELECT to_json({
        'note': 'Ground-truth answer key. identities.json is a frozen fakeit fixture (fakeit is not seedable); regenerating it re-rolls all PII. false_negatives are real PII forms the seed matcher is expected to miss. fp_bait should be over-redacted then rejected by a human. Generated by samples/gen/01_identities.sql + 02_corpus.sql via scripts/generate-samples.sh.',
        'files': list(file_obj ORDER BY doc_id)
    })
    FROM (
        SELECT
            d.doc_id,
            {
                'filename': d.filename,
                'case_no': d.case_no,
                'pii': {
                    'subject_name': x.subject_name,
                    'ssn_written': [x.ssn_written],
                    'dob': x.subject_dob,
                    'address': x.subject_address,
                    'subject_phone': x.subj_phone_written,
                    'subject_phone_canonical': x.subject_phone,
                    'witnesses': [
                        {
                            'name': x.w0_name_written,
                            'canonical_name': x.w0_name,
                            'phone': x.w0_phone_written,
                            'canonical_phone': x.w0_phone
                        },
                        {
                            'name': x.w1_name,
                            'canonical_name': x.w1_name,
                            'phone': x.w1_phone,
                            'canonical_phone': x.w1_phone
                        }
                    ],
                    'field_tags': {
                        'name': 'identity.person.full_name',
                        'ssn': 'SSN',
                        'dob': 'datetime.date.iso',
                        'address': 'geography.address.full_address',
                        'phone': 'identity.person.phone_number'
                    }
                },
                'fp_bait': {
                    'street': x.fp_street,
                    'citation': x.fp_citation,
                    'surname_sharing_officer': x.shared_officer
                },
                'false_negatives': coalesce((
                    SELECT list({
                        'type': p.type,
                        'text': p.text,
                        'page': p.page,
                        'why': p.why
                    } ORDER BY p.type, p.text)
                    FROM _fn_pages p WHERE p.doc_id = d.doc_id
                ), []),
                'fn_plants': coalesce((
                    SELECT list({
                        'type': p.type,
                        'case_no': p.case_no,
                        'written': p.text,
                        'canonical': p.canonical,
                        'why': p.why,
                        'page': p.page
                    } ORDER BY p.type, p.text)
                    FROM _fn_pages p WHERE p.doc_id = d.doc_id
                ), [])
            } AS file_obj
        FROM _written d
        JOIN _doc_ctx x ON x.doc_id = d.doc_id
    )
) TO (getvariable('samples_dir') || '/manifest.json') (FORMAT csv, HEADER false, QUOTE '');

SELECT 'manifest.json written' AS manifest_status;

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. MESSY PDFs — edge cases for PDF handling (NOT ingested by samples/*.pdf)
-- ═══════════════════════════════════════════════════════════════════════════

-- Clean prior messy artifacts (keep directory).
-- DuckDB cannot rm; shell wrapper may leave old files. Overwrite known names.

-- 7a. Source text for scan pipeline, then image-only rebuild (no text layer).
SELECT write_pdf(
    E'CITY POLICE DEPARTMENT — SCANNED EVIDENCE EXHIBIT\n'
    || E'This page was rasterized and rebuilt without a text layer.\n'
    || E'Subject reference SSN 512-48-3391 phone (503) 555-0142.\n'
    || E'If a detector only reads the text layer, these identifiers are invisible.',
    getvariable('samples_dir') || '/messy/_scan_source.pdf'
) AS scan_source;

-- Prove rasterization path (pdf_to_png) — size recorded in messy manifest.
CREATE OR REPLACE TEMP TABLE _scan_raster AS
SELECT
    octet_length(pdf_to_png(
        getvariable('samples_dir') || '/messy/_scan_source.pdf', 1, 72
    )) AS png_bytes;

-- Image-only / scanned: valid PDF page with graphics, zero text operators.
-- (libharu write_pdf always emits a text layer; raw PDF bytes are required here.)
COPY (
    SELECT '%PDF-1.4
1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj
2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj
3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> >>endobj
4 0 obj<< /Length 68 >>stream
0.92 0.92 0.90 rg 36 36 540 720 re f
0.75 0.75 0.72 rg 72 400 468 200 re f
endstream
endobj
xref
0 5
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000220 00000 n 
trailer<< /Size 5 /Root 1 0 R >>
startxref
339
%%EOF
' AS b
) TO (getvariable('samples_dir') || '/messy/image_only_scanned.pdf') (FORMAT csv, HEADER false, QUOTE '', DELIMITER '|', ESCAPE '');

-- 7b. Encrypted / password-protected
SELECT write_pdf(
    E'CONFIDENTIAL — PASSWORD PROTECTED CASE NOTES\n'
    || E'Subject SSN 611-22-3344 phone (971) 555-8821.\n'
    || E'Release requires authorized credentials.',
    getvariable('samples_dir') || '/messy/_enc_source.pdf'
);
SELECT pdf_encrypt(
    getvariable('samples_dir') || '/messy/_enc_source.pdf',
    getvariable('samples_dir') || '/messy/encrypted.pdf',
    'closure-sample'
) AS encrypted_path;

-- 7c. Truncated / malformed (incomplete objects)
COPY (
    SELECT '%PDF-1.4
1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj
2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj
3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]
' AS b
) TO (getvariable('samples_dir') || '/messy/truncated.pdf') (FORMAT csv, HEADER false, QUOTE '', DELIMITER '|', ESCAPE '');

COPY (
    SELECT '%PDF-1.4
1 0 obj<< /Type /Catalog /Pages 99 0 R >>endobj
trailer<< /Root 1 0 R >>
%%EOF
' AS b
) TO (getvariable('samples_dir') || '/messy/malformed.pdf') (FORMAT csv, HEADER false, QUOTE '', DELIMITER '|', ESCAPE '');

-- 7d. Rotated 90°
SELECT write_pdf(
    E'ROTATED PAGE FIXTURE\n'
    || E'Subject name Jordan Example SSN 400-11-2233.\n'
    || E'Word boxes after rotation must come from post-rotate read_pdf_words.',
    getvariable('samples_dir') || '/messy/_rot_source.pdf'
);
SELECT pdf_rotate(
    getvariable('samples_dir') || '/messy/_rot_source.pdf',
    getvariable('samples_dir') || '/messy/rotated_90.pdf',
    90
) AS rotated_path;

-- 7e. Non-Latin / CJK (Helvetica cannot encode; stresses mojibake path)
SELECT write_pdf(
    E'日本語テスト 姓名：山田太郎 SSN 999-88-7777\n'
    || E'中文测试 姓名：张三 出生日期 1990年1月15日\n'
    || E'한글 테스트 이름: 김철수\n'
    || E'Mixed Latin: Witness Alice Chen and case file reference 24-009999.',
    getvariable('samples_dir') || '/messy/cjk_nonlatin.pdf'
) AS cjk_path;

-- Messy manifest: what each file stresses (not part of ingest answer key).
CREATE OR REPLACE TEMP TABLE _messy_meta AS
SELECT * FROM (VALUES
    (
        'image_only_scanned.pdf',
        'image_only_scanned',
        'Rasterize→rebuild with no text layer. Source text written via write_pdf, rasterized with pdf_to_png (see png_bytes), delivered artifact is graphics-only so read_pdf_words returns 0 rows without OCR.',
        NULL::VARCHAR,
        (SELECT png_bytes FROM _scan_raster)
    ),
    (
        'encrypted.pdf',
        'encrypted_password',
        'AES password-protected PDF via pdf_encrypt. Password: closure-sample. read_pdf_words without password must fail; with password := ''closure-sample'' extracts words.',
        'closure-sample',
        NULL::BIGINT
    ),
    (
        'truncated.pdf',
        'truncated_corrupt',
        'Truncated PDF bytes (page object cut off). pdf_info / read_pdf_words should error — ingest must isolate/skip bad files.',
        NULL, NULL
    ),
    (
        'malformed.pdf',
        'malformed_xref',
        'Broken catalog/pages graph (no readable pages). Stresses corrupt-file handling.',
        NULL, NULL
    ),
    (
        'rotated_90.pdf',
        'rotated_page',
        'pdf_rotate 90°. Word count preserved; coordinate axes swap. Redaction boxes must use post-rotate word geometry.',
        NULL, NULL
    ),
    (
        'cjk_nonlatin.pdf',
        'nonlatin_cjk',
        'Japanese/Chinese/Korean mixed with Latin via write_pdf (Helvetica). CJK becomes mojibake; ASCII tokens (SSN, Alice, Chen) survive. Do not plant non-Latin PII via write_pdf for answer-key fixtures.',
        NULL, NULL
    ),
    (
        '_scan_source.pdf',
        'scan_pipeline_source',
        'Intermediate text PDF used only to drive pdf_to_png for the image-only fixture. Not an edge-case under test by itself.',
        NULL, NULL
    ),
    (
        '_enc_source.pdf',
        'encrypt_pipeline_source',
        'Intermediate plaintext PDF before pdf_encrypt. Companion to encrypted.pdf.',
        NULL, NULL
    ),
    (
        '_rot_source.pdf',
        'rotate_pipeline_source',
        'Intermediate upright PDF before pdf_rotate. Companion to rotated_90.pdf.',
        NULL, NULL
    )
) t(filename, stress, description, password, png_bytes);

COPY (
    SELECT to_json({
        'note': 'Edge-case PDF corpus for handling tests. NOT loaded by server/ingest.sql (which globs samples/*.pdf only). Generated by samples/gen/01_identities.sql + 02_corpus.sql via scripts/generate-samples.sh.',
        'files': list({
            'filename': filename,
            'stress': stress,
            'description': description,
            'password': password,
            'png_bytes': png_bytes
        } ORDER BY filename)
    })
    FROM _messy_meta
) TO (getvariable('samples_dir') || '/messy/manifest.json') (FORMAT csv, HEADER false, QUOTE '');

-- Sanity on messy set (best-effort; corrupt files are expected to fail some probes).
SELECT 'image_only words (expect 0)' AS probe,
       (SELECT count(*) FROM read_pdf_words(
           getvariable('samples_dir') || '/messy/image_only_scanned.pdf',
           auto_ocr := false, ocr := false
       )) AS n;

SELECT 'encrypted with password words' AS probe,
       (SELECT count(*) FROM read_pdf_words(
           getvariable('samples_dir') || '/messy/encrypted.pdf',
           password := 'closure-sample'
       )) AS n;

SELECT 'rotated words' AS probe,
       (SELECT count(*) FROM read_pdf_words(
           getvariable('samples_dir') || '/messy/rotated_90.pdf'
       )) AS n;

SELECT 'cjk words (ASCII expected)' AS probe,
       (SELECT count(*) FROM read_pdf_words(
           getvariable('samples_dir') || '/messy/cjk_nonlatin.pdf'
       )) AS n;

-- ═══════════════════════════════════════════════════════════════════════════
-- 8. OPERATOR SUMMARY
-- ═══════════════════════════════════════════════════════════════════════════

SELECT
    c.case_no,
    c.subject_name AS subject,
    c.subject_ssn AS ssn,
    c.fp_street,
    (SELECT list(o.officer) FROM _offs o WHERE o.cid = c.cid) AS officers
FROM _cases c
ORDER BY c.cid;

SELECT
    d.filename,
    d.case_no,
    d.mode_name,
    i.page_count AS pages,
    (SELECT count(*) FROM _fn_pages p WHERE p.doc_id = d.doc_id) AS fn_count
FROM _written d
LEFT JOIN (
    SELECT regexp_replace(file, '.*/', '') AS basename, page_count
    FROM pdf_info(getvariable('samples_dir') || '/*.pdf')
) i ON i.basename = d.filename
ORDER BY d.filename;

SELECT
    '02_corpus.sql complete' AS status,
    (SELECT count(*) FROM _cases) AS cases,
    (SELECT count(*) FROM _written) AS pdfs,
    (SELECT count(*) FROM _fn_pages) AS fn_plants,
    (SELECT count(*) FROM _messy_meta) AS messy_entries;
