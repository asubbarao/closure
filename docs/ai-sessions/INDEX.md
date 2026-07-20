# AI Tool Sessions — Index

This directory is the raw export of AI-assisted work behind the `closure`
take-home (an AI-powered PDF redaction review tool). It contains the
orchestrator transcript, ~190 sub-agent transcripts, the prompts issued to
each sub-agent, and the shared build contract they all read first.

## Working method

A Claude Code session acted as **orchestrator**: it held the assignment,
owned the shared build contract (`grok-prompts/contract.md`), and fanned work
out to **xAI Grok agents** invoked over ACP (Agent Client Protocol, stdio) —
the `call-grok` pattern. Each Grok agent ran in its own process against the
shared working tree, was given a narrow file-ownership boundary (e.g. "you
own only `server/templates/review.html` and `static/review.js`"), and
reported back what it proved (boot log, curl output, screenshot, test run)
before the orchestrator folded its work into the next wave. Waves ran
roughly sequentially, each building on the previous wave's state; a few
waves (w4, w6) ran many Grok agents in parallel against the same tree and
needed an explicit integration/bootfix pass afterward (wave 5).

Separately, three **independent clean-room control implementations**
(Next.js/TypeScript, React+Vite, or similar conventional stacks) were built
by dedicated Grok agents from the assignment text alone — no access to the
`closure` app, its design mocks, or its DuckDB-native architecture — purely
to give an honest comparison point against the unconventional "DuckDB is the
whole backend" approach. A separate review pass (`revcleanroom`,
`w4_uxcompare`, `w4_tradeoff`) compared all four implementations head to
head.

**Gemini** was used for one targeted UX review pass over the shipped
frontend (mock fidelity, interaction quality, copy) as a second-opinion
check outside the Grok/Claude loop.

Adjacent to the closure app itself, a large share of the Grok sessions in
this export were spent hardening **quackapi** — the user's own DuckDB
community extension that serves as `closure`'s HTTP server (the load-bearing
piece of the "one DuckDB process is the whole backend" architecture). That
work is a FastAPI-parity effort: feature specs, implementation rigs, and
cross-language conformance corpora (Python/Node/Go/Ruby/Django/Flask/Express)
proving quackapi's HTTP surface (pagination, versioning, OIDC, rate
limiting, health probes, streaming, etc.) behaves like a real web framework.
It is included here because it is real AI-tool-usage history from the same
period and directory tree, even though it is infrastructure rather than a
graded deliverable of the take-home itself.

## Contents

- `grok-transcripts/` — 192 JSONL event logs, one per Grok agent run (tool
  calls, file edits, terminal output, final report).
- `grok-prompts/` — the task prompt handed to each Grok agent (`.txt`), plus
  `contract.md`, the shared build contract every agent read first.
- The Claude Code orchestrator session (the session that dispatched all
  Grok agents and did the higher-level planning/integration/review) is
  retained privately and available on request — it is not committed because
  the raw transcript interleaves unrelated personal/work context.

## Major waves (closure app)

