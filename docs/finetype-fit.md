# finetype (+ quickjs residual) vs Closure detection core

**Date:** 2026-07-19  
**Scope:** Honest fit assessment of DuckDB community extension **finetype** for
the Closure app’s detection / confidence path. Secondary note on **quickjs**
only for residue finetype + SQL do not cover. Spikes only under
`spikes/ext-finetype/` — **no** edits to `server/*.sql`, `templates/`,
`static/`, or `samples/`.

**Local DuckDB:** `v1.5.3` (osx_arm64)  
**finetype version:** `0.6.23` (INSTALL/LOAD verified)

```sql
INSTALL finetype FROM community;  -- verified LOAD
INSTALL quickjs FROM community;   -- verified LOAD (residual only)
```

---

## Extension surface (what they actually do)

### finetype

Semantic **format classifier** over strings — not a redaction engine, not NER
with document context.

| Function (used or relevant) | Role |
|-----------------------------|------|
| `finetype(v)` / `ft_infer(v)` | Per-value type label (weak alone) |
| `finetype_detail(v)` / `ft_detail(v)` | JSON `{type, confidence, duckdb_type, samples, disambiguation, votes}` |
| `finetype_cast(v)` / `ft_cast(v)` | Normalize for `TRY_CAST` (dates → ISO; **not** phone digit-canon) |
| `finetype(list)` / `finetype_detail(list)` | Column-distribution classify on a LIST |
| `ft_profile('table')` | **Primary column API** — one row per column with type + confidence |
| `finetype(list, 'phone'\|'ssn'\|…)` | Header/domain **hint** (boosts a label; not free detection) |
| `finetype_unpack` / `ft_unpack` | Recurse JSON fields |
| Taxonomy | ~244 types / 7 domains (datetime, identity, geography, …) |

**Not present:** document-context roles (subject vs officer vs citation). No
PDF geometry. No band logic (`high` / `review` / `flagged`).

### quickjs (secondary)

| Function | Role |
|----------|------|
| `quickjs(code)` | Run JS; scalar or table-producing |
| `quickjs_eval(fn, …args)` | Call a JS function (arrow form works); returns JSON |

Useful for awkward transforms **if** SQL cannot express them. Phone/SSN digit
strip is one `regexp_replace` — not a quickjs win.

---

## App contract being matched

From `server/schema.sql` / `server/ingest.sql` / `server/judge.sql`:

```text
entities (canonical_text, kind)  ← identities.json catalog
words → v_grams → roster match → suggestions(confidence, flag_tag, entity_id)
judge ensemble: pattern regex + context regex + prior → judge_band
bands: confidence ≥90 high · ≥60 review · else flagged
```

Hard pattern kinds the product cares about:

| Kind | App detection today |
|------|---------------------|
| SSN | `^[0-9]{3}[-.][0-9]{2}[-.][0-9]{4}$` + entity kind |
| PHONE | paren / dash / dot US forms in `judge.sql` Pattern judge |
| DOB | `^[0-9]{2}/[0-9]{2}/[0-9]{4}$` + entity kind |
| PERSON / ADDRESS | catalog match + **context** (citation / officer / street) |

finetype sits next to the **Pattern** judge: “what format is this string?”
It does **not** sit next to the Context judge: “is this the subject?”

---

## Fit 1 — Semantic typing of PHONE / SSN / DOB / ADDRESS / PERSON

### Verdict: **marginal** (not a drop-in for detection core)

### Mechanism

1. For **column-shaped** values (a pure phone field, a pure SSN field), call
   `ft_profile('col_table')` or `finetype_detail(list(v))`.
2. Map taxonomy labels → Closure kinds:
   - `identity.person.phone_number` → PHONE  
   - `identity.government.ssn` → SSN  
   - `datetime.date.mdy_slash` → DATE OF BIRTH  
   - `geography.address.full_address` → ADDRESS  
   - `identity.person.full_name` → PERSON (format only)
3. Feed `confidence` (0–1) into something like `round(confidence * 100)` for
   bands — **only when the type is correct**.
4. For free-text PDF word spans (Closure’s real path), each span is often a
   **single value** or a tiny n-gram — exactly the weak case.

