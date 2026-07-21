# Data-model assault — Closure

**Reviewer stance:** Ralph Kimball (bus matrix, grain, conformed dims, fact discipline) + Bill Inmon (CIF/3NF integration before marts, single version of truth) + **Martin Kleppmann** (logs as truth, stream-table duality, derived data, idempotence, schema evolution, fault models, unbundling the database).  
**Scope:** `/Users/aloksubbarao/personal/closure` — DuckDB + quackapi, append-only `exports/decisions/`.  
**Method:** Read `server/app.sql` boot order + domain modules + routes; sample decision JSON; `read_json_auto` on the live decision glob. Live `closure.db` was lock-held by a running duckdb (PID) — schema truth taken from CTAS SQL + decision files.  
**Constraint:** This file only. No commits. No “portfolio coach” fluff.

---

## 0. Executive verdict

**Shit scale: 8 / 10** (was 7.5 before the stream/log audit; Kleppmann raises the ceiling because the *one good idea* is implemented as cargo-cult event sourcing).

The one idea that is not shit is correct: **status is not a mutable column — it is a projection of an append-only decision event stream.** That is Kimball transaction-fact discipline, Inmon historical integration, and Kleppmann stream-table duality in one stroke — *as a slogan*. Everything around it is an **app-shaped CTAS pile with UUID roulette**: boot re-issues `uuid()` for documents, suggestions, and entities (`ingest.sql`, `detect.sql`), while the durable “log” stores those UUIDs forever. After a clean boot you have a warehouse of **orphans with confidence scores**. That is not “turning the database inside out”; that is **destroying the foreign keys of the changelog** every time the process starts.

**Kleppmann, specifically:** the decision “log” is a **bag of JSON files** (`COPY TO … FILENAME_PATTERN 'dec_{uuid}'`), not an ordered, durable, append-only log with offsets, compaction, or consumer identity. Readers use `read_json_auto` + `union_by_name` + **`ignore_errors := true`** (`sources.sql:44–49`) — schema by inference, corrupt shards dropped silently. There is **no event version**, no request-id for idempotent POST, no exactly-once story under retry, and dual write paths (`exports/decisions/` hardcoded on write vs `CLOSURE_EXPORTS_DIR` on read). Derived state (words, suggestions, judge_votes, residual) is **full batch rebuild at boot**, not incremental materialization; crash mid-boot is undefined. Geometry is a flat four-column cargo cult (`x0,y0,x1,y1`) duplicated across words / suggestions / residual / export STRUCT with a Y-axis flip smuggled into plan views. Dimensions are not conformed — `kind` is a free-text junk string (`PERSON · SUBJECT`), ids are cast to VARCHAR at every join, decision log columns type-churn (`entity_id`/`undoes_batch_id` inferred as JSON, `ts` as VARCHAR). There is **no atomic integrated subject-area model**; there is a boot script that rebuilds UI-ready tables, a filesystem JSON dump pretending to be Kafka + a table store + a search index, and a freeze contract (`SCHEMA_CONTRACT.md`) that enshrines the wrong surface. As a single-process FOIA redaction prototype this is operable. As a data model — warehouse *or* dataflow system — it is a crime scene.

---

## 1. As-is map

### 1.1 Inventory

| Relation | Kind | Materialized how | Role |
|----------|------|------------------|------|
| `app_config` | TABLE CTAS | `config.sql` | Key/value runtime knobs |
| `v_src_pdf_info` | VIEW | `sources.sql` over `pdf_info` | Raw PDF dimension feed |
| `v_src_decisions` | VIEW | `sources.sql` over `exports/decisions/*.json` | **THE** decision event reader |
| `cases` | TABLE CTAS | `ingest.sql` from manifest | Case shell |
| `documents` | TABLE CTAS | `ingest.sql` + `uuid()` | Document shell |
| `pages` | TABLE CTAS | `ingest.sql` `read_pdf` | Page geom |
| `words` | TABLE CTAS | `ingest.sql` then **replaced** in `pdf_io.sql` with `source` | Word/OCR tokens |
| `watchlist` | TABLE CTAS | `ingest.sql` from `watchlist.json` | Operator name roster |
| `entities` | TABLE CTAS | empty shell then **replaced** in `detect.sql` | Detected/watchlist parties |
| `pii_taxonomy` | TABLE VALUES | `detect.sql` | Detector→kind map (tiny) |
| `suggestions` | TABLE CTAS | `detect.sql` AI hits only | Detection fact (status-less) |
| `v_latest_decision` | VIEW | `detect.sql` arg_max over log | Status projection spine |
| `v_manual_suggestions` | VIEW | `detect.sql` from `kind='added'` | Manual adds as pseudo-suggestions |
| `v_suggestions` | VIEW | AI ∪ manual + status + band | **App universal interface** |
| `judge_rules` / `judge_votes` | TABLE | `judge.sql` boot snapshot | Ensemble votes |
| `v_judge_panel` / `v_suggestions_judged` | VIEW | blend | Confidence presentation |
| `entity_address_canon` / `entity_groups` / `entity_group_members` | TABLE | `remainder_scan.sql` | Bulk-group side graph |
| `v_entity_groups` | VIEW | member counts | Group UI |
| `residual_pii_hits` | TABLE CTAS | remainder re-detect | FN candidate fact (not in v_suggestions) |
| `document_custody` | TABLE CTAS | `provenance.sql` | Hash snapshot at boot |
| `v_case_provenance` | VIEW | live recheck + seal | Custody dashboard row |
| `pdf_store_source` / `pdf_store_events` | TABLE | lifecycle | Source stage + working events |
| `v_pdf_store` / `v_working_plans` | VIEW | stages + redact SQL sentences | PDF lifecycle |
| `document_scan_status` | VIEW | COUNT FILTER over words | Scan badges (metric view) |
| `v_doc_ui` / `v_case_page` / `v_review_page` | VIEW | UI mega-projections | **Marts baked as base** |
| `v_page_geom` / `v_page_words` / `v_page_marks` / `v_page_map` | VIEW | display px | Presentation layer |
| `v_audit` / `v_history_events` / `v_prior_states` / `v_decision_batches` | VIEW | log folds | Audit/history |
| `v_export_plans` / `v_address_map` | VIEW | plan + schematic geo | Export + map |
| `app_templates` | TABLE | HTML strings | Presentation store |
| **JSON side-files** | files | `exports/decisions/*.json` | Durable events (759 decision rows + 4 added in sample) |
| **PDF side-files** | files | `samples/`, `data/working/`, `exports/*_redacted.pdf` | Binary artifacts |
| **CSV side-file** | file | `exports/export_map.csv` | Path map at boot |

Ephemeral: `_detect_lines`, `_detect_hits`, `_remainder_spans`, `_empty_pages` (dropped or intermediate).

### 1.2 Declared grain (honest)

