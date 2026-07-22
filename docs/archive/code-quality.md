# Closure — Code Quality & Repo Structure Spec

**Status:** integration / refactor plan (apply later; do not implement in this pass)  
**Audience:** you (submission polish) + any agent applying this  
**Write constraint for this investigation:** only this file was written; `server/` was not touched  
**Date:** 2026-07-19  

This document is the **integration/refactor spec** for code quality and professional repo structure before private-company submission. The take-home grades **code quality and organization** explicitly. Closure already has a strong product thesis (DuckDB + quackapi + real PDF words); the gap is **boundaries, tree layout, and PDF I/O hygiene** — not more features.

---

## 0. Executive summary

| Area | Today | Target (professional) |
|------|--------|------------------------|
| PDF files | Flat `samples/` + `exports/` + `pages/` mixed with fixtures, stress, decisions, redacted outs | Explicit **INPUT / WORKING / OUTPUT** storage layer + one SQL “service” module that owns all PDF I/O |
| Server SQL | Mostly flat `server/*.sql`; **809-line** `routes.sql` monolith; dual boot (`run.sh` vs `app.sql`) | Split by concern: schema / ingest / detection / pdf / routes-by-resource / render / boot |
| Config | Hardcoded machine paths (`/Users/aloksubbarao/personal/quackapi/...`), port `8117`, `samples/` string literals | Env-driven config macros; no absolute home paths in repo SQL |
| Tests | Playwright e2e + stress SQL; no route smoke SQL suite | SQL smoke (ingest/seed/routes/export guards) + Playwright e2e (keep) |
| Dead / drift | README claims `render_static.sql`, `mutate.sh`, `export_case.sh` (missing); `schema.sql` unused by `app.sql`; `judge.sql` / `remainder_scan.sql` not boot-loaded | One boot path, docs match tree, optional modules wired or archived under `server/experimental/` |

**Borrow from Vori (patterns, not NestJS itself):**

| Vori pattern | Where | Closure analogue |
|--------------|--------|------------------|
| `services/` + `shared/` | `Vori/backend` | Runtime surface (`server/routes/`, `server/boot.sql`) vs pure libraries (`server/pdf/`, `server/schema/`, `server/detection/`) |
| Controllers **by resource** | `services/graphql-api/src/controllers/{store,vendor,...}` | `server/routes/{cases,documents,suggestions,export}.sql` |
| Domain modules + service layer | `shared/nest/libs/*` (`*.service.ts` owns logic; controller is thin) | SQL **macros** = service methods; **routes** = thin `SELECT * FROM macro(...)` |
| Isolated PDF helper | `shared/pdf.ts` (single ownership of PDF bytes) | `server/pdf/*.sql` — sole call sites for `pdf_info` / `read_pdf_words` / `pdf_redact` / `pdf_to_png` |
| Routes by domain path | `composer/src/routes/_auth/retail/...` | HTTP paths already resource-shaped; **files** should match |
| `docs/standards/` + README entry | `composer/docs/standards/code-standards.md` | This file + slim README “Layout” that matches reality |
| `scripts/` for ops | `backend/scripts/`, `composer/scripts/` | `scripts/boot.sh`, `scripts/smoke.sql`, not mixed into `server/` domain SQL |
| Playwright layout | `composer/src/playwright/{fixtures,helpers,specs}` | Keep `tests/e2e/` but mirror helpers/fixtures discipline; drop absolute path hardcodes in e2e README |
| Config not secrets-in-tree | env + `configs/` | `config/paths.sql` + env vars in boot shell |

---

## 1. Proper PDF handling (key)

### 1.1 How a real FastAPI / Fastify app would do it

In a typical Node/Python app you would **never** treat the repo tree as a bag of PDFs. You would have:

1. **Object storage abstraction** (local dir, S3, etc.) with three **lifecycle stages**.
2. **A storage service** that is the only code allowed to open/read/write PDF bytes.
3. **DB rows that hold paths/keys**, never raw multi-MB BLOBs for working state.
4. **Guards before open** (size, content-type, encryption, virus scan).
5. **Streaming / page-scoped work** for UI; **batch jobs** for full-document export on large files.
6. **Immutable inputs** vs **regenerable derivatives** vs **user-visible exports**.

Closure can (and should) keep DuckDB + the community `pdf` extension — but must **fake that same architecture in SQL + directories**.

### 1.2 Lifecycle stages

| Stage | Meaning | Mutability | Git | Who writes |
|-------|---------|------------|-----|------------|
| **INPUT** | Source PDFs for a case (evidence as received) | Immutable after ingest registration | Fixtures only under `samples/`; runtime under `storage/input/` (gitignored) | Ingest / bootstrap copy |
| **WORKING** | Derived state: word tables (in DB), page PNGs, decision JSON events, DuckDB spill, export-plan SQL temps | Regenerable | **gitignored** | Ingest, routes (decisions), optional page raster jobs |
| **OUTPUT** | Redacted PDFs + audit package for release | Append-only per export run | gitignored | Export service only |

