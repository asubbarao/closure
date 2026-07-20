# SCHEMA FREEZE CONTRACT — the rebuild must preserve these exactly

The SQL is being rebuilt schema-first (layered views over raw sources) and cut ≥50%.
This file is the frozen public surface. Refactor the SQL that PRODUCES these; never change the outputs.

## 0. Structural truths (read first)
- **`schema.sql` is NOT `.read` at boot.** The live schema is assembled by
  `ingest.sql` → `pdf_io.sql` → `seed.sql` → `judge.sql` → `routes/decisions.sql`.
  The rebuild's raw layer is **`server/sources.sql`** (unmaterialized views over source files),
  loaded FIRST; expensive extraction (`words`, `pages`, `suggestions`) stays CTAS; everything
  else composes as views. Delete the stale unused `schema.sql` or make it the real thing.
- **`v_document_stats` and `v_entity_hits` have ZERO consumers** — every route recomputes the
  same counts inline against `v_suggestions`. The rebuild should either wire a single clean
  stats view up everywhere (DRY win) or drop them. Don't preserve them as dead code.
- **`qnorm` and `v_grams` are internal-only** (seed matcher + search). Replace with
  splink `ngrams()` / `unaccent` + rapidfuzz. No route reads them directly.
- **Fix these pre-existing bugs in the rewrite:** `ingest.sql` stray `e` token in the
  `documents` CTAS (breaks boot); `routes/search.sql` `search_alnum` macro defined inside a
  comment (breaks `/api/search`).

## 1. Load-bearing VALUE strings (not just column names)
`entities.kind` / suggestion `kind` — judge.sql and geo.sql dispatch on these literal substrings.
Keep them EXACTLY:
`PERSON · SUBJECT`, `PERSON · WITNESS`, `SSN`, `DATE OF BIRTH`, `ADDRESS · SUBJECT`,
`PHONE · SUBJECT`, `PHONE · WITNESS`, `OFFICER · NOT SUBJECT PII`, `STREET NAME · NOT PII`,
`CITATION · NOT PII`. Dispatch tests used: `starts_with(kind,'PHONE'/'ADDRESS'/'PERSON')`,
`position('NOT PII'/'STREET'/'OFFICER'/'CITATION' IN kind)`, `kind IN ('SSN','DATE OF BIRTH')`.

## 2. Decision-log FILE schema (file-format contract — historical files must still parse)
Each write appends one JSON to `exports/decisions/*.json`. `v_decisions` reads them back.
Columns: `kind, suggestion_id, status, actor, reason, ts, document_id, page_no,
x0, y0, x1, y1, text, context, confidence, flag_tag, source, entity_id, case_id,
batch_id, batch_label, undoes_batch_id, scope`. A committed `_sentinel.json` pins the columns.
`v_decision_log` MUST expose the batch columns (`batch_id, batch_label, undoes_batch_id, scope`) —
history/undo/restore/audit all require them.

## 3. Core view: v_suggestions (status projection) — columns consumed everywhere
`id, document_id, page_no, x0, y0, x1, y1, text, context, confidence, flag_tag, reason,
entity_id, source, kind, entity_text, status, band` (`created_at` exists but is dead).
`status` ∈ pending|accepted|rejected (latest decision wins; manual→accepted, ai→pending).
`band` = high(≥90)|review(60-89)|flagged(<60). **These two gate export-block + triage auto-pass —
correctness, not display.** If coords move to a `box` struct internally, unpack back to
`x0/y0/x1/y1` at every route/template edge (those JSON keys + template vars are frozen).

## 4. Route inventory (49 routes) — path + JSON keys / template context frozen
HTML (tera): `/` & `/cases/:id` → case.html ctx `{case, stats, documents, entities, audit}`;
`/cases/:id/audit` → audit.html `{case, events}`; `/documents/:id[/pages/:page]` → review.html
`{case, doc, page, words, marks, docs, page_map, suggestions, stats}` (`proof` is dead, drop);
`/ui/reject|add-missed|bulk` raw shells; `/cases/:id/library` = render_case; `/ui/geo` geo_panel
`{case_id, case, standalone}`; `/ui/missed` remainder_panel `{doc_id, case_id, page_no, standalone}`.

JSON (output columns = keys): full list in the freeze map below. Key ones:
- `/api/documents/:id/suggestions` & `/api/cases/:id/suggestions` → the v_suggestions columns (+`filename` for case).
- `/api/cases/:id/documents` → id, filename, page_count, file_size, source_path, width_pt, height_pt, word_count, scan_*, suggestion_count, pending/accepted/rejected/flagged/high/review_count, progress_pct.
- `/api/documents/:id/page_map` → page_no, total, pending, accepted, rejected, flagged.
- `/api/cases/:id/triage` → case_id, threshold, total, resolved, pending, auto_passable, residual, high_pending, review_pending, flagged_pending, residual_bulk_eligible, progress_pct.
- `/api/cases/:id/triage/groups` → group_key, group_label, kind, entity_id, n, doc_count, page_count, min_conf, max_conf, has_flagged, has_fp, sample_reason, ids, instances[], group_band.
- `/api/cases/:id/history` → batch_id, label, actor, ts, ts_end, decision_count, accepted/rejected/pending/added_count, is_undo, undoes_batch_id, undone, case_id.
- `/api/suggestions/:id/judges` → suggestion_id, judge_id, judge_name, factor, verdict, score, reason, panel_confidence, panel_signal, judge_count, redact/keep/unsure_votes, judge_band.
- `/api/documents/:id/missed` & `/api/cases/:id/missed` → id, document_id, filename, case_id, page, x0,y0,x1,y1, text, kind, why, detector, score, entity_id.
- `/api/cases/:id/provenance[/recheck]`, `/api/documents/:id/store`, `/api/search`, `/api/cases/:id/audit`, `/api/stats`, `/api/documents/:id/scan`, `/api/cases/:id/geo|addresses`, `/api/cases/:id/entity-groups[/members]`, `/api/cases/:id/address-canon` — keep their existing key sets (see git history of each route file).
- POST mutation routes write the decision-log file schema (§2); they don't return bespoke bodies.

## 5. DANGER — renaming/removing these breaks things SILENTLY (no error)
1. `v_suggestions.band`/`.status` → export gate + triage. 2. `kind` value strings → judge/geo dispatch.
3. `v_decision_log` batch columns → history/undo/restore/audit. 4. decision-log file columns → historical files.
5. `suggestions.entity_id`↔`entities.id` join → fan-out/judge/remainder. 6. `app_templates.name` = file basename.
7. `words.font_size` (silent 9pt fallback). 8. `pages` vs `documents` width_pt/height_pt (fallback semantics).
9. `qnorm` semantics → suggestion counts (diff row counts pre/post, not callers). 10. Wiring up the dead
stats views makes their column sets load-bearing — preserve as given if you do.

## 6. app_templates.name values (file basenames, hardcoded in lookups + splices)
home.html, case.html, audit.html, review.html, reject.html, add_missed.html, bulk.html,
geo_panel.html, remainder_panel.html, provenance_panel.html, judge_panel.html,
triage_funnel.html, history_panel.html. Renaming a template file breaks its `WHERE name=` lookup.
