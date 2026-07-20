# Confidence design — ensemble scores that power the triage funnel

**Status:** Design note. Deterministic 3-judge ensemble is **built** (`server/judge.sql`). Local-LLM tier is **proposed / demo-flag only** (`docs/llm-judge.md`, `spikes/llm-judge/`). This is a **heuristic** system, not trained ML.

**Product requirement:** A human thoroughly clears **1000+ AI redaction suggestions** across **1000+ pages**, fast — via a funnel (auto-pass high-confidence + bulk groups, then hand-review the grouped residual), catching false negatives, with a full audit trail + revert.

**Related:** `docs/detection-design.md` (ensemble + remainder scan), `docs/llm-judge.md` (Ollama spike), `server/judge.sql`, `server/remainder_scan.sql`.

---

## 1. Conceptual model (get this exact)

### What confidence attaches to

**Confidence attaches only to AI-generated suggestions** — spans the detector already proposed to redact. Each row in `suggestions` is a claim: “this box should be blacked out.” The ensemble scores **how strongly that claim holds**, not “how much PII is on the page.”

```text
suggestion  →  confidence, panel_signal (agree | split | conflict)
no suggestion  →  no confidence  (nothing for judges to score)
```

### False positives vs false negatives

| Error class | What it is | Does a suggestion exist? | How we surface it |
|-------------|------------|--------------------------|-------------------|
| **False positive (FP)** | A suggestion that **should not** be redacted (citation, street name sharing a surname, officer-of-record line, etc.) | **Yes** — it is a real row with text, kind, context, and a score | **Confidence system:** low blended confidence + `split` / `conflict` panel votes push FPs into the human residual queue |
| **False negative (FN)** | Missed PII — protectable text the AI **never proposed** | **No** — there is nothing to attach confidence to | **Remainder scan only** (`server/remainder_scan.sql`): residual PII after accepted (and known) redaction boxes. Judges cannot score what was never suggested |

**Say it plainly:**

- You **find likely FPs** by looking at suggestions where judges are weak or disagree. Low confidence and split votes are the *feature*, not a bug — they are how the funnel routes “probably wrong to redact” into human eyes.
- You **do not find FNs** with confidence. No suggestion ⇒ no score ⇒ no judge vote. FNs are a **detection remainder** problem, not a ranking problem. The confidence system and the remainder scan are complementary rails; conflating them is a design error.

```text
                    AI suggestions
                         │
         ┌───────────────┴───────────────┐
         │                               │
   confidence ensemble              remainder scan
   (rank / triage / FP bait)        (FN catcher on residual words)
         │                               │
   funnel + human residual           "possible missed redactions"
```

---

## 2. Why an ensemble (not a single seed number)

Seed `suggestions.confidence` is a useful prior, but one integer hides **disagreement**. The hard false-positive classes in this corpus (street-as-person, case citations, officers) often sit in the mid band — not “obvious keep,” not “obvious redact.” A panel that can say **agree / split / conflict** is a better human signal than nudging one score.

Humans clearing 1000+ items do not read paragraphs of rationale. They need:

1. A **0–100** score to sort and band.
2. A **one-word panel signal** (`agree` · `split` · `conflict`) to gate bulk vs individual review.
3. **2–3 chips** on expand — short factor lines, not essays.
4. A **gradient** on the mark / band chrome so posture is glanceable.

Confidence **sorts and flags**; it does not explain the law.

---

## 3. Design: 2–3 judge ensemble (deterministic core)

### What is already built

`server/judge.sql` implements a **pure-SQL, deterministic 3-judge ensemble** over every suggestion. No LLM. No `LIKE`. No runtime writes. Boot-time CTAS + views; same boot ⇒ same votes forever (jitter is `hash(suggestion_id) % 5` only).

| Artifact | Role |
|----------|------|
| `judge_votes` | One row per (suggestion × judge): verdict, score, reason |
| `v_judge_votes` | Flat votes for on-demand UI |
| `v_judge_panel` | One row per suggestion: blended `confidence`, `panel_signal`, vote counts, `judges` list |
| `v_suggestions_judged` | Live suggestion status + panel + `judge_band` |

**Honest label:** This is a **hand-tuned heuristic** over kind/text/context/entity counts — not a trained model, not calibrated probabilities. “96” means “pattern judge was very sure about shape,” not “96% true-positive rate on a held-out set.” Treat scores as **ranking fuel**, not science.

