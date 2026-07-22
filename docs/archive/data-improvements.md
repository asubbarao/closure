# Sample corpus data improvements

**Status:** research + proposal only — do **not** regenerate `samples/identities.json`, `samples/manifest.json`, or PDFs until this plan is approved.  
**Scope:** improve realism of the fakeit-generated cast and make false-positive bait more believable, using DuckDB community extensions already in the project’s stack.  
**Survey date:** 2026-07-19  
**Local probe:** DuckDB **v1.5.4** (`osx_arm64`), `INSTALL … FROM community` + `LOAD` succeeded for all three extensions; CDN `HTTP 200` for  
`https://community-extensions.duckdb.org/v1.5.4/osx_arm64/{fakeit,finetype,us_address_standardizer}.duckdb_extension.gz` (community-signed builds).

---

## 1. Current fake data (what exists)

### Pipeline

| File | Role |
|------|------|
| `samples/gen/identities.sql` | One-shot DuckDB script: `LOAD fakeit`, draw 4 subjects + witnesses + officers, `COPY` → `samples/identities.json` |
| `samples/identities.json` | **Frozen fixture** (fakeit is not seedable) — answer-key identities |
| `samples/gen/generate.py` | Reads fixture only; builds police-report narratives + FN plants; renders via Typst |
| `samples/gen/report.typ` | US-letter template; no PII generation |
| `samples/manifest.json` | Ground truth per PDF: `pii`, `fp_bait`, `fn_plants` |
| `server/ingest.sql` | Loads identities into `entities` kinds (`PERSON · SUBJECT`, `SSN`, `DATE OF BIRTH`, `ADDRESS · SUBJECT`, phones, officers, `STREET NAME · NOT PII`, `CITATION · NOT PII`) |

### PII types in the fixture (4 cases)

| Kind | Source fields | Example (case `24-000117`) |
|------|---------------|----------------------------|
| Person name (subject) | `subject.name` | Yasmine Nienow |
| SSN | `subject.ssn` | `280-96-9531` |
| DOB | `subject.dob` | `12/23/1999` (MM/DD/YYYY, ages ~25–65 via `random()`) |
| Full address | `subject.address` | `5024 Island Ton, Carissaton, New Mexico 45146` |
| Phone (subject + 2 witnesses) | `(NNN) NNN-NNNN` from raw digits | `(668) 724-5138` |
| Officers | `Ofc./Det./Sgt. F. Last #NNNN` | includes **surname-sharing plant** on case 1 only |
| FP street bait | `{surname} Street` | `Nienow Street` |
| FP citation bait | `{surname} v. Ohio, 494 U.S. 541 (1990)` | fixed U.S. Reports cite for all cases |

**FN plants (generate.py only, not in identities):** spaced SSN (`280 96 9531`); misspelled witness (`Robyn Prce` ← Price). These are good and should stay.

### Realism scorecard (committed fixture)

| Issue | Evidence | Impact on redaction review |
|-------|----------|----------------------------|
| **Addresses look synthetic** | Street lines are faker “word + place-suffix” (`Island Ton`, `Trail Shire`, `Creek Town`, `Club Borough`); cities are `-ton/-furt/-borough` blobs (`Carissaton`, `Ortizfurt`, `Tremayneton`, `Effertzborough`) | Humans and weak NER still tag them as ADDRESS, but they train eye/heuristics on **unrealistic** patterns; standardizers leave `suffix` null (no ST/AVE) |
| **ZIP ≠ state** | NM + `45146` (OH range); UT + `03737` (NH); VT + `47630` (IN); OK + `84822` | Breaks any zip/state sanity check a detector might grow; looks “fake at a glance” |
| **Invalid NANP phones** | Subject `(067) 258-5647` (area code cannot start with 0); witness `(316) 111-6215` (exchange `111` invalid); several area codes unassigned/implausible | Phone regex still hits, but corpus fails a “looks like real CJ data” bar |
| **Weak / invalid SSN structure** | `695-00-9863` has group `00` (historically invalid); area codes not constrained vs 000/666/9xx | Same as phones — format-only |
| **DOB is fine** | Real calendar dates, adult range | Keep formula; optionally multi-format later for FN plants |
| **Names: mixed** | Realistic-enough Western names; rare surnames (`Nienow`, `Skiles`, `Stiedemann`) make **street FP bait** less believable | Naive surname match still works; **common-surname collision** (`Brown Street`) is the only street that looks like a real road |
| **Citation bait is copy-paste** | Same volume/page for every surname | Fine for string match; slightly cartoonish for legal-literate reviewers |
| **Officer plant only case 1** | `Det. C. Nienow #9418` | Intentional; good for surname FP |

