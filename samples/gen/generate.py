#!/usr/bin/env python3
"""Render the redaction-review sample corpus from samples/identities.json.

Usage:  python3 samples/gen/generate.py     # (re)writes samples/*.pdf + manifest.json

WHY typst (not DuckDB's write_pdf): typst embeds its fonts, so pages render
correctly through poppler / pdf_to_png on stock macOS. PDFs produced by other
means come out blank through that pipeline.

WHY read identities.json: fakeit is not seedable, so the identities are generated
ONCE (samples/gen/identities.sql) and committed as a frozen fixture. This script
holds NO hardcoded people — it only arranges the fixture's PII into narratives.

Produces:
  * ~10 folder documents at ~10 pages each across the 4 cases (incident /
    supplemental / interview / witness statement / evidence log / case summary),
    each a 10-section report whose prose naturally embeds the case PII plus the
    false-positive bait (an intersection at "<surname> Street", a citation
    "<surname> v. Ohio", and a report signed by an officer sharing the subject's
    surname).
  * ONE ~110-page consolidated case file for case 1 (110 daily-activity logs),
    so the subject/witness entities recur ~110x — fuel for bulk-review flows.

Plants recorded in samples/manifest.json:
  * false-positive bait  (fp_bait): should be surfaced then dismissed by a human.
  * false-negative plants (fn_plants): a seeded detector may legitimately MISS
    these — the subject SSN written with spaces, and a witness surname misspelled.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

SAMPLES = Path(__file__).resolve().parent.parent
TEMPLATE = Path(__file__).resolve().parent / "report.typ"
IDENTITIES = SAMPLES / "identities.json"


# ---------------------------------------------------------------------------
# Fixture access + derived values
# ---------------------------------------------------------------------------
def load_cases() -> dict[str, dict]:
    cases = json.loads(IDENTITIES.read_text())["cases"]
    return {c["case_no"]: c for c in cases}


def surname(full_or_officer: str) -> str:
    """Last name from a person name, or from an 'Ofc. F. Lastname #NNNN' string."""
    token = full_or_officer.split("#")[0].strip()
    return token.split()[-1]


def shared_officer(case: dict) -> str | None:
    """The planted officer whose surname equals the subject's (case 1), else None."""
    subj = surname(case["subject"]["name"])
    return next((o for o in case["officers"] if surname(o) == subj), None)


def misspell(name: str) -> str:
    """A plausible one-letter typo of the surname (drop an interior letter)."""
    first, last = name.rsplit(" ", 1)
    typo = last[:2] + last[3:] if len(last) >= 4 else last[:-2] + last[-1] + last[-2]
    return f"{first} {typo}"


# ---------------------------------------------------------------------------
# Narrative — 10 realistic report sections that embed the PII + bait.
# ---------------------------------------------------------------------------
def para(*parts: str) -> str:
    return " ".join(" ".join(p.split()) for p in parts if p.strip())