| Relation | Claimed / implied grain | Actual |
|----------|-------------------------|--------|
| `cases` | 1 row / case | OK natural key `case_no`; `id` **duplicates** `case_no` |
| `documents` | 1 row / PDF file | OK **if** id stable; **id = uuid() every boot** → not durable |
| `pages` | 1 row / (doc, page) | OK; **no PK declared** |
| `words` | 1 row / token on page | **GRAIN UNKNOWN** — no word_id, no (doc,page,seq), order only via (y0,x0) bags |
| `watchlist` | 1 row / (case, term, kind) | OK natural; no PK |
| `entities` | 1 row / (case, text, kind) | Intended unique on those; **id = uuid() boot**; fuzzy link to suggestions |
| `suggestions` | 1 AI hit / bbox span | **MIXED**: detection event + denormalized entity attrs; **no status**; id unstable |
| `v_manual_suggestions` | 1 latest `added` / suggestion_id | Separate creation path; not in `suggestions` table |
| `v_suggestions` | AI ∪ manual + projected status | **MIXED GRAIN** — detection instance + workflow state + band + group_key |
| `v_src_decisions` / files | 1 event / JSON row | **MIXED**: status change (`decision`) **and** entity creation (`added`) **and** batch header fields on every row |
| `judge_votes` | 1 row / (suggestion, judge 1..3) | OK snapshot grain; dies/reboots with suggestion ids |
| `residual_pii_hits` | 1 FN candidate / deduped box+kind | Parallel fact stream **not** conformed to suggestions |
| `entity_groups` / members | M:N bridge-ish | Hash pseudo-keys `% 2147483647` — collision theater |
| `document_custody` | 1 row / document at boot | Snapshot fact OK; not event-sourced over file changes |
| `pdf_store_events` | (doc, stage, gen, kind) | Closest thing to a proper event table for working copies |
| `v_doc_ui` / `v_case_page` / triage routes | doc / case metrics | **Dashboard grain smuggled into “model”** |
| `v_decision_batches` | 1 row / batch_id | Aggregate over events — OK as mart, not base |
| `v_export_plans` | 1 row / case | Plan sentence; not an export fact |

### 1.3 ER-style joins (reality, not marketing)

```
manifest.json ──unnest──► cases (id = case_no)
                     └──► documents.case_id
pdf_info / read_pdf / read_pdf_words ──filename──► documents ──uuid()──► id  [REISSUED EVERY BOOT]
        │                                      │
        ├── pages (document_id, page_no)
        └── words (document_id, page_no, word, x0..y1 [, source])
                    │
                    ▼ detect (finetype / addrust / rapidfuzz × watchlist)
              entities (uuid, case_id, canonical_text, kind)
              suggestions (uuid, document_id, page, bbox, text, entity_id?, kind, source='ai')
                    │
                    │  LEFT JOIN cast(id AS VARCHAR) everywhere
                    ▼
exports/decisions/*.json  ◄── COPY TO (routes/decisions, triage, history)
   kind ∈ {decision, added, sentinel}
        │
        ├── v_latest_decision  (arg_max status by ts) ──► v_suggestions.status
        ├── v_manual_suggestions (kind=added) ──UNION──► v_suggestions
        ├── v_history_events → v_prior_states → v_decision_batches
        └── v_audit (display)

residual_pii_hits ──(not in v_suggestions)──► remainder UI ──POST add──► kind=added event

pages.height_pt ──Y-flip──► export/working STRUCT(page,x,y,w,h) ──pdf_redact──► exports/*_redacted.pdf
document_custody / v_case_provenance ──hash seals──► prose custody_statement
```

**There is no FK enforcement.** Joins are `cast(a AS VARCHAR) = cast(b AS VARCHAR)`. That is not a model; that is apologizing in SQL.

---

## 2. Kimball indictment

### 2.1 Dimensional sins

- **No fact/dimension separation.** `suggestions` is treated as the fact table but carries degenerate text, context, reason, kind, confidence, flag_tag, and geometry — a **transaction fact that swallowed its dimensions**.
- **No bus matrix.** Case, document, page, entity, actor, time, detector, status are not conformed dimensions shared by detection / decision / residual / export / custody facts. Each module invents local shapes.
- **Unstable surrogate keys (capital sin).** `documents.id`, `suggestions.id`, `entities.id` = `uuid()` at CTAS (`ingest.sql:22`, `detect.sql:118,127`). Decision log stores those ids. Reboot = **broken grain lineage**. Kimball: surrogate keys are durable. You mint disposable ones and write them to cold storage.
- **Natural key for case is half-done.** `cases.id = cases.case_no` (`ingest.sql:10–11`) — fine for natural key, but then everything else refuses natural keys for documents (`filename` exists and is the real durable key) and uses random UUIDs instead.
- **Mixed grain in the decision “fact”.** One physical stream holds:
  - status change on existing suggestion (`kind='decision'`) — transaction fact of judgment
  - birth of a suggestion (`kind='added'`) — creation event with full geometry payload
  - batch metadata denormalized onto every row (`batch_id`, `batch_label`, `undoes_batch_id`)
  That is **two facts + a junk batch dimension** smashed into one JSON schema (`SCHEMA_CONTRACT.md` §2, `routes/decisions.sql`).
- **`kind` is a junk dimension left as VARCHAR soup.** Load-bearing substrings (`PERSON · SUBJECT`, `OFFICER · NOT SUBJECT PII`, …) drive judge/geo/remainder (`SCHEMA_CONTRACT.md` §1, `judge.sql:69–79`, `geo.sql:27–30`). No `dim_pii_kind(kind_key, family, role, is_subject_pii)`. Stringly-typed dimensional modeling.
- **No conformed time.** `ts` is VARCHAR from JSON; consumers `try_cast` to TIMESTAMP (`detect.sql:147–150`, `history.sql:21`). No date key, no session, no “review day” rollup grain.
- **No actor dimension.** Actor is free text (`DEFAULT 'reviewer'`, `app_config.actor`, template stamp). Cannot answer “who accepted this entity last week” without string equality luck.
- **No detector / source dimension.** `source` is `'ai'|'manual'|'ocr'|'text'` scattered; residual uses `detector` (`finetype|addrust|rapidfuzz`) — **not conformed** to suggestion.source.
- **Entity–suggestion is not a clean FK fact.** Link is fuzzy:
  ```sql
  e.canonical_text = h.text OR starts_with(e.canonical_text, h.text) OR starts_with(h.text, e.canonical_text)
  ```
  (`detect.sql:131–133`). That is a **bridge table waiting to happen**, implemented as a LEFT JOIN hope. Fan-out / wrong entity assignment is baked in.
- **Bridge tables done with hash theater.** `entity_groups.group_id = abs(hash(...)) % 2147483647` (`remainder_scan.sql:68`). Collision-prone pseudo-keys are not keys.
- **SCD ignored.** Entity canonical text / kind changes on every detect rebuild. No Type 2 history. Watchlist is the only slow-changing input, and it is not versioned.
- **Snapshot vs transaction confusion.** `judge_votes` is a **boot-time snapshot fact** over suggestions; decisions are **transactions**. Residual hits are a **snapshot**. Document custody is a **snapshot**. None of this is labeled or versioned as such — the app pretends they are all “the model.”
- **Presentation facts in the core.** `v_doc_ui` (`pages.sql:9–62`) is a classic **aggregate fact table** (counts, progress_pct, badge classes) sitting where dimensions should live. `document_scan_status` (`pdf_io.sql:80–156`) is COUNT FILTER dashboard. Kimball: aggregates are **downstream marts**, not peers of `words`.
- **Degenerate keys done wrong.** `group_key` on `v_suggestions` (`detect.sql:201–202`) is a derived degenerate key for triage — fine as a query attribute, toxic when used as the sole bulk-decision identity without a real entity_id.
- **Export is not a fact.** Redaction produces files; there is no `export_event` fact with case_id, document_id, box_count, actor, fingerprint, decision_batch. Provenance invents a case-level `decision_chain_seal` hash over the whole log (`provenance.sql:88–97`) — a **gimmick measure**, not a grain.
- **Geometry is not a dimension and not typed.** Four doubles + page_no, re-projected to px in `v_page_*`, re-projected to bottom-left STRUCT for `pdf_redact` (`export.sql:18–27`, `pdf_store.sql:170–180`). Duplicated conversion = two sources of truth for “what is a box.”

### 2.2 Target bus matrix