### Spike result (`spikes/ext-finetype/01_single_vs_column.sql`)

**A. Isolated single-value literals** (the pre-verified misfires, re-confirmed):

| Input | `finetype(v)` | Confidence (detail) | Correct? |
|-------|---------------|---------------------:|----------|
| `(613) 235-3301` | `identity.commerce.isbn` | ~0.38 | **no** |
| `271-72-1446` | `identity.commerce.isbn` | ~0.23–0.66 | **no** |
| `08/16/1979` | `datetime.date.mdy_slash` | ~0.85–0.88 | yes |

**B. Column mode (`ft_profile`) on pure columns** — the key question:

| Scenario | Samples | Want | Got | Conf | OK? |
|----------|--------:|------|-----|-----:|-----|
| PHONE US paren (catalog + fixture) | 13 | `identity.person.phone_number` | **same** | **0.79** | **yes** |
| PHONE US dash | 8 | phone_number | `alphanumeric_id` | 0.50 | **no** |
| PHONE UK-ish | 4 | phone_number | `isbn` | 0.48 | **no** |
| SSN pure (identities + extras) | 7 | `identity.government.ssn` | **same** | **0.57** | **yes** |
| SSN tiny | 2 | ssn | `isbn` | 0.70 | **no** |
| DOB mdy slash | 7 | `datetime.date.mdy_slash` | **same** | **0.90** | **yes** |
| ADDRESS full (identities) | 4 | `geography.address.full_address` | **same** | **1.00** | **yes** |
| PERSON names + officer/citation/street traps | 10 | `full_name` | **same** | **0.42** | format yes / **context no** |

**Answer to the key question:** column mode **sometimes** corrects the ISBN
misfire (US-paren phones n≈13; SSN n≈7 via `ft_profile`), and **sometimes
does not** (dash phones, UK phones, SSN n=2). It is **not** a reliable fix for
Closure’s per-span path.

**API instability (honest):** for `ssns_pure`, `ft_profile` returned
`identity.government.ssn` while `finetype(list(v))` returned
`identity.commerce.isbn` in the same session. Prefer `ft_profile` if you use
the extension at all; treat list-scalar as second-class.

**App regex on the same shapes:** PHONE 13/13, SSN 7/7, DOB 7/7 — **100%**,
deterministic, no sample-size cliff.

**Context failure (names):** every trap still types as `full_name`:

| String | finetype | What Closure needs |
|--------|----------|--------------------|
| `Yasmine Nienow` | full_name | PERSON · SUBJECT (maybe) |
| `Nienow v. Ohio` | full_name | CITATION · NOT PII |
| `Det. Nienow` | full_name | OFFICER · NOT SUBJECT PII |
| `Cronin Street` | full_name | STREET NAME · NOT PII |

**finetype TYPES FORMATS, not CONTEXT.** It cannot solve the hard problem the
judge ensemble exists for. Say that plainly: if the take-home value is “is this
redactable subject PII?”, finetype is not the tool.

### Where it wins vs loses vs existing SQL

| | finetype | App regexp + judge.sql |
|--|----------|------------------------|
| Clean DOB / full address formats | Strong (conf ~0.9–1.0) | Also strong |
| US SSN / phone in free text | Unreliable single-value; column-format fragile | **Reliable** on defined patterns |
| Real confidence number (0–1) | **Yes** (when type is right) | Hand-scored 0–100 with jitter |
| ~250 type coverage (email, IP, UUID, IBAN…) | **Yes** — future remainder scan spice | Only what you write |
| Subject vs officer vs citation | **No** | Context judge + kind tags |
| Dependency / early-release risk | Extra community ext; API dualism | Already in-repo SQL |

### Recommendation

| Integrate? | How (roughly) |
|------------|----------------|
| **Optional remainder / column profiler**, not Pattern-judge replacement | After roster match, profile **entity catalog columns** or extracted field tables with `ft_profile` for extra type labels + confidence spice. |
| **Do not** call `finetype(token)` per PDF word as primary detector | Single-value PHONE/SSN → ISBN; false confidence. |
| **Do not** drop regex | Pattern judge stays; finetype is additive at best. |
| Map confidence only when type ∈ allowlist | e.g. only trust conf if type is `*.phone_number` / `*.ssn` / `datetime.date.*` / `*.full_address`. |
| Domain hints (`finetype(list, 'phone')`) | Useful if UI already knows the field is a phone; **not** free detection on narrative PDFs. |