Mental model (matches a FastAPI `StorageService`):

```
POST /cases/:id/documents  →  save bytes to INPUT
  → job: extract words → DB (WORKING metadata)
  → optional: raster page N → WORKING/pages/...
POST /cases/:id/export     →  read INPUT + accepted boxes → write OUTPUT
```

### 1.3 Concrete directory layout

```
closure/
  samples/                          # FIXTURES only (checked in, small/medium)
    identities.json
    manifest.json
    *.pdf                           # demo corpus (canonical cases)
    gen/                            # sample generators (not runtime)
    stress/                         # stress fixtures + harness outputs (isolated)

  storage/                          # RUNTIME (gitignored entire tree except .gitkeep)
    input/
      cases/
        {case_no}/
          {stem}.pdf                # immutable copies or hardlinks of fixtures
    working/
      pages/
        {stem}/
          p{n}.png                  # page previews (today: repo-root pages/)
      decisions/
        _sentinel.json
        dec_{uuid}.json             # append-only decision events (today: exports/decisions/)
      spill/                        # DuckDB temp_directory
      export_plan/                  # optional: per-case built SQL strings for audit
    output/
      cases/
        {case_no}/
          {stem}_redacted.pdf
          export_manifest.json      # paths + box counts + actor + ts
      audit/
        package_{case_no}_{ts}/     # optional bundle: pdfs + decision snapshot

  pages/                            # DEPRECATED → move to storage/working/pages
  exports/                          # DEPRECATED → split to working/decisions + output/
```

**Bootstrap rule (boot script, not ad-hoc SQL literals):**

1. Ensure `storage/{input,working,output}/...` exist.
2. For demo: hardlink or copy `samples/*.pdf` → `storage/input/cases/{case_no}/` using `manifest.json` (case_no + filename).
3. Set path roots once via config macros (see §1.5).
4. Never glob `samples/stress/*.pdf` into the serve process (stress stays offline).

**Why not keep writing into `samples/` and `exports/`?**  
Graders (and future you) will see fixture PDFs co-mingled with redacted outs, decision logs, and 700 MB stress monsters (`samples/` is currently ~954 MB). That reads as “prototype dump,” not “product with a storage layer.”

### 1.4 How the app references PDFs

| Concern | Column / field | Rule |
|---------|----------------|------|
| Source file | `documents.source_path` | Always **INPUT** path, e.g. `storage/input/cases/2024-0117/incident_report_2024-0117.pdf` |
| Display stem | `documents.filename` | Stem only (no directory, no `.pdf` if you prefer consistency — pick one convention and stick to it) |
| Page image URL | static URL | `/storage/working/pages/{stem}/p{n}.png` (or keep `/pages/...` via static_dir mapping) |
| Redacted out | derived | `storage/output/cases/{case_no}/{stem}_redacted.pdf` — **never** computed only as string concat in three files |
| Decisions | event files | `storage/working/decisions/*.json` — not next to redacted PDFs |

**DB is source of truth for paths.** Routes and export macros must read `documents.source_path` / a path macro — not re-hardcode `'samples/' || filename`.

Today’s failures against this rule:

| File | Issue |
|------|--------|
| `server/ingest.sql` | `source_path := 'samples/' \|\| m.filename`; triple glob `samples/*.pdf` |
| `server/routes.sql` | `build_export_sql` → `'exports/' \|\| d.filename \|\| '_redacted.pdf'` |
| `server/app.sql` | Same export path literals; absolute `LOAD '/Users/aloksubbarao/...'` |
| `server/_export_macros.sql` | Generated + committed sample-specific `pdf_redact('samples/...')` strings |
| `run.sh` | `DATA_DIR=samples`, identity-copy into `exports/` |

### 1.5 The PDF “service” boundary (even in SQL)

Isolate **all** extension PDF calls behind macros in `server/pdf/`. No other file may call `pdf_info`, `read_pdf`, `read_pdf_words`, `pdf_redact`, `pdf_to_png`, `pdf_encrypt`, etc.

```
server/pdf/
  paths.sql          -- path macros only (INPUT/WORKING/OUTPUT roots)
  guards.sql         -- size / encryption / openability checks
  extract.sql        -- words + page dims CTAS helpers
  geometry.sql       -- sole word-box → pdf_redact (page,x,y,w,h) conversion
  redact.sql         -- sole pdf_redact invocation builders
  raster.sql         -- optional page PNG generation
  README.md          -- contract: who may call what
```

#### Suggested macro contract

