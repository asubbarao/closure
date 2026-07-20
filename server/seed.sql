-- seed.sql — "AI" redaction suggestions via pure CTAS.
-- Targets derive from samples/identities.json; boxes from words (read_pdf_words).
-- Matcher: consecutive same-line (y0 within 2pt) words whose qnorm equals target tokens.
-- Canonical forms only — spaced SSNs and misspelled witnesses are intentional FNs.
--
-- Runtime decisions: exports/decisions/*.json (one file per POST).
-- v_suggestions folds latest decision per suggestion_id; manual adds surface as source=manual.

-- ── target catalog (no hand-typed PII) ─────────────────────────────────────
CREATE OR REPLACE TABLE _seed_targets AS
WITH roster AS (
    SELECT
        ca.id AS case_id,
        cast(c.case_no AS VARCHAR) AS case_no,
        cast(c.subject.name AS VARCHAR) AS subject_name,
        cast(c.subject.ssn AS VARCHAR) AS subject_ssn,
        cast(c.subject.dob AS VARCHAR) AS subject_dob,
        cast(c.subject.address AS VARCHAR) AS subject_address,
        cast(c.subject.phone AS VARCHAR) AS subject_phone,
        c.witnesses,
        c.officers,
        cast(c.fp_street AS VARCHAR) AS fp_street,
        cast(c.fp_citation AS VARCHAR) AS fp_citation,
        regexp_extract(cast(c.subject.name AS VARCHAR), '(\S+)$', 1) AS subject_surname
    FROM (
        SELECT unnest(cases) AS c
        FROM read_json_auto('samples/identities.json')
    )
    JOIN cases ca ON ca.case_no = cast(c.case_no AS VARCHAR)
),
raw AS (
    SELECT case_id, subject_name AS phrase, 'PERSON · SUBJECT' AS kind,
           96 AS base_conf, NULL::VARCHAR AS reason, 'true_positive' AS bucket
    FROM roster
    UNION ALL
    SELECT case_id, subject_ssn, 'SSN', 97, NULL, 'true_positive' FROM roster
    UNION ALL
    SELECT case_id, subject_dob, 'DATE OF BIRTH', 95, NULL, 'true_positive' FROM roster
    UNION ALL
    SELECT case_id, subject_phone, 'PHONE · SUBJECT', 94, NULL, 'true_positive' FROM roster
    UNION ALL
    SELECT case_id,
           array_to_string(list_slice(string_split(subject_address, ' '), 1, 3), ' '),
           'ADDRESS · SUBJECT', 93, NULL, 'true_positive'
    FROM roster
    UNION ALL
    SELECT case_id, cast(w.name AS VARCHAR), 'PERSON · WITNESS', 94, NULL, 'true_positive'
    FROM roster, unnest(witnesses) AS t(w)
    UNION ALL
    SELECT case_id, cast(w.phone AS VARCHAR), 'PHONE · WITNESS', 95, NULL, 'true_positive'
    FROM roster, unnest(witnesses) AS t(w)
    UNION ALL
    SELECT case_id, fp_street, 'STREET NAME · NOT PII', 71,
           'matched PERSON pattern on the surname but context is a street address',
           'false_positive'
    FROM roster
    WHERE fp_street IS NOT NULL AND fp_street <> ''
    UNION ALL
    SELECT case_id,
           array_to_string(list_slice(string_split(fp_citation, ' '), 1, 3), ' '),
           'CITATION · NOT PII', 58,
           'published case citation',
           'false_positive'
    FROM roster
    WHERE fp_citation IS NOT NULL AND fp_citation <> ''
    UNION ALL
    SELECT case_id, cast(o AS VARCHAR), 'OFFICER · NOT SUBJECT PII', 64,
           'officer of record, not the subject',
           'false_positive'
    FROM roster, unnest(officers) AS t(o)
    WHERE position(subject_surname IN cast(o AS VARCHAR)) > 0
),
tokenized AS (
    SELECT
        case_id,
        phrase,
        kind,
        base_conf,
        reason,
        bucket,
        list_transform(string_split(trim(phrase), ' '), lambda x: qnorm(x)) AS tokens
    FROM raw
    WHERE phrase IS NOT NULL AND trim(phrase) <> ''
)
SELECT
    row_number() OVER (ORDER BY case_id, kind, phrase)::INTEGER AS target_id,
    case_id,
    phrase,
    kind,
    base_conf,
    reason,
    bucket,
    tokens,
    len(tokens)::INTEGER AS n_tokens,
    array_to_string(tokens, ' ') AS text_norm
FROM tokenized
WHERE len(tokens) BETWEEN 1 AND 4;

-- ── match targets against same-line word n-grams ───────────────────────────
CREATE OR REPLACE TABLE _seed_hits AS
SELECT
    t.target_id,
    t.case_id,
    t.phrase,
    t.kind,
    t.base_conf,
    t.reason,
    t.bucket,
    t.n_tokens,
    g.document_id,
    g.page_no,
    g.seq AS start_seq,
    g.text_raw,
    g.x0,
    g.y0,
    g.x1,
    g.y1
FROM _seed_targets t
JOIN documents d ON d.case_id = t.case_id
JOIN v_grams g
  ON g.document_id = d.id
 AND g.n = t.n_tokens
 AND g.text_norm = t.text_norm;

-- ── context snippets (±6 surrounding words on the page) ───────────────────
CREATE OR REPLACE TABLE _seed_context AS
SELECT
    h.document_id,
    h.page_no,
    h.start_seq,
    h.n_tokens,
    string_agg(w.word, ' ' ORDER BY w.seq) AS context
FROM _seed_hits h
JOIN words w
  ON w.document_id = h.document_id
 AND w.page_no = h.page_no
 AND w.seq BETWEEN h.start_seq - 6 AND h.start_seq + h.n_tokens + 5
GROUP BY h.document_id, h.page_no, h.start_seq, h.n_tokens;

-- ── suggestions (CTAS) ─────────────────────────────────────────────────────
CREATE OR REPLACE TABLE suggestions AS
SELECT
    row_number() OVER (
        ORDER BY h.document_id, h.page_no, h.start_seq, h.target_id
    )::INTEGER AS id,
    h.document_id,
    h.page_no,
    h.x0,
    h.y0,
    h.x1,
    h.y1,
    h.phrase AS text,
    coalesce(c.context, h.text_raw) AS context,
    least(99, greatest(1,
        h.base_conf
        + (abs(hash(h.document_id || ':' || h.page_no || ':' || h.start_seq || ':' || h.phrase)) % 5)
        - 2
    ))::INTEGER AS confidence,
    CASE WHEN h.bucket = 'false_positive' THEN 'false_positive' ELSE NULL END AS flag_tag,
    h.reason,
    e.id AS entity_id,
    'ai' AS source,
    now() AS created_at
FROM _seed_hits h
LEFT JOIN _seed_context c
  ON c.document_id = h.document_id
 AND c.page_no = h.page_no
 AND c.start_seq = h.start_seq
 AND c.n_tokens = h.n_tokens
LEFT JOIN entities e
  ON e.case_id = h.case_id
 AND e.kind = h.kind
 AND (
        e.canonical_text = h.phrase
     OR starts_with(e.canonical_text, h.phrase)
     OR starts_with(h.phrase, e.canonical_text)
 );

-- ── decision log from exports/decisions/*.json (sentinel present at boot) ──
-- kind: decision | added | sentinel
-- Use columns= to force a stable schema even when only the sentinel file exists.
CREATE OR REPLACE VIEW v_decision_log AS
SELECT
    coalesce(filename, '') AS _file,
    cast(kind AS VARCHAR) AS kind,
    try_cast(suggestion_id AS BIGINT)::INTEGER AS suggestion_id,
    cast(status AS VARCHAR) AS status,
    cast(actor AS VARCHAR) AS actor,
    cast(reason AS VARCHAR) AS reason,
    try_cast(ts AS TIMESTAMP) AS ts,
    try_cast(document_id AS BIGINT)::INTEGER AS document_id,
    try_cast(page_no AS BIGINT)::INTEGER AS page_no,
    try_cast(x0 AS DOUBLE) AS x0,
    try_cast(y0 AS DOUBLE) AS y0,
    try_cast(x1 AS DOUBLE) AS x1,
    try_cast(y1 AS DOUBLE) AS y1,
    cast(text AS VARCHAR) AS text,
    cast(context AS VARCHAR) AS context,
    try_cast(confidence AS BIGINT)::INTEGER AS confidence,
    cast(flag_tag AS VARCHAR) AS flag_tag,
    cast(source AS VARCHAR) AS source,
    try_cast(entity_id AS BIGINT)::INTEGER AS entity_id,
    try_cast(case_id AS BIGINT)::INTEGER AS case_id
FROM read_json(
    'exports/decisions/*.json',
    format := 'auto',
    ignore_errors := true,
    union_by_name := true,
    filename := true,
    columns := {
        'kind': 'VARCHAR',
        'suggestion_id': 'BIGINT',
        'status': 'VARCHAR',
        'actor': 'VARCHAR',
        'reason': 'VARCHAR',
        'ts': 'VARCHAR',
        'document_id': 'BIGINT',
        'page_no': 'BIGINT',
        'x0': 'DOUBLE',
        'y0': 'DOUBLE',
        'x1': 'DOUBLE',
        'y1': 'DOUBLE',
        'text': 'VARCHAR',
        'context': 'VARCHAR',
        'confidence': 'BIGINT',
        'flag_tag': 'VARCHAR',
        'source': 'VARCHAR',
        'entity_id': 'BIGINT',
        'case_id': 'BIGINT'
    }
)
WHERE kind IS NULL OR kind <> 'sentinel';
-- Latest decision status per suggestion_id
CREATE OR REPLACE VIEW v_latest_decision AS
SELECT suggestion_id, status, actor, reason, ts
FROM (
    SELECT
        suggestion_id,
        status,
        actor,
        reason,
        ts,
        row_number() OVER (
            PARTITION BY suggestion_id
            ORDER BY coalesce(ts, TIMESTAMP '1970-01-01') DESC, _file DESC
        ) AS rn
    FROM v_decision_log
    WHERE kind = 'decision' AND suggestion_id IS NOT NULL
) z
WHERE rn = 1;

-- Manual adds surface as suggestions (source=manual, born accepted)
CREATE OR REPLACE VIEW v_manual_suggestions AS
SELECT
    suggestion_id AS id,
    document_id,
    page_no,
    x0, y0, x1, y1,
    text,
    coalesce(context, text) AS context,
    coalesce(confidence, 99) AS confidence,
    flag_tag,
    reason,
    entity_id,
    'manual' AS source,
    coalesce(ts, now()) AS created_at
FROM (
    SELECT
        *,
        row_number() OVER (
            PARTITION BY suggestion_id
            ORDER BY coalesce(ts, TIMESTAMP '1970-01-01') DESC, _file DESC
        ) AS rn
    FROM v_decision_log
    WHERE kind = 'added' AND suggestion_id IS NOT NULL
) z
WHERE rn = 1;

-- ── status projection: latest decision wins; manual→accepted, ai→pending ──
CREATE OR REPLACE VIEW v_suggestions AS
WITH base AS (
    SELECT
        s.id, s.document_id, s.page_no, s.x0, s.y0, s.x1, s.y1,
        s.text, s.context, s.confidence, s.flag_tag, s.reason,
        s.entity_id, s.source, s.created_at
    FROM suggestions s
    UNION ALL BY NAME
    SELECT
        m.id, m.document_id, m.page_no, m.x0, m.y0, m.x1, m.y1,
        m.text, m.context, m.confidence, m.flag_tag, m.reason,
        m.entity_id, m.source, m.created_at
    FROM v_manual_suggestions m
)
SELECT
    b.*,
    e.kind,
    e.canonical_text AS entity_text,
    coalesce(
        ld.status,
        CASE b.source WHEN 'manual' THEN 'accepted' ELSE 'pending' END
    ) AS status,
    CASE WHEN b.confidence >= 90 THEN 'high'
         WHEN b.confidence >= 60 THEN 'review'
         ELSE 'flagged' END AS band
FROM base b
LEFT JOIN entities e ON e.id = b.entity_id
LEFT JOIN v_latest_decision ld ON ld.suggestion_id = b.id;

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

-- drop seed scratch
DROP TABLE IF EXISTS _seed_context;
DROP TABLE IF EXISTS _seed_hits;
DROP TABLE IF EXISTS _seed_targets;

SELECT 'seed complete' AS status,
       (SELECT count(*) FROM suggestions) AS suggestions,
       (SELECT count(*) FROM suggestions WHERE flag_tag = 'false_positive') AS false_positives,
       (SELECT count(*) FROM v_decision_log WHERE kind = 'decision') AS decisions;