def report_sections(case: dict, lead: str, *,
                     spaced_ssn: bool = False, misspell_w1: bool = False) -> list[dict]:
    s = case["subject"]
    name, dob, addr = s["name"], s["dob"], s["address"]
    ssn = s["ssn"].replace("-", " ") if spaced_ssn else s["ssn"]
    w0, w1 = case["witnesses"][0], case["witnesses"][1]
    w0name = misspell(w0["name"]) if misspell_w1 else w0["name"]
    signer = shared_officer(case) or case["officers"][0]
    invest = case["officers"][-1]
    fp_street, fp_cit = case["fp_street"], case["fp_citation"]

    return [
        {"heading": "SYNOPSIS", "paras": [
            para(lead, f"The subject of this report is {name} (DOB {dob}), whose",
                 f"residence of record is {addr}. This document supplements the master",
                 f"case file under number {case['case_no']} and is subject to redaction",
                 "review prior to any release under public-records request."),
            para(f"The reporting officer, {signer}, was dispatched and assumed",
                 "primary responsibility for the investigation described herein.")]},
        {"heading": "COMPLAINANT AND REPORTING PARTY", "newpage": True, "paras": [
            para("Dispatch received a call for service at the location described below.",
                 f"On arrival, the reporting officer made contact with {name} and",
                 "confirmed identity by state-issued identification. No discrepancy was",
                 "noted between the identification presented and department records."),
            para(f"A secondary caller, later identified as witness {w0name}, remained on",
                 f"scene and was reachable by telephone at {w0['phone']} for follow-up.")]},
        {"heading": "SUBJECT IDENTIFICATION", "newpage": True, "paras": [
            para(f"Full name: {name}. Date of birth: {dob}. The subject provided a social",
                 f"security number of {ssn}, which the reporting officer recorded for the",
                 "case file. Address of record at the time of contact was verified as",
                 f"{addr}."),
            para("Physical descriptors and photographs are retained in the evidence",
                 "management system and are not reproduced in this narrative. The subject's",
                 f"identifiers above ({name}, {ssn}) are flagged as confidential.")]},
        {"heading": "NARRATIVE — INITIAL CONTACT", "newpage": True, "paras": [
            para("Responding units located the involved parties near the intersection of",
                 f"{fp_street} and 9th Avenue. The area was well lit and foot traffic was",
                 f"light. {name} was cooperative during the initial contact and made no",
                 "spontaneous statements at that time."),
            para(f"The reporting officer advised {name} of the nature of the complaint.",
                 f"A canvass of {fp_street} produced no additional physical evidence.",
                 "The scene was photographed and released without further incident.")]},
        {"heading": "WITNESS STATEMENTS", "newpage": True, "paras": [
            para(f"Witness 1 — {w0name}, telephone {w0['phone']} — provided a recorded",
                 "statement describing the sequence of events consistent with the physical",
                 "evidence. The witness was cooperative and agreed to be contacted for",
                 "any subsequent proceedings."),
            para(f"Witness 2 — {w1['name']}, telephone {w1['phone']} — corroborated the",
                 "account in relevant part. Both witnesses were advised of the",
                 "confidentiality of their contact information under department policy.")]},
        {"heading": "EVIDENCE AND PROPERTY", "newpage": True, "paras": [
            para("Items recovered were photographed, tagged, and entered into the property",
                 f"room under the master case number {case['case_no']}. Chain of custody was",
                 "maintained by the reporting officer and the assigned evidence technician."),
            para(f"A property receipt was issued to {name} at {addr}. No items of apparent",
                 "evidentiary value were released at the scene.")]},
        {"heading": "LEGAL REVIEW AND SUPPRESSION", "newpage": True, "paras": [
            para("Prior to the interview, counsel for the subject raised the applicability",
                 f"of {fp_cit}, with respect to the scope of the search and the sequence of",
                 "questioning. The reporting officer noted the objection on the record."),
            para("The evidence was preserved for suppression review and no dispositive",
                 f"ruling was made in the field. The citation to {fp_cit} is reproduced",
                 "here for the reviewing prosecutor's reference only.")]},
        {"heading": "FOLLOW-UP INVESTIGATION", "newpage": True, "paras": [
            para(f"Detective {invest} conducted follow-up on the leads developed above,",
                 f"including a return visit to {addr} and a telephone re-interview of",
                 f"{w0name} at {w0['phone']}. No new subjects were identified."),
            para(f"The subject, {name} (DOB {dob}), was determined to be the sole party of",
                 "interest at the conclusion of the follow-up phase.")]},
        {"heading": "OFFICER OBSERVATIONS", "newpage": True, "paras": [
            para(f"Throughout the contact, {name} remained calm and responsive. The",
                 "reporting officer observed no indications of impairment or medical",
                 "distress. Body-worn camera footage was activated and retained."),
            para("These observations are the reporting officer's own and are offered to",
                 "assist the reviewing authority in weighing the statements above.")]},
        {"heading": "DISPOSITION AND CERTIFICATION", "newpage": True, "paras": [
            para(f"This matter remains open pending prosecutorial review. All PII pertaining",
                 f"to {name} (SSN {ssn}, DOB {dob}, {addr}) and to the named witnesses is",
                 "designated confidential and must be redacted before release."),
            para(f"Certified by {signer} as true and accurate to the best of the officer's",
                 f"knowledge under case {case['case_no']}.")]},
    ]