**Why marginal, not “genuinely useful”:** the product’s hard work is
context-aware PERSON decisions and stable hard-ID patterns. finetype’s best
mode assumes **column purity + enough samples + lucky format** — Closure’s
PDF path is the opposite (mixed tokens, n=1 spans). The confidence number is
real but only as good as the (often wrong) type.

---

## Fit 2 — `finetype_cast` for phone / SSN normalization

### Verdict: **no** for the phone token-match hole; **yes** for DOB ISO only

### Mechanism

`finetype_cast` / `ft_cast` normalizes some values for safe `TRY_CAST` (notably
US/EU dates → ISO). It is **not** a phone normalizer.

### Spike result (`spikes/ext-finetype/02_cast_normalize.sql`)

| Check | Result |
|-------|--------|
| `finetype_cast('(613) 235-3301')` | **unchanged** `(613) 235-3301` |
| `finetype_cast('271-72-1446')` | **unchanged** |
| `finetype_cast('08/16/1979')` | `1979-08-16` (**good**) |
| `qnorm('(613) 235-3301')` vs token 2-gram `qnorm('(613)') \|\| ' ' \|\| qnorm('235-3301')` | still **mismatch** (`613) 235-3301` vs `613 235-3301`) |
| Digit-strip SQL pieces vs catalog | **match** (`6132353301`) |

**Does finetype_cast fix the web-ingest phone match failure?** **No.**  
Fix remains: digitize (or a phone-aware normalizer), not finetype_cast.

### Recommendation

| Integrate? | How (roughly) |
|------------|----------------|
| **No for phone/SSN match keys** | Use `regexp_replace(t, '[^0-9]+', '', 'g')` (or keep catalog forms aligned with tokenizer). |
| **Optional for DOB** | `finetype_cast` → ISO is fine; `strptime` / `strftime` already cover it without a dependency. |

---

## quickjs — residual fit

### Verdict: **no** (no residual Closure needs today)

finetype_cast does **not** normalize phone/SSN, but **SQL already does** the
transform that would fix matching:

```sql
regexp_replace(v, '[^0-9]+', '', 'g')  -- equals quickjs_eval digit strip
```

Spike (`spikes/ext-finetype/03_quickjs_residual.sql`):

| Task | Winner | Note |
|------|--------|------|
| Phone digit strip | SQL `regexp_replace` | quickjs not needed |
| SSN digit strip | SQL | same |
| DOB → ISO | finetype_cast *or* SQL date parse | no JS required |
| libphonenumber-grade parse | neither in-repo | quickjs *could* host a port; out of take-home scope |
| PERSON subject vs citation vs officer | `judge.sql` context | neither extension adds document context |

**Do not force-fit quickjs** into boot for this product. Only revisit if a
real JS-only algorithm (metadata-heavy phone parse, complex address lib) becomes
an explicit requirement.

---

## Combined architecture sketch (if ever productized)

```text
PDF words ──► v_grams ──► catalog match ──► suggestions
                 │
                 ├─ Pattern judge: SQL regexp (SSN/PHONE/DOB)     ◄── keep
                 ├─ Context judge: citation / officer / street    ◄── keep
                 └─ optional: ft_profile on pure extracted fields ◄── finetype spice
                              (never per-token free text as sole detector)

phone match keys: regexp digit-strip (not finetype_cast, not quickjs)
```

---

## Spike outputs (artifacts)

| File | Contents |
|------|----------|
| `spikes/ext-finetype/out/00_setup.log` | Version + catalog counts |
| `spikes/ext-finetype/out/01_single_vs_column.log` | Single-value + `ft_profile` scorecard |
| `spikes/ext-finetype/out/02_cast_normalize.log` | Cast / qnorm / digits match matrix |
| `spikes/ext-finetype/out/03_quickjs_residual.log` | JS vs SQL digit strip + residual table |

Reproduce: see `spikes/ext-finetype/README.md`.