```sql
-- paths.sql (config, not business logic)
CREATE OR REPLACE MACRO cfg_input_root() AS 'storage/input';
CREATE OR REPLACE MACRO cfg_working_root() AS 'storage/working';
CREATE OR REPLACE MACRO cfg_output_root() AS 'storage/output';
CREATE OR REPLACE MACRO cfg_max_open_bytes() AS 200*1024*1024;  -- demo host ceiling

CREATE OR REPLACE MACRO path_input(case_no, stem) AS
  cfg_input_root() || '/cases/' || case_no || '/' || stem || '.pdf';
CREATE OR REPLACE MACRO path_output(case_no, stem) AS
  cfg_output_root() || '/cases/' || case_no || '/' || stem || '_redacted.pdf';
CREATE OR REPLACE MACRO path_page_png(stem, page_no) AS
  cfg_working_root() || '/pages/' || stem || '/p' || page_no || '.png';

-- guards.sql
-- Returns one row per path: ok, reason, file_size, is_encrypted, page_count
CREATE OR REPLACE MACRO pdf_guard(path) AS TABLE
SELECT ... FROM pdf_info(path)  -- wrap; never call pdf_info outside this file
WHERE ...;

-- geometry.sql  (ONLY place that flips y for pdf_redact)
CREATE OR REPLACE MACRO redact_box(page_no, x0, y0, x1, y1, height_pt) AS
  struct_pack(
    page := page_no,
    x := x0,
    y := height_pt - y1,   -- schema already documents this; keep it HERE only
    w := x1 - x0,
    h := y1 - y0
  );

-- extract.sql
-- Prefer page-range extraction for large files; full glob only after guards.
CREATE OR REPLACE MACRO pdf_words_for_file(path) AS TABLE
SELECT * FROM read_pdf_words(path);

-- redact.sql
-- Build foldable literal SQL for quackapi constraints; still OWNED here.
CREATE OR REPLACE MACRO pdf_redact_sql(in_path, out_path, boxes_lit) AS
  'SELECT count(*)::INTEGER AS pages FROM pdf_redact(''' || in_path || ''', ''' ||
  out_path || ''', ' || boxes_lit || ')';
```

**Ingest** becomes:

```sql
-- server/ingest/documents.sql
-- 1) enumerate fixtures or storage/input via manifest
-- 2) pdf_guard each file (isolated loop / per-file CTAS — see stress doc F4/F5)
-- 3) CTAS words via pdf_words_for_file — NOT raw read_pdf_words('samples/*.pdf')
```

**Export** becomes:

```sql
-- server/routes/export.sql  (thin)
SELECT * FROM export_case_live($id::INTEGER, 'reviewer');
-- where export_case_live lives in server/pdf/redact.sql or server/services/export.sql
-- and is the only path that materializes pdf_redact(...)
```

This mirrors Vori’s rule: **controllers/routes stay thin; services own side effects** (`shared/nest/libs` README: Controllers = HTTP; Services = business logic + data access).

### 1.6 Messy / large PDFs — streaming, guards, isolation

Evidence already in-repo (`docs/pdf-stress.md`, `docs/backend-oom-and-fastapi.md`):

| Risk | Fact | Required product rule |
|------|------|------------------------|
| Process RSS ≈ file size | Opening ~709 MB PDF → ~791 MB RSS; `memory_limit` does **not** cap Poppler | **Hard refuse** interactive open/redact when `file_size > cfg_max_open_bytes()` |
| Full-doc `list(struct)` | OOM under quackapi 256 MB serve default | UI routes **page-scoped only** (already good in `render_document` words/marks; keep the hard cap) |
| Glob abort | One encrypted/truncated member kills `samples/*.pdf` | Per-file guard; quarantine bad files; never blind-glob stress into serve |
| Image-only pages | 0 words, silent | Surface `word_count=0` + “no text layer” in UI; OCR is future, not silent success |
| Forms / annotations | PII not in word layer | Document as known limit in README; optional later pass |
| Export of huge files | Same open cost as ingest | Export = batch path; block when size > guard; never in request if RSS would thrash demo host |
| Serve memory | quackapi forces 256 MB then app re-raises | Keep post-serve `SET memory_limit` in **one** boot file; document why |

**Streaming rules (non-negotiable for submission honesty):**

1. **UI:** `WHERE page_no = ?` for words and suggestion overlays; queue capped (today ≤80 — keep).
2. **Ingest:** Prefer per-file CTAS; for multi-thousand-page files, page-range chunks into `words` if needed.
3. **Never** pack all document words into tera context.
4. **Page PNGs:** pre-render offline or on first view into WORKING; serve as static files (not base64 in HTML).
5. **Stress corpus** never shares a glob with demo ingest.

### 1.7 Migration path from current layout (apply later)

