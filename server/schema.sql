-- schema.sql — Closure data model.
-- One DuckDB file (closure.db) is the whole backend.
--
-- Design decisions:
--   1. Decisions are APPEND-ONLY EVENTS (audit_events). A suggestion's status
--      is a projection of its latest event (v_suggestions), so the audit trail
--      cannot disagree with the data — undo is just another event.
--   2. Geometry is PDF points, top-left origin (read_pdf_words space).
--      The single conversion to pdf_redact box (page,x,y,w,h) happens in the
--      export route and nowhere else.
--   3. Entities are the canonical PII catalog (from identities.json). Bulk
--      operations fan out via entity_id, not UI tricks.
--   4. suggestions is STRUCTURAL ONLY this pass — empty until the seeding
--      step. No fabricated confidence scores.

--#I suppose we can't "derive" these? if we can, it's always better to CTAS/Replace and a bit tedious to define the ddl, but its okay if we have to. 
--#make all things verbose, OI mean page_no is okay, height_t is okay, i geuss the coords are oky but maybe put them in a coords arr/map/whatever json idont care 

CREATE SEQUENCE IF NOT EXISTS seq_document;
CREATE SEQUENCE IF NOT EXISTS seq_entity;
CREATE SEQUENCE IF NOT EXISTS seq_suggestion;
CREATE SEQUENCE IF NOT EXISTS seq_audit;

CREATE TABLE IF NOT EXISTS cases (
    id      INTEGER PRIMARY KEY,
    case_no VARCHAR NOT NULL UNIQUE,
    title   VARCHAR NOT NULL
);

CREATE TABLE IF NOT EXISTS documents (
    id          INTEGER PRIMARY KEY DEFAULT nextval('seq_document'),
    case_id     INTEGER NOT NULL REFERENCES cases(id),
    filename    VARCHAR NOT NULL UNIQUE,
    source_path VARCHAR NOT NULL,
    page_count  INTEGER NOT NULL,
    width_pt    DOUBLE NOT NULL,
    height_pt   DOUBLE NOT NULL,
    file_size   BIGINT
);

CREATE TABLE IF NOT EXISTS pages (
    document_id INTEGER NOT NULL REFERENCES documents(id),
    page_no     INTEGER NOT NULL,
    width_pt    DOUBLE NOT NULL,
    height_pt   DOUBLE NOT NULL,
    PRIMARY KEY (document_id, page_no)
);

CREATE TABLE IF NOT EXISTS words (
    document_id INTEGER NOT NULL REFERENCES documents(id),
    page_no     INTEGER NOT NULL,
    seq         INTEGER NOT NULL,
    word        VARCHAR NOT NULL,
    x0 DOUBLE NOT NULL, y0 DOUBLE NOT NULL,
    x1 DOUBLE NOT NULL, y1 DOUBLE NOT NULL,
    font_size   DOUBLE
);

CREATE TABLE IF NOT EXISTS entities (
    id             INTEGER PRIMARY KEY DEFAULT nextval('seq_entity'),
    case_id        INTEGER NOT NULL REFERENCES cases(id),
    canonical_text VARCHAR NOT NULL,
    kind           VARCHAR NOT NULL,
    UNIQUE (case_id, canonical_text, kind)
);