**Net:** the corpus is structurally sound for a redaction product demo (types, FP/FN plants, bulk recurrence). Weakness is **surface realism of free-form identity fields**, especially addresses and NANP/SSN validity — not the Typst narrative shape.

---

## 2. Extension study

All three use the same install pattern and are available as **community-signed `osx_arm64` builds for DuckDB v1.5.4** (probed CDN + local install).

```sql
INSTALL <name> FROM community;
LOAD <name>;
```

### 2.1 fakeit

| | |
|--|--|
| **Docs** | https://duckdb.org/community_extensions/extensions/fakeit |
| **Version (catalog)** | 0.3.4 |
| **Install / load** | `INSTALL fakeit FROM community; LOAD fakeit;` |
| **osx_arm64 v1.5.x signed** | **Yes** — CDN 200 for v1.5.4; loads on local v1.5.4. Excludes wasm + `linux_amd64_musl` only. |
| **What it does** | 120+ scalar generators (names, addresses, phones, SSN, datetime pieces, cards, UUIDs, …). Powered by the Rust `fakeit` crate. **Not seedable** (volatile) → fixture must stay committed. |

**Key functions for this corpus**

| Function | Use |
|----------|-----|
| `fakeit_name_first()` / `fakeit_name_last()` / `fakeit_name_full()` | People (keep) |
| `fakeit_person_ssn()` | 9 raw digits — **must** format + validate |
| `fakeit_contact_phone()` | 10 raw digits — **must** format + validate |
| `fakeit_contact_phone_formatted()` | Pre-formatted but often non-NANP; prefer raw + own formatter |
| `fakeit_address_street_number()` / `_name()` / `_suffix()` | Building blocks (suffix is often junk: `furt`, `mouth`, `borough`) |
| `fakeit_address_street()` | **Avoid** — docs claim “123 Main St”; live draws often look like `11618 New Underpass mouth` |
| `fakeit_address_city()` / `_state()` / `_state_abr()` / `_zip()` | Independent randoms — **no geo correlation** |
| `fakeit_datetime_date()` | Optional alternate DOB source |

**Live quality (100 SSN / 50 phone draws on this machine)**

- SSN: ~11% invalid area (000/666/9xx), ~2% group `00` → ~87% “structurally okish” after filters.
- Phone: ~28% bad NPA (starts 0/1), ~22% bad NXX (starts 0/1); only ~54% pass basic NANP digit rules in one sample.

**How it improves the corpus:** still the right **name/SSN/phone digit** source. Improvements are **post-filters and composition**, not swapping libraries. Do not expect realistic US addresses from fakeit alone.

### 2.2 finetype

| | |
|--|--|
| **Docs** | https://duckdb.org/community_extensions/extensions/finetype |
| **Version (catalog)** | 0.6.36 |
| **Install / load** | `INSTALL finetype FROM community; LOAD finetype;` |
| **osx_arm64 v1.5.x signed** | **Yes** — CDN 200 for v1.5.4; loads locally. Excludes wasm, musl, `windows_amd64_mingw`. |
| **What it does** | Semantic type classification (~244 types, `domain.category.type`). **Column-oriented** (`ft_profile`) + per-value scalars (`ft_infer`, `ft_detail`, `ft_cast`, `ft_validate` / `ft_validate_text`). **Does not generate data.** |

**Key functions**

| Function | Role for corpus / app |
|----------|----------------------|
| `ft_profile('table')` | One row/column: type, confidence, recommended DuckDB type |
| `ft_infer(v)` / `ft_detail(v)` | Ad-hoc labels |
| `ft_cast(v)` | Normalize dates etc. for storage |
| `ft_validate(table, schema_json)` | Reject columns that fail a JSON Schema |

**Probe on current fixture (flat subject table)**

