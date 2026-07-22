# Sanity check: is Closure sound?

**Date:** 2026-07-19  
**Method:** Read frontend (`server/templates/*.html`, `static/*.js`) + backend (`server/*.sql`, `app.sql`, routes); boot with the specified command on a fresh/reloaded `closure.db`; curl real routes and mutations; one-way peek at `closure-cleanroom/attempt-{1,2,3}` (read-only).  
**Boot:**  
`/Users/aloksubbarao/personal/quackapi/build/release/duckdb -unsigned closure.db -c ".read server/app.sql"` → `http://127.0.0.1:8117/`

---

## Verdict

**Mostly yes — sound, and it actually works.**

This is **not** “utterly crazy shit.” It is an unconventional but coherent take-home: one DuckDB process is DB + HTTP (`quackapi`) + PDF (`pdf`) + HTML (`tera`), with a real review UI and real sample PDFs. End-to-end paths I exercised **work**. It could stand as a **simple, legit frontend webapp** for the assignment’s scope, with a short list of submission-risk items (README rot, custom binary, a few load-bearing hacks).

| Dimension | Grade | One-liner |
|-----------|-------|-----------|
| Does it boot and serve? | **Yes** | Listen on `:8117`; routes register; static + pages served |
| Does review workflow work E2E? | **Yes** | Accept/reject → JSON decision → `v_suggestions` updates; bulk + entity + manual add work |
| Is architecture reasonable? | **Mostly** | Thesis is clear; a few hacks will get flagged in review |
| Pass as a real simple webapp? | **Yes, with caveats** | Polished UI + real clicks; stack will surprise a conventional reviewer |
| Vs clean-room TS apps | **Same ballpark, different tradeoffs** | Ours is deeper on data/PDF; clean-room is safer on “how every FDE ships a take-home” |

If you need a single phrase for the owner: **ship-viable prototype; not a demo shell; fix docs + a few rough edges before a skeptical human opens it.**

---

## What I actually observed running it

### Boot summary (live)

| Metric | Value |
|--------|------:|
| Cases | 4 |
| Documents | 11 |
| Pages | 210 |
| Words (`read_pdf_words`) | 22,247 |
| Entities | 54 |
| AI suggestions | 1,328 |
| Templates loaded | 7 |

Per-doc suggestion counts include a **110-page** `consolidated_case_file_2024-0117` with **964** suggestions — this is real scale, not a 12-row stub.

### Routes hit (HTTP)

| Route | Observed |
|-------|----------|
| `GET /api/stats` | **200** — counts above |
| `GET /` | **200** — case dashboard for **case 1 only** (`24-000117`), ~41KB, ~0.05–0.7s |
| `GET /cases/1` | **200** — same library UI; docs listed |
| `GET /documents/:id` + `/pages/:n` | **200** — review shell, boot JSON, queue, marks, word layer |
| `GET /documents/3` (110-page) | **200** in **~36ms**, queue **capped at 80**, page marks present |
| `GET /api/documents/:id/suggestions` | **200** — full geometry + status/band/kind |
| `GET /api/cases/:id/documents` | **200** — progress/pending per doc |
| `GET /api/cases/:id/export_plan` | **200** — emits real `pdf_redact(...)` SQL with box literals |
| `GET /api/cases/:id/audit` | **200** — capped ~500 events |
| `GET /cases/:id/audit` | **200** — HTML (can be large) |
| `GET /ui/reject`, `/ui/add-missed`, `/ui/bulk` | **200** — client shells + large JS |
| `GET /static/review.js` | **200** |
| `GET /pages/.../p1.png` | **200** for case `24-000117` docs; **404** for other cases’ stems (e.g. arrest report, evidence log) |

### Mutations (live)