| Fact | Grain | Measures | Foreign keys (conformed dims) |
|------|-------|----------|-------------------------------|
| `f_word_occurrence` | 1 token instance on a page | (none / optional char_len) | document_sk, page_sk, word_sk?, source_sk (text\|ocr), bbox |
| `f_detection` | 1 detector hit (AI) at ingest/run_id | confidence, score | document_sk, page_sk, entity_sk?, detector_sk, kind_sk, run_sk, bbox |
| `f_decision_event` | 1 status transition (or add) | (event only) | suggestion_sk, batch_sk, actor_sk, status_sk, reason_sk?, date_sk, time |
| `f_judge_vote` | 1 (suggestion, judge, run) | score | suggestion_sk, judge_sk, verdict_sk, run_sk |
| `f_residual_hit` | 1 FN candidate at scan_run | score | document_sk, page_sk, entity_sk?, detector_sk, kind_sk, scan_run_sk, bbox |
| `f_export` | 1 document export attempt | pages_redacted, box_count, ok | document_sk, case_sk, actor_sk, decision_batch_sk, date_sk, fingerprint |
| `f_working_copy` | 1 working gen materialization | accepted_count, pages_redacted | document_sk, gen, actor_sk, decision_batch_sk |

| Dimension | Grain | SCD |
|-----------|-------|-----|
| `dim_case` | case_no | Type 1 title |
| `dim_document` | natural key = content hash or (filename, case_no); surrogate stable | Type 2 if file replaced |
| `dim_page` | (document_sk, page_no) + width/height | Type 1 |
| `dim_entity` | (case_sk, canonical_text, kind_sk) | Type 2 on merge/rename |
| `dim_suggestion` | durable suggestion_sk; links to detection or manual add | Type 1 attrs; status **not** here |
| `dim_pii_kind` | kind_key → family, role, is_pii | Type 1 taxonomy |
| `dim_actor` | actor_id | Type 1 |
| `dim_status` | pending\|accepted\|rejected | Type 1 |
| `dim_detector` | finetype\|addrust\|rapidfuzz\|manual\|… | Type 1 |
| `dim_date` / `dim_time` | calendar | Type 1 |
| `dim_batch` | batch_id, label, is_undo, undoes_batch_sk | Type 1 |
| `bridge_entity_group` | group_sk ↔ entity_sk | Type 1 membership + score |

**What dies**

- Boot-time `uuid()` as identity for anything that appears in the decision log.
- Flat four-column geometry as the interchange format (keep only at API edge if frozen).
- `v_doc_ui` / case `stats` structs as “base model.”
- `kind` free-text as the only taxonomy.
- Dual suggestion stores (`suggestions` table vs `added` JSON) without a unified `dim_suggestion` birth event.
- `entity_id` JSON-typed nulls in the log.

**What becomes a bridge**

- Entity multi-match / group members (`entity_group_members` → real bridge with stable keys).
- Suggestion ↔ word span (optional many-words-to-one-box).

---

## 3. Inmon indictment

Inmon: **integrate at the atomic level first; marts are projections.** Closure inverted that.

### 3.1 What you have

- **ODS?** No. You have **CTAS application tables** rebuilt from sample globs every boot (`app.sql:15–16`, module order 118–125).
- **Enterprise 3NF subject areas?** No. Entities are an output of detection, not a master subject area. Cases are distincts from a test manifest.
- **Single version of truth?** Split brain:
  1. In-memory CTAS (`suggestions`, `entities`, `words`)
  2. Filesystem JSON (`exports/decisions/`)
  3. Filesystem PDFs (`samples/`, `data/working/`, `exports/`)
  4. Provenance snapshots that re-read blobs live
- **Atomic integration layer?** The closest candidate is `v_src_decisions`, and it is a **semi-structured dump** (`read_json_auto` + `union_by_name` + `ignore_errors` — `sources.sql:43–50`). That is not CIF; that is “hope the files parse.”
- **App spaghetti as schema.** `v_case_page` packs `struct_pack` stats + document lists + entity lists + audit LIMIT 12 (`pages.sql:126–179`) — a **page controller**, not a subject area. `v_export_plans` embeds executable SQL strings as columns (`export.sql:34–56`) — control plane pollution of the data model.
- **SCHEMA_CONTRACT freezes the wrong layer.** It freezes route JSON keys and kind **display strings**, not integrated entities. That is API product freeze, not enterprise model discipline. Stale names (`schema.sql`, `seed.sql`, `v_decisions`) prove the “contract” already drifted from boot truth.

### 3.2 Proper subject-area ODS/CIF sketch

| Subject area | Atomic tables (3NF-ish) | Notes |
|--------------|-------------------------|-------|
| **Case** | `case(case_sk, case_no NK, title, opened_at, …)` | Independent of PDF inventory |
| **Document** | `document(document_sk, case_sk, filename NK, source_uri, page_count, …)` + `document_version(document_sk, gen, sha256, stage, path)` | Version is first-class (source/working/export) |
| **Page** | `page(document_sk, page_no, width_pt, height_pt)` | PK composite |
| **Word** | `word(word_sk, document_sk, page_no, ord, text, font_size, source, bbox)` | Atomic extract; OCR is `source`, not a second warehouse |
| **Entity** | `entity(entity_sk, case_sk, kind_sk, canonical_text, …)` + optional `entity_alias` | Mastered before detection optional; detection **proposes** links |
| **Suggestion** | `suggestion(suggestion_sk, document_sk, page_no, bbox, text, context, confidence, entity_sk?, detector_sk, run_sk, origin)` | Birth only; **no status column** |
| **DecisionEvent** | `decision_event(event_sk, suggestion_sk, status_sk, actor_sk, reason_text, batch_sk, event_ts, undoes_batch_sk?)` | Append-only; **table or typed files with schema**, not free JSON |
| **Export** | `export_run(export_sk, case_sk, actor_sk, started_at, …)` + `export_document(export_sk, document_sk, path, sha256, box_count)` | Queryable audit of release |

Marts (Kimball) then sit on top: triage funnel, doc UI counts, judge panel, geo placement, audit HTML. **Those marts already exist as views — they just infected the base layer.**

---

## 3b. Kleppmann indictment

Kleppmann’s question is not “is there a star schema?” It is: **what is the system of record, how is derived state rebuilt, what fails under retry/crash/schema change, and did you unbundle deliberately or by accident?** Closure claims “append-only decisions → status projection.” That is the right religion. The implementation is a **filesystem cargo cult of event sourcing** sitting under a **boot-time batch warehouse** that pretends to be online OLTP.

### 3b.1 Log as source of truth — claim vs reality

**Claim (README + sources.sql):** decisions under `exports/decisions/*.json` are *the* append-only event log; status is a projection; one reader (`v_src_decisions`).

**Reality:**

| Property of a real log | Closure |
|------------------------|---------|
| Total order (offset / LSN) | **No.** Ordering is wall-clock `now()` as `ts` string + filename UUID. Concurrent POSTs have no defined order beyond timestamp ties broken ad hoc in lag/arg_max. |
| Append-only durability | **Maybe.** `COPY TO … FILENAME_PATTERN 'dec_{uuid}'` creates new shards; `OVERWRITE_OR_IGNORE` is not a log protocol. Partial write of a JSON object is not fenced. |
| Compaction / retention | **None.** Bag grows forever; no snapshot+truncate of projections. |
| Consumer offsets / checkpoints | **None.** Every view re-scans the glob. |
| Idempotent produce | **None.** Each POST mints a new file UUID and (for add) a new `suggestion_id`. Retry = second event. |
| Typed payload + version | **No.** Free-form JSON; `read_json_auto`; no `schema_version` field. Sentinel pins *names*, not types (and pins **INTEGER** for ids that live data stores as UUID strings — `app.sql:86–110`). |
| Corrupt shard policy | **`ignore_errors := true`** — silent drop. That is the opposite of an audit log. |