| Column | `ft_profile` type | Notes |
|--------|-------------------|-------|
| `name` | `identity.person.full_name` (~0.96) | Correct |
| `address` | `geography.address.full_address` (1.0) | Correct even for fake cities |
| `phone` | `identity.person.phone_number` (0.5) | Correct, low confidence |
| `dob` | `datetime.date.iso` (0.5) | Accepts MM/DD/YYYY via cast path; label is coarse |
| `ssn` | **misclassified** as `identity.person.phone_number` / per-value `identity.commerce.isbn` | **No reliable SSN type in practice** |

FP street strings (`Nienow Street`, `Brown Street`) often land as `geography.address.street_name` in votes, then demoted to generic text — useful signal that “surname + Street” is ambiguous (exactly the product lesson).

**How it improves the corpus:** **quality gate + optional kind mapping**, not generation.

1. After assembling a flat `subjects` / `witnesses` table, `ft_profile` asserts names/phones/addresses look like those types before `COPY`.
2. Optional future: map finetype labels → `entities.kind` seeds (with an explicit SSN override — do not trust finetype for SSN).
3. `ft_validate` can enforce phone/SSN regex schemas that the generator claims to produce.

### 2.3 us_address_standardizer

| | |
|--|--|
| **Docs** | https://duckdb.org/community_extensions/extensions/us_address_standardizer |
| **Version (catalog)** | 0.2.1 |
| **Install / load** | `INSTALL us_address_standardizer FROM community; LOAD us_address_standardizer;` |
| **osx_arm64 v1.5.x signed** | **Yes** — CDN 200 for v1.5.4; loads locally. **Excluded:** `osx_amd64`, all wasm (not a problem for this Mac arm64 workflow). |
| **What it does** | **Parse / standardize** US addresses — does **not** invent people or streets. Two engines: Rust `addrust_parse` (no tables) and PostGIS-style PAGC (`load_us_address_data()` then `standardize_address` / `parse_address`). |

**Key functions**

```sql
SELECT load_us_address_data();  -- once per session: us_lex / us_gaz / us_rules

SELECT addrust_parse('123 N Main St Apt 4, Springfield IL 62704');
-- struct: street_number, pre_direction, street_name, suffix, city, state, zip, unit, …

SELECT standardize_address('us_lex', 'us_gaz', 'us_rules',
  '123 Main Street', 'Kansas City, MO 45678');
-- struct: house_num, name, suftype, city, state, postcode, …
```

**Probe on current fixture addresses:** parses house number + city/state/zip, but **street suffix is always NULL** and PAGC often splits nonsense streets (`Island Ton` → pretype `ISLAND`, name `TON`). On **curated** `1204 Maple St` + `Portland, OR 97205`, both engines return clean `MAPLE` + `STREET`/`St` + OR + zip.

**How it improves the corpus:**

1. **Normalize** composed addresses into USPS-ish display forms (`1204 MAPLE ST, PORTLAND, OR 97205` or title-case rebuild from struct fields).
2. **Validate** that every subject address parses with non-null `street_name` + `suffix` + `zip` before commit — rejects fakeit-style `Creek Town` lines.
3. **FP street bait:** use a real street **suffix** and optional predir (`N Brown St`, `Brown Avenue`) so bait matches what address NER and `addrust_parse` call a street — stronger than bare `Brown Street` string equality only.

---

## 3. Concrete proposal (what to change in `samples/gen`)

**Do not regenerate the corpus yet.** When approved, re-roll is intentional and will replace all PII + PDFs + manifest.

### 3.1 `identities.sql` — primary change set

#### A. Load all three extensions

```sql
INSTALL fakeit FROM community;
INSTALL finetype FROM community;
INSTALL us_address_standardizer FROM community;
LOAD fakeit;
LOAD finetype;
LOAD us_address_standardizer;
SELECT load_us_address_data();
```

(Today only `LOAD fakeit` — and only if already installed.)

#### B. Keep case scaffold; improve subject draws

**Names:** keep `fakeit_name_first/last`. Optional: for case 1 (or a dedicated case), **force a common US surname** from a small list (`Brown`, `Smith`, `Johnson`, `Williams`, `Miller`, `Davis`, `Wilson`, `Anderson`, `Taylor`, `Thomas`) so `fp_street` is a street name humans believe (`Brown Street` already works; rare surnames do not).

**SSN:** keep `fakeit_person_ssn()`, then reject until valid:

