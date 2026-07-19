# Design rationale (Part 3)

## Core interaction model

I built this as a triage inbox, not a word processor. The unit of work is a decision, not a page scroll.

- **Keyboard-first queue triage** — `j`/`k` move, `a` accept, `r` reject, `e` entity case-wide, `n` add missed, `u` undo. The queue is sorted by entity then confidence band so the hands stay on the home row for the common path.
- **Entity-level bulk decisions** — once I decide "Yasmine Nienow is PII," that decision fans out across every document via `entity_id`. Instances stay visible and reversible; bulk is a proposal that writes one audit event per instance, not a silent rewrite.
- **Why-cards on flagged items** — HIGH/REVIEW/FLAGGED bands (not a continuous slider). Flagged rows show a why-card on the mark (pattern match vs. actual context) so judgment is local to the page, not buried in a settings panel.

The PDF canvas is non-negotiable: without surrounding text I cannot tell subject from citation from street name.

## Alternatives considered and rejected

**React + Node/FastAPI (or similar multi-service stack).** Rejected to keep one process and zero services. One DuckDB binary owns the database, HTTP routes (`quackapi`), PDF geometry/redaction (`pdf`), and HTML (`tera`). Fewer deploy surfaces, fewer lock/sync bugs between API and store, and mutations stay SQL-shaped.

**Figma / v0 for mocks.** Rejected for plain HTML/CSS that is the same surface the app serves. Mockups under `design/` are the CSS source of truth; templates under `server/templates/` render the same tokens. Design and implementation cannot drift by tool.

Also rejected: table-only review (loses page context), continuous confidence filters (three decision modes beat a percentage), and silent entity apply (would ink "Det. C. Nienow" with the subject).

## False positives / negatives and the reviewer's mental model

**AI proposes, human disposes.** Status is never written by the detector; only `audit_events` change state (`v_suggestions` projects latest event; undo is another event).

- **False positives** — why-card + reject (or reject-all-matching for the same pattern). Flagged items are excluded from bulk-accept by default and require individual judgment; export stays blocked while any remain pending.
- **False negatives** — `n` + drag marks a box; scope is this instance or find-all-matches case-wide. Reviewer-added rows are first-class (`source = 'manual'`), logged distinctly from AI suggestions.

Mental model for a clerk: clear the HIGH band in bulk when safe, walk REVIEW with eyes on the canvas, stop cold on FLAGGED, and draw anything the model missed before export.

## Scaling

- **100+ suggestions** — band chips + entity grouping + bulk-accept on HIGH; flagged excluded so volume never becomes "accept all blindly."
- **50+ documents** — case dashboard with per-doc band bars and entity fan-out; one entity decision propagates; left rail keeps multi-doc navigation without two-up comparison.
- **Detection and geometry** — set-based SQL: `read_pdf_words` → n-gram views → roster match → boxes in PDF points. No per-suggestion Python loops on the hot path.

## User assumptions

Records clerk or detective doing public-records release. Keyboard-comfortable, desktop, multi-hour sessions under time pressure, legally accountable. They understand redaction; they do not want to tune ML. Every action should show what will hit the audit log before anxiety sets in.

## MVP vs. ideal

**MVP (this submission):** real PDF word boxes, roster-seeded suggestions, keyboard triage, entity bulk, add-missed, append-only audit, export via `pdf_redact` with a proof pass that re-reads output and expects zero residual hits.

**More time buys:** OCR for scanned pages; multi-reviewer sign-off / supervisor handoff on FLAGGED; version-pinned exports (content hash + policy version in the audit row); session resume and multi-reviewer presence; richer model rationales without leaving the why-card pattern.
