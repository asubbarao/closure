# Detection design — judge ensemble + remainder scan

Product frame: reviewers face **hundreds of AI suggestions** and must clear them
fast, catch misses, and leave an audit trail. Nobody reads a paragraph of
rationale per item. Confidence must **sort and flag**, not explain.

This doc covers two pure-SQL modules that other code consumes as tables/views.
They do not write the decisions log (that stays append-only JSON under
`exports/decisions/`).

---

## 1. Confidence as a judge ensemble (`server/judge.sql`)

### Why not a single hardcoded score?

Seed confidence is a useful prior, but a single number hides disagreement.
False positives in this corpus (street names sharing a surname, case citations,
officers of record) often sit in the 58–71 band — “review,” not “obvious keep.”
A panel that can **agree / split / conflict** is a better human signal than
nudging one integer.

### Model (simulated, deterministic)

Each AI suggestion gets **3 judges**. No LLM — every verdict is pure SQL over
`text`, `kind`, `context`, `flag_tag`, and cross-document entity counts.

| Judge | Factor | What it looks at |
|-------|--------|------------------|
| **Pattern** | pattern-match strength | Digit/name shape; SSN/phone/DOB hard patterns; NOT-PII kinds |
| **Context** | surrounding-context | Nearby “v. / U.S.”, street words, Ofc./Det./Sgt., SSN/DOB/subject cues |
| **Prior** | entity-type prior + cross-document corroboration | Kind base rates × how many docs host the entity |

Each vote is:

```text
(verdict: redact | keep | unsure,  score: 0–100 strength,  reason: one short line)
```

### Aggregation (one row per suggestion)

View **`v_judge_panel`** (keyed by `suggestion_id`):

| Field | Meaning |
|-------|---------|
| `confidence` | Blend of judge scores mapped onto “should redact?” (keep → `100 - score`, unsure → ~50) |
| `panel_signal` | **`agree`** all same verdict · **`split`** mixed but no hard oppose · **`conflict`** at least one redact **and** one keep |
| `judges` | `LIST` of `{judge_name, factor, verdict, score, reason}` for on-demand UI |

On-demand breakdown without the list: **`v_judge_votes`** (one row per suggestion × judge).

Triage join for the app: **`v_suggestions_judged`** = `v_suggestions` + panel +
`judge_band` where **split/conflict always → `flagged`** (human-required), else
thresholds match the seed bands (high ≥90, review ≥60).

### Human-facing model

```text
agree  + high confidence  → bulk-accept is safe to offer
agree  + keep             → bulk-reject / skip (FP bait)
split / conflict          → forced individual review (the real work queue)
```

UI shows **2–3 judge chips**, not prose. Example:

```text
Pattern  REDACT  96  hard SSN digit pattern
Context  KEEP    88  citation wording in surrounding text
Prior    KEEP    86  citation prior: keep
→ conflict · confidence 37 · FLAG
```

Split/conflict panels **are** the flagged items needing judgment — same product
role as the old low-confidence band, but with an explicit “judges disagree”
affordance.

### Determinism

Scores use `hash(suggestion_id)` only as a 0–4 jitter so identical kinds do not
look artificially identical. Same DB boot → same votes forever. No random(), no
external model.

---

## 2. Automated false-negative catcher (`server/remainder_scan.sql`)

### Concept: remainder scan

```text
accepted redactions  →  mask those boxes on the page
remainder words      →  words not covered by accepted boxes
detect residual PII  →  surface as "possible missed redactions"
```

The main seed detector matches **canonical roster forms only** (see
`seed.sql`). Planted variants in `identities.json` / `manifest.json` are
intentional misses:

| Plant | Example | Why seed misses it |
|-------|---------|-------------------|
| Spaced SSN | `271 72 1446` | Three tokens; roster is `271-72-1446` |
| Dotted SSN | `119.32.4498` | Dot separators vs dash form |
| Dotted phone | `613.235.3301` | Roster is `(613) 235-3301` |

### Detection stack

1. **Mask** — words overlapping an `accepted` suggestion box are removed from the remainder.
2. **N-grams** — 1-grams + same-line 3-grams over remainder words only (so a redacted middle digit kills a spaced SSN).
3. **Regex** (`regexp_matches` only — **LIKE banned**):
   - SSN: `ddd-dd-dddd`, `ddd.dd.dddd`, spaced `ddd dd dddd`
   - Phone: dotted / dashed / compact parenthesized
   - Email: standard local@domain
4. **finetype** (`INSTALL finetype FROM community`) on identifier-shaped 1-grams; keep hits labeled `phone_number` or `email`.  
   Note: finetype has **no reliable SSN class** (often ISBN/plain_text) — SSN is regex-owned, as documented in `docs/data-improvements.md`.
5. **De-dupe vs known suggestions** — drop residual spans that already overlap **any** suggestion box (pending, accepted, or rejected) so the UI shows true **misses**, not re-queues of items humans already saw.

### Output contract

**`residual_pii_candidates`** (alias `v_residual_pii_candidates`):

| Column | Type | Notes |
|--------|------|-------|
| `document_id` | INT | |
| `page` | INT | page number |
| `box` | STRUCT(x0,y0,x1,y1) | PDF points, top-left origin |
| `x0,y0,x1,y1` | DOUBLE | flat copy for simple joins |
| `text` | VARCHAR | normalized span text |
| `kind` | VARCHAR | `SSN` / `PHONE` / `EMAIL` / … |
| `why` | VARCHAR | one line, e.g. `regex: spaced SSN (ddd dd dddd)` |
| `detector` | VARCHAR | `regex` or `finetype` |

These rows are **candidates for “Add missed redaction”**, not auto-accepted
decisions. Accepting one still goes through the append-only decisions path.

---

## 3. Wire into `app.sql` (do not forget)

After seed (suggestions + `v_suggestions` exist), **before** routes that want
to expose the views (or at least before serve):

```sql
.read server/seed.sql
.read server/judge.sql
.read server/remainder_scan.sql
```

Exact lines to add (owned by the backend agent; this module does **not** edit
`app.sql`):

```sql
.read server/judge.sql
.read server/remainder_scan.sql
```

Recommended placement: immediately after `.read server/seed.sql` and before
`.read server/load_templates.sql` / `.read server/routes.sql`.

Suggested consumer surfaces (for the backend/UX agents):

- Review queue sort: `v_suggestions_judged` order by
  `panel_signal = 'conflict' DESC`, `split`, then `judge_confidence`.
- Suggestion drawer: expand → `v_judge_votes` for that `suggestion_id`.
- “Possible misses” rail: `residual_pii_candidates` filtered by
  `document_id` / current page.

---

## 4. What we deliberately do **not** do

- No real LLM judges (assignment focus is UX + data modeling).
- No silent auto-accept of residual hits (humans own the audit trail).
- No LIKE/contains substring scans.
- No edits to seed confidence column — ensemble is a **projection** so seed
  stays reproducible; UI should prefer `judge_confidence` when the panel is wired.
