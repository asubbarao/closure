# Closure — Design Rationale
**Part 1 design mockup suite · Round 2 · A. Subbarao · Case 24-000117**

---

## Core thesis: triage, not reading

The interaction model is borrowed from a judicial clerk's inbox, not a word processor. The reviewer's job is to *decide*, not to *discover*. That means the information hierarchy is:

1. **What needs a decision right now?** (The suggestion queue, sorted by entity then confidence)
2. **Where is it on the page?** (The PDF canvas, with marks at real PDF coordinates)
3. **What does the AI think, and why is it uncertain?** (Confidence score + flagging rationale inline)

Everything else — audit log, export, case stats — is one click away but never competes for attention during the review flow.

---

## Interaction model: keyboard-first inbox

```
j / k     Move to next / previous suggestion
a         Accept (lay the ink)
r         Reject (clear the mark)
e         Accept entity case-wide (propagate to all 5 documents)
n + drag  Add a missed redaction (false negative)
u         Undo (last action, always available)
```

The queue is grouped by **entity**, not by document or page. This is intentional: the fundamental decision unit is "should Yasmine Nienow be redacted?" — not "should this word on page 3 be redacted?" Once you decide at the entity level, the decision propagates across every document with individual per-instance visibility.

---

## How confidence is shown (assignment bullet 6)

Confidence scores are displayed in three triage bands, not on a continuous scale:

| Band | Range | Color | Treatment |
|------|-------|-------|-----------|
| HIGH | ≥90 | Ink/black | Candidates for bulk-verify; safe to accept-all via `e` |
| REVIEW | 60–89 | Amber | Need a look; confidence lowered for a reason shown inline |
| FLAGGED | <60 | Red | **Always require individual human judgment** — excluded from bulk operations by default |

The FLAGGED band is where the hard problems live: "Nienow v. Ohio" (surname matches PERSON but is a case citation), "Det. C. Nienow" (surname matches SUBJECT but is an officer). These items have dashed outlines on the canvas and red backgrounds in the queue, and the export is blocked until they are individually resolved. The callout in the bulk-review sheet ("5 flagged items excluded from bulk-accept by default") makes this explicit.

A numeric score appears on every row alongside its band color so a reviewer can see *how* high-confidence or *how* flagged an item is without reading a tooltip.

---

## The six required scenarios and which screen covers each

| # | Scenario | Screen |
|---|----------|--------|
| 1 | The main review interface | `02_review.html` |
| 2 | Reject a bad AI suggestion (false positive) | `03_reject_false_positive.html` |
| 3 | Add a missed redaction (false negative) | `04_add_missed_redaction.html` |
| 4 | Bulk operations | `05_bulk_review.html` |
| 5 | Multi-document workflow | `01_case_dashboard.html` + left rail in 02 |
| 6 | Confidence levels | All screens, triaged as HIGH / REVIEW / FLAGGED |

---

## False positive design (screen 03)

When the AI flags an item it's uncertain about, two affordances appear simultaneously:

- **Why-card callout**: anchored to the mark on the page, showing the specific linguistic reason the confidence was lowered, with an entity-comparison table ("Matched: Nienow Street [STREET NAME] vs. Subject: Yasmine Nienow [PERSON]"), and two clear actions: Reject `r` or Keep `a`.
- **Reject-all-matching panel**: in the right rail, showing every occurrence of the same false pattern across all documents. One button ("Reject all 9 — log as 'street name'") clears them all.

After rejection, an undo toast appears with the full audit preview visible *before* the user commits (shown as a "will be written" preview in the queue panel). This prevents the anxiety of "what did I just write to the legal record?"

---

## False negative design (screen 04)

The missed-redaction flow is triggered by `n` + drag, switching the cursor to crosshair and showing a mode banner. After releasing the drag, a popover appears with:

- **Category picker** (PERSON / SSN / PHONE / ADDRESS / DOB / OTHER) — defaults to best guess
- **Scope choice**: this instance only, or find-and-redact-all (with live match count: "7 other pages across 3 docs")
- **Audit preview**: shows that the item will be logged as "reviewer-added" distinct from AI-suggested

Manually added items appear in a dedicated **Reviewer-added** section at the top of the queue, styled in blue (current focus color). They are first-class citizens — not a footnote. Previously added missed items stay visible in this section with a "ADDED ✓" badge.

---

## Multi-document workflow (screen 01)

The case dashboard shows:
- Per-document **confidence-band mini-bars** (HIGH/REVIEW/FLAGGED/REJECTED as proportional colored segments)
- A **blocked-export banner** making it explicit which documents and how many flagged items are preventing export
- The **entity panel**: "decide once, propagates everywhere" — with flagged entities explicitly labeled HUMAN REQUIRED and shown in red

The interaction model is: start at the dashboard to see the big picture, click into the document with the most pending flagged items first, work through HIGH items with bulk-accept, then resolve REVIEW items individually, then face FLAGGED items one at a time.

---

## Assumptions about users

- Experienced administrative reviewers, not AI engineers. They understand "redaction" as a concept but don't think in confidence percentages.
- Working at a desktop, in a dedicated workflow session — not on mobile.
- Under time pressure. 100-page documents with 400+ suggestions is a real workload; we need to make the fast path (bulk-accept HIGH items) feel safe, not reckless.
- Legally accountable. Every decision needs an audit entry. The system should make it hard to take an action without knowing what it will write to the log.

---

## Alternatives considered and rejected

**Presentation as a table** (all suggestions as rows, no document canvas): Faster to scan in aggregate, but destroys context. You cannot tell if "Yasmine Nienow" on page 4 is the subject or a street name without seeing the surrounding sentence — and even that is often not enough without the broader paragraph. The canvas is non-negotiable.

**Continuous confidence slider filter**: More expressive, but cognitive overhead without added value. Three semantic bands (safe / look closer / must decide) map to human decision modes better than a percentage.

**Entity decisions applying silently**: The original risk was: accept "Yasmine Nienow" case-wide, and every mention — including "Det. C. Nienow" — gets silently redacted. The solution is to keep entity decisions as *proposals* that propagate visibly and remain individually reversible, not as silent bulk operations.

**Side-by-side two-up view**: Considered for multi-document comparison but deferred. The entity panel in the dashboard covers the multi-doc review need without the cognitive cost of comparing two pages simultaneously.

---

## What I would do with more time (MVP vs. ideal)

**MVP** (what this mockup represents): Manual review of AI suggestions with entity-level bulk operations, missed-item addition, and a tamper-evident audit log.

**Next iteration**:
- Animated state transitions (accept → ink animation; the mark "sets" like a stamp)
- Inline confidence *explanation* beyond the why-card — full model reasoning, similar cases
- Reviewer assignment and handoff: "pass to supervisor" for FLAGGED items
- Keyboard shortcut for "accept all HIGH in this document" (one-stroke, safeguarded by confirmation)
- Progress persistence: resume where you left off across sessions
- Real-time collaboration indicators (two reviewers working the same case)
