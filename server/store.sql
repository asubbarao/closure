-- server/store.sql — what persists.
--
-- One database (closure.db). Boot does not wipe it, same as any deployed app:
-- a department's decisions are the evidentiary record and outlive every
-- release. Only the two kinds of state differ in how they're built:
--
--   this file   durable  — decisions. CREATE IF NOT EXISTS, never dropped.
--   facts/      derived  — cases, documents, words, suggestions: pure functions
--                          of samples/ + watchlist, so boot rebuilds them.
--
-- Schema changes to the durable table go here as ALTER TABLE (a migration),
-- not as an edit to the CREATE — the table is already full of real decisions.

-- Page geometry, PDF points, origin top-left. Declared once so every layer says
-- ::bbox instead of respelling the four fields.
CREATE OR REPLACE TYPE bbox AS STRUCT(x0 DOUBLE, y0 DOUBLE, x1 DOUBLE, y1 DOUBLE);

-- Append-only by use, not by storage: routes only ever INSERT, and "current
-- status" is the latest row per suggestion (see domain/fold.sql).
CREATE TABLE IF NOT EXISTS decisions (
    ts              TIMESTAMP DEFAULT now(),
    kind            VARCHAR,    -- 'decision' (verdict) | 'added' (missed by AI)
    suggestion_id   VARCHAR,
    status          VARCHAR,    -- accepted | rejected | pending
    actor           VARCHAR,
    reason          VARCHAR,
    document_id     VARCHAR,
    case_id         VARCHAR,
    text            VARCHAR,
    batch_id        VARCHAR,    -- one per request, so undo can address it
    batch_label     VARCHAR,
    undoes_batch_id VARCHAR,
    -- 'added' rows only: a reviewer-drawn box the AI never proposed
    page_no         INTEGER,
    bbox            bbox,
    context         VARCHAR,
    confidence      INTEGER,
    flag_tag        VARCHAR,
    entity_id       VARCHAR,
    source          VARCHAR,
    scope           VARCHAR
);
