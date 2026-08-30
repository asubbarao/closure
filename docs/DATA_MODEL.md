# Data model (working doctrine)

Not Claude’s “orthogonal layers of views.”  
**Star the raw object. Fold in CTEs. Marts last.**

## The nice pattern (set-based / declarative)

You never need to invent a column list for a source. Star it. Schema and
profile are first-class CTEs when you want them — not hand-written laundry.

```sql
WITH
  raw AS (
    SELECT * FROM v_src_decisions          -- or read_json_auto / pdf_info / …
  ),
  shape AS (
    DESCRIBE SELECT * FROM raw             -- when you need the schema
  ),
  profile AS (
    SUMMARIZE SELECT * FROM raw            -- when you need counts/min/max
  )
SELECT *
FROM raw
WHERE kind = 'decision';
```

`server/sources.sql` is exactly that for every batch input:

| View | Star of |
|------|---------|
| `v_src_samples_fs` | `ls(samples_dir)` **+ every hostfs scalar** (see below) |
| `v_src_pdf_info` | hostfs PDF rows × `pdf_info` (dims); natural key = `file_name` (keeps `.pdf`) |
| `v_src_manifest` | `read_json_auto(manifest.json)` |
| `v_src_manifest_files` | `unnest(files)` — filename is **JSON data**, not a path |
| `v_src_watchlist` | `read_json_auto(watchlist.json)` |
| `v_src_decisions` | `read_json_auto(decisions/*.json)` |

### hostfs rule

Filesystem work uses **hostfs only**, and **only** via the full projection off `ls` / `lsr`:

```sql
SELECT
  path,
  file_name(path) AS name,
  file_extension(path) AS ext,
  path_split(path) AS segments,
  is_dir(path) AS is_dir,
  is_file(path) AS is_file,
  path_type(path) AS kind,
  hsize(file_size(path)) AS size,
  file_last_modified(path) AS modified,
  absolute_path(path) AS abs
FROM ls(samples_dir);
```

- No `parse_filename` (not hostfs; agents used it to fake basenames).
- No `file_name('bare.pdf')` on non-paths — hostfs returns NULL if the path does not exist.
- No macros for path helpers unless you explicitly greenlight one.
- Extension semantics: `ext_catalog_clean` on quack `:9494` (see Grok skill `ext-catalog`).

Detect folds the same way: `WITH raw AS (SELECT * FROM v_src_decisions) …`
and only casts at the fold (`arg_max(cast(status AS VARCHAR), …)`).

Rules of thumb:

1. **Sources** = `SELECT *` (plus `* RENAME` / `* EXCLUDE` / `* REPLACE` only when names are wrong).
2. **Do not** re-list every column at the reader. If you need a type, cast at the **fold**.
3. **Stats** = `SUMMARIZE` / `DESCRIBE` in a CTE — not `count(*) FILTER (WHERE …)` stacks baked into base views.
4. **TVF paths** = scalar `getenv` CASE in the arg — table functions reject subqueries.
5. **Durable subject keys** still apply (log FKs must rebind after boot). See `server/ids.sql`.

## Layers

| Layer | What | How |
|-------|------|-----|
| **0 · sources** | Files on disk | `server/sources.sql` — `v_src_*` star views |
| **1 · load** | Pin expensive extracts + durable ids | `ingest.sql` — `WITH … SELECT * FROM v_src_*` |
| **2 · detect** | Suggestions / entities | `detect.sql` — folds over words + starred log |
| **3 · marts** | UI / triage / export packs | `routes/*.sql` — projections, not the model |

## System of record

| Surface | Role |
|---------|------|
| `v_src_decisions` (`exports/decisions/*.json`) | Append-only **changelog** |
| `v_src_pdf_info` / `v_src_watchlist` / `v_src_manifest*` | Batch **inputs** |
| `cases` `documents` `pages` `words` `entities` `suggestions` | **Derived** CTAS (rebuildable, durable keys) |
| `v_doc_ui` / triage counts / … | **Marts** only |

## Durable keys (required)

Boot **must not** `uuid()` subjects that appear in the decision log.

| Subject | Payload → md5 → UUID |
|---------|----------------------|
| document | `case_no \|\| chr(31) \|\| filename` |
| entity | `case_id \|\| chr(31) \|\| kind \|\| chr(31) \|\| canonical_text` |
| suggestion (AI) | `document_id \|\| page \|\| rounded bbox \|\| text \|\| kind \|\| 'ai'` |

Event keys (`batch_id`, shard filenames) may still be random `uuid()`.

## Geometry

Suggestions carry `bbox STRUCT(...)` and flat `x0..y1` for the route/JS edge. Prefer `bbox` internally.

## Full assault (Kimball / Inmon / Kleppmann)

[`data-model-assault.md`](./data-model-assault.md)
