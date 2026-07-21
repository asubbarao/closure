-- judge.sql — 3-judge confidence ensemble (deterministic, no LLM).
-- Depends on: suggestions, entities, v_suggestions. Ext: finetype.
-- Product: confidence % + panel_signal + per-judge chips. Taxonomy is data.

INSTALL finetype FROM community; LOAD finetype;

CREATE OR REPLACE TABLE judge_rules AS
SELECT * FROM (VALUES
    (1, 'ssn',      'redact', 94, 4, 0, 0, 'hard SSN digit pattern'),
    (1, 'phone',    'redact', 90, 4, 0, 0, 'hard phone digit pattern'),
    (1, 'dob',      'redact', 91, 4, 0, 0, 'DOB pattern match'),
    (1, 'address',  'redact', 86, 4, 0, 0, 'address-shaped span'),
    (1, 'person',   'redact', 82, 4, 0, 0, 'person-name token shape'),
    (1, 'citation', 'keep',   88, 4, 0, 0, 'citation form, not subject PII'),
    (1, 'street',   'keep',   78, 4, 0, 0, 'street label, not a person'),
    (1, 'officer',  'keep',   72, 4, 0, 0, 'officer line, weak person pattern'),
    (1, 'fp',       'keep',   70, 4, 0, 0, 'seed-tagged non-PII pattern hit'),
    (1, 'other',    'unsure', 50, 4, 0, 0, 'weak / ambiguous pattern'),
    (2, 'ssn',      'redact', 92, 4, 0, 0, 'SSN kind — context does not override'),
    (2, 'phone',    'redact', 92, 4, 0, 0, 'phone kind — context does not override'),
    (2, 'dob',      'redact', 92, 4, 0, 0, 'DOB kind — context does not override'),
    (2, 'address',  'redact', 88, 4, 0, 0, 'address field context'),
    (2, 'person',   'unsure', 68, 4, 0, 0, 'name needs human context call'),
    (2, 'citation', 'keep',   90, 4, 0, 0, 'citation wording in surrounding text'),
    (2, 'street',   'keep',   84, 4, 0, 0, 'street-name context, not subject'),
    (2, 'officer',  'keep',   80, 4, 0, 0, 'officer/badge context'),
    (2, 'fp',       'keep',   55, 4, 0, 0, 'seed-tagged non-PII context'),
    (2, 'other',    'unsure', 55, 4, 0, 0, 'context inconclusive'),
    (3, 'ssn',      'redact', 96, 2, 0, 0, 'SSN prior: almost always redact'),
    (3, 'phone',    'redact', 90, 4, 3, 1, 'phone prior · seen in N doc(s)'),
    (3, 'dob',      'redact', 90, 4, 0, 0, 'DOB prior: redact'),
    (3, 'address',  'redact', 84, 4, 0, 0, 'address prior: redact'),
    (3, 'person',   'unsure', 70, 4, 5, 4, 'person prior · single-doc only'),
    (3, 'citation', 'keep',   86, 4, 0, 0, 'citation prior: keep'),
    (3, 'street',   'keep',   74, 4, 4, 1, 'street-name prior · N docs (often FP bait)'),
    (3, 'officer',  'unsure', 62, 4, 0, 0, 'officer prior: usually not subject PII'),
    (3, 'fp',       'keep',   52, 4, 0, 0, 'no strong entity prior'),
    (3, 'other',    'unsure', 52, 4, 0, 0, 'no strong entity prior')
) AS t(judge_id, bucket, verdict, base, jitter_cap, docs_cap, docs_mult, reason);