| Current | Move to |
|---------|---------|
| `samples/*.pdf` (demo) | stay as fixtures; boot **copies/links** → `storage/input/cases/...` |
| `samples/stress/**` | stay; document “offline only” |
| `pages/{stem}/pN.png` | `storage/working/pages/{stem}/pN.png` |
| `exports/*_redacted.pdf` | `storage/output/cases/{case_no}/...` |
| `exports/decisions/*` | `storage/working/decisions/*` |
| `exports/export_map.csv` | generate under `storage/working/` or drop (derive from `documents`) |
| `exports/audit_sidecar.jsonl` | fold into decisions or `storage/working/audit/` — one event stream |
| `server/_export_macros.sql` | generate into `storage/working/export_plan/` (gitignored); never commit |

Update `.gitignore` to ignore all of `storage/` (keep `.gitkeep` files).

---

## 2. Professional repo structure

### 2.1 What’s wrong today (concrete)

```
server/
  app.sql              # boot + export macro codegen + serve (183 LOC) — good intent, mixed concerns
  routes.sql           # 809 LOC: render + export builders + HTML + JSON GET + POST  ← monolith
  schema.sql           # CREATE TABLE IF NOT EXISTS model — NOT read by app.sql
  ingest.sql           # DROP+CTAS real load; redefines qnorm, v_grams; also writes export_map
  seed.sql             # detection suggestions + v_decision_log
  judge.sql            # not boot-loaded
  remainder_scan.sql   # not boot-loaded
  load_templates.sql
  stress.sql           # duplicate of tests/stress concept
  _export_macros.sql   # generated artifact checked in
  templates/
run.sh                 # alternate boot (no seed); SET VARIABLE; missing scripts README claims
```

**Dual boot (P0 structural smell):**

| Path | Seed? | Serve memory fix? | Notes |
|------|-------|-------------------|--------|
| `server/app.sql` | yes | post-serve SET 4GB | Absolute quackapi path; e2e README uses this |
| `run.sh` | no (suggestions empty) | pre-serve only (serve clobbers) | Still references missing `render_static.sql` / `export_case.sh` |

**Duplication:** `qnorm`, `v_grams` in both `schema.sql` and `ingest.sql`.  
**Dead schema path:** `app.sql` never `.read server/schema.sql` — CTAS in ingest is the real model.  
**README drift:** claims `mutate.sh`, `export_case.sh`, `render_static.sql` — files absent.  
**Hardcoded machine path:** `app.sql` line 12 `LOAD '/Users/aloksubbarao/personal/quackapi/...'`.  
**Debug residue:** `render_document` `proof` CTE hardcodes sample surnames (`Yasmine`, `Nienow`, …) — submission red flag.

### 2.2 Target tree

Modeled on Vori’s separation (`services` vs `shared`, controllers by resource, `scripts/`, `docs/`, tests with helpers) scaled to a single-process SQL app:

```
closure/
  README.md                         # entry: stack, boot, layout (matches tree)
  AGENTS.md                         # optional: agent rules (one boot path, no absolute paths)
  .gitignore
  config/
    env.example                     # PORT, DUCKDB_BIN, QUACKAPI_EXT, CLOSURE_ROOT, MEMORY_LIMIT
    paths.sql                       # cfg_* macros (INPUT/WORKING/OUTPUT); loaded first
  scripts/
    boot.sh                         # THE only human/agent entry (replaces dual run.sh/app.sql drift)
    smoke.sh                        # curl + SQL smoke after boot
    link_fixtures.sh                # samples → storage/input
    render_pages.sh                 # optional offline PNG raster
  server/
    boot.sql                        # INSTALL/LOAD, memory, .read chain, serve, post-serve SET
    schema/
      00_sequences.sql
      01_tables.sql                 # logical model (documentation + IF NOT EXISTS for tools)
      02_views.sql                  # v_suggestions, v_document_stats, v_entity_hits, v_audit
      03_macros_shared.sql          # qnorm only (once)
    ingest/
      00_teardown.sql               # DROP order (if CTAS boot)
      01_cases.sql
      02_documents.sql              # uses server/pdf only
      03_pages_words.sql
      04_entities.sql
      05_audit_ingest.sql
    detection/                      # "AI" layer (pure CTAS; no HTTP)
      seed.sql                      # suggestions from identities + words
      judge.sql                     # optional; load if product uses panel signal
      remainder_scan.sql            # optional FN catcher
    pdf/                            # ★ storage + PDF I/O service (§1.5)
      paths.sql                     # re-export or include config/paths.sql
      guards.sql
      extract.sql
      geometry.sql
      redact.sql
      raster.sql
    render/                         # tera macros only (no CREATE ROUTE)
      home.sql
      case.sql
      document.sql                  # page-scoped
      audit.sql
      shells.sql                    # reject / add-missed / bulk static shells
    routes/                         # thin CREATE ROUTE by resource (Vori controllers)
      _register.sql                 # .read order
      cases.sql                     # HTML + JSON for /cases/:id...
      documents.sql                 # /documents/:id...
      suggestions.sql               # decisions, band, add
      entities.sql                  # bulk entity decision
      export.sql                    # export_plan, export, export/run
      meta.sql                      # /api/stats, search
    templates/                      # tera HTML (unchanged content initially)
    load_templates.sql
  static/                           # browser JS only (not generated HTML dumps)
    js/
      review.js
      dashboard.js
      ...
    css/                            # if extracted from templates later
  design/                           # hi-fi mockups (submission Part 1) — leave alone
  samples/                          # fixtures only (§1.3)
  storage/                          # runtime gitignored
  tests/
    sql/
      smoke_ingest.sql
      smoke_seed.sql
      smoke_routes.sql              # SELECT from macros with typed asserts
      smoke_pdf_guards.sql
      README.md
    e2e/                            # existing Playwright (keep)
      helpers/
      specs/
      playwright.config.ts
      package.json
    stress/                         # existing offline harness (keep)
  docs/
    code-quality.md                 # this file
    rationale.md
    pdf-stress.md
    ...
```