def daily_log_sections(case: dict, n: int) -> list[dict]:
    """n daily-activity-log sections (one page each) for the consolidated file.
    Each entry repeats the case PII so entities recur ~n times across the file."""
    s = case["subject"]
    name, ssn, dob, addr = s["name"], s["ssn"], s["dob"], s["address"]
    w0 = case["witnesses"][0]
    signer = shared_officer(case) or case["officers"][0]
    activities = [
        "reviewed body-worn camera footage and logged timestamps against the incident timeline",
        "attempted telephone contact with the witness of record and left a callback message",
        "prepared a supplemental evidence inventory for the assigned prosecutor",
        "conducted a records check and confirmed the subject identifiers below",
        "canvassed the area of the original contact for additional camera coverage",
        "coordinated with the evidence technician on chain-of-custody documentation",
        "drafted correspondence to counsel regarding the pending suppression question",
        "updated the case management system and reconciled report numbering",
    ]
    out = []
    for i in range(1, n + 1):
        act = activities[(i - 1) % len(activities)]
        out.append({
            "heading": f"DAILY ACTIVITY LOG — ENTRY {i:03d}",
            "newpage": i > 1,  # entry 1 shares page 1 with the cover block -> ~n pages
            "paras": [
                para(f"On this date the reporting officer {signer} {act}. The activity",
                     f"pertains to the subject {name} (DOB {dob}) of {addr}."),
                para(f"Subject identifiers on file: name {name}; SSN {ssn}; date of birth",
                     f"{dob}; address {addr}. Witness of record {w0['name']} remains",
                     f"reachable at {w0['phone']}. Entry certified for case {case['case_no']}."),
                para("No additional investigative activity was recorded for this period",
                     "beyond the contact noted above. Log maintained per policy 4.12."),
            ],
        })
    return out


# ---------------------------------------------------------------------------
# Corpus definition
# ---------------------------------------------------------------------------
def build_corpus(cases: dict[str, dict]) -> list[dict]:
    """Return a list of {filename, case_no, data, fn_plants} doc descriptors."""
    docs: list[dict] = []

    def rep(case_no, filename, title, classification, lead, **plants):
        case = cases[case_no]
        secs = report_sections(case, lead,
                               spaced_ssn=plants.get("spaced_ssn", False),
                               misspell_w1=plants.get("misspell_w1", False))
        signer = shared_officer(case) or case["officers"][0]
        fn = []
        if plants.get("spaced_ssn"):
            fn.append({"type": "spaced_ssn", "case_no": case_no,
                       "written": case["subject"]["ssn"].replace("-", " "),
                       "canonical": case["subject"]["ssn"],
                       "why": "SSN written with spaces evades a dash-delimited SSN regex"})
        if plants.get("misspell_w1"):
            fn.append({"type": "misspelled_witness", "case_no": case_no,
                       "written": misspell(case["witnesses"][0]["name"]),
                       "canonical": case["witnesses"][0]["name"],
                       "why": "surname typo never matches the canonical name list"})
        docs.append({
            "filename": filename, "case_no": case_no,
            "data": {"case_no": case_no, "title": title, "date": "See case file",
                     "classification": classification, "officer": signer,
                     "sections": secs},
            "fn_plants": fn,
        })

    # Case 1 (24-000117) — richest cluster; carries both FN plants.
    c1 = "24-000117"
    rep(c1, "incident_report_2024-0117.pdf", "Incident Report",
        "Assault — Investigation",
        "This incident report documents the initial response and investigation.")
    rep(c1, "supplemental_report_2024-0117A.pdf", "Supplemental Report",
        "Assault — Follow-up",
        "This supplemental report memorializes follow-up investigation.",
        spaced_ssn=True)                     # FN plant #1
    rep(c1, "interview_transcript_2024-0117C.pdf", "Interview Transcript",
        "Assault — Interview",
        "This transcript summarizes a recorded interview.",
        misspell_w1=True)                    # FN plant #2
    rep(c1, "case_summary_2024-0117.pdf", "Case Summary for Prosecution",
        "Assault — Summary",
        "This summary is prepared for prosecutorial review.")

    # Case 2 (24-000233)
    c2 = "24-000233"
    rep(c2, "arrest_report_2024-0233.pdf", "Arrest Report", "Burglary — Custody",
        "This arrest report documents a custodial arrest and booking.")
    rep(c2, "witness_statement_2024-0233B.pdf", "Witness Statement",
        "Burglary — Statement",
        "This document records a sworn witness statement.")

    # Case 3 (24-000312)
    c3 = "24-000312"
    rep(c3, "incident_report_2024-0312.pdf", "Incident Report",
        "Burglary — Investigation",
        "This incident report documents a reported burglary.")
    rep(c3, "evidence_log_2024-0312.pdf", "Evidence Log", "Burglary — Evidence",
        "This evidence log accompanies the master case file.")

    # Case 4 (24-000405)
    c4 = "24-000405"
    rep(c4, "incident_report_2024-0405.pdf", "Incident Report",
        "Trespass — Investigation",
        "This incident report documents a reported criminal trespass.")
    rep(c4, "property_receipt_2024-0405.pdf", "Property Receipt",
        "Trespass — Property",
        "This property receipt accompanies the master case file.")

    # One ~110-page consolidated case file for case 1.
    case = cases[c1]
    signer = shared_officer(case) or case["officers"][0]
    docs.append({
        "filename": "consolidated_case_file_2024-0117.pdf", "case_no": c1,
        "data": {"case_no": c1, "title": "Consolidated Case File",
                 "date": "See case file", "classification": "Assault — Full File",
                 "officer": signer, "sections": daily_log_sections(case, 110)},
        "fn_plants": [],
    })
    return docs