-- STRUCTURAL ONLY this pass — left empty until the seeding step.
CREATE TABLE IF NOT EXISTS suggestions (
    id          INTEGER PRIMARY KEY DEFAULT nextval('seq_suggestion'),
    document_id INTEGER NOT NULL REFERENCES documents(id),
    page_no     INTEGER NOT NULL,
    x0 DOUBLE NOT NULL, y0 DOUBLE NOT NULL,
    x1 DOUBLE NOT NULL, y1 DOUBLE NOT NULL,
    text        VARCHAR NOT NULL,
    context     VARCHAR NOT NULL DEFAULT '',
    confidence  INTEGER NOT NULL,
    flag_tag    VARCHAR,
    reason      VARCHAR,
    entity_id   INTEGER REFERENCES entities(id),
    source      VARCHAR NOT NULL DEFAULT 'ai' CHECK (source IN ('ai', 'manual')),
    created_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS audit_events (
    id            INTEGER PRIMARY KEY DEFAULT nextval('seq_audit'),
    ts            TIMESTAMP NOT NULL DEFAULT now(),
    actor         VARCHAR NOT NULL,
    action        VARCHAR NOT NULL
                  CHECK (action IN (
                      'accepted', 'rejected', 'undone', 'added',
                      'exported', 'ingested'
                  )),
    -- No FK on suggestion_id this pass: suggestions is empty until seed, but
    -- the decision POST path must still append an audit row end-to-end.
    suggestion_id INTEGER,
    case_id       INTEGER REFERENCES cases(id),
    target        VARCHAR,
    reason        VARCHAR
);

CREATE OR REPLACE VIEW v_suggestions AS
       --#way too 'prescriptive' we want a set of elegant views and tables. 
SELECT s.*,
       e.kind,
       e.canonical_text AS entity_text,
       coalesce(
           (SELECT CASE a.action WHEN 'undone' THEN 'pending' ELSE a.action END
            FROM audit_events a
            WHERE a.suggestion_id = s.id
              AND a.action IN ('accepted', 'rejected', 'undone')
            ORDER BY a.id DESC LIMIT 1),
           CASE s.source WHEN 'manual' THEN 'accepted' ELSE 'pending' END
       ) AS status,
       CASE WHEN s.confidence >= 90 THEN 'high'
            WHEN s.confidence >= 60 THEN 'review'
            ELSE 'flagged' END AS band
FROM suggestions s
LEFT JOIN entities e ON e.id = s.entity_id;

--#delete. definitely none of this kind of stuff. there are other ways to do itsplink etc. 
CREATE OR REPLACE MACRO qnorm(t) AS lower(trim(t, '.,;:()"'''));

CREATE OR REPLACE VIEW v_grams AS
       --# yeah idk what this is but I do know its codesmell and we don't need or want it. replace it with a placeholder 
       --# which explains what wer're trying to do. do this for ll page.s if u dont know how to do something if i say no on it, then remove it w/placehlder, and explanation what is trying to achieved and i can sketch the query
WITH base AS (
    SELECT document_id, page_no, seq, word, x0, y0, x1, y1,
           lead(word, 1) OVER w AS word1, lead(x1, 1) OVER w AS x1_1,
           lead(y0, 1) OVER w AS y0_1,   lead(y1, 1) OVER w AS y1_1,
           lead(word, 2) OVER w AS word2, lead(x1, 2) OVER w AS x1_2,
           lead(y0, 2) OVER w AS y0_2,   lead(y1, 2) OVER w AS y1_2,
           lead(word, 3) OVER w AS word3, lead(x1, 3) OVER w AS x1_3,
           lead(y0, 3) OVER w AS y0_3,   lead(y1, 3) OVER w AS y1_3
    FROM words
    WINDOW w AS (PARTITION BY document_id, page_no ORDER BY seq)
)
       
       --#not a fan of this. something is wrong. a single extract cte and defining the concat string will save characters across all. 
       
       --#what is this? some kind of like nlp thing? i fso, delete it entirely, splink_udfs, and rapidfuzz, should be sufficient
SELECT document_id, page_no, seq, 1 AS n, qnorm(word) AS text_norm,
       word AS text_raw, x0, y0, x1, y1
FROM base
UNION ALL
SELECT document_id, page_no, seq, 2, qnorm(word) || ' ' || qnorm(word1),
       word || ' ' || word1, x0, y0, x1_1, greatest(y1, y1_1)
FROM base WHERE word1 IS NOT NULL AND abs(y0_1 - y0) < 2
UNION ALL
SELECT document_id, page_no, seq, 3,
       qnorm(word) || ' ' || qnorm(word1) || ' ' || qnorm(word2),
       word || ' ' || word1 || ' ' || word2, x0, y0, x1_2, greatest(y1, y1_2)
FROM base WHERE word2 IS NOT NULL AND abs(y0_1 - y0) < 2 AND abs(y0_2 - y0) < 2
UNION ALL
SELECT document_id, page_no, seq, 4,
       qnorm(word) || ' ' || qnorm(word1) || ' ' || qnorm(word2) || ' ' || qnorm(word3),
       word || ' ' || word1 || ' ' || word2 || ' ' || word3, x0, y0, x1_3, greatest(y1, y1_3)
FROM base WHERE word3 IS NOT NULL
       AND abs(y0_1 - y0) < 2 AND abs(y0_2 - y0) < 2 AND abs(y0_3 - y0) < 2;




--#I don't like this at all, absolute worst antipattenr. all available in DESCIRBE SUMMARIZE and has ugly inner subselect, just no. completely remove. 
CREATE OR REPLACE VIEW v_document_stats AS
SELECT
    d.id AS document_id,
    d.case_id,
    d.filename,
    d.page_count,
    d.file_size,
    d.width_pt,
    d.height_pt,
    (SELECT count(*) FROM words w WHERE w.document_id = d.id) AS word_count,
    (SELECT count(*) FROM pages p WHERE p.document_id = d.id) AS page_rows,
    (SELECT count(*) FROM v_suggestions s WHERE s.document_id = d.id) AS suggestion_count,
    (SELECT count(*) FROM v_suggestions s WHERE s.document_id = d.id AND s.status = 'pending') AS pending_count,
    (SELECT count(*) FROM v_suggestions s WHERE s.document_id = d.id AND s.status = 'accepted') AS accepted_count,
    (SELECT count(*) FROM v_suggestions s WHERE s.document_id = d.id AND s.status = 'rejected') AS rejected_count,
    (SELECT count(*) FROM v_suggestions s WHERE s.document_id = d.id AND s.band = 'flagged' AND s.status = 'pending') AS flagged_count,
    (SELECT count(*) FROM v_suggestions s WHERE s.document_id = d.id AND s.band = 'high') AS high_count,
    (SELECT count(*) FROM v_suggestions s WHERE s.document_id = d.id AND s.band = 'review') AS review_count
FROM documents d;

CREATE OR REPLACE VIEW v_entity_hits AS
SELECT
    e.id AS entity_id,
    e.case_id,
    e.canonical_text,
    e.kind,
    count(g.document_id) AS hit_count,
    count(DISTINCT g.document_id) AS doc_count
FROM entities e
LEFT JOIN documents d ON d.case_id = e.case_id
LEFT JOIN v_grams g
  ON g.document_id = d.id
 AND g.text_norm = qnorm(e.canonical_text)
GROUP BY e.id, e.case_id, e.canonical_text, e.kind;



-- HTML templates loaded from server/templates/*.html at boot (see boot step).
CREATE TABLE IF NOT EXISTS app_templates (
    name    VARCHAR PRIMARY KEY,
    content VARCHAR NOT NULL
);