A directory of JSON files with inferred schema is **not** a log. It is a **document dump with chronological hope**. Kafka/Pulsar/EventStore/even a single DuckDB append-only table with `event_id + seq` would be more honest. You got the *vocabulary* of event sourcing without the *mechanics*.

**Write/read split brain:** writers hardcode `TO 'exports/decisions'` (`routes/decisions.sql`, `history.sql`, `triage.sql`). Reader binds via `CLOSURE_EXPORTS_DIR` / `exports` (`sources.sql:44–48`). Redirect reads without moving writes and the “log” forks. Kleppmann: dual writers/readers to different stores without a single coordination rule is how you invent consistency bugs for free.

### 3b.2 Stream-table duality — broken at the root

Stream-table duality: the table is a **fold** over the stream; the stream is the **changelog** of the table. Rebuild table from stream → same keys, same state.

Closure’s fold that is *conceptually* correct:

```
v_src_decisions (stream)
  → v_latest_decision  (arg_max status by ts)     -- status table
  → v_manual_suggestions (arg_max added payload)  -- birth table for manual
  → v_suggestions = AI table ∪ manual ⟕ latest    -- serving projection
```

What **destroys** duality:

1. **AI `suggestions` and `documents` / `entities` are not derived from the log.** They are **batch re-detect CTAS** that mint **new** `uuid()` every boot (`ingest.sql:22`, `detect.sql:118,127`). The log holds the *old* UUIDs. After reboot, `v_latest_decision.suggestion_id` no longer joins `suggestions.id` → status falls back to `pending` (`detect.sql:198`). **You re-derived the table by regenerating its primary keys.** That is the capital sin of stream processing: the changelog’s foreign keys become orphans.

2. **Manual adds** are log-native (`kind='added'`, stable `suggestion_id` in the file). AI hits are table-native (UUID in CTAS, later copied into decision files). Two birth authorities. Duality only holds for half the universe.

3. **Projections are not materializations with lag semantics.** `v_latest_decision` is a live view over the glob — good for a prototype — but there is no “caught up to offset N,” no rebuild job, no “serving store behind by 200ms.” It is either full rescan or nothing. Fine at hundreds of files; not a model.

4. **Boot CTAS is a second, competing system of record** for detection state. If detect changes algorithms, suggestion ids change *and* the historical decisions still name the old ids. There is no **rekeying / join-on-natural-key** consumer to re-bind old decisions to new detections. The dual brain just bleeds.

Kleppmann would say: you cannot “materialize” a changelog whose subjects are re-minted each run and still claim the table is a projection of the log. You have **two independent timelines** — detect-boot time and decision-file time — papered over with `cast(… AS VARCHAR)`.

### 3b.3 Derived data: batch rebuild vs incremental, crash mid-boot

Derived (in the DDIA sense — anything computed from the log or sources):

| Artifact | How built | Incremental? | Crash semantics |
|----------|-----------|--------------|-----------------|
| `words` / `pages` | full extract CTAS at boot | No | Partial: some tables replaced, later modules not run |
| `suggestions` / `entities` | full detect CTAS | No | Same |
| `judge_votes` | boot snapshot | No | Dies with suggestion ids |
| `residual_pii_hits` | full remainder scan | No | Same |
| `v_latest_decision` / `v_suggestions` | view fold over log ∪ tables | “Live” rescan | Correct only if table keys still match log |
| redacted PDFs / working gens | request-time / store events | Partial | Files can exist without export_event fact |
| `document_custody` | boot snapshot + live recheck | Hybrid | Hash at boot ≠ continuous custody |

`app.sql:14–15` boasts: *“All derived tables are CREATE OR REPLACE CTAS — re-run is always clean.”* That is **batch job honesty**, not stream processing. Clean re-run **replaces identity**, which is only “clean” if nothing durable pointed at those identities. **The decision log does.** So “clean boot” is **destructive to the changelog’s referential integrity**.

Crash mid-boot: no multi-table transaction around the CTAS chain. You can serve (if serve starts) with detect complete and remainder half-done, or refuse via integrity gates — neither is a defined recovery of derived state from the log. There is no “replay from offset 0 into empty tables.”

### 3b.4 Idempotence and exactly-once (you have neither)

- **POST `/api/suggestions/:id/decision`:** always appends a new `dec_{uuid}` with a new `batch_id`. Client timeout + retry → **two decision events**. Latest `ts` wins in `arg_max` — so double-accept is *eventually* same status, but **audit trail doubles**, batch history lies, undo undoes only one batch layer. That is **at-least-once produce + last-write-wins consume**, not exactly-once.
- **No producer idempotency key.** No `request_id` / `Idempotency-Key` stored and unique-constrained. Dedup is impossible without re-reading the whole bag and inventing a key.
- **POST add-missed** (`api_document_add`): mints **new** `suggestion_id = uuid()` every call (`decisions.sql:152`). Double-submit → **two accepted marks** at the same box. Not last-write-wins; **duplicate entities in the projection**.
- **Bulk entity / band decisions:** snapshot of “pending” at read time inside the COPY select; concurrent POST on one member → races; no transactional isolation across the multi-row append (multiple rows in one COPY is better than N requests, but still no client-level idempotency).
- **Undo / restore:** correctly **append inverse events** (good). The undo *route* itself is not idempotent: double-click undo can target the next forward batch or re-emit depending on timing of `v_decision_batches` fold. No fencing token.

DDIA: **effectively-once** requires either (a) idempotent writes with a natural key, or (b) transactional outbox / atomic log append + consumer dedup. You have neither. You have **hope and arg_max**.

### 3b.5 Schema evolution

Historical clerk decisions must parse forever. Your strategy:

1. `_sentinel.json` with **wrong types** (INTEGER ids) to “pin columns.”
2. `read_json_auto` + `union_by_name` + cast soup in every consumer.
3. Comments in `detect.sql:139–145` admitting that empty log infers `status` as **JSON**, so you cast everything to VARCHAR to avoid “Malformed JSON … pending.”

That is not schema evolution. That is **schema inference as a production dependency**. No `version` field on events. No reader that branches on version. No forward-compatible optional fields with defaults documented as a contract **with types**. `SCHEMA_CONTRACT.md` freezes **column names and display kind strings**, not Avro/Protobuf/JSON Schema evolution rules. Adding a field works by accident (`union_by_name`); removing or retyping a field silently corrupts folds or triggers `ignore_errors` drops.

**Encoding failure:** UUID vs VARCHAR vs INTEGER vs JSON-null across the same logical key (`suggestion_id`, `entity_id`, `document_id`) is exactly the “data encoding” chapter done wrong — one logical type, three physical encodings, glue with `cast`.

### 3b.6 Fault model

| Fault | What happens |
|-------|----------------|
| Process death mid-COPY | Possible incomplete JSON file; next `read_json_auto` may error or **drop** it (`ignore_errors`). Clerk action may vanish or poison a shard. |
| Process death mid-boot CTAS | Partial derived catalog; identity already re-minted for replaced tables; log still old. |
| Disk full on append | Write fails; client may retry → at-least-once mess if partial success unclear. |
| Dual brain drift | CTAS suggestions ≠ log suggestion_ids; PDFs on disk ≠ export facts; working registry path vs `exports/*_redacted.pdf` naming. Export plan can gate on status that no longer joins accepted history. |
| `CLOSURE_EXPORTS_DIR` ≠ write path | Reads another universe than writes. |
| Corrupt single decision file | Silently omitted from all folds — **audit lies by omission**. |

No checksums on decision shards, no write-ahead single file, no “log is immutable after rename into place.” Provenance’s `decision_chain_seal` hashes whatever the reader *could* parse — not what was written.

