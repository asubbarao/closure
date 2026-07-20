# Workflow suite — final interaction thesis

**Home:** `design/workflow/` · improves Closure’s incumbent review flow for **2,394-suggestion / 1,000+ page / multi-file** scale.  
**Medium:** high-fidelity HTML/CSS. Terminology per `design/copy.md`. Case fiction per `06_design_notes.md` (24-000117, Yasmine Nienow, street/citation/officer decoys).

---

## Final interaction model (what the suite ships)

**Primary navigation unit = the entity** (one normalized string + every suggestion that matches it across the case). Not the page, not the document, not the raw suggestion row.

**Cardinality collapse is the product.** 2,394 suggestions are not 2,394 decisions. They collapse into ~80–200 entity decisions (plus a thin occurrence-split tail for context conflicts). The review surface is a **case-wide entity stream**, leverage-ranked:  
`open_suggestions × confidence_uncertainty × files_touched`.

**Decision card is primary; the PDF is verification.** At this scale, living inside a full PDF canvas re-implements manual black-box work. The center stage shows: entity identity, confidence band + min score, footprint (suggestions · files · flagged), 2–3 system-sampled contexts, and one-keystroke **Accept entity / Reject entity** (case-wide). Page peek opens on demand (`n`/`p` step occurrences). REVIEW and FLAGGED items auto-emphasize the peek; HIGH items stay on the card.

**Bulk is layered and confidence-gated.**

1. **Entity bulk** (`a` / `r`) — accept/reject all pending suggestions for one entity across every file. Default path.
2. **Multi-select bulk** (Space + Shift+a/r) — several entities at once.
3. **Band bulk** — “Accept remaining HIGH entities with zero flags” after preview + samples. Never silent.
4. **Occurrence split** (`o` / `x`) — rare path when contexts diverge.

**Flagged is sacred.** FLAGGED suggestions are excluded from every bulk path, block export until individually decided, and surface a why-card (Closure’s best false-positive pattern).

**Multi-file is case-scoped.** The queue is the case. Document rails answer “which files are still dirty?” Entity accept lays the ink everywhere the string appears. Progress is always absolute: `{done} of {total} reviewed · {clear}/{docs} files clear`.

**Confidence is triage posture, not decoration.**

| Band | Reviewer does | Bulk permission |
|------|----------------|-----------------|
| HIGH (≥90) | Sample 1–2 contexts → `a` | Entity + band bulk |
| REVIEW (60–89) | Read context + peek page | Entity bulk only after glance |
| FLAGGED (&lt;60) | Why-card + individual judgment | Never in bulk |

Default order: burn HIGH volume → clear REVIEW judgment → resolve FLAGGED carefully.

**Keyboard (inbox, not form):**  
`j k` entity · `n p` occurrence · `a` accept entity · `r` reject entity · `o x` split one · `e` entity bulk sheet · `f` flag · `Space` multi-select · `Shift+a/r` selection · `g h/v/f` band jump · `u` undo · `n` add missed (mode) · `/` search · `?` legend.

**Secondary:** add-missed (`n` + mark) with scope *this instance* vs *find & redact all in case* — lightweight, after the suggestion queue is the main work.

---

## Why this navigates 2,394 best

1. **Decisions scale with entities, not pages.** Throughput is dpm on ~100 entities, not 2,394 marks.
2. **Leverage ranking** always presents the next decision that clears the most remaining work safely.
3. **Case-wide default** kills multi-file re-work (the silent killer of doc-by-doc UIs).
4. **Confidence gates bulk** so speed does not become wrongful redaction.
5. **Progress is legible** at case, band, entity, and file levels — the reviewer never loses “where am I in 2,394?”
6. **Undo + audit language** (copy.md) keep speed legally defensible.

---

## Is there a fundamentally different way?

### Paradigms explored seriously

| Paradigm | Idea | Verdict for 2,394 throughput + safety |
|----------|------|----------------------------------------|
| **Page filmstrip / heatmap** | Navigate density of marks on pages | Great overview, terrible decision rate — no collapse |
| **Document completion** | Finish file A before file B | Multiplies the same entity decision × files — rejected |
| **Raw suggestion inbox (2,394 rows)** | Gmail for every mark | Fails without entity grouping; fatigue errors |
| **Diff / redacted-vs-original two-up** | Compare outputs | Export QA, not review throughput |
| **Auto-accept HIGH zero-keystroke** | Machine lays ink | Fails legal “human decided” bar; keyboard `a` is enough |
| **Pattern / similarity clusters** | Decide once for all SSNs, all phones of a shape | Powerful second layer; keep as power mode, not sole unit (values differ, policy may not) |
| **Spatial case map only** | Graph of entities × docs | Excellent multi-file lens; weak as sole decision surface |
| **System-pushed decision stream** | Next-best entity auto-advances | **Adopted** as default posture on top of entity unit |
| **Entity decision card (PDF secondary)** | Card is product; peek verifies | **Adopted** as star of core screen |
| **Conventional queue + PDF canvas** | Closure / cleanroom default | Strong for context on FLAGGED; weaker as permanent center of gravity at 2,394 |

