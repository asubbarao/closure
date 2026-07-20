# Spike: detection / DQ community extensions

Isolated probes for the survey in `docs/ext-survey-detection.md`.
**Owns only** `spikes/ext-detection/**`. Does not modify `server/`.

## Prerequisites

```text
DuckDB ≥ 1.5.4 (osx_arm64 community builds signed)
  /opt/homebrew/bin/duckdb  → v1.5.4 on this machine
```

From **repo root**:

```bash
duckdb -unsigned -markdown :memory: < spikes/ext-detection/01_address_parse.sql
duckdb -unsigned -markdown :memory: < spikes/ext-detection/02_crypto_custody.sql
```

## What’s spiked

| # | Extension | Claim |
|---|-----------|--------|
| 01 | `us_address_standardizer` | `addrust_parse` canonicalizes roster addresses; street-only FP bait is separable from full addresses via a simple gate |
| 02 | `crypto` | PDF digests match core `sha256`; ordered `crypto_hash_agg` + `crypto_hmac` seal real decision JSON |

## Verdicts (full list in survey doc)

**Integrate now:** `crypto`, `us_address_standardizer`  
**Spike later:** `json_schema`, `ai` (offline only)  
**No:** everything else in the survey set