### 3b.7 Unbundling the database (or: smashing it back together wrong)

Kleppmann’s unbundling: **log / replication stream**, **durable document/blob store**, **secondary indexes**, **materialized views / caches**, **batch analytics** — composed explicitly.

Closure’s pile:

| Concern | Where it lives today | Should be |
|---------|----------------------|-----------|
| Decision changelog | JSON files + glob scan | True append log (table or segment files) with seq + types |
| Document binaries | `samples/`, `data/working/`, `exports/*.pdf` | Object store / content-addressed paths (you almost have sha in custody) |
| Primary serving state (suggestion + status) | CTAS tables + views | Materialized projection rebuilt from log + stable suggestion registry |
| Search | ad hoc routes over words | Explicit index (FTS / inverted) derived from words |
| Analytics / triage marts | views mixed into core | Downstream marts (Kimball) |
| UI templates | `app_templates` in DB | Fine as config; not a data model issue |

You put **everything** into DuckDB CTAS + a directory and called the directory a log. That is not unbundling; that is **one process wearing five hats without role labels**.

### 3b.8 Batch vs online — honesty

- **Batch:** detect, OCR enrich, remainder, judge votes, custody snapshot — all boot-time.
- **Online OLTP-ish:** decision POST, undo, add-missed, export, working-copy materialize — request-time, low latency expected by clerks.
- **Online analytical-ish:** triage funnels, history folds over full log — rescans.

The model does **not** separate these. FOIA review is an **interactive decision system** on top of a **batch detection job**. Status-as-projection is the right online pattern; re-running the entire detector to “refresh the warehouse” is the wrong way to recover online state. After any restart you need: (1) reload **stable** suggestion registry + documents by natural key, (2) replay or re-fold the decision log, (3) optionally re-detect into a **new run_id** without clobbering registry keys. Today (3) clobbers (1).

### 3b.9 Consistency: can export disagree with status projection?

Yes.

- **Export / working plans** read `v_suggestions` (status fold) and hash `(id, status)` for `decision_batch` (`pdf_store.sql:189–190`). That hash is **ephemeral identity** of the projection at request time — fine as a fingerprint, useless as a durable FK into the log if ids reminted.
- After boot remint: historical **accepted** decisions no longer join → suggestions show **pending** → export **omits** boxes the clerk already accepted (fail-open on privacy? or fail-closed on workflow? either way **wrong**). Reverse: if a stale in-memory cache existed (it mostly doesn’t — views re-read files), you could imagine export seeing file-log accepts the UI hadn’t refreshed; with pure views the worse case is **orphan log, empty projection**.
- **Manual adds** survive reboot (ids live in files). **AI accepts** do not bind. Inconsistent durability by origin — the worst kind of partial correctness.

### 3b.10 Encoding as a reliability bug

Repeated `cast(id AS VARCHAR)` joins are not style. They are evidence that **no single encoding** of identity was chosen. JSON null → JSON type; UUID → UUID; route params → VARCHAR; sentinel → INTEGER. Stream processors die on schema mismatch; you paper over it until `arg_max` silently groups the wrong set. Fix encoding first or every “exactly-once” patch is theater.

### 3b.11 Verdict under the Kleppmann lens

You understood **stream-table duality as a product idea**. You implemented **batch CTAS + a JSON junk drawer + last-timestamp-wins**. That is closer to “git for decisions” (append commits) done with `cp` into a folder than to a dataflow system. The brutal fix list is not “add Kafka.” It is: **stable keys in a registry that survives boot**, **typed append log with seq and version**, **projections rebuilt only from log + registry**, **idempotent writes**, **no ignore_errors on the audit path**.

---

## 4. Top 10 concrete fixes (by leverage)

Lenses: **K** = Kimball · **I** = Inmon · **Mk** = Kleppmann (log / duality / idempotence / evolution / faults).

### 1. Stop re-minting durable keys on boot  **[K · I · Mk]**
- **Problem:** `uuid()` on documents/suggestions/entities every CTAS; decision log references die. **Mk:** destroys stream-table duality — changelog FKs cannot rebind after restart.
- **Target:** Deterministic document_sk from `sha256(file bytes)` or `uuidv5(namespace, case_no || filename)`. Suggestion_sk: deterministic from `(document_sk, page, rounded bbox, text, detector, run_id)` **or** mint once and **persist** suggestion registry table/parquet that survives reboot. Never `uuid()` for ids that land in `exports/decisions/`. Detect may add a `detect_run_id`; it must not replace `suggestion_sk`.
- **Migration:** Dual-write: keep old uuid column as `legacy_id`; new `suggestion_sk` stable; backfill log by join on (document natural key, page, text, bbox) for historical files.
- **Risk:** High if UI bookmarks ids; medium if only session-scoped. e2e that assumes boot-stable ids will flip green for the right reason.

### 2. Split the decision log into typed events (or enforce a rigid schema)  **[K · Mk]**
- **Problem:** One blob schema for status transitions and suggestion births; type inference hell (`entity_id` JSON, `ts` VARCHAR). **Mk:** no encoding contract, no `schema_version`, `read_json_auto` + `ignore_errors` is not an audit substrate.
- **Target:**  
  - `decision_event`: kind always `status_change`; columns fixed types; **`event_seq` or uuidv7 + monotonic write**; **`schema_version INTEGER`**.  
  - `suggestion_birth`: kind `added` **or** better: insert into `suggestion` table + optional status_change.  
  - `batch` dimension table keyed by batch_id.  
  - Reader: explicit `columns={…}` (or JSON Schema / typed table), **`ignore_errors := false`** (quarantine bad shards to a dead-letter path, do not drop).
- **Migration:** Keep filesystem append if you must; write with explicit casts; reader view with `columns={...}` map instead of free `read_json_auto` + cast soup (`detect.sql:146–153`). Unify write path with read path env (`CLOSURE_EXPORTS_DIR`).
- **Risk:** Low if writers updated together; historical files need `union_by_name` shim view versioned as v0.

### 3. Make `dim_suggestion` the single birth record; status only from events  **[K · I · Mk]**
- **Problem:** AI rows in `suggestions` table; manual rows only in JSON (`v_manual_suggestions`). Two fact sources for one business entity. **Mk:** two birth authorities break duality; only half the stream can rebuild the table.
- **Target:** All origins insert/upsert `suggestion` registry. Manual add = INSERT suggestion + APPEND decision(accepted). `v_suggestions` = suggestion ⟕ latest decision. Registry survives boot; detect **upserts by natural key**, does not replace PKs.
- **Migration:** On read of `kind=added`, materialize into `suggestion` table at boot (CTAS from log ∪ detect).
- **Risk:** Medium — remainder/add-missed paths and e2e add flows.

### 4. Conformed `dim_pii_kind` — kill stringly taxonomy in joins  **[K · I]**
- **Problem:** Judge/geo/remainder parse kind with `starts_with` / `position` (`judge.sql:69–79`).
- **Target:**
  ```sql
  CREATE TABLE dim_pii_kind (
    kind_sk INTEGER PRIMARY KEY,
    kind_code VARCHAR,      -- 'PERSON_SUBJECT'
    family VARCHAR,         -- PERSON|PHONE|SSN|ADDRESS|...
    role VARCHAR,           -- SUBJECT|WITNESS|OFFICER|FP_BAIT|...
    is_subject_pii BOOLEAN,
    label VARCHAR           -- display 'PERSON · SUBJECT' if you must
  );
  ```
  Facts store `kind_sk`. Display label at the edge only.
- **Migration:** Map existing strings once; freeze codes not labels.
- **Risk:** SCHEMA_CONTRACT kind strings — keep labels as attributes so UI does not break.

