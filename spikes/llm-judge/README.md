# Spike: local-LLM judges (nice-to-have)

Isolated probes for optional LLM-as-judge on **flagged residuals**.
**Owns only** `spikes/llm-judge/**` + `docs/llm-judge.md`. Does **not** modify `server/`.

## Prerequisites

```text
Ollama running on :11434
  /usr/local/bin/ollama list
  models used: llama3.2:3b, qwen2.5:7b  (already on this machine)

DuckDB ≥ 1.5.4
  /opt/homebrew/bin/duckdb

Live app optional (for refreshing fixture.json):
  http://127.0.0.1:8117  (or boot via run.sh)
```

## Run

From **repo root**:

```bash
# 1) prove both call paths (ai extension + http_client)
duckdb -unsigned -markdown :memory: < spikes/llm-judge/01_probe_paths.sql

# 2) full judge run on fixture (11 real suggestions × 3 judge configs)
rm -f spikes/llm-judge/out/run.duckdb
duckdb -unsigned spikes/llm-judge/out/run.duckdb < spikes/llm-judge/02_run_judges.sql

# outputs
ls spikes/llm-judge/out/   # llm_votes.csv comparison.csv latency_summary.csv
```

Refresh fixture from a running app (optional):

```bash
# see how fixture was built — re-export via API if needed
# spikes/llm-judge/fixture.json is checked in from the 2026-07-19 live sample
```

## What’s spiked

| File | Claim |
|------|--------|
| `01_probe_paths.sql` | `ai` extension → Ollama **and** `http_client.http_post` → `/api/generate` both work |
| `02_run_judges.sql` | 2 independent model×prompt judges + `ai_classify` control on 11 real items; compare vs deterministic panel |
| `fixture.json` | Real suggestion rows + deterministic judge votes from `/api/suggestions/:id/judges` |
| `sketch_routes_judge_llm.sql` | **Not wired** — integration shape if promoted |
| `docs/llm-judge.md` | Latency, quality, cost, honest ship/demo-flag/skip verdict |

## Call-path choice

| Path | Works? | Notes |
|------|--------|-------|
| **`http_client`.http_post** | **yes — preferred** | Model/prompt can vary per row; Ollama returns `total_duration` for latency |
| **`ai` extension** | **yes, with caveats** | `ai_classify` / `ai_complete` work with `SET duckdb_ai_provider='ollama'`; **`model` named arg must be a constant** (cannot `model := col`) |

## Verdict (one line)

**demo-flag** — see `docs/llm-judge.md`. Do not put on the boot-path ensemble.