CREATE OR REPLACE TABLE judge_votes AS
WITH entity_docs AS (
    SELECT entity_id AS entity_id,
           count(DISTINCT document_id)::INTEGER AS doc_count
    FROM suggestions WHERE entity_id IS NOT NULL GROUP BY 1
),
feat AS (
    SELECT s.id AS suggestion_id, s.text, s.context, s.flag_tag,
           coalesce(e.kind, s.kind, '') AS kind,
           coalesce(ed.doc_count, 1)::INTEGER AS docs,
           (abs(hash(s.id)) % 5)::INTEGER AS jitter,
           finetype([s.text]) AS ft,
           regexp_matches(coalesce(s.context, ''), '(?i)\sv\.\s|u\.s\.') AS ctx_cite,
           regexp_matches(coalesce(s.context, ''), '(?i)\bsubject\b|\bwitness\b|\bvictim\b|\bsuspect\b') AS ctx_subj,
           regexp_matches(coalesce(s.context, s.text, ''), '(?i)\bofc\.|\bdet\.|\bsgt\.|\bofficer of record\b') AS ctx_ofc,
           regexp_matches(coalesce(s.text, ''), '(?i)street|avenue|ave\b|blvd|road|drive|lane') AS txt_st,
           regexp_matches(coalesce(s.context, ''), '(?i)\bssn\b|social security|\bdob\b|\bborn\b|\bphone\b|\bcalled\b|\bcontact\b') AS ctx_id
    FROM suggestions s
    LEFT JOIN entities e ON e.id = s.entity_id
    LEFT JOIN entity_docs ed ON ed.entity_id = s.entity_id
),
buck AS (
    SELECT *, CASE
        WHEN kind = 'SSN' OR ft LIKE 'identity.commerce.isbn%' THEN 'ssn'
        WHEN starts_with(kind, 'PHONE') OR ft LIKE '%phone%' THEN 'phone'
        WHEN kind = 'DATE OF BIRTH' OR ft LIKE 'datetime.date%' THEN 'dob'
        WHEN starts_with(kind, 'ADDRESS') THEN 'address'
        WHEN starts_with(kind, 'PERSON') THEN 'person'
        WHEN position('CITATION' IN kind) > 0 THEN 'citation'
        WHEN position('STREET' IN kind) > 0 THEN 'street'
        WHEN position('OFFICER' IN kind) > 0 THEN 'officer'
        WHEN flag_tag = 'false_positive' OR position('NOT PII' IN kind) > 0 THEN 'fp'
        ELSE 'other'
    END AS bucket FROM feat
)
SELECT b.suggestion_id, j.judge_id,
    CASE j.judge_id WHEN 1 THEN 'Pattern' WHEN 2 THEN 'Context' ELSE 'Prior' END AS judge_name,
    CASE j.judge_id
        WHEN 1 THEN 'pattern-match strength'
        WHEN 2 THEN 'surrounding-context'
        ELSE 'entity-type prior + cross-document corroboration'
    END AS factor,
    coalesce(
        CASE
            WHEN j.judge_id = 2 AND b.bucket NOT IN ('ssn','phone','dob','address') AND b.ctx_cite THEN 'keep'
            WHEN j.judge_id = 2 AND b.bucket = 'person' AND (b.ctx_cite OR b.txt_st OR b.ctx_ofc) THEN 'keep'
            WHEN j.judge_id = 2 AND b.bucket = 'person' AND b.ctx_subj THEN 'redact'
            WHEN j.judge_id = 2 AND b.bucket = 'person' THEN 'unsure'
            WHEN j.judge_id = 2 AND b.bucket = 'other' AND b.ctx_id THEN 'redact'
            WHEN j.judge_id = 3 AND b.bucket = 'person' AND b.docs >= 2 THEN 'redact'
            WHEN j.judge_id = 3 AND b.bucket = 'person' THEN 'unsure'
            WHEN j.judge_id = 3 AND b.bucket = 'officer' AND b.docs >= 3 THEN 'keep'
            WHEN j.judge_id = 3 AND b.bucket = 'officer' THEN 'unsure'
        END, r.verdict
    ) AS verdict,
    least(99,
        coalesce(CASE WHEN j.judge_id = 2 AND b.ctx_cite AND b.bucket NOT IN ('ssn','phone','dob','address')
                      THEN 90 END, r.base)
        + least(b.jitter, r.jitter_cap)
        + least(b.docs, r.docs_cap) * r.docs_mult
    )::INTEGER AS score,
    coalesce(
        CASE
            WHEN j.judge_id = 2 AND b.bucket NOT IN ('ssn','phone','dob','address') AND b.ctx_cite
                THEN 'citation wording in surrounding text'
            WHEN j.judge_id = 2 AND b.bucket = 'person' AND b.txt_st THEN 'street-name context, not subject'
            WHEN j.judge_id = 2 AND b.bucket = 'person' AND b.ctx_ofc THEN 'officer/badge context'
            WHEN j.judge_id = 2 AND b.bucket = 'person' AND b.ctx_subj THEN 'subject/witness context nearby'
            WHEN j.judge_id = 2 AND b.bucket = 'other' AND b.ctx_id THEN 'identifier cue in surrounding text'
            WHEN j.judge_id = 3 AND b.bucket = 'phone' THEN 'phone prior · seen in ' || b.docs || ' doc(s)'
            WHEN j.judge_id = 3 AND b.bucket = 'person' AND b.docs >= 2
                THEN 'person prior · corroborated across ' || b.docs || ' docs'
            WHEN j.judge_id = 3 AND b.bucket = 'person' THEN 'person prior · single-doc only'
            WHEN j.judge_id = 3 AND b.bucket = 'street'
                THEN 'street-name prior · ' || b.docs || ' docs (often FP bait)'
        END, r.reason
    ) AS reason
FROM buck b, UNNEST([1, 2, 3]) AS j(judge_id)
JOIN judge_rules r ON r.judge_id = j.judge_id AND r.bucket = b.bucket;

-- Consumer: /api/suggestions/:id/judges (routes/judge.sql).
CREATE OR REPLACE VIEW v_judge_panel AS
SELECT suggestion_id,
    round(avg(CASE verdict WHEN 'redact' THEN score WHEN 'keep' THEN 100 - score
                           WHEN 'unsure' THEN 48 + (score % 5) END))::INTEGER AS confidence,
    CASE WHEN bool_or(verdict = 'redact') AND bool_or(verdict = 'keep') THEN 'conflict'
         WHEN count(DISTINCT verdict) = 1 THEN 'agree' ELSE 'split' END AS panel_signal,
    count(*)::INTEGER AS judge_count,
    count(*) FILTER (WHERE verdict = 'redact')::INTEGER AS redact_votes,
    count(*) FILTER (WHERE verdict = 'keep')::INTEGER AS keep_votes,
    count(*) FILTER (WHERE verdict = 'unsure')::INTEGER AS unsure_votes,
    list(struct_pack(judge_id := judge_id, judge_name := judge_name, factor := factor,
                     verdict := verdict, score := score, reason := reason)
         ORDER BY judge_id) AS judges
FROM judge_votes GROUP BY suggestion_id;

SELECT 'judge ensemble ready' AS status,
       (SELECT count(*) FROM judge_votes) AS votes,
       (SELECT count(*) FROM v_judge_panel) AS panels;