### The three judges (what each sees)

Each vote is:

```text
(verdict: redact | keep | unsure,  score: 0–100 strength-of-vote,  reason: one short line)
```

| # | Name | Factor | Inputs | Typical behavior |
|---|------|--------|--------|------------------|
| 1 | **Pattern** | pattern-match strength | `text`, `kind`, `flag_tag` | Hard SSN/phone/DOB shapes → strong **redact**. Citation / street / officer / seed-tagged FP → **keep** or weak pattern. Ambiguous → **unsure**. |
| 2 | **Context** | surrounding-context | `context`, `text`, `kind` | Hard identifier kinds almost never overridden. Citation wording (`v.`, `U.S.`), street tokens, Ofc./Det./Sgt. → **keep**. Subject/witness/victim cues → **redact**. Person names without cues → **unsure**. |
| 3 | **Prior** | entity-type prior + cross-document corroboration | `kind`, `entity_id` → doc/hit counts | SSN/phone/DOB/address priors → **redact**. Person seen in ≥2 docs → **redact**; single-doc person → **unsure**. Street/citation priors → **keep**. Officer multi-doc → **keep**, else **unsure**. |

Cross-doc counts come from `_judge_entity_docs` (distinct documents per entity among suggestions). Corroboration raises Prior scores for true multi-file subjects and keeps street-name FPs from looking like solitary weak names.

### How votes combine

**Panel signal** (disagreement is first-class):

| `panel_signal` | Rule |
|----------------|------|
| `agree` | All three verdicts identical |
| `conflict` | At least one **redact** and at least one **keep** (hard oppose) |
| `split` | Mixed set but not hard oppose (e.g. redact + unsure, or keep + unsure) |

**Blended confidence** (mapped onto “should we redact?”):

```text
per judge contribution:
  redact  → score          (high = strong yes-redact)
  keep    → 100 - score    (strong keep → low redact-confidence)
  unsure  → ~48–52         (near the decision boundary)

confidence = round(avg(contributions))   ∈ 0–100
```

So a unanimous “keep citation” panel correctly yields **low** redact-confidence (FP bait for reject/bulk-skip). A unanimous hard SSN panel yields **high** redact-confidence (auto-pass fuel). A Pattern=redact / Context=keep conflict collapses toward the middle and forces the human queue.

**Triage band** (`judge_band` on `v_suggestions_judged`):

```text
split | conflict              → flagged   (always; bulk banned)
confidence ≥ 90               → high
confidence ≥ 60               → review
else                          → flagged
```

Thresholds match the product bands used by the funnel UI (default auto-pass bar **90**, adjustable 80–95 in triage chrome).

### Two-judge variant (optional simplification)

If ops want a thinner panel: **Pattern + Context** only. Drop Prior when cross-doc entity graph is empty (single-document cases). Aggregation rules stay the same (`agree` / `split` / `conflict` over two votes). Prefer keeping Prior when multi-file cases are the common unit of work — corroboration is cheap SQL and earns its chip.

---

## 4. Optional tier: local-LLM judge (async, off hot path)

### Status

**Not in boot path.** Spike proved DuckDB → local Ollama works (`docs/llm-judge.md`). Verdict: **demo-flag** — advisory chip only; never sole triage; never mutates `panel_signal` alone.

### When it fires

```text
boot  →  seed  →  judge.sql (always, free, deterministic)
      →  remainder_scan (FN rail)
      →  serve UI

async (optional):
  residual = judge_band = flagged
             OR panel_signal ∈ {split, conflict}
             OR confidence < auto-pass threshold
  enqueue residual → local LLM judge(s) → advisory chips only
```

**Never:** score all ~1–3k suggestions with LLM on boot.  
**Never:** auto-accept / auto-reject from LLM alone.  
**Never:** block export on LLM completion.  
**Never:** use LLM score to sort the residual queue (scores are unreliable even when verdict is right).

### What the LLM judge sees

Per residual suggestion only:

- span `text`, `kind`, short surrounding `context`
- optional: deterministic panel summary (verdict tally) as *context*, not as ground truth to parrot
- FOIA-ish keep/redact rules in a **short** JSON prompt (long rule lists over-fired on 3B models in the spike)