# ---------------------------------------------------------------------------
# Manifest — the ground-truth answer key.
# ---------------------------------------------------------------------------
def manifest_entry(doc: dict, cases: dict[str, dict]) -> dict:
    case = cases[doc["case_no"]]
    s = case["subject"]
    fn_types = {p["type"] for p in doc["fn_plants"]}
    ssn_written = [s["ssn"]]
    if "spaced_ssn" in fn_types:
        ssn_written = [s["ssn"].replace("-", " ")]  # this doc writes only the spaced form
    witnesses = []
    for i, w in enumerate(case["witnesses"]):
        as_written = w["name"]
        if i == 0 and "misspelled_witness" in fn_types:
            as_written = misspell(w["name"])
        witnesses.append({"name": as_written, "canonical_name": w["name"],
                          "phone": w["phone"]})
    return {
        "filename": doc["filename"], "case_no": doc["case_no"],
        "pii": {
            "subject_name": s["name"],
            "ssn_written": ssn_written,
            "dob": s["dob"], "address": s["address"], "subject_phone": s["phone"],
            "witnesses": witnesses,
        },
        "fp_bait": {
            "street": case["fp_street"],
            "citation": case["fp_citation"],
            "surname_sharing_officer": shared_officer(case),
        },
        "fn_plants": doc["fn_plants"],
    }


def main() -> int:
    if not IDENTITIES.exists():
        print(f"missing {IDENTITIES}; run identities.sql first", file=sys.stderr)
        return 1
    cases = load_cases()

    # Delete stale sample PDFs before regenerating.
    for old in SAMPLES.glob("*.pdf"):
        old.unlink()

    corpus = build_corpus(cases)
    for d in corpus:
        out = SAMPLES / d["filename"]
        proc = subprocess.run(
            ["typst", "compile", "--input", f"data={json.dumps(d['data'])}",
             str(TEMPLATE), str(out)],
            capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"FAILED {d['filename']}:\n{proc.stderr}", file=sys.stderr)
            return 1
        print(f"wrote {d['filename']}")

    manifest = {
        "note": "Ground-truth answer key. identities.json is a frozen fakeit "
                "fixture (fakeit is not seedable); regenerating it re-rolls all PII.",
        "files": [manifest_entry(d, cases) for d in corpus],
    }
    (SAMPLES / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"\n{len(corpus)} PDFs + manifest.json in {SAMPLES}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