### 2.3 How to split the monoliths

#### `routes.sql` (809 lines) → resource files

| Block today (approx lines) | Target file | Vori analogue |
|----------------------------|-------------|---------------|
| `render_*` macros | `server/render/*.sql` | `lib/` / service, not controller |
| `boxes_lit_for_doc`, `build_export_sql`, `export_case_exec` | `server/pdf/redact.sql` + `server/routes/export.sql` | `*Service` + thin controller |
| HTML `CREATE ROUTE` home/case/document/ui | `server/routes/cases.sql`, `documents.sql` | `controllers/store` |
| JSON GET documents/cases/search/stats | same resource files | REST controllers by domain |
| POST decision/add | `server/routes/suggestions.sql`, `entities.sql` | mutation endpoints on resource |
| Export routes (in routes + app) | **one** `server/routes/export.sql` | don’t split export across two files |

**Rule:** each `CREATE ROUTE` body should be ≤ ~15 lines: validate params lightly, `SELECT * FROM some_macro(...)`.

#### `ingest.sql` (220 lines)

Split by entity CTAS; shared teardown once. PDF open only via `server/pdf/extract.sql`.

#### `app.sql` / `run.sh`

Collapse to:

1. `scripts/boot.sh` — resolves `DUCKDB_BIN`, `QUACKAPI_EXT`, `PORT`, creates `storage/`, links fixtures, invokes duckdb.
2. `server/boot.sql` — single SQL entry: load extensions → `.read config/paths.sql` → schema/views → ingest → detection → templates → render → routes → optional export plan gen → `quackapi_serve` → post-serve memory raise.

#### `schema.sql` vs CTAS

Pick **one** model for submission (recommend **CTAS boot** for demo purity + “re-run is clean”):

- Keep `schema/` as the **documented** logical model and view definitions applied **after** CTAS tables exist, **or**
- Use schema DDL then `INSERT...SELECT` — but team convention in this repo is **no INSERT-for-setup**; stick to CTAS and treat `schema/01_tables.sql` as comments + empty-table docs if needed.

Do **not** leave two competing definitions.

### 2.4 Config

```bash
# config/env.example
PORT=8117
MEMORY_LIMIT=4GB
THREADS=4
DUCKDB_BIN=          # required; no default to a personal home path
QUACKAPI_EXT=        # required
CLOSURE_DATA=storage
CLOSURE_FIXTURES=samples
```

`scripts/boot.sh` exports these; SQL paths come only from `config/paths.sql` (string roots), not from `SET VARIABLE` if that fights team SQL style — prefer **macros** over variables for foldable constants.

### 2.5 Static / templates / design

| Dir | Role |
|-----|------|
| `server/templates/` | Server-rendered tera (source of truth for HTML structure) |
| `static/js/` | Client behavior (today’s `static/*.js`) |
| `design/` | Part 1 mockups; not served in production path (or served read-only under `/design` if demo) |
| Generated HTML dumps | If needed for offline demos, write under `storage/working/static_html/` — not committed |

### 2.6 Tests layout (professional)

| Suite | Location | What it proves |
|-------|----------|----------------|
| SQL smoke | `tests/sql/*.sql` | Ingest counts, seed non-empty, page-scoped render returns html, export guard blocks flagged, pdf_guard rejects oversized/encrypted fixtures |
| Playwright e2e | `tests/e2e/specs/` | Real UX flows (already good coverage list 01–07) |
| Stress | `tests/stress/` | Offline scale/failure modes; never part of default CI smoke |

Borrow from composer: **helpers** (`api.ts`, `ui.ts`) stay thin; specs name the user journey; fixtures isolated. Fix e2e README absolute paths to use env.

---

## 3. Code-quality checklist