Output contract (stored, not free text in UI):

```text
{ verdict: redact|keep|unsure, reason: ≤1 line, model, prompt_style, raw_json, latency_ms, ts }
```

### Model bar (from spike)

| Model class | Role |
|-------------|------|
| **≥7B** (e.g. qwen2.5:7b) | Acceptable advisory judge when local and pinned |
| **3B** | **Unsafe as sole judge** — measured false *keeps* on subject name + address |

Prefer `http_client.http_post` → `http://127.0.0.1:11434/api/generate` with `format: json`, `temperature: 0`, short `num_predict`. Hosted APIs are out of scope (PII egress + cost).

### Latency budget

| Tier | Budget | Reality |
|------|--------|---------|
| Deterministic ensemble | **&lt; 1 s** case-wide CTAS on boot; **0 ms** per UI click (views already material) | Built |
| Residual queue paint | **&lt; 100 ms** sort/filter on `v_suggestions_judged` | Built path |
| LLM per item | **~300–500 ms** warm; 800 residuals × 2 models ≈ **minutes** wall | Async only |
| Cold model load | multi-second / multi-ten-second spikes | Not on first paint |

Product math: the funnel’s speed comes from **deterministic agree + high** clearing most of the pile in bulk. LLM exists only to enrich the **already-small residual** while the human works entity groups — chips appear when ready, empty until then.

### Audit for LLM votes

Append-only JSON under something like `exports/llm_votes/` (mirror decisions pattern): one file per vote, pin **model id + digest + prompt version + raw response**. Reproducibility is weaker than SQL judges; the log is how you defend a chip in court-adjacent review.

---

## 5. How confidence powers the funnel

The singular requirement is throughput **with** thoroughness. Funnel shape:

```text
~1k–3k AI suggestions
        │
        ▼
┌───────────────────────────────────────┐
│  Stage A — Auto-passable              │
│  agree + high confidence (≥ thr)      │
│  + known hard PII kinds (SSN/…)       │
│  → "Accept all N high-confidence"     │
│  → each decision still written to     │
│     audit log (bulk = many events)    │
└───────────────────────────────────────┘
        │ residual
        ▼
┌───────────────────────────────────────┐
│  Stage B — Bulk groups                │
│  same entity / same text / same kind  │
│  across docs; confidence-gated        │
│  (HIGH ok; REVIEW after glance;       │
│   FLAGGED never in band bulk)         │
└───────────────────────────────────────┘
        │ residual
        ▼
┌───────────────────────────────────────┐
│  Stage C — Grouped human residual     │
│  split / conflict / low confidence    │
│  → why-card + 2–3 judge chips         │
│  → optional LLM advisory chip         │
│  → individual or entity-family decide │
└───────────────────────────────────────┘
        │ parallel rail (not the same queue)
        ▼
┌───────────────────────────────────────┐
│  FN rail — remainder scan             │
│  residual_pii_candidates              │
│  → "Add missed redaction"             │
│  (no confidence; new human-authored   │
│   suggestions enter audit as adds)    │
└───────────────────────────────────────┘
```

### Mapping panel → funnel posture

| Ensemble state | Human posture | Bulk |
|----------------|---------------|------|
| `agree` + high redact-confidence | Volume fire — sample 1–2 contexts, accept | Entity + band bulk OK after residual cleanup |
| `agree` + low redact-confidence (strong keep) | FP bait — reject / skip matching | Reject-all-matching OK for pure FP families |
| `agree` mid / `review` band | Judgment — page peek, then decide | Entity bulk only after glance |
| `split` or `conflict` | Human required — why-card | **Banned** — fails closed; blocks export until decided |

**Flagged is sacred:** never auto-pass, never band-bulk. That is how false positives are *caught* rather than shipped.

### Audit trail + revert (orthogonal but required)

Confidence does not write decisions. Humans (and bulk actions that act as humans) write **append-only** decision records (`exports/decisions/`). Each accept/reject/add-missed is reversible by a later compensating decision. Ensemble outputs are **projections** recomputed from suggestion features; they are not the system of record. Revert does not “undo a score” — it reopens or overrides a **decision** while the suggestion row and its panel remain queryable for “what did the system think then.”

---

## 6. UI contract (chips + gradient, not essays)