| Action | Result |
|--------|--------|
| `POST /api/suggestions/37/decision?status=rejected&actor=sanity-check` | **200** `[{"Count":1}]`; status flipped to **rejected** on re-fetch; file written under `exports/decisions/dec_*.json` |
| Re-accept same id | **200**; projection uses latest decision |
| `POST /api/documents/2/add?...&text=Missed%20PII%20Sanity` | **200**; appears in suggestions API as `source=manual`, `status=accepted`, synthetic id |
| `POST /api/entities/7/decision?status=accepted` | **200** `[{"Count":259}]` — entity fan-out works |
| `POST /api/documents/5/band/high/decision?status=accepted` | **200** `[{"Count":21}]` |
| `POST /api/cases/1/export` | **200** `{"exported":1,"blocked":true,"flagged_remaining":7}` — gate reports blocked while still counting partial export |
| `GET /api/search?case=1&q=Cronin` / `Magnolia` | **200** with matches; wrong name → empty (search itself is fine) |

Keyboard contract in `static/review.js` is real: `j/k`, `a/r`, Shift+A/R bulk, `x` multi-select, `u` undo (posts prior status), `e` → `/ui/bulk`, `n` → `/ui/add-missed`.

---

## Architecture: reasonable or embarrassing?

### What’s sound

1. **Clear product loop:** case library → document review (canvas + queue + rail) → decide → audit → export blocked while flagged pending. Matches the assignment challenges (FP/FN, volume, multi-doc, audit).

2. **Data model is thoughtful for a take-home:**
   - Cases / documents / pages / words / entities / suggestions
   - Status as **projection** (`v_suggestions` + `v_latest_decision` over decision log), not silent overwrites
   - Geometry in PDF points; one conversion to `pdf_redact` boxes at export
   - Seed from `identities.json` + n-gram match on real words (`seed.sql`) with planted FPs (officer, street, citation)

3. **Scale-aware rendering:** `render_document` loads **current-page** words/marks only; suggestion queue hard-capped (80). The 110-page doc did not explode the HTML.

4. **Stack thesis is honest:** not a fake “SQL web framework” demo — it loads a real extension, `CREATE ROUTE`, `quackapi_serve`, community `pdf` + `tera`. Rationale in `docs/rationale.md` matches the code better than `README.md` does.

5. **Frontend is a real app,** not pure mockups: ~5k lines of vanilla JS (`review.js` ~1.2k, `dashboard.js`, `bulk.js`, `addmissed.js`, `reject.js`) talking to JSON APIs; templates are polished (IBM Plex, consistent tokens from `design/`).

### Load-bearing hacks a reviewer will notice

Ranked by how hard they land in review:

| # | Risk | Severity | What I saw |
|---|------|----------|------------|
| 1 | **Custom DuckDB binary required** | **High (submission)** | Stock DuckDB won’t do `CREATE ROUTE`. Path is hard-coded to `/Users/aloksubbarao/personal/quackapi/build/release/...`. Reviewer cannot `npm i && npm run dev`. |
| 2 | **Mutations = `COPY` to `exports/decisions/*.json`** | **High (architecture)** | POST handlers cannot multi-statement UPDATE; state lives as append-only files, projected by `read_json('exports/decisions/*.json')`. Clever and working — also a filesystem event store. Will grow files (I previously saw **2600+** decision files in tree; this session started lean after re-boot). |
| 3 | **Export SQL baked at boot + partial export while “blocked”** | **High** | `app.sql` writes `server/_export_macros.sql` with giant literal `pdf_redact` strings. Mid-session accepts need reboot or `export_plan` + `export/run`. Live `POST .../export` returned `blocked:true` **and** `exported:1` — gate is soft. |
| 4 | **`README.md` is wrong** | **High (first impression)** | Still says suggestions empty, `shellfs` + `mutate.sh`, old route table. Reality is `seed.sql`, decision JSON, `/api/...` routes. **First file a reviewer opens lies.** |
| 5 | **Page PNGs only for case `24-000117`** | **Med** | `pages/` has 5 stems. Case 2+ docs (e.g. `arrest_report_2024-0233`) **404** page images. Word boxes still render; canvas looks half-broken. |
| 6 | **Home is hard-coded to case 1** | **Med** | `CREATE ROUTE home GET '/' AS SELECT * FROM render_case(1);` while `render_home()` / `home.html` exist unused. Four cases ingested; multi-case entry is weak. |
| 7 | **Hardcoded “proof” names in `routes.sql`** | **Med (sloppy)** | `Yasmine` / `Nienow` / `Reyes` / … while live subject is **Magnolia Cronin**. Leftover demo data. |
| 8 | **Add-missed words API 404** | **Med** | `addmissed.js` tries `/api/documents/:id/words` → **404**. Falls back to scraping review HTML. Works if scrape succeeds; brittle. |
| 9 | **Secondary flows are full navigations** | **Low–Med** | `n` → `/ui/add-missed`, entity bulk → `/ui/bulk` — multi-page shells, not in-workspace modals. Functional, slightly 2012. |
| 10 | **No automated tests** | **Med (vs peers)** | Stress SQL exists; no Vitest/Playwright suite for the review loop. Clean-room apps have component + repo tests. |
| 11 | **quackapi memory dance** | **Low–Med** | Documented: serve forces 256MB then re-`SET` 4GB. Explained in `app.sql` comments; still a footgun. |
| 12 | **Actor hard-coded** | **Low** | `"A. Subbarao"` in JS boot — fine for demo, slightly awkward for anonymous review. |