Use this as a pre-submission gate. Items map to Vori `docs/standards/code-standards.md` spirit (DRY, clear ownership, no dead code, typed boundaries) adapted to SQL-first Closure.

### 3.1 Naming

- [ ] Tables: plural nouns (`cases`, `documents`, `words`, `suggestions`, `audit_events`).
- [ ] Views: `v_*` projection only (`v_suggestions`, `v_audit`).
- [ ] Staging CTAS: `_seed_*` / `_tmp_*` prefix; drop or leave clearly ephemeral.
- [ ] Macros: verb_noun (`render_document`, `pdf_guard`, `export_case_live`) — not `run_sql` as a public API without a safer wrapper.
- [ ] Routes: `resource_action` names matching path (`api_case_export`, `document_page`).
- [ ] Files: match resource/domain (`routes/export.sql` not `routes2.sql`).
- [ ] Paths: `stem` vs `filename` vs `source_path` — one glossary in README.

### 3.2 Comments

- [ ] File header: purpose, dependencies, what must not call this file.
- [ ] Comment **why** (coord system, quackapi literal-SQL constraint, serve memory re-SET) not **what** the next line does.
- [ ] Remove stale “this pass / deferred / no shellfs” comments that contradict boot.
- [ ] No commented-out dead blocks.

### 3.3 No dead code / no drift

- [ ] One boot path documented and used by e2e.
- [ ] README file list matches `ls`.
- [ ] Remove or relocate unused: `schema.sql` if truly unused; wire or archive `judge.sql`, `remainder_scan.sql`.
- [ ] Delete committed generated `_export_macros.sql` or gitignore it.
- [ ] Remove debug `proof` CTE name hardcodes in `render_document`.
- [ ] `stress.sql` under `server/` vs `tests/stress/` — keep one home.

### 3.4 No hardcoded specifics

- [ ] No `/Users/aloksubbarao/...` in any tracked file.
- [ ] No magic case ids in route home (`render_case(1)` as `/` is OK for demo **if** documented; prefer list home).
- [ ] No PII/sample surnames in SQL for “proof” overlays.
- [ ] Port, memory, roots from config.
- [ ] Export CASE WHEN 1..4 → data-driven map (macro table or dynamic plan only).

### 3.5 Consistent SQL style

Aligned with existing good intent in `ingest.sql` / `app.sql` headers:

| Rule | Do | Don’t |
|------|-----|--------|
| Setup | `CREATE OR REPLACE TABLE … AS SELECT` | `INSERT INTO` for boot seed |
| Config in SQL | path **macros** | `SET VARIABLE` for business paths (run.sh still does this) |
| Literals | `read_json_auto` / fixtures | hand-typed `VALUES (...)` of PII |
| Idempotent boot | DROP/CTAS or full replace | half-updated tables |
| Types | explicit `::INTEGER`, `::DOUBLE`, `struct_pack` | untyped JSON soup in routes |
| Geometry | one conversion site (`server/pdf/geometry.sql`) | y-flip copy-pasted in app + routes |
| Dynamic SQL | isolated in `pdf/redact.sql` + documented quackapi constraint | string-build `pdf_redact` in three files |

### 3.6 Typed outputs

- [ ] JSON routes return stable column sets (document in a short OpenAPI-ish table in README).
- [ ] HTML routes return single column `html VARCHAR`.
- [ ] Export returns `{exported, blocked, flagged_remaining}` only — not ad-hoc extras without versioning.
- [ ] Decision COPY rows share one schema (kind, suggestion_id, status, actor, reason, ts, document_id, case_id, text, …).

### 3.7 Error handling in routes

quackapi constraints limit try/catch; still professionalize:

- [ ] **Export block:** already returns `blocked` when flagged pending — keep; ensure UI surfaces it.
- [ ] **Missing id:** return empty html or JSON error row with `error` key rather than cryptic SQL failure (where extension allows).
- [ ] **PDF size guard:** refuse export/open with structured JSON `{ok:false, reason:'file_too_large', file_size, limit}`.
- [ ] **Invalid decision status:** constrain allowed values in macro (`accepted|rejected|undone`) before COPY.
- [ ] **export/run with client SQL:** dangerous (`run_sql($sql)`). For submission either remove, or gate to precomputed plan hash — do not leave arbitrary SQL execution as a public route without a comment that it’s a quackapi workaround and a tighter alternative.

### 3.8 Tests story

**SQL smoke (new, high leverage):**

```sql
-- tests/sql/smoke_ingest.sql (sketch)
SELECT assert(count(*) > 0) FROM cases;
SELECT assert(count(*) = (SELECT count(*) FROM documents)) FROM ...;
-- every document has page_count matching pages rows
-- words only for files that pdf_guard marked ok
```

**Playwright (existing):** keep 01–07; re-point boot docs to `scripts/boot.sh`; use `BASE_URL` env.

