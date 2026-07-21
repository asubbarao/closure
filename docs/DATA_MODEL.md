# Data model (working doctrine)

This is **not** Claude’s “orthogonal layers of views = the model” story.

## System of record

| Surface | Role |
|---------|------|
| `exports/decisions/*.json` | Append-only **changelog** for status transitions + manual suggestion birth |
| Sample PDFs + `watchlist.json` + manifest | Batch **inputs** to detect at boot |
| `cases` / `documents` / `pages` / `words` / `entities` / `suggestions` | **Derived tables** rebuilt at boot — must use **durable keys** |
| `v_*` UI / triage / counts | **Marts** (projections), not the core model |

See the full Kimball / Inmon / Kleppmann assault: [`data-model-assault.md`](./data-model-assault.md).

## Durable keys (required)

Boot **must not** call `uuid()` for subjects that appear in the decision log.

| Subject | Payload for md5→UUID |
|---------|----------------------|
| document | `case_no \|\| chr(31) \|\| filename` |
| entity | `case_id \|\| chr(31) \|\| kind \|\| chr(31) \|\| canonical_text` |
| suggestion (AI) | `document_id \|\| page \|\| rounded bbox \|\| text \|\| kind \|\| 'ai'` |

Contract: `server/ids.sql`. Implementations: `ingest.sql`, `detect.sql`, `remainder_scan.sql`.

**Event** keys (decision shard filenames, `batch_id`) may still use random `uuid()` — those name events, not subjects.

## Geometry

Suggestions carry `bbox STRUCT(page, x0, y0, x1, y1, origin)` **and** flat `x0..y1` for the frozen route/JS edge. Prefer `bbox` internally; unpack at the edge until the contract moves.

## Decision log reader

`v_src_decisions` is the **only** glob reader. Typed casts; `ignore_errors` is off (corrupt shard fails loud).