| Wave | Purpose | Grok jobs |
|---|---|---|
| **G — initial build** | First working app: backend/ingest (schema, seed, routes), the four core UX surfaces, and initial hardening/QA/docs passes | `backend` (ingest/seed/routes/app.sql), `dashboard` (case dashboard, S1), `review` (review surface, S2 — the star screen), `reject` (false-positive/reject flow), `addmissed` (false-negative/add-missed flow), `bulk` (bulk-review screen), `ux` (visual system pass, frontend-design skill), `data` (sample-data research), `datagen` (professional/general fake-data generator), `ocr` (scanned/image-only PDF support in the `pdf` extension), `oom` / `fixoom` (memory_limit OOM diagnosis + fix), `playwright` (e2e proving the core workflow), `extsurvey` / `webext` (DuckDB community-extension survey for web-serving), `quackapi` (feasibility: can quackapi serve the whole app?), `pubdocs` (quackapi publishing artifacts for community-extensions submission), `limits` (scaling-and-limits design doc), `quality` (code-quality/repo-structure review), `sanity` (honest soundness check), `stress` (PDF pipeline stress harness), `revclosure`/`revcleanroom` (deep review of closure vs. the clean-room controls), `detect` (judge ensemble + remainder scan — see below) |
| **Alt-architecture spike** | A parallel one-SQL-entrypoint + standalone React/Vite SPA architecture spike, explored and ultimately not the shipped path | `g1-backend` (single SQL boot entrypoint), `g2-frontend` (React+Vite+TS SPA talking only to the JSON API), `g9-docs` (docs pass on that spike) |
| **Clean-room controls** | Three independent from-scratch implementations built from the assignment text alone, for comparison | `clean1`, `clean2`, `clean3` (attempt-1/2/3, each Next.js/TS or equivalent), `closure` (control-set support job) |
| **w1 — restructure & spikes** | Professional repo restructure without behavior change; false-positive/negative sample tuning; extension spikes; punch list | `restructure` (exclusive `server/**`/`static/**` restructure), `fpfn` (false-positive/negative sample data), `marisa` (PII-dictionary matching spike), `provspike` (chain-of-custody / `pdf_revisions` spike), `memfix` (fix hardcoded 256MB `quackapi_serve()` memory cap), `punchlist` (consolidated punch list from all prior review docs), `workflow` (reviewer-seat walkthrough of 800 suggestions, workflow-improvements doc) |
| **w2 — judge ensemble, provenance, search** | Judge panel for flagged items, missed-redaction queue, fuzzy search, provenance panel, e2e coverage for all of it | `judge` (judge ensemble on flagged suggestions), `remainder` (remainder scan for missed redactions), `fuzzysearch` (fuzzy add-missed search), `provenance` (chain-of-custody panel wired from the spike), `e2e` (Playwright coverage for the wave-2 features) |
| **w3 — extension surveys, P0 fixes, undo** | Detection/platform/geo extension surveys; export P0 bug fixes; decision undo | `extA` (detection-relevant extensions), `extB` (platform extensions), `extGeo` (geo/raster rendering extensions), `p0` (four P0 export bugs), `pdfstore` (PDF storage/handling module), `undo` (decision revert on the append-only JSON log) |
| **w4 — throughput funnel & UX depth** | The "3k suggestions → auto-pass + bulk groups → ~800 hand-reviewed, grouped" funnel; sample corpus breadth; comparative analysis | `funnel` (grouped-residual triage funnel), `cryptoaddr` (crypto-address entity type), `gensetup` (sample generation setup), `geominimap` (page minimap navigation), `localllm` (local-LLM detection option), `part3` (funnel wave continuation), `scans` (scanned-document handling), `courtdocs` (real public-domain court document corpus), `tradeoff` (closure vs. clean-room tradeoff analysis), `uxcompare` (full UX comparison, closure vs. controls), `uxflesh` (UX polish round) |
| **w5 — integration fix** | Ten parallel wave-4 agents left the app failing to boot; emergency fix | `bootfix` (restore `:8117` boot after overlapping parallel edits) |
| **w6 — audit, data model, tradeoffs, observability** | Deeper review pass: revert/audit trail, data model, observability honesty, confidence-scoring design, tradeoffs | `auditrevert` (audit trail + revert review), `confdesign` (confidence-scoring design doc, not implemented — ML explicitly out of scope), `datamodel` (schema/CTAS review), `otel` (observability assessment), `tradeoff` (deep tradeoff/gap analysis) |
| **w7 — adversarial / failure testing** | Empirically break the DuckDB-as-backend architecture; fix real regressions from UX edits; prior-art research | `breakit` (push every axis to failure, record exact boundaries), `e2efix` (fix 3 failing Playwright specs, root-cause not band-aid), `priorart` (verify/refute the "embedded OLAP DB as whole web backend" claim against real prior art) |
| **w8 — line addressing, redaction safety, bulk tool** | Line-level addressing spike, redaction-safety hardening (the #1 real legal-tool failure mode), bulk-tool UX finish | `bulktool` (bulk-review screen, design-matched finish), `readlines` (line-level addressing spike + `server/lines.sql`), `redactsafe` (hardened `pdf_redact`/export correctness, `docs/redaction-safety.md`) |
| **Docs & standalone reviews** | Longer-lived docs-only research jobs interleaved throughout | `review` (review-surface build report), `redaction` (early assignment-reading pass) |

## Infrastructure & tooling support (quackapi, duckdb-chrome-bridge)

A large remaining share of the transcripts is adjacent engineering on
**quackapi** (the DuckDB HTTP-server extension `closure` depends on) and, in
a handful of jobs, an unrelated **duckdb-chrome-bridge** project. These are
included for completeness (real history from the same machine/timeframe)
but are not part of the graded `closure` deliverable.

| Cluster | Purpose | Grok jobs |
|---|---|---|
| Feature specs (FastAPI parity) | Written specs for HTTP-framework features quackapi should support | `spec_api_versioning`, `spec_background_tasks`, `spec_body_partial`, `spec_cache_etag`, `spec_gzip`, `spec_health`, `spec_lifespan`, `spec_middleware`, `spec_oidc`, `spec_pagination`, `spec_problem_details`, `spec_rate_limit`, `spec_request_id`, `spec_route_groups`, `spec_serdes`, `spec_sessions`, `spec_static_files`, `spec_streaming`, `spec_test_client`, `spec_websocket_sse` |
| Implementation rigs | Built the above specs into quackapi's C++ | `rig_admin_ui`, `rig_bridge_hard`, `rig_cache_etag`, `rig_compression_zstd`, `rig_cron_jobs`, `rig_djangokiller`, `rig_example_gallery`, `rig_fastapi_bridge`, `rig_health_probes`, `rig_pagination`, `rig_pydantic_endpoints`, `rig_versioning` |
| Conformance corpora | Cross-framework/cross-language fixtures proving quackapi behaves like a real web framework | `corpus_go`, `corpus_node`, `corpus_py`, `corpus_ruby`, `corpus_spec`, `br_django`, `br_express_nest`, `br_flask`, `br_openapi`, `fastapieq`, `gc1`, `gc2`, `gc3`, `gc4`, `gc_arrow`, `gc_batteries`, `gc_compression`, `gc_docpipe`, `gc_docs`, `gc_fakedata`, `gc_fromfast`, `gc_fuzz`, `gc_group`, `gc_handler`, `gc_infera`, `gc_ledger`, `gc_merge`, `gc_ocr`, `gc_paddle`, `gc_policy`, `gc_pydantic`, `gc_queue`, `gc_rails`, `gc_readpdf`, `gc_readpdf2`, `gc_rpconsolidate`, `gc_scope`, `gc_scope_batt`, `gc_scope2`, `gc_stream`, `gc_submit` |
| quackapi core hardening | Bug fixes, auth, memory limits, streaming, OpenAPI export, QA passes | `ast`, `audit`, `auth-impl`, `bridge`, `bughunt`, `builder1`, `curlhttpfs`, `fix-core`, `handler_logic`, `integrate`, `jsproto`, `next15`, `oauth-spec`, `onquack`, `openapi`, `ofbverify`, `offboarder`, `pydantic`, `qa-ci`, `qa-review`, `qa-verify`, `qa1`, `qa1_raw`, `quackhook`, `queue`, `radio`, `sitting`, `snowdocs`, `snowflake`, `streaming`, `tsfix`, `valsafe`, `wanted` |
| Closure/quackapi cross-cutting | De-hardcoding, type-tightening, mock verification, workflow review directly against closure | `closure-dehardcode`, `closure-finetype`, `closure-mocks`, `closure-quickjs`, `closure-stress`, `closure-verify`, `closure-workflow` |
| Unrelated project (duckdb-chrome-bridge) | A separate DuckDB/Chrome DevTools bridge extension, not part of this take-home | `g1`, `g2`, `g3`, `ex`, `fig` |

## Orchestrator session

The full Claude Code orchestrator session (~15 MB JSONL) ran throughout —
planning, wave sequencing, per-agent file-ownership assignments, and the
integration/review work done directly by the orchestrator. It is available
on request rather than committed, since the raw transcript interleaves
unrelated personal and work context beyond this project.
## Notes on completeness

Total export size is ~22 MB (well under the ~100 MB cutoff), so nothing was
pruned — all 192 Grok transcripts and all prompt files are present in full.