### 5. Geometry type discipline  **[K · Mk]**
- **Problem:** Flat x0..y1 everywhere; Y-flip duplicated; export STRUCT different from storage. **Mk:** encoding inconsistency across producers (detect, manual add, export, residual).
- **Target:** One storage type, e.g. `STRUCT(page INTEGER, x0 DOUBLE, y0 DOUBLE, x1 DOUBLE, y1 DOUBLE, origin VARCHAR)` with `origin ∈ {'pdf_tl','pdf_bl'}`. Single function/view `bbox_for_redact(b, page_height)` used by export **and** working plans.
- **Migration:** Internal STRUCT; unpack to x0..y1 at route edge (contract).
- **Risk:** Low if edge unpack is complete; medium if JS assumes column order only.

### 6. Word grain: identity + source as first-class  **[K · I]**
- **Problem:** Words have no key; OCR union rebuilds whole table (`pdf_io.sql:69–74`); remainder rebuilds spans from scratch.
- **Target:** `word_sk` or at least `(document_sk, page_no, ord)` with `source`. One word fact stream feeds detect, search, remainder.
- **Migration:** CTAS assign `ord` via ordered window **once** (allowed at load; not as fake business id). Persist if boot must be stable.
- **Risk:** Low for UI; detect line bags may shift if order changes.

### 7. Entity resolution bridge, not starts_with join  **[K · I]**
- **Problem:** Fuzzy entity attach at suggestion birth (`detect.sql:131–133`).
- **Target:** `suggestion_entity_link(suggestion_sk, entity_sk, method, score, is_primary)` bridge; detection can emit multiple candidates; human can confirm.
- **Migration:** Current LEFT JOIN becomes one primary link row method=`boot_heuristic`.
- **Risk:** Medium for entity bulk decision routes (`/api/entities/:id/decision`).

### 8. Demote metrics views out of “core”  **[K · I · Mk]**
- **Problem:** `v_doc_ui`, `document_scan_status`, triage COUNT FILTER stacks, remainder boot FILTER report (`remainder_scan.sql:311–326`) look like model. **Mk:** these are **derived serving marts**, not the log or the atomic table; label them so crash-rebuild order is clear.
- **Target:** Base: atomic tables + event views. Mart schema/views: `mart.doc_review_status`, `mart.case_funnel` — named and documented as aggregates. No progress_pct in base document.
- **Migration:** Rename/move; routes keep column aliases for contract.
- **Risk:** Low (cosmetic + load order).

### 9. First-class export + custody events  **[K · I · Mk]**
- **Problem:** Audit of release is files + optional provenance prose; not a queryable fact for “what left the building.” **Mk:** blob store without a changelog of releases; dual brain (PDF file vs no event).
- **Target:** On successful `pdf_redact`, APPEND `export_event` (or decision-kind `export`) with document_sk, path, sha256, box list hash, actor, ts, **and the decision log offset/hash used**. Custody recheck reads that, not only `read_blob('exports/*')`.
- **Migration:** Dual-write file + event; provenance view joins events.
- **Risk:** Low for UI; e2e export assertions may need event presence.

### 10. Residual hits as suggestion proposals (same bus)  **[K · Mk]**
- **Problem:** `residual_pii_hits` is a parallel galaxy (`remainder_scan.sql:192–308`) with `page` not `page_no`, own ids, not in `v_suggestions`. **Mk:** parallel stream without shared keys; add-missed double-submit creates two births.
- **Target:** Same `f_detection` / proposal grain with `detector_run_id` and `status=proposed_fn`; human accept → birth + decision. Or promote to `suggestion` with `origin='remainder'`. **Idempotent add:** client `request_id` or natural key `(document_sk, page, rounded bbox, text)` unique in registry.
- **Migration:** View union into triage “missed” with shared bbox type.
- **Risk:** Medium — remainder UI + add-missed double-submit.

### 10b. Idempotent decision writes (producer keys)  **[Mk]** — promote into top 10 if you renumber later
- **Problem:** Every POST mints new file UUID + batch_id; retries duplicate audit; add-missed duplicates marks. No exactly-once path.
- **Target:** Require `Idempotency-Key` / `request_id` on mutating POSTs; store as unique column in the event (or sidecar index). Same key → return prior result, **do not append**. Optionally: single DuckDB table `f_decision_event` with `PRIMARY KEY (request_id)` and filesystem export as async materialization.
- **Migration:** New optional header/param; old clients stay at-least-once until forced.
- **Risk:** Medium for clients; high correctness payoff for legal audit.

---

## 5. Target schema sketch (minimal but real)