**Stress:** cite `docs/pdf-stress.md` in README “Limits”; do not require graders to run 700 MB cases.

### 3.9 Security / demo hygiene (brief)

- [ ] No arbitrary SQL export route in the “happy path” demo.
- [ ] Bind serve to `127.0.0.1` (already).
- [ ] Don’t commit decision logs or redacted outputs.
- [ ] Don’t commit `closure.db`.

---

## 4. Prioritized punch-list (apply before submission)

### 4.1 Small (do first — high grade ROI, low risk)

| # | Item | Files | Effort |
|---|------|-------|--------|
| S1 | **Single boot path** — pick `app.sql`-style (with seed + post-serve memory) as canonical; make `run.sh` a thin wrapper or delete | `run.sh`, `server/app.sql` → `scripts/boot.sh` + `server/boot.sql`, README, e2e README | S |
| S2 | **Remove absolute home paths** — `DUCKDB_BIN` / `QUACKAPI_EXT` required env | `app.sql`, e2e README, any docs | S |
| S3 | **Fix README layout** — drop missing `mutate.sh` / `export_case.sh` / `render_static.sql` or restore them | `README.md` | S |
| S4 | **Delete debug name hardcodes** in `render_document` proof CTE | `server/routes.sql` (later `render/document.sql`) | S |
| S5 | **Gitignore generated export macros** + stop committing `_export_macros.sql` | `.gitignore`, `server/_export_macros.sql` | S |
| S6 | **Home route** — prefer multi-case `render_home()` (macro already exists!) instead of `render_case(1)` on `/` | `routes.sql` line ~546 | S |
| S7 | **Deduplicate `qnorm` / `v_grams`** — one definition | `schema.sql` / `ingest.sql` | S |
| S8 | **Document honest PDF limits** in README (link `docs/pdf-stress.md`) — size guard, no 1 GB claim | `README.md` | S |
| S9 | **Post-serve memory raise** in whatever boot graders run | boot SQL | S |
| S10 | **Strip or quarantine sample-specific export CASE 1..4** comments; ensure codegen covers all cases dynamically | `app.sql` | S |
| S11 | **Static JS path cleanup** — ensure templates reference `/static/...` consistently | templates + static | S |
| S12 | **Add `tests/sql/smoke_*.sql`** minimal (counts + one render macro) | `tests/sql/` | S |

### 4.2 Medium (structure that graders notice)

| # | Item | Files | Effort |
|---|------|-------|--------|
| M1 | **Introduce `server/pdf/`** with geometry + redact as sole `pdf_redact` / y-flip owners | new `server/pdf/*`, slim routes/app | M |
| M2 | **Split `routes.sql`** into `render/` + `routes/{cases,documents,suggestions,export,meta}.sql` | `server/routes.sql` → tree | M |
| M3 | **Split `ingest.sql`** by entity; call pdf extract macros only | `server/ingest/*` | M |
| M4 | **Storage dirs** `storage/{input,working,output}` + fixture link script; update `source_path` + static page URLs | ingest, routes, `.gitignore`, boot | M |
| M5 | **Move decisions** out of `exports/` into `storage/working/decisions` | seed, routes POST COPY paths | M |
| M6 | **Wire or archive** `judge.sql` / `remainder_scan.sql` | boot or `server/experimental/` | M |
| M7 | **Harden `export/run`** — remove public arbitrary SQL or bind to plan id | `routes` export | M |
| M8 | **Config package** `config/paths.sql` + `env.example` | new | M |
| M9 | **SQL smoke in CI-ish script** `scripts/smoke.sh` | scripts + tests/sql | M |
| M10 | **Align e2e** with new boot + paths | `tests/e2e` | M |

### 4.3 Structural (if time; do after M1–M4)

| # | Item | Why |
|---|------|-----|
| L1 | Full target tree (§2.2) with empty `__init__`-style `.read` aggregators | Looks like a product codebase |
| L2 | Per-file PDF guard isolation at ingest (no whole-glob fail) | Matches stress findings F4–F6 |
| L3 | Size guard on export + UI banner for large docs | Professional PDF handling story |
| L4 | Page PNG generation owned by `pdf/raster.sql` into WORKING | Clear INPUT/WORKING/OUTPUT |
| L5 | OpenAPI-ish route table generated from `quackapi_routes()` | Ops polish |
| L6 | Collapse dual audit streams (table vs decisions JSON vs sidecar) to one event model | Data model clarity |

### 4.4 Explicit non-goals before submission

- Do not rewrite in FastAPI “for quality” — docs already argue OOM ≠ HTTP-in-DuckDB; a mid-rewrite will look unfinished.
- Do not add real LLM APIs.
- Do not expand stress monsters in the main demo path.
- Do not drive-by reformat all templates/JS.

### 4.5 Suggested apply order (one sitting)

