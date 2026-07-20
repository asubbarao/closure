# Phase 1 — Blind Interaction Thesis

**Constraint:** Written from the assignment brief only. No existing mocks consulted.

## The problem restated

A human must clear ~2,394 AI redaction suggestions across 1,000+ pages and 10–50 related files. The product metric is **reviewer throughput**: decisions per minute, with nothing missed and nothing wrongly redacted. Unredacting false positives is core. Adding missed redactions is secondary.

## Is the unit a suggestion? No.

If the interface treats each suggestion as a row in a 2,394-item inbox, the human loses. Even at 4 seconds per decision, that is ~2.5 hours of pure keystroke labor—before context switches, multi-file thrash, and fatigue errors. The only way 1,000+ pages feel like a handful of decisions is **cardinality collapse**: many suggestions must share one human decision.

## Primary navigation unit: the Decision Cluster

**Primary unit = Decision Cluster** — a set of suggestions the system claims can share one accept/reject.

Three nested cluster kinds, coarsest first:

1. **Entity cluster** (default): one normalized string (e.g. a person’s full name, one SSN, one badge number) and every occurrence across the entire case. Accept once → ink everywhere that string appears. Reject once → clear the false-positive everywhere.
2. **Pattern cluster** (power mode): same *shape* of sensitive data when values differ but the decision is identical—“all DOB fields,” “all 10-digit phones matching this officer’s line,” “all street addresses on Maple Ave.” Useful when the AI over-generates on a form template repeated across files.
3. **Occurrence** (exception path): a single suggestion on a single page. Used only when context splits the entity (defendant name in a caption vs. the same string as a case citation).

**Not primary:** page, document, or raw suggestion index. Those are lenses and anchors, not the queue.

Why this beats page-first and doc-first:

- False positives are almost always **type-wrong**, not page-wrong (“Smith St.” is a street everywhere it appears as an address line).
- True positives for identifiers are almost always **case-wide** (victim name, SSN, home address).
- Multi-file work dies if the same name is re-decided per PDF. The workspace is the **case**.

## How the stream works (push, not only pull)

Two complementary modes:

- **Decision Stream (push):** the system surfaces the next *highest-leverage* undecided cluster—scoring by `(open occurrences × confidence uncertainty × files touched)`. The reviewer lands on a decision card, samples 1–3 contexts, hits accept/reject, and the next cluster advances. This is the default for HIGH-confidence burn-down.
- **Case Map / Ledger (pull):** a left rail of all open clusters, filterable by confidence band, entity type, and document. Used for search, jump, and “finish the last 40 REVIEW items.”

Throughput comes from the stream; confidence and safety come from always being able to pull and drill.

## Bulk operations

Bulk is layered and **confidence-gated**:

| Layer | What it does | Gate |
|-------|----------------|------|
| Entity accept/reject | All pending occurrences of one string | Always available |
| Multi-select | Space-select N clusters → accept/reject selection | Available; flagged excluded |
| Band bulk | “Accept remaining HIGH person-names with no flags” | HIGH only; preview count + samples; confirm |
| Pattern bulk | Accept/reject a pattern cluster | REVIEW+ requires expand-once |

**Flagged is sacred.** Any flagged suggestion is excluded from every bulk path. Bulk fails closed if it would touch flagged ink.

Every bulk action is one undoable transaction with a human-readable summary (“Accepted 47 of YASMINE NIENOW across 12 files”).

## Multi-file model

- Queue and stream are **case-scoped**, not file-scoped.
- Each cluster shows footprint: `12 files · 47 hits · 3 open`.
- Accepting an entity writes across every file that contains it.
- A document strip answers “which files still dirty?” without becoming the primary nav.
- Progress chrome is always absolute: `1,847 / 2,394 decided · 18 / 23 files clear`.

## Confidence as triage engine

Confidence is a **sort key and a permission**, not a decorative badge.

| Band | Posture | Bulk |
|------|---------|------|
| **HIGH** (≥~90%) | Stream fire: sample context → accept | Eligible for band bulk |
| **REVIEW** (~60–89%) | Full context + page peek required | Entity bulk only after glance |
| **LOW / FLAGGED** | Slow path; never auto-include | Banned from band bulk |

Default triage order: burn HIGH (volume), then REVIEW (judgment), then FLAGGED (care). Progress is shown per band so “HIGH is empty” is a real milestone.

## Keyboard model

Trained operator; mouse is secondary. No modals on the happy path.

| Key | Action |
|-----|--------|
| `j` / `k` | Next / previous cluster in stream or filtered ledger |
| `n` / `p` | Next / previous occurrence inside cluster |
| `a` | Accept cluster (all pending occurrences, all files) |
| `r` | Reject cluster |
| `o` / `x` | Accept / reject **this occurrence only** (split) |
| `e` | Expand occurrence list |
| `f` | Flag |
| `Space` | Multi-select toggle |
| `Shift+a` / `Shift+r` | Accept / reject selection |
| `u` | Undo last transaction |
| `g` then `h`/`v`/`l` | Jump filter HIGH / REVIEW / LOW |
| `/` | Search entity string |
| `m` | Toggle case map / stream focus |
| `?` | Cheat sheet |

## Core screen spatial model

Not “PDF canvas with a sidebar of 2,394 rows.”

1. **Top progress:** absolute position in 2,394 + band burn-down + files clear.
2. **Left — Decision ledger:** open clusters sorted by leverage; band chips; multi-select.
3. **Center — Decision card (star):** entity string, type, confidence distribution, 2–3 live context snippets with file·page, footprint map across docs, big Accept / Reject.
4. **Right (collapsible) — Page peek:** PDF fragment for the focused occurrence only when needed—not the permanent center of gravity.
5. **Footer:** last transaction + undo + key legend.

The radical claim: **the decision card is the product; the PDF is a verification tool.** At 2,394 scale, living inside the PDF re-creates the manual black-box workflow the AI was meant to replace.

## Deliberately rejected (blind)

- Page filmstrip as primary nav — no collapse.
- Document-by-document completion — multiplies the same entity decision by file count.
- Infinite scroll of suggestion cards — no hierarchy.
- Auto-accept HIGH with zero keystroke — audit needs a human decision; `a` is still human and still fast.
- Equal weight for false-negative hunting — secondary mode after the suggestion queue is clear.

## Success criterion

One trained reviewer clears 2,394 suggestions in one sitting because they make **~150–300 cluster decisions**, not 2,394 box decisions—with band bulk for residual HIGH, occurrence split only when context diverges, continuous awareness of progress, full undo, and an audit trail.

That is the interaction thesis encoded in the first-pass mock.