```sql
-- ═══ ATOMIC / CIF-ish (durable) ═══════════════════════════════════════════

CREATE TABLE dim_case (
  case_sk     BIGINT PRIMARY KEY,          -- or UUID v5 from case_no
  case_no     VARCHAR NOT NULL UNIQUE,
  title       VARCHAR
);

CREATE TABLE dim_document (
  document_sk   UUID PRIMARY KEY,          -- uuidv5(case_no || filename) OR content hash
  case_sk       BIGINT NOT NULL,
  filename      VARCHAR NOT NULL,
  source_path   VARCHAR NOT NULL,
  content_sha256 VARCHAR NOT NULL,         -- natural integrity key
  page_count    INTEGER,
  width_pt      DOUBLE,
  height_pt     DOUBLE,
  file_size     BIGINT,
  UNIQUE (case_sk, filename)
);

CREATE TABLE dim_page (
  document_sk UUID NOT NULL,
  page_no     INTEGER NOT NULL,
  width_pt    DOUBLE,
  height_pt   DOUBLE,
  PRIMARY KEY (document_sk, page_no)
);

CREATE TABLE dim_pii_kind (
  kind_sk       INTEGER PRIMARY KEY,
  kind_code     VARCHAR NOT NULL UNIQUE,
  family        VARCHAR NOT NULL,
  role          VARCHAR,
  is_subject_pii BOOLEAN NOT NULL,
  label         VARCHAR NOT NULL           -- UI/contract display
);

CREATE TABLE dim_actor (
  actor_sk  INTEGER PRIMARY KEY,
  actor_id  VARCHAR NOT NULL UNIQUE,       -- login / CLOSURE_ACTOR
  display_name VARCHAR
);

CREATE TABLE dim_status (
  status_sk INTEGER PRIMARY KEY,
  status_code VARCHAR NOT NULL UNIQUE      -- pending|accepted|rejected
);

CREATE TABLE dim_detector (
  detector_sk INTEGER PRIMARY KEY,
  detector_code VARCHAR NOT NULL UNIQUE    -- finetype|addrust|rapidfuzz|manual|remainder
);

-- BBox: one discipline
-- STRUCT(page INTEGER, x0 DOUBLE, y0 DOUBLE, x1 DOUBLE, y1 DOUBLE, origin VARCHAR)
-- origin: 'pdf_tl' (words/UI) | 'pdf_bl' (pdf_redact)

CREATE TABLE f_word (
  word_sk     BIGINT PRIMARY KEY,
  document_sk UUID NOT NULL,
  page_no     INTEGER NOT NULL,
  ord         INTEGER NOT NULL,            -- reading order on page
  text        VARCHAR NOT NULL,
  font_size   DOUBLE,
  source      VARCHAR NOT NULL,            -- text|ocr
  bbox        STRUCT(page INTEGER, x0 DOUBLE, y0 DOUBLE, x1 DOUBLE, y1 DOUBLE, origin VARCHAR),
  UNIQUE (document_sk, page_no, ord)
);

CREATE TABLE dim_entity (
  entity_sk       UUID PRIMARY KEY,        -- stable: uuidv5(case_no|kind_code|canonical)
  case_sk         BIGINT NOT NULL,
  kind_sk         INTEGER NOT NULL,
  canonical_text  VARCHAR NOT NULL,
  UNIQUE (case_sk, kind_sk, canonical_text)
);

CREATE TABLE dim_suggestion (
  suggestion_sk UUID PRIMARY KEY,          -- STABLE across boots
  document_sk   UUID NOT NULL,
  page_no       INTEGER NOT NULL,
  bbox          STRUCT(page INTEGER, x0 DOUBLE, y0 DOUBLE, x1 DOUBLE, y1 DOUBLE, origin VARCHAR),
  text          VARCHAR,
  context       VARCHAR,
  confidence    INTEGER,
  entity_sk     UUID,                      -- optional primary; prefer bridge
  detector_sk   INTEGER NOT NULL,
  kind_sk       INTEGER,
  origin        VARCHAR NOT NULL,          -- ai|manual|remainder
  created_at    TIMESTAMP NOT NULL,
  detect_run_id UUID                       -- which boot/detect run minted AI row
);

CREATE TABLE bridge_suggestion_entity (
  suggestion_sk UUID NOT NULL,
  entity_sk     UUID NOT NULL,
  method        VARCHAR,
  score         DOUBLE,
  is_primary    BOOLEAN,
  PRIMARY KEY (suggestion_sk, entity_sk)
);

-- Append-only integration (Inmon historical) / transaction fact (Kimball)
CREATE TABLE f_decision_event (
  event_sk        UUID PRIMARY KEY,        -- file uuid or uuidv7
  suggestion_sk   UUID NOT NULL,
  status_sk       INTEGER NOT NULL,
  actor_sk        INTEGER NOT NULL,
  reason_text     VARCHAR,
  batch_sk        UUID,
  undoes_batch_sk UUID,
  event_ts        TIMESTAMP NOT NULL,
  -- optional denormalized NK for offline files:
  case_no         VARCHAR,
  document_sk     UUID
);

CREATE TABLE dim_batch (
  batch_sk        UUID PRIMARY KEY,
  batch_label     VARCHAR,
  actor_sk        INTEGER,
  opened_ts       TIMESTAMP
);

CREATE TABLE f_judge_vote (
  suggestion_sk UUID NOT NULL,
  detect_run_id UUID NOT NULL,
  judge_id      INTEGER NOT NULL,
  verdict       VARCHAR NOT NULL,
  score         INTEGER,
  reason        VARCHAR,
  PRIMARY KEY (suggestion_sk, detect_run_id, judge_id)
);

CREATE TABLE f_export_event (
  export_sk     UUID PRIMARY KEY,
  document_sk   UUID NOT NULL,
  case_sk       BIGINT NOT NULL,
  actor_sk      INTEGER,
  path          VARCHAR NOT NULL,
  content_sha256 VARCHAR,
  box_count     INTEGER,
  decision_batch_hash VARCHAR,
  exported_at   TIMESTAMP NOT NULL
);

CREATE TABLE f_document_version (
  document_sk UUID NOT NULL,
  stage       VARCHAR NOT NULL,           -- source|working|export
  gen         INTEGER NOT NULL,
  path        VARCHAR NOT NULL,
  sha256      VARCHAR,
  actor_sk    INTEGER,
  created_ts  TIMESTAMP,
  PRIMARY KEY (document_sk, stage, gen)
);

-- ═══ PROJECTIONS (views — not second stores) ═══════════════════════════════

CREATE VIEW v_latest_decision AS
SELECT suggestion_sk,
       arg_max(status_sk, event_ts) AS status_sk,
       arg_max(actor_sk, event_ts)  AS actor_sk,
       arg_max(reason_text, event_ts) AS reason_text,
       max(event_ts) AS ts
FROM f_decision_event
GROUP BY suggestion_sk;

CREATE VIEW v_suggestions AS
SELECT s.*,
       k.label AS kind,
       e.canonical_text AS entity_text,
       coalesce(st.status_code,
         CASE s.origin WHEN 'manual' THEN 'accepted' ELSE 'pending' END) AS status,
       CASE WHEN s.confidence >= 90 THEN 'high'
            WHEN s.confidence >= 60 THEN 'review' ELSE 'flagged' END AS band
FROM dim_suggestion s
LEFT JOIN dim_entity e ON e.entity_sk = s.entity_sk
LEFT JOIN dim_pii_kind k ON k.kind_sk = s.kind_sk
LEFT JOIN v_latest_decision ld ON ld.suggestion_sk = s.suggestion_sk
LEFT JOIN dim_status st ON st.status_sk = ld.status_sk;

-- Marts (explicit)
CREATE VIEW mart_doc_review_status AS
SELECT document_sk,
       count(*) AS suggestion_count,
       count(*) FILTER (WHERE status = 'pending') AS pending_count
       -- … only here, not on dim_document
FROM v_suggestions
GROUP BY 1;

CREATE VIEW v_bbox_redact AS
SELECT s.suggestion_sk,
       s.document_sk,
       struct_pack(
         page := s.bbox.page,
         x := s.bbox.x0,
         y := p.height_pt - s.bbox.y1,
         w := s.bbox.x1 - s.bbox.x0,
         h := s.bbox.y1 - s.bbox.y0
       ) AS redact_box
FROM dim_suggestion s
JOIN dim_page p ON p.document_sk = s.document_sk AND p.page_no = s.bbox.page
JOIN v_suggestions v ON v.suggestion_sk = s.suggestion_sk AND v.status = 'accepted';
```

Filesystem option that is still not shit: keep `f_decision_event` as JSON **with a frozen typed schema and stable suggestion_sk**, and treat CTAS tables as **caches**, not identity authorities.

---

## 6. What to stop doing immediately

1. **`uuid()` for any key that is written to `exports/decisions/` or referenced after process death.** **[Mk]** This is how you delete the changelog’s foreign keys.
2. **Baking `progress_pct`, badge CSS classes, and COUNT FILTER funnels into base relations** — those are marts.
3. **Free-text `kind` as join/dispatch logic** — codes in facts, labels at edge.
4. **`cast(x AS VARCHAR) = cast(y AS VARCHAR)` as the integration strategy** — pick UUID or VARCHAR and declare FKs. **[Mk]** Encoding chaos is a reliability bug.
5. **Dual geometry systems without a single conversion view** — one place flips Y, everyone else calls it.
6. **`read_json_auto` + `ignore_errors` as the audit substrate without a schema map** — audit that drops bad files is not audit. **[Mk]**
7. **Parallel residual/judge/custody universes that do not share suggestion_sk / document_sk.**
8. **Treating SCHEMA_CONTRACT route shapes as a substitute for a data model** — freeze the bus, version the API; add **`schema_version` on events**.
9. **Hash modulo integer as primary key** for groups.
10. **Calling a boot CTAS rebuild “the warehouse”** — it is a cache; the log + content hashes are the warehouse. **[Mk]** Do not re-mint identities inside a “cache refresh.”
11. **Silent LIMIT on audit strips inside “model” views** (`v_case_page` audit LIMIT 12) as if that were the trail.
12. **Embedding executable SQL sentences in tables as if they were data** without also recording the resulting export event.
13. **POST without idempotency keys** on decision/add/undo — retries must not fork the legal record. **[Mk]**
14. **Hardcoded write path vs env-bound read path** for the decision directory — one binding rule. **[Mk]**
15. **Calling a JSON file bag a “log”** without order, types, or corrupt-shard quarantine. **[Mk]**

---

## 7. What is actually good

