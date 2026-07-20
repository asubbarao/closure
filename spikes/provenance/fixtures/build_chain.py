#!/usr/bin/env python3
"""Build multi-revision PDF fixtures for the provenance spike.

Uses pypdf PdfWriter(fileobj=..., incremental=True) so each save APPENDS a new
xref/%%EOF segment (true PDF incremental update). pdf_revisions then enumerates
the startxref/%%EOF chain.

Run from repo root:
  python3 spikes/provenance/fixtures/build_chain.py
"""
from __future__ import annotations

import shutil
from pathlib import Path

from pypdf import PdfWriter

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
SRC = REPO / "samples" / "incident_report_2024-001001.pdf"


def bump(inp: Path, out: Path, title: str, keywords: str) -> None:
    w = PdfWriter(fileobj=str(inp), incremental=True)
    w.add_metadata(
        {
            "/Title": title,
            "/Author": "closure-provenance-spike",
            "/Keywords": keywords,
        }
    )
    with open(out, "wb") as f:
        w.write(f)


def main() -> None:
    if not SRC.is_file():
        raise SystemExit(f"missing sample PDF: {SRC}")

    r0 = ROOT / "chain_r0.pdf"
    shutil.copy(SRC, r0)
    bump(r0, ROOT / "chain_r1.pdf", "Incident Report R1", "rev1")
    bump(ROOT / "chain_r1.pdf", ROOT / "chain_r2.pdf", "Incident Report R2", "rev2")
    bump(ROOT / "chain_r2.pdf", ROOT / "chain_r3.pdf", "Incident Report R3", "rev3")

    # Mid-review tamper: another incremental save (hash + revision_count both move).
    w = PdfWriter(fileobj=str(ROOT / "chain_r3.pdf"), incremental=True)
    w.add_metadata({"/Title": "TAMPERED", "/Keywords": "tamper"})
    with open(ROOT / "chain_r3_tampered.pdf", "wb") as f:
        w.write(f)

    for p in sorted(ROOT.glob("chain_*.pdf")):
        data = p.read_bytes()
        print(
            f"{p.name:28s} size={p.stat().st_size:6d}  "
            f"%%EOF={data.count(b'%%EOF')}  startxref={data.count(b'startxref')}"
        )


if __name__ == "__main__":
    main()