---

## Repo polish (reviewer’s eye)

Read alongside `docs/code-quality.md` (structure/refactor spec). This section is
**submission hygiene only** — most-embarrassing-first, concrete, no deletions
performed.

### 1. Runtime dirt on disk (mostly untracked; still looks bad in a zip/ls)

| Artifact | Tracked? (`git ls-files`) | Notes |
|----------|---------------------------|--------|
| `.tmp/duckdb_temp_storage_*` | **No** | **~154 GB** local spill — catastrophic if zipped for submit |
| `.playwright-mcp/` logs + page yml | **No** | Agent/browser residue |
| `closure.db` + `closure.db.wal` | **No** (gitignore present) | Correctly ignored; ensure not force-added |
| `exports/_probe*.pdf`, `_test_*.pdf`, macro probe PDFs | **No** (covered by `exports/*.pdf`) | Probe noise in tree |
| `data/working/*.pdf` scratch | **No** (gitignore present) | OK if ignored |
| `.DS_Store` | **No** | Already in `.gitignore` |

**Confirmed:** none of the above are currently tracked. Reviewer still sees them
in a working tree or accidental archive. **One-line `.gitignore` additions**
(report only — not applied here):

```gitignore
.tmp/
.playwright-mcp/
exports/_probe*.pdf
# optional belt-and-suspenders if globs drift:
*.db-wal
**/duckdb_temp_storage_*.tmp
```

(`closure.db`, `closure.db.wal`, `exports/*.pdf`, `.DS_Store` already covered.)

### 2. Top-level layout clarity

Readable story (`README`, `server/`, `samples/`, `static/`, `docs/`, `tests/`) is
good. Reviewer friction:

| Issue | Why it hurts |
|-------|----------------|
| **~27 docs**, no index | Looks like agent dump; hard to find the few that matter for grading |
| Dual SQL surfaces | `server/routes.sql` **and** `server/routes/`; `schema.sql` unused by boot (see code-quality.md) |
| `server/_export_macros.sql` | Generated-looking name at server root |
| `data/` + `exports/` + `pages/` | Lifecycle mix (INPUT/WORKING/OUTPUT already specified in code-quality.md) |

**Recommend:** add `docs/README.md` index pointing graders at:

1. `rationale.md` (assignment Part 3)  
2. `code-quality.md` (structure honesty)  
3. `web-extensions-usage.md` / `finetype-fit.md` (extension spikes — optional reading)  
4. `pdf-stress.md` / `scaling-and-limits.md` (limits evidence)  

Everything else = working notes; consider `docs/archive/` later (not required for this pass).

### 3. README run-path (spot check)

| Claim | Reality |
|-------|---------|
| `DUCKDB_BIN` / `QUACKAPI_EXT` with `$HOME/personal/quackapi/...` defaults | Works **on this machine**; grader without that path must set env — OK if documented as required |
| Port **8117**, kill via `lsof` | Matches documented boot |
| `rm -f closure.db` then `.read server/app.sql` | Correct canonical path; `run.sh` is still dual-boot smell (code-quality S1) |

No change made here; flag only: absolute home defaults in docs are a polish ding
if the grader’s tree differs.

---

## Bottom line

| Fit | Verdict | Integrate into app? |
|-----|---------|---------------------|
| **1. finetype for detection/confidence** | **Marginal** | **No as primary detector**; optional `ft_profile` on pure fields / remainder catalog only |
| **2. finetype_cast for phone match** | **No** (DOB ISO only) | Digit-strip in SQL for phones; cast optional for dates |
| **3. quickjs residual** | **No** | Do not add for MVP |
| **Column mode fixes ISBN?** | **Partially** — US-paren phones + larger SSN cols via `ft_profile`; fails dash/UK/tiny SSN; free-text spans still n=1 | Not enough for Closure’s path |
| **Repo polish** | Hygiene gaps are ignore-rules + docs sprawl, not missing product | See section above; do not delete in this pass |

Do not replace Pattern/Context judges with finetype. Do not expect column mode
to save per-token PDF detection. Do use SQL digit-strip for the phone match
hole Alok hit in the web-ingest spike — finetype_cast will not.