Humans do not read judge essays. The UI surface is deliberately thin.

### Primary chrome

1. **Gradient / band mark** on the suggestion (or entity card):
   - High (≥90) — cool/ink, volume posture  
   - Review (60–89) — amber, glance posture  
   - Flagged (&lt;60 or split/conflict) — red, why-card posture  
2. **Numeric confidence** (mono, e.g. `96` or `37`) next to band — one glance.
3. **Panel signal chip**: `AGREE` · `SPLIT` · `CONFLICT` — only conflict/split need visual weight equal to the score.

### On expand / why-card (2–3 chips)

```text
Pattern   REDACT  96   hard SSN digit pattern
Context   KEEP    88   citation wording in surrounding text
Prior     KEEP    86   citation prior: keep
────────────────────────────────────────────
conflict · confidence 37 · FLAG
```

Optional fourth chip when async LLM finished:

```text
LLM · local   KEEP   advisory   citation form, not subject
```

Badge **advisory** is mandatory for LLM — does not change band alone.

### What we deliberately hide by default

- Full factor essays, prompt text, token traces  
- Per-judge score calculus  
- LLM raw JSON (audit store only; show one-line reason)

Triage funnel chrome (see `server/templates/triage_funnel.html`): total → auto-pass ≥ threshold → residual “need eyes,” with threshold presets 80/85/90/95. Copy: *Flagged + known FPs never auto-pass.*

---

## 7. Built vs proposed (honest ledger)

| Piece | State | Notes |
|-------|-------|-------|
| 3-judge deterministic ensemble | **Built** | `server/judge.sql` |
| Blend → `confidence` + `panel_signal` | **Built** | `v_judge_panel` |
| `judge_band` + join to suggestions | **Built** | `v_suggestions_judged` |
| Remainder scan (FN rail) | **Built** | `server/remainder_scan.sql` |
| Funnel / residual triage UI | **Partially built** | Templates + design mocks; wire to `judge_*` where not already |
| Confidence gradient + chips in review | **Design + partial** | `design/workflow/05_confidence.html`, judge panel routes |
| Local-LLM async judges | **Spike only** | `spikes/llm-judge/`, `docs/llm-judge.md` — demo-flag |
| LLM mutates panel / auto-pass | **Out of scope** | Explicitly rejected |
| Trained ML calibrator | **Out of scope** | Assignment is UX + data modeling; this doc is judgment, not a training plan |
| Silent auto-accept of residual FNs | **Out of scope** | Humans own adds |

---

## 8. Failure modes and limits (heuristic honesty)

1. **Not calibrated.** Scores are not probabilities. Do not publish “96% accurate” from the integer.
2. **Seed `flag_tag` / kind leakage.** Judges use seed kinds and FP tags; on wild corpora without good kinds, Pattern/Prior weaken and more items fall to Context + human residual (correct fail-open).
3. **Jitter.** 0–4 hash jitter avoids identical chips looking fake-identical; it is not noise for privacy and must stay deterministic across boots.
4. **LLM unsafe keep.** Small models can clear real PII. Cap: advisory, ≥7B, never sole gate, never export blocker.
5. **Confidence cannot invent misses.** If the detector never suggested a spaced SSN, the ensemble will not “get low confidence” about it — remainder scan must run.
6. **Bulk without audit is not allowed.** Auto-pass and entity bulk must still emit one decision event per suggestion (or an explicit bulk event with member ids) for revert.

---

## 9. Summary

| Question | Answer |
|----------|--------|
| What has confidence? | **AI suggestions only** |
| How do we find FPs? | Low confidence + split/conflict on **existing** suggestions |
| How do we find FNs? | **Remainder scan** — not confidence |
| Hot path? | Deterministic Pattern / Context / Prior in SQL |
| Slow path? | Optional local LLM on residual, async, advisory chips |
| Funnel fuel? | High+agree → auto-pass; groups → bulk; split/low → human residual |
| UI? | Gradient + number + 2–3 chips; no essays |
| Is it ML? | **No** — explicit multi-signal heuristic with a panel metaphor |

The assignment’s win condition is a human clearing a mountain of suggestions without shipping FPs or missing planted FNs, with every decision reversible. Confidence is the **sorting and gating layer** that makes that mountain funneled instead of flat — not a black-box model and not a substitute for the remainder scan.
