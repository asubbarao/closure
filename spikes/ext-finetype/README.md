# Spike: finetype (+ quickjs residual) for Closure detection

Isolated evaluation of DuckDB community extension **finetype** (semantic type
classifier + confidence) against Closure’s detection core — typing spans as
PHONE / SSN / DOB / PERSON / ADDRESS and feeding confidence bands. **quickjs**
is secondary: only if a normalize/transform is left after finetype + SQL.

**Not wired into** `server/`, `templates/`, `static/`, or `samples/`.

## Prerequisites

```text
DuckDB CLI ≥ 1.5.3 (this machine: v1.5.3)
osx_arm64 community builds:
  INSTALL finetype FROM community;  -- LOAD ok (v0.6.23)
  INSTALL quickjs FROM community;   -- LOAD ok
```

Despite some early README caution about platform builds, both install and load
on local v1.5.3 osx_arm64.

## Run

From **repo root** (`/Users/aloksubbarao/personal/closure`):

```bash
duckdb -unsigned -markdown < spikes/ext-finetype/00_setup.sql
duckdb -unsigned -markdown < spikes/ext-finetype/01_single_vs_column.sql
duckdb -unsigned -markdown < spikes/ext-finetype/02_cast_normalize.sql
duckdb -unsigned -markdown < spikes/ext-finetype/03_quickjs_residual.sql
```

Captured markdown reports live under `spikes/ext-finetype/out/`.

## Files

| Path | Role |
|------|------|
| `00_setup.sql` | INSTALL/LOAD + catalog counts from `samples/identities.json` |
| `01_single_vs_column.sql` | Single-value misfires vs `ft_profile` column mode scorecard |
| `02_cast_normalize.sql` | `finetype_cast` vs `qnorm` vs digit-strip for phone match |
| `03_quickjs_residual.sql` | JS digit-strip vs SQL; residual-fit table |
| `out/*.log` | Pasted real run output |

## Headline results (local run)

### Isolated single-value (true scalar literals)

| Input | `finetype(v)` | Notes |
|-------|---------------|--------|
| `(613) 235-3301` | `identity.commerce.isbn` | **WRONG** (phone → ISBN) |
| `271-72-1446` | `identity.commerce.isbn` | **WRONG** (SSN → ISBN) |
| `08/16/1979` | `datetime.date.mdy_slash` | Correct |

### Column mode (`ft_profile`) scorecard

| Scenario | Want | Got | Conf | OK? |
|----------|------|-----|-----:|-----|
| PHONE US paren (n=13) | `identity.person.phone_number` | same | ~0.79 | yes |
| PHONE US dash (n=8) | phone_number | `alphanumeric_id` | ~0.50 | **no** |
| PHONE UK-ish (n=4) | phone_number | `isbn` | ~0.48 | **no** |
| SSN pure (n=7) | `identity.government.ssn` | same | ~0.57 | yes |
| SSN tiny (n=2) | ssn | `isbn` | ~0.70 | **no** |
| DOB mdy slash (n=7) | `datetime.date.mdy_slash` | same | ~0.90 | yes |
| ADDRESS full (n=4) | `geography.address.full_address` | same | ~1.00 | yes |
| PERSON names + traps | `full_name` | same | ~0.42 | format-only “yes” |

**App regex** on the same PHONE/SSN/DOB shapes: **13/13, 7/7, 7/7**.

### `finetype_cast` vs phone token match

| Check | Result |
|-------|--------|
| Cast leaves `(613) 235-3301` unchanged | **yes** (no canonicalize) |
| Cast normalizes DOB `08/16/1979` → `1979-08-16` | **yes** |
| Fixes web-ingest `qnorm` phone residue mismatch | **no** |
| SQL `regexp_replace(..., '[^0-9]+', '')` digit match | **yes** |

### quickjs residual

`quickjs_eval('(s) => String(s).replace(/[^0-9]/g,"")', phone)` equals SQL
digit-strip. **No residual** Closure needs that SQL + finetype cannot cover
without dragging in a real JS library (e.g. libphonenumber).

## Verdict summary

See [`docs/finetype-fit.md`](../../docs/finetype-fit.md).

Short version: **finetype is marginal for Closure’s detection core** — useful
column confidence for clean DOB/address and *sometimes* SSN/phone, but it
types **formats not context**, single-value PHONE/SSN still misfire, column
mode is format/sample-size fragile, and `finetype_cast` does **not** fix the
phone token-match hole. Prefer app regex + judge context for MVP; treat
finetype as optional column-profiler spice, not a replacement.