### Honest verdict

There **is** a better primary surface than “PDF canvas with a suggestion list,” but it is **not** a rejection of entity grouping or keyboard inbox — those are correct. The fundamental upgrade is:

> **Collapse first (entity), push next (leverage stream), decide on a card, verify on a page — case-wide, confidence-gated bulk.**

Betting against pure novelty (heatmap-only, spreadsheet-only, auto-accept) and against pure convention (document-first PDF room). The winner is a **hybrid**: conventional entity + confidence bands (Closure) + similar-group case bulk (cleanroom-2) + decision-stream/card primacy and leverage sort (blind take). At 2,394 scale, the PDF remains non-negotiable for *judgment* moments and disposable for *volume* moments.

---

## Comparison table

| Source | What it got right for 2,394 | What we rejected / limited | What we took into `workflow/` |
|--------|----------------------------|----------------------------|-------------------------------|
| **Blind (`_blind/`)** | Entity/decision cluster as unit; leverage stream; decision card primary; PDF as peek; case footprint; band burn-down chrome | Dark “ops console” aesthetic (wrong DS); “pattern cluster” as co-equal primary (kept secondary); fictional scale details without copy.md terms | Stream ranking, card-first stage, absolute 2,394 progress, doc footprint chips |
| **Closure (01–06)** | Entity grouping; HIGH/REVIEW/FLAGGED; `e` propagate; flagged excluded from bulk; why-card FP; reject-all-matching; copy.md vocabulary; design tokens; bulk sheet safety tally | Doc-scoped progress (“25 of 44”) underplays case scale; PDF as permanent center slows HIGH burn-down; queue still suggestion-heavy inside entities; multi-file secondary via left rail only | Terminology, tokens, why-card, flagged sacred, bulk exclusion banner, entity bulk sheet, add-missed scope fork |
| **Cleanroom attempt-1** | Keyboard triage; confidence filter chips; multi-select; “bulk similar” on group key; pending-first | Suggestion-row primary (weak collapse); canvas-anchored default; no entity dossier as home | Multi-select selection model; band filter chips; similar-count affordance |
| **Cleanroom attempt-2** | **BulkSimilarPanel** with case vs document scope; groups sorted by pending count; case package rail | Still queue+canvas dual; similar panel secondary not primary nav; weaker flagged ritual | Case-vs-doc bulk scope; similar group as first-class bulk surface → folded into entity bulk |
| **Cleanroom attempt-3** | Floating multi-select bulk bar; similar counts on rows; dense operational UI | Heterogeneous multi-select without entity collapse can be unsafe; less rich FP why | Selection bulk bar pattern; density of operational chrome |

**Verdict for 2,394-scale navigation:**  
**Entity stream + decision card (blind) beats pure suggestion queues (cleanroom 1/3).**  
**Closure’s confidence bands + flagged exclusion beat unguarded bulk (all peers).**  
**Cleanroom-2’s case-scoped similar bulk beats doc-only accept.**  
**None alone was enough:** Closure under-weighted case-wide stream and card primacy; cleanrooms under-weighted entity-as-row and flagged ritual; blind under-weighted Closure’s FP why-card and copy system. The suite is the merge.

---

## Screen map

| File | Design decision it embodies |
|------|-----------------------------|
| `01_review_stream.html` | Core: entity stream + decision card + page peek; “where am I in 2,394” |
| `02_bulk_entity.html` | Entity bulk sheet across files; flagged excluded; lay the ink |
| `03_bulk_band.html` | Band bulk for residual HIGH — confidence-gated, previewed |
| `04_multifile.html` | Case map: files × entities; dirty-file navigation without re-deciding |
| `05_confidence.html` | Same UI, three postures: HIGH fire / REVIEW glance / FLAGGED why-card |
| `06_add_missed.html` | Secondary FN: mark + this instance vs find-all in case |
| `index.html` | Suite entry |
| `_blind/` | Phase-1 thesis + first-pass mock (preserved) |
