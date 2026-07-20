# CLOSURE — shared build contract (every grok reads this first)

## What we're building
A REAL, working, local webapp: an AI-powered PDF redaction review tool for law
enforcement (read the file "Alok_FDE_Fullstack Engineer Take-Home Assignment.txt"
in /Users/aloksubbarao/personal/closure). The whole point is a WORKING UX — a
reviewer clears hundreds of AI redaction suggestions fast. The mockup screens in
design/*.html and the PNGs in
"/Users/aloksubbarao/Downloads/Legal_Document_Review/Folder (1)"/*.png are
INSPIRATION for a full working app, not pixel targets. design/copy.md is the
microcopy spec — use its exact strings.

## Stack (FIXED — do not change, do not add others)
ONE DuckDB process is database + HTTP server + PDF engine + HTML renderer.
Extensions: pdf (community), tera (community), quackapi (local build). The UI is
tera-rendered HTML served by quackapi, made interactive by small vanilla JS
files under static/ that fetch() the JSON routes. NO npm, NO React, NO Vite, NO
node, NO python, NO shell scripts, NO shellfs. If the backend must do more, it is
DuckDB SQL or a quackapi C++ change — never a shell script.

## Run command (the ONLY way it boots)
/Users/aloksubbarao/personal/quackapi/build/release/duckdb -unsigned closure.db -c ".read server/app.sql"
Serves at http://127.0.0.1:8117/ . closure.db is a throwaway build artifact
(app.sql rebuilds all derived tables via CREATE OR REPLACE CTAS every boot).

## HARD SQL rules (the repo owner is militant about these)
- Derived data = CREATE OR REPLACE TABLE ... AS SELECT (CTAS). NEVER
  "INSERT INTO ... SELECT" for setup, NEVER a VALUES list, NEVER SET VARIABLE.
- The only runtime writes are decisions and exported PDFs (see below). Persist
  decisions DuckDB-NATIVELY: append one JSON file per decision under
  exports/decisions/ and read them back with read_json over the glob (a fresh
  file per write sidesteps the single-writer lock and stays pure DuckDB). If you
  ever truly must INSERT, it is "INSERT OR REPLACE INTO t BY NAME SELECT ..." only.
- Substring match operators (the LIKE family / contains) are BANNED — use
  position(), regexp_matches, or list operations instead.
- Nothing hand-typed: all data derives from samples/*.pdf, samples/identities.json,
  samples/manifest.json, and read_pdf_words coordinates.

## Data model already built (server/ingest.sql, server/seed.sql — pure CTAS)
cases, documents, words (real read_pdf_words boxes), entities, suggestions
(id, document_id, page_no, x0,y0,x1,y1, text, context, confidence, flag_tag,
reason, entity_id, source), plus a v_suggestions view projecting status
(pending|accepted|rejected) and band (high >=90 | review 60-89 | flagged <60).
~1296 suggestions, 4 cases; false positives present (Nienow Street x8); false
negatives absent (a spaced SSN, "Robyn Prce" — reviewer adds these by hand).
Case 1 (id 1, "24-000117") is the demo case with 5 docs including a 110-page file.

## Coordinate transform (marks on the page canvas)
Page is width_pt x height_pt PDF points, TOP-LEFT origin (read_pdf_words space).
Page PNGs are pre-rendered at static path /pages/<filename>/p<N>.png (filename =
document filename WITHOUT .pdf), served by quackapi static_dir. Display the PNG
at a fixed CSS width W (e.g. 700px): scale = W / width_pt; a box draws at
left=x0*scale, top=y0*scale, width=(x1-x0)*scale, height=(y1-y0)*scale.
Mark styles by status: pending=amber highlighter fill; accepted=solid black bar;
rejected=dashed gray strikeout; flagged=dashed red outline; current=blue ring.

## HTTP ROUTE CONTRACT (owned by the backend grok; UX groks code to it)
HTML pages (tera, output column named `html` => served as text/html):
  GET  /                          dashboard for case 1
  GET  /cases/:id                 case dashboard
  GET  /documents/:id             review surface, page 1
  GET  /documents/:id/pages/:page review surface, page N
JSON (output column names become JSON keys):
  GET  /api/documents/:id/suggestions   -> rows from v_suggestions for that doc
  GET  /api/cases/:id/suggestions       -> all rows for the case (bulk/entity)
  GET  /api/search?q=TEXT&case=ID       -> {matches:[{document_id,filename,page_no,x0,y0,x1,y1}], count}
  GET  /api/cases/:id/audit             -> decision log rows, newest first
  POST /api/suggestions/:id/decision?status=accepted|rejected|pending&reason=...&actor=...
  POST /api/entities/:id/decision?status=accepted|rejected&actor=...   (fan-out; EXCLUDES flagged band)
  POST /api/documents/:id/add?page=&x0=&y0=&x1=&y1=&text=&kind=&scope=one|all&actor=...  (manual add, born accepted)
  POST /api/cases/:id/export?actor=...  -> pdf_redact accepted boxes per doc into exports/,
                                           then read_pdf proves zero hits; returns
                                           {exported, blocked, flagged_remaining}
All POSTs return JSON. Frontend uses fetch(); update in place or reload.

## PRIMARY DESIGN REFERENCE (build the frontend to THIS quality)
/Users/aloksubbarao/Downloads/clozure-redaction-mocks.html — one self-contained
file with a screen switcher (S1 dashboard, S2 review, reject, add-missed, bulk).
It is the design system to match: fonts IBM Plex Sans + IBM Plex Mono + Courier
Prime; tokens --ws #E9ECF0 (workspace), --panel #FFFFFF, --ink #1A2230,
--black #0B0E14 (laid redaction), --pend #B45309 amber (pending), --acc #1D4ED8
blue (accepted/current), --rej #B42318 red (rejected/flagged), --ok #087443.
Cards, badges (.b-pend/.b-ok/.b-rej/.b-blue), .btn, .kbd, the 3-column .review
grid (220px doclist | page | 340px suggestions), the confidence bars, the
keyboard legend — reuse these classes/styles. Pull the CSS from this file; keep
each of your templates self-contained (inline <style>). The document page itself
: use the real page PNG at /pages/<filename>/p<N>.png with absolutely-positioned
overlay marks at the coordinates above (truthful to the real PDF), styled with
the mock's pending/accepted/rejected/flagged colors. Match the mock's chrome,
panels, queue, badges, and typography closely — this is the graded artifact.

## File ownership (do NOT edit files outside your set)
Backend grok:  server/ingest.sql, seed.sql, routes.sql, load_templates.sql,
               app.sql; DELETE all *.sh, render_static.sql, static/*.html dumps.
Each UX grok owns only its listed template(s) + its own static/<name>.js.
Templates are self-contained (inline <style> pulling tokens from design/*.html:
Inter + JetBrains Mono, --bg #F4F5F6, --ink #191B1E, amber pending, red flagged,
blue current). Read the CURRENT server/templates/<file> to learn which tera
context vars the render macro passes and keep that contract; if you need a NEW
var, state it clearly at the top of your final report so the backend grok adds it.

## Verify before you finish
Boot with the run command, curl your routes / open your page, confirm real data
renders and your interactions actually work. Report what you PROVED, with
evidence. Do NOT touch design/ or samples/.