```
S2 → S1 → S9 → S3 → S4 → S6 → S7 → S5
  → M1 (pdf boundary + geometry) 
  → M4/M5 (storage paths) 
  → M2 (split routes) 
  → M3 (split ingest)
  → S12/M9 (smoke)
  → M7 (export/run)
  → S8 (README limits)
```

---

## 5. Traceability: current → target

| Current file | Fate |
|--------------|------|
| `server/app.sql` | → `server/boot.sql` + pieces to `pdf/redact.sql` / `routes/export.sql` |
| `server/routes.sql` | → `server/render/*` + `server/routes/*` |
| `server/schema.sql` | → `server/schema/*` or delete if CTAS-only; stop dual maintenance |
| `server/ingest.sql` | → `server/ingest/*` + `server/pdf/extract.sql` |
| `server/seed.sql` | → `server/detection/seed.sql` |
| `server/judge.sql` | → `server/detection/judge.sql` (load or experimental) |
| `server/remainder_scan.sql` | → `server/detection/remainder_scan.sql` |
| `server/load_templates.sql` | stay (or `server/templates/load.sql`) |
| `server/_export_macros.sql` | generate to `storage/working/`; gitignore |
| `server/stress.sql` | → pointer to `tests/stress/` only |
| `run.sh` | → `scripts/boot.sh` |
| `exports/` | → `storage/output` + `storage/working/decisions` |
| `pages/` | → `storage/working/pages` |
| `samples/` | fixtures only |
| `static/*.js` | → `static/js/` |
| `tests/e2e/` | keep; fix boot docs |
| `tests/stress/` | keep offline |
| `docs/*` | keep; this file is the refactor spec |

---

## 6. Definition of done (submission-ready structure)

You can claim professional structure when:

1. **One command** boots the full demo (`scripts/boot.sh`) with seed + memory fix + no absolute paths.
2. **All PDF extension calls** live under `server/pdf/`.
3. **INPUT / WORKING / OUTPUT** directories exist; `documents.source_path` points at INPUT; redacted files only under OUTPUT; decisions only under WORKING.
4. **`routes.sql` monolith is gone**; each route file is skimmable; render separate from HTTP.
5. **README tree matches disk**; no missing-file references; limits section links stress evidence.
6. **SQL smoke + Playwright** both documented; smoke runs without a browser.
7. **No sample surnames / machine paths / committed generated macros** in the graded tree.

---

## 7. Appendix — Vori patterns borrowed (quick reference)

| Pattern | Vori location | Closure application |
|---------|---------------|---------------------|
| Monorepo services vs shared libs | `backend/services/*`, `backend/shared/*` | `server/routes` vs `server/pdf` + `server/schema` |
| Resource controllers | `graphql-api/src/controllers/{store,vendor,...}` | `server/routes/{cases,documents,...}.sql` |
| Service owns logic | `shared/nest/libs/*/example.service.ts` | Macros in `pdf/`, `detection/`, `render/` |
| PDF isolation | `shared/pdf.ts` | `server/pdf/*` |
| Route tree by domain | `composer/src/routes/_auth/retail/...` | file tree mirrors URL resources |
| Standards doc | `composer/docs/standards/code-standards.md` | this document |
| Scripts for ops | `backend/scripts`, `composer/scripts` | `scripts/boot.sh`, `scripts/smoke.sh` |
| Playwright helpers | `composer/src/playwright` | `tests/e2e/helpers` |
| Module README contract | nest libs README “who imports what” | `server/pdf/README.md` call rules |
| Config externalized | env / `configs/` | `config/env.example`, `config/paths.sql` |

---

## 8. Appendix — closure hotspots to touch (line-level anchors)

| Hotspot | Why |
|---------|-----|
| `server/app.sql:12` | Absolute `LOAD` path |
| `server/app.sql:86–128` | Export macro codegen + y-flip + path literals (move to pdf service) |
| `server/app.sql:141–147` | Hardcoded `CASE cid WHEN 1..4` |
| `server/app.sql:174–178` | Serve + memory re-raise (keep pattern, one place) |
| `server/ingest.sql:59–102` | Raw `samples/*.pdf` globs |
| `server/ingest.sql:208–213` | `exports/` map side effect inside ingest |
| `server/routes.sql:277–297` | Debug proof surnames |
| `server/routes.sql:479–512` | Second copy of redact SQL builder |
| `server/routes.sql:546` | `/` → `render_case(1)` ignores `render_home()` |
| `server/routes.sql:808–809` | Arbitrary `run_sql($sql)` |
| `run.sh:24–25, 68` | Personal defaults + `SET VARIABLE` |
| `run.sh:104` | Missing `render_static.sql` |
| README layout block | Drift vs actual files |

---

*End of spec. Implement in a later session; do not apply while other agents edit `server/`.*