None of these make the app “fake.” They make it **opinionated systems work under constraints of single-SELECT HTTP handlers**, which is exactly the bet.

---

## Frontend-webapp reality

### Could this pass as a simple, real frontend webapp?

**Yes.** A skeptical reviewer opening `http://127.0.0.1:8117/`:

**First 30 seconds (positive):**
- Looks like a product: sticky app bar, progress meter, document table with band bars, entity roster, blocked-export banner
- Open a case-1 document → real page PNG + amber/black marks + keyboard queue
- Accept/reject updates UI; refresh keeps status (projection works)
- 110-page consolidated file is navigable without melting the browser (queue cap + page-local words)

**Next 10 minutes (mixed):**
- “Where is React/Next?” — nowhere. SSR HTML + vanilla JS. For a take-home that asked for full-stack skill, this still reads as intentional if rationale is solid
- “How do I run this?” — custom binary path; if that fails, submission is dead on arrival
- Cases 2–4 missing page images → “broken assets”
- `/ui/*` flows feel like separate mini-apps (design fidelity from mockups, not SPA cohesion)
- Export story is subtle: blocked banner + macros + optional dynamic SQL is more engineer-brain than clerk-brain

**Would they think it’s a legit webapp?**  
Yes — **if it boots.** The UI is not a static Figma export with dead buttons. It is denser and more “real data” than the clean-room stubs. It is **not** a conventional Node app; the question is whether the reviewer values that or punishes it.

### Assignment coverage (Part 2)

| Requirement | Closure |
|-------------|---------|
| Working interactive prototype | **Yes** |
| Main review interface | **Yes** (`review.html` + `review.js`) |
| Reject false positives | **Yes** (inline `r` + reject shell + reasons) |
| Add missed redactions | **Yes** (manual POST + `/ui/add-missed`) |
| Bulk similar | **Yes** (selection bulk, band, entity) |
| Multi-document | **Yes** (case rail + dashboard) |
| Confidence levels | **Yes** (high/review/flagged bands) |
| Audit trail | **Yes** (HTML + API; decision log projection) |
| Serverless DB | **Yes** (DuckDB file) |
| Hardcoded realistic suggestions | **Yes** (seeded from answer key + match) |
| Design fidelity | **Strong** (`design/` → templates) |
| Design rationale | **Present** (`docs/rationale.md`) |

---

## Compare vs clean-room TS apps (attempt-1/2/3)

One-way peek only. All three are **Next.js 15 + React 19 + Tailwind + SQLite + Zod + Vitest**, ~4k LOC of TS/TSX each, tiny **fixture stubs** (1 case, ~2 docs, handful of suggestions), plant explicit FP/FN for demo.

