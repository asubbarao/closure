# AI-Session Export

Closure's SQL backend was rebuilt schema-first by a small fleet of AI sub-agents
(Grok, driven through an ACP driver) orchestrated from a Claude Code session. This
directory is the honest paper trail of that work: what each sub-agent was told, and
the machine-readable event stream of what it did.

## Layout

- **`grok-prompts/`** — the shared context every sub-agent received.
  - `PREAMBLE.md` — architecture rulings (DuckDB-as-entire-backend, generic detection
    over the fixture, near-zero macros, no bare `CROSS JOIN`, unmaterialized purposeful
    views, uuid-at-load identity) + hard style rules, including the absolute "run **no**
    git commands" rule added after a sub-agent's `git checkout` wiped uncommitted work.
  - `EXT_REFERENCE.md` — exact call shapes for the DuckDB extensions the rebuild leans on
    (`finetype`, `us_address_standardizer`, `rapidfuzz`, `splink_udfs`, `scalarfs`,
    `crypto`, `pdf`, `tera`) so every agent used them consistently instead of hand-rolling.

- **`grok-transcripts/*.jsonl`** — one ACP event stream per sub-agent run (`start`,
  `tool_call`, `update`, `permission`, `done`). These are event logs, not prose chat;
  the authored side of each conversation is the shared prompt above plus the per-file
  task embedded at dispatch. Full conversational bodies remain queryable from the
  session store (`agent_data`) and were deliberately not vendored here to keep the repo
  lean (the graded submission tag drops them entirely).

## The runs

Naming: `sp_` = spine (load + detect), `g_` = generic rewrite / cleanup pass,
`lf_` = leaf (one route or model file). One agent = one file, so no two ever collided.

| Job | Scope | Tools | Wall | Finished |
|-----|-------|------:|-----:|:--------:|
| `sp_ingest`     | `ingest.sql` — cases/documents/pages/words/watchlist load | 29 | 231s | ✅ |
| `sp_detect`     | `detect.sql` — generic PII detection spine | 79 | 1186s | ✅ |
| `g_detect2`     | detection rewrite: finetype on words, addrust tightened, ngram union removed (17k→1.7k suggestions) | 29 | 495s | ✅ |
| `g_viewclean`   | kill count(*) stat-views, everything set-based, purposeful unmaterialized views | 59 | 433s | ✅ |
| `lf_pages`      | `routes/pages.sql` | 49 | 1248s | ✅ |
| `lf_pdfio`      | `pdf_io.sql` | 51 | 901s | ✅ |
| `lf_pdfstore`   | `pdf_store.sql` (scalarfs) | 59 | 1490s | ⚠️ timed out; output reconciled by hand |
| `lf_remainder`  | `remainder_scan.sql` | 44 | 1394s | ✅ |
| `lf_search`     | `routes/search.sql` (rapidfuzz) | 48 | 793s | ✅ |
| `lf_triage`     | `routes/triage.sql` | 51 | 682s | ✅ |
| `lf_history`    | `routes/history.sql` | 50 | 734s | ✅ |
| `lf_decisions`  | `routes/decisions.sql` | 42 | 728s | ✅ |
| `lf_geo`        | `routes/geo.sql` | 39 | 508s | ✅ |
| `lf_judge`      | `judge.sql` + `routes/judge.sql` | 27 | 366s | ✅ |
| `lf_provenance` | `provenance.sql` | 41 | 475s | ✅ |
| `lf_compare`    | cleanroom-vs-duckdb comparison pass | 29 | 236s | ✅ |
| `lf_smalls`     | small route files, batched | 64 | 1438s | ⚠️ timed out; output reconciled by hand |

Every file was re-verified against a fresh boot after the fan-out; the two timed-out
runs were finished and checked by hand. Net effect of the whole rebuild: server SQL
went from ~7,380 lines to ~3,249 (>50% cut) while moving hand-rolled string/NLP/address
logic onto the extensions above.