```sql
-- 9 digits; area not 000/666/9xx; group not 00; serial not 0000
-- re-draw pattern: generate_series oversize + QUALIFY / filter, or recursive CTE
substr(ssn,1,3) NOT IN ('000','666') AND substr(ssn,1,1) <> '9'
AND substr(ssn,4,2) <> '00' AND substr(ssn,6,4) <> '0000'
-- format: XXX-XX-XXXX (unchanged)
```

**Phone:** keep raw 10 digits from `fakeit_contact_phone()`, reject until NANP-basic:

```sql
-- NPA: [2-9][0-9]{2}, NXX: [2-9][0-9]{2}, station: [0-9]{4}
-- optional: also reject NXX in (555) if you want to avoid “hollywood” fiction — or KEEP 555 for clearly synthetic demo data
```

Format as today: `(NPA) NXX-XXXX`. Optionally emit a second field `phone_alt` later for FN (dots / bare digits) — that would be a generate.py plant, not required for v1.

**DOB:** keep age window relative to a fixed “today” date; optionally also store ISO in the JSON for finetype-friendly profiling while narratives keep MM/DD/YYYY.

#### C. Replace free-form address composition with curated geo + standardizer

Add small **deterministic** tables in SQL (no external files required):

1. **`us_places`** — real city + state abbr + ZIP that actually belong together, biased to **Oregon** to match “City of Riverton PD” / ORS footer (and a few other states for diversity):

   | city | st | zip |
   |------|----|-----|
   | Portland | OR | 97205 |
   | Salem | OR | 97301 |
   | Eugene | OR | 97401 |
   | Bend | OR | 97701 |
   | Gresham | OR | 97030 |
   | Medford | OR | 97501 |
   | (plus 4–8 more real triples if desired) | | |

2. **`us_streets`** — realistic street *names* and USPS-style suffixes (not fakeit suffixes):

   | name | suf | notes |
   |------|-----|--------|
   | Maple | St | ordinary residential |
   | Oakwood | Dr | |
   | Industrial | Blvd | commercial |
   | River | Rd | |
   | 9th | Ave | matches narrative “9th Avenue” intersections |
   | *(subject last name)* | St | **per-case FP bait street**, filled after subject draw |

3. **Compose** line1 / line2:

   ```text
   {house_num} [{predir}] {street_name} {suf}
   {city}, {st} {zip}
   ```

   `house_num`: prefer `100–9999` (avoid leading-zero `047`). Optional: `fakeit_address_street_number()` filtered to that range.

4. **Standardize** before storing the display string:

   ```sql
   SELECT standardize_address('us_lex','us_gaz','us_rules', line1, line2) AS std;
   -- rebuild e.g. initcap(house_num || ' ' || name || ' ' || suftype) || ', ' || initcap(city) || ', ' || state_abr || ' ' || postcode
   -- OR use addrust_parse and rebuild from struct fields with known casing
   ```

5. **Hard gate:** drop/re-draw rows where `std.suftype IS NULL` OR `std.postcode IS NULL` OR `addrust_parse(...).suffix IS NULL`.

**Subject address** should use an ordinary street from `us_streets` (not the surname street).  
**`fp_street`** should be the human-facing bait used in prose (today: `{last} Street`). Improve to:

- Prefer common surnames (above), **or**
- Keep rare surnames but set `fp_street` to a **full standardized fragment** that still contains the surname as the street *name*: e.g. `Nienow St` / `Nienow Avenue` produced the same way as real streets (suffix + optional predir), so detectors that require “looks like a street” still fire.

Also store optional structured fields in JSON (backward-compatible if generate.py only reads `address` string):

```json
"address": "1204 Maple St, Portland, OR 97205",
"address_parts": { "house": "1204", "street": "Maple", "suffix": "St", "city": "Portland", "state": "OR", "zip": "97205" }
```

`generate.py` can ignore `address_parts` until needed; ingest can keep using the single string.

#### D. Officers / witnesses / citations

- Keep surname-sharing officer plant on case 1.
- Consider planting one more shared-surname officer on a **common-surname** case so FP dismissal UX has a second example.
- Citations: vary volume/page slightly per case (still fake) so every cite is not `494 U.S. 541`.
- Witnesses: unchanged generation + phone validation.

#### E. Finetype quality gate (before `COPY`)

Flatten subjects into a temp table `gate_subjects(name, ssn, dob, address, phone)` and:

```sql
SELECT * FROM ft_profile('gate_subjects');
-- Assert (raise error via CASE / assert pattern, or write a rejection table):
--   name    ~ identity.person.full_name
--   address ~ geography.address.full_address
--   phone   ~ identity.person.phone_number
--   dob     ~ datetime.* 
-- DO NOT assert finetype on ssn (known misclassification → ISBN/phone)
```

Optional JSON Schema via `ft_validate` for phone/SSN patterns as a second belt.

#### F. Output contract

Keep the same top-level JSON shape so `generate.py` and `server/ingest.sql` keep working:

```text
cases[].case_no, subject{name,ssn,dob,address,phone}, witnesses[], officers[], fp_street, fp_citation
```

Only additive fields (`address_parts`, ISO dob) if needed.

### 3.2 `generate.py` — small follow-ups (after re-roll)

No change required for a pure identity realism pass. Optional later:

1. Intersection prose: use `fp_street` as standardized (`Nienow St` / `Brown Avenue`) consistently with “and 9th Avenue”.
2. Extra FN plants: phone without punctuation; DOB as `1999-12-23` in one section only; SSN last-four only — each recorded in `fn_plants`.
3. When subject lives on a real-looking street, avoid putting **subject house number** on the **surname street** unless you want a deliberate hard case.

### 3.3 `report.typ`

No change. Template already preserves SSN/phone tokens (`hyphenate: false`).

### 3.4 Regeneration checklist (when approved)

1. Edit `identities.sql` as above.
2. Run from repo root:  
   `/opt/homebrew/bin/duckdb :memory: -c ".read samples/gen/identities.sql"`  
   → overwrites `samples/identities.json`.
3. Run `python3 samples/gen/generate.py` → PDFs + `manifest.json`.
4. Re-ingest (`server/ingest.sql` / app seed path) and smoke-test review UI: subject hits, dismiss `fp_street` / citation / surname officer, spaced-SSN FN still present on supplemental.
5. Commit fixture + PDFs + manifest together (never commit a re-roll of identities without regenerating PDFs).

### 3.5 What *not* to do

| Avoid | Why |
|-------|-----|
| Rely on `fakeit_address_street()` / city+zip independence | Guarantees fake-looking lines and zip/state mismatch |
| Expect finetype to label SSN | Probe shows ISBN/phone; keep explicit `SSN` kind in ingest |
| Seed fakeit | Impossible today — fixture remains the source of truth |
| Regenerate without re-running generate.py | Manifest and PDFs would desync from identities |
| Require `osx_amd64` for us_address_standardizer | Extension excludes that platform |

---

## 4. Priority order (minimal → maximal)

| Priority | Change | Benefit | Risk |
|----------|--------|---------|------|
| **P0** | NANP + SSN structural filters on fakeit draws | Phones/SSNs stop looking broken | Low; still non-seedable |
| **P0** | Curated OR (etc.) place triples + real street name/suffix list | Addresses stop looking like faker garbage | Low; small static tables |
| **P1** | `us_address_standardizer` normalize + parse gate | USPS-ish strings; parseable FP streets | Medium (API shape / casing choices) |
| **P1** | Bias ≥1 subject surname to common US name for FP street | Believable “Street” false-positive bait | Low; changes demo story slightly |
| **P2** | `ft_profile` gate on flat subject table | Catches botched regenerations | Low; SSN exception required |
| **P3** | Extra FN formats in generate.py | Harder detector eval | Medium (manifest + tests) |

---

## 5. Summary

The redaction-review sample stack is already well designed: frozen fakeit fixture, Typst narratives, FP bait (street / citation / shared-surname officer), and FN plants (spaced SSN, misspelled witness). The main data quality gap is **identity surface realism** — addresses in particular read as synthetic, phones/SSNs sometimes violate basic US rules, and rare-surname “X Street” bait is weaker than common-surname streets.

| Extension | Generates? | Role in the fix |
|-----------|------------|-----------------|
| **fakeit** | Yes | Keep for names/SSN/phone digits; add validation filters; stop trusting its address composition |
| **us_address_standardizer** | No (parse only) | Compose from curated real place+street tables, then standardize/validate — this is how you get believable addresses and street-shaped FP bait |
| **finetype** | No (classify only) | Post-draw quality gate and optional kind hints; **not** SSN ground truth |

**Only file written for this task:** `docs/data-improvements.md`. Corpus files intentionally untouched.
)