| | **Closure (DuckDB)** | **Clean-room (Next/TS)** |
|--|----------------------|---------------------------|
| Stack familiarity | Low for most FDE reviewers | High — “looks like every take-home” |
| Run story | Custom quackapi duckdb | `npm i && npm run dev` |
| Data depth | 11 real PDFs, 22k words, 1.3k suggestions, 110-page doc | ~dozens of suggestions, text-line fixtures |
| PDF reality | Real `read_pdf_words` + `pdf_redact` | No real PDF; layout fixtures / char offsets; “apply” is DB flag |
| Types / contracts | SQL + informal JSON | TypeScript + Zod end-to-end |
| Tests | Stress SQL, no UI tests | Vitest + Testing Library on queue/workspace |
| UI components | Monolithic templates + IIFEs | Modular React components |
| Design polish | High (custom CSS system) | High (Tailwind, more generic) |
| Audit | File-projected event log | Normal SQLite rows |
| Bulk / entity | Entity_id fan-out across case (259 in one POST observed) | Similar text bulk; solid but small data |
| Completeness vs brief | **Over-delivers** on detection/geometry/export | **Hits the brief cleanly** with intentional small scope |

### Better / worse / equivalent

- **Ours better:** authenticity of the domain (real PDFs, real boxes, real redaction export), multi-doc scale, entity-centric bulk at volume, design system fidelity to LE-adjacent product feel, single-process demo for “systems taste.”
- **Ours worse:** reviewer run friction, no type system, no test suite, README drift, mutation/export hacks, incomplete page PNG set, weaker multi-case home.
- **Equivalent:** core UX loop (queue + canvas + keyboard + confidence bands + audit + multi-doc rail). Clean-room proves the same product idea with less risk; Closure proves more of the hard data plane.

**Ballpark judgment:** not wildly off. If clean-room is a **solid A- conventional take-home**, Closure is an **A/A- unconventional** one *when it runs* — or a **C** if the binary story fails for the reviewer.

---

## Must-fix before submission

### Small (hours)

1. **Rewrite `README.md` to match reality** — boot command, route table, decision files, seeded suggestions, prerequisites (quackapi duckdb path). Delete “suggestions empty / shellfs mutate.sh” lies.
2. **Multi-case entry** — either wire `render_home()` to `GET /` or document “open `/cases/1`…`/cases/4`” and link cases from somewhere visible.
3. **Strip or fix hardcoded proof names** in `routes.sql` (`Yasmine`/`Nienow`/…).
4. **Page PNGs for all sample stems** or hide broken `img` and rely on word layer with a clear empty-state.
5. **Label `/ui/*` shells** in README (first-class flows vs design demos) and ensure query params (`?doc=`, `?entity=`) are the documented contract.
6. **Export UX copy** — when `blocked:true`, say what was still exported (if anything) so partial export isn’t silent.

### Big (worth doing if time)

1. **Reviewer run path:** ship a documented binary location, container, or script that fails loud with “build quackapi first”; ideally one `./run.sh` that matches what you test (today `run.sh` and `app.sql` diverge in places).
2. **Mutation story you can defend in 60 seconds:** either keep file-based decisions and document as intentional event sourcing, or fold decisions into `audit_events` / a table if quackapi can support it — don’t leave both README and schema comments describing a third outdated model.
3. **Export correctness:** blocked ⇒ no `pdf_redact` side effects (or only dry-run plan); live export uses post-decision boxes without reboot. Today’s boot macros + soft block is the weakest “does export really work?” answer.
4. **Add-missed robustness:** implement `GET /api/documents/:id/words` (or page-scoped) so the FN path doesn’t depend on HTML scrape + 404 fallbacks.
5. **Minimal automated proof:** even 5–10 curl-based smoke tests or a short `tests/smoke.sh` for decision → status → export_plan would outclass “trust me.”

---

## Bottom line for the owner

- **Sound?** Yes — deliberate architecture, real data plane, real review UX.  
- **Works?** Yes — I ran boot, GETs, POSTs, bulk, manual add, export gate, search.  
- **Embarrassing hacks?** A few (file-backed mutations, boot-baked export SQL, custom binary, stale README). Explainable, but **must be owned** in rationale/README, not left as surprise.  
- **Simple legit frontend webapp?** Yes, if the reviewer can start it and you fix the first-impression docs + missing PNGs.  
- **Vs clean-room TS:** same product brief; they chose safety and conventional stack; you chose depth and a single-binary thesis. Neither is crazy. **Your risk is operational (run + honesty of docs), not conceptual.**

Do **not** rewrite in Next “to look normal” unless the run story is hopeless — that would throw away the distinctive, working parts. Do **fix the submission surface** so a cold reviewer never hits a lie or a missing binary without a clear path.
