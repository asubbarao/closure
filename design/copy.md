# Closure — copy spec

The product is a throughput tool: a reviewer clears hundreds of AI redaction
suggestions per sitting. Every string exists to keep them moving or to make a
judgment call safe. The five mockups are direction, not panels — the app is
one review surface plus a case rollup; bulk, reject, and add-missed are
overlays inside the flow.

## Terminology (never substitute)

| Correct | Never |
|---|---|
| suggestion | detection, hit, finding |
| mark | box, highlight, annotation |
| accept / reject / undo | approve, dismiss, revert |
| flagged | low-confidence, warning |
| entity | group, cluster |
| add missed | manual redaction, draw box |
| lay the ink | apply, burn in |
| export | download, generate |

Decisions are always verbs the reviewer performs. Statuses are always the
past participle of the same verb ("Accept" → "accepted"), never a synonym.

## Review surface (the spine)

### Queue
- Group header: `{entity} · {kind} · {n} in case` + inline action `Accept all in case`
- Band filter chips: `{n} HIGH ≥90` / `{n} REVIEW` / `{n} FLAGGED`
  Note: numbers first — the reviewer scans counts, not labels.
- Item row: the matched text, a one-line context snippet with the match
  highlighted, confidence number, page ref. No status words on pending rows —
  pending is the default and needs no announcement.
- Progress (header): `{done} of {total} reviewed`

### Keyboard legend (persistent, footer)
`j k next / prev · a accept · r reject · e entity, case-wide · n add missed · u undo`

### Decision toasts (≤ 8 words + undo)
- Accept: `Accepted — "{text}"` `[u Undo]`
- Reject: `Rejected — "{text}"` `[u Undo]`
- Undo: `Restored to pending — "{text}"`
Note: past simple, names the exact text acted on. Never "successfully".

## Flagged items (the judgment moments)

### Why-card (on the current flagged suggestion)
- Title: `Likely a false positive`
- Body: one sentence of mechanism, one of context. Pattern:
  `Matched the {PATTERN} pattern via "{token}", but {what the context actually is}. Confidence lowered to {n}.`
- Actions: `Reject  r` / `Keep  a`
Note: the card argues; the reviewer rules. Never auto-reject.

### Reject-all panel
- Title: `Reject all matching`
- Body: `"{text}" matched the {PATTERN} pattern {n} times across {d} documents — always as {context}, never as the subject.`
- Action: `Reject all {n} — log as "{reason}"`
Note: the button states the audit consequence in the label.

## Bulk sheet (entity decision)

- Header: `{entity}` + `{KIND} · SUBJECT OF CASE {case}`
- Tally line: `{n} instances across {d} documents · {s} selected to accept · {x} excluded — different context · {r} already decided`
- Exclusion banner: `{x} flagged items are excluded from bulk accept — they require individual decisions. They are shown below with a red background.`
- Primary: `Accept {n} — lay the ink` · Secondary: `Reject selected`
- Footer: `Every bulk action writes one audit event per instance — who, what, when, prior state.`
Note: the count in the button is the contract; it must equal selected rows.

## Add missed (false negatives)

- Mode banner: `ADD MISSED MODE — drag to mark any text on the page · Esc to exit`
- Scope choice (the critical fork):
  - `This instance only` / `Redact just this one occurrence on p.{n}`
  - `Find & redact all matches in case` + count chip `{n} matches` /
    `Same text found on {p} other pages across {d} docs`
- Confirm: `Redact all {n} ⏎` · `Cancel`
- Provenance line: `Will log as reviewer-added · {actor} · reason: missed by AI`
Note: reviewer-added marks are born accepted — drawing the box IS the decision.

## Export

- Ready: `Export redacted case…`
- Blocked button + banner: `Export blocked: {d} documents have {n} flagged items that require individual judgment before export.` + `Jump to flagged items →`
- Done toast: `Exported {d} redacted documents · {n} redactions laid`
Note: blocked state names the unblock path, not just the refusal.

## Audit log

Row form: `{hh:mm} {verb} {object} — {detail} · {actor}`
- `14:31 rejected "Nienow Street" ×9 — matched PERSON, is a street name · not PII · A. Reviewer`
- `14:28 added missed redaction supplemental_report p.4 — "280 96 9531" (spaced SSN) · A. Reviewer`
Note: verbs in past simple, object quoted verbatim, reason after the dash.
The log is written in the same vocabulary as the buttons that caused it.

## Empty / edge states

- Queue cleared: `All suggestions reviewed. {n} flagged items remain →` (link)
  or, truly done: `Document clear. Next: {next_doc} ({n} pending)`
- No matches on add-missed search: `No other matches in this case.`
- Undo window expired (decision already exported): `Can't undo — already exported. Add a new decision instead.`