- **Append-only decisions with status as projection** (`v_latest_decision` / `v_suggestions`) — correct event-sourcing instinct for legal review. Keep this religion.
- **Undo as inverse events** (`undoes_batch_id`, `v_prior_states`) — right pattern; batch as unit of work matches clerk mental model.
- **Single decision reader** (`v_src_decisions`) declared as the one glob consumer — good composition rule (even if the payload schema is a mess).
- **AI proposals do not write status** — detectors feed suggestions; humans (or explicit triage POST) append decisions. Separation of detection fact vs judgment fact is sound.
- **Export fail-closed on flagged-pending** (`v_export_plans` gate) — business rule in the right place (plan construction), not a silent filter on the base suggestion grain.
- **OCR `source` discriminator on words** (`pdf_io.sql` rebuild) — correct dual-path modeling at the token grain (once word identity exists).
- **No macro forest for config** — `app_config` as a relation is cleaner than cfg_* macro theater.
- **Natural case_no and filename** exist and are used for ingest join — the durable keys are sitting there; you just refused to use them as surrogates.
- **Working-copy registry with (document_id, gen)** (`pdf_store_events`) — nearest-to-correct lifecycle fact table in the repo.

Fairness stops there. The rest is a demo that grew route views until it looked like a model.

### 7b. Kleppmann: what is actually good

Credit where the dataflow instinct is real — not marketing:

- **Status is a fold, not a cell.** `arg_max(status, ts)` over an append-only decision stream is the correct stream→table projection for clerk judgment. Do not regress to `UPDATE suggestions SET status=…`.
- **One declared log reader** (`v_src_decisions`) — every history/audit/latest path composes it. That is the right unbundling of *read path*, even if the physical log is a file bag.
- **Compensating transactions as append** (undo/restore write inverse events with `undoes_batch_id`) — not tombstone deletes, not in-place mutation. Matches “events are facts about the past.”
- **Detection vs judgment split** — AI/batch detect does not stamp status; humans append. That is CQRS-adjacent discipline without the framework cosplay.
- **Views as always-rebuildable serving layer** for pure log folds (`v_latest_decision`, `v_history_events`) — when keys are stable, you can trash the process and re-fold. That *is* the point of derived data. (Today only manual-add half of the world is stable enough to prove it.)
- **Fail-closed export gate on business state** — derived plan depends on projection; good place for policy (once projection keys work).

What is *not* good under this lens is everything that pretends the CTAS boot is the log, or that `ignore_errors` is durability. Keep the religion; rebuild the church.

---

## Appendix A — Evidence anchors (file references)

| Claim | Where |
|-------|--------|
| Boot = CTAS replace, clean re-run | `server/app.sql:15–16` |
| Module order raw→ingest→pdf_io→detect→… | `server/app.sql:116–125` |
| Decision sentinel INTEGER-typed legacy columns | `server/app.sql:86–110` |
| cases id = case_no | `server/ingest.sql:8–16` |
| documents uuid() | `server/ingest.sql:20–22` |
| words no PK / no seq | `server/ingest.sql:52–61` |
| entities empty shell then detect replace | `server/ingest.sql:76–81`, `detect.sql:117–124` |
| suggestions uuid() + fuzzy entity join | `server/detect.sql:126–133` |
| v_latest_decision cast soup | `server/detect.sql:138–153` |
| v_suggestions UNION manual + band | `server/detect.sql:183–205` |
| words OCR union + source | `server/pdf_io.sql:69–74` |
| scan status COUNT FILTER | `server/pdf_io.sql:80–156` |
| judge kind string dispatch | `server/judge.sql:69–79` |
| residual separate fact + page column | `server/remainder_scan.sql:301–308` |
| decision COPY writers | `server/routes/decisions.sql` |
| export Y-flip STRUCT | `server/routes/export.sql:17–32` |
| history batch mart | `server/routes/history.sql:43–65` |
| v_doc_ui metric pile | `server/routes/pages.sql:9–62` |
| v_audit queryable | `server/routes/pages.sql:68–79` |
| provenance seal over full log | `server/provenance.sql:88–97` |
| working path regex extract of document_id | `server/pdf_store.sql:76–78`, `provenance.sql:67–74` |
| Contract freezes kind strings + decision file columns | `docs/SCHEMA_CONTRACT.md` |
| Live log: 759 decisions / 4 added; entity_id JSON typed | `exports/decisions/*.json` probe 2026-07-20 |

## Appendix B — Live DB note

`closure.db` existed but was lock-held by a running duckdb process; this assault did not DESCRIBE the live catalog. **Authoritative for structure is the CTAS SQL boot path**, not a locked binary. Decision-log grain was verified via `read_json_auto` on `exports/decisions/`.

## Appendix C — Stream-table duality map (event log → projections)

What *should* be true if Closure were a real dataflow system. “Rebuildable?” means: wipe the projection, replay/fold the stream, get the same keys and state.

| Stream (changelog / source) | Fold / materialization | Serving table/view today | Rebuildable from stream alone? | Breakage |
|-----------------------------|------------------------|---------------------------|--------------------------------|----------|
| `exports/decisions/*.json` kind=`decision` | `arg_max(status, ts)` by suggestion_id | `v_latest_decision` | **Yes** (fold is pure) | Joins die when suggestion_id not in current CTAS |
| kind=`added` | `arg_max(payload, ts)` by suggestion_id | `v_manual_suggestions` | **Yes** | OK if document_id still resolves |
| kind=`decision`+`added` + batch cols | group by batch_id; lag prior status | `v_history_events` → `v_prior_states` → `v_decision_batches` | **Yes** for history shape | Undo/restore append more stream |
| *(no stream — batch detect)* | CTAS `uuid()` per hit | `suggestions` | **No** | Re-mint destroys log FKs |
| *(no stream — batch detect)* | CTAS `uuid()` per entity | `entities` | **No** | Same |
| PDF bytes / manifest | CTAS `uuid()` per file | `documents` | **No** (should be content-hash / filename NK) | Natural key exists; unused as PK |
| words extract + OCR | full replace CTAS | `words` | From PDFs, not from decisions | No word_sk; order bag |
| detect run (implicit) | boot snapshot | `judge_votes` | From suggestions+rules only | Dies with suggestion ids |
| remainder scan (implicit) | boot CTAS | `residual_pii_hits` | From words+rules | Parallel stream; not in v_suggestions |
| accepted subset of `v_suggestions` | request-time STRUCT + pdf_redact | `exports/*_redacted.pdf` | **No** event of export | File without export_event |
| decision stream hash | live seal | `v_case_provenance.decision_chain_seal` | From parseable files only | `ignore_errors` omits shards from seal |
| `v_suggestions` (id,status) | sha256 aggregate | `decision_batch` on working plans | Ephemeral fingerprint | Not a log offset |

**Duality repair order (Mk):**

1. Persist **suggestion registry** (stable sk) + **document sk** from natural keys.  
2. Make detect an **upsert producer** into the registry (new `detect_run_id`), not a PK lottery.  
3. Typed decision stream with **seq + schema_version + request_id**.  
4. All status/history/export fingerprints fold **only** from stream + registry.  
5. Batch marts (triage counts, judge, residual) labeled derived; may lag; never re-key the registry.

```
                    ┌─────────────────────────────┐
  PDF / watchlist ──►│ batch detect (run_id)       │──upsert──► dim_suggestion (stable)
                    └─────────────────────────────┘                │
                                                                   │
  POST decision/add ──append──► f_decision_event (log, seq)        │
                                      │                            │
                                      ▼                            ▼
                               v_latest_decision ─────────► v_suggestions (serving)
                                      │
                                      ├──► v_history / undo folds
                                      └──► export_event + pdf artifact
```

---

*End of assault. Fix keys, log mechanics, and event grain first — or stop calling this a data model (and stop calling a JSON folder a log).*
