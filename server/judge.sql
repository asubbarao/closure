-- judge.sql — 3-judge confidence ensemble (deterministic, no LLM).
-- Depends on: suggestions, entities, v_suggestions (detect.sql).
-- Product: confidence % + panel_signal (agree|split|conflict) + per-judge chips.
-- Ext: finetype types hard PII shapes (replaces digit-regex cascade).
-- kind strings load-bearing (SCHEMA_CONTRACT §1).

INSTALL finetype FROM community; LOAD finetype;

CREATE OR REPLACE TABLE judge_votes AS
WITH entity_docs AS (
    SELECT cast(entity_id AS VARCHAR) AS entity_id,
           count(DISTINCT document_id)::INTEGER AS doc_count
    FROM suggestions WHERE entity_id IS NOT NULL GROUP BY 1
),
feat AS (
    SELECT cast(s.id AS VARCHAR) AS suggestion_id, s.text, s.context, s.flag_tag,
           coalesce(e.kind, s.kind, '') AS kind,
           coalesce(ed.doc_count, 1)::INTEGER AS docs,
           (abs(hash(cast(s.id AS VARCHAR))) % 5)::INTEGER AS jitter,
           finetype([s.text]) AS ft,
           -- context cues (regex only for surrounding-word signals extensions miss)
           regexp_matches(coalesce(s.context, ''), '(?i)\sv\.\s|u\.s\.') AS ctx_cite,
           regexp_matches(coalesce(s.context, ''), '(?i)\bsubject\b|\bwitness\b|\bvictim\b|\bsuspect\b') AS ctx_subj,
           regexp_matches(coalesce(s.context, s.text, ''), '(?i)\bofc\.|\bdet\.|\bsgt\.|\bofficer of record\b') AS ctx_ofc,
           regexp_matches(coalesce(s.text, ''), '(?i)street|avenue|ave\b|blvd|road|drive|lane') AS txt_st,
           regexp_matches(coalesce(s.context, ''), '(?i)\bssn\b|social security|\bdob\b|\bborn\b|\bphone\b|\bcalled\b|\bcontact\b') AS ctx_id
    FROM suggestions s
    LEFT JOIN entities e ON cast(e.id AS VARCHAR) = cast(s.entity_id AS VARCHAR)
    LEFT JOIN entity_docs ed ON ed.entity_id = cast(s.entity_id AS VARCHAR)
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
SELECT
    b.suggestion_id, j.judge_id,
    CASE j.judge_id WHEN 1 THEN 'Pattern' WHEN 2 THEN 'Context' ELSE 'Prior' END AS judge_name,
    CASE j.judge_id
        WHEN 1 THEN 'pattern-match strength'
        WHEN 2 THEN 'surrounding-context'
        ELSE 'entity-type prior + cross-document corroboration'
    END AS factor,
    CASE j.judge_id
        WHEN 1 THEN CASE
            WHEN b.bucket IN ('ssn','phone','dob','address','person') THEN 'redact'
            WHEN b.bucket IN ('citation','street','officer','fp') THEN 'keep'
            ELSE 'unsure' END
        WHEN 2 THEN CASE
            WHEN b.bucket IN ('ssn','phone','dob','address') THEN 'redact'
            WHEN b.bucket IN ('citation','street','officer','fp') OR b.ctx_cite THEN 'keep'
            WHEN b.bucket = 'person' AND (b.ctx_cite OR b.txt_st OR b.ctx_ofc) THEN 'keep'
            WHEN b.bucket = 'person' AND b.ctx_subj THEN 'redact'
            WHEN b.bucket = 'person' THEN 'unsure'
            WHEN b.ctx_id THEN 'redact' ELSE 'unsure' END
        ELSE CASE
            WHEN b.bucket IN ('ssn','phone','dob','address') THEN 'redact'
            WHEN b.bucket = 'person' AND b.docs >= 2 THEN 'redact'
            WHEN b.bucket = 'person' THEN 'unsure'
            WHEN b.bucket IN ('street','citation','fp') THEN 'keep'
            WHEN b.bucket = 'officer' AND b.docs >= 3 THEN 'keep'
            WHEN b.bucket = 'officer' THEN 'unsure' ELSE 'unsure' END
    END AS verdict,
    least(99, CASE j.judge_id
        WHEN 1 THEN CASE b.bucket
            WHEN 'ssn' THEN 94 WHEN 'phone' THEN 90 WHEN 'dob' THEN 91
            WHEN 'address' THEN 86 WHEN 'person' THEN 82 WHEN 'citation' THEN 88
            WHEN 'street' THEN 78 WHEN 'officer' THEN 72 WHEN 'fp' THEN 70 ELSE 50
        END + b.jitter
        WHEN 2 THEN CASE
            WHEN b.bucket IN ('ssn','phone','dob') THEN 92 WHEN b.bucket = 'address' THEN 88
            WHEN b.bucket = 'citation' OR b.ctx_cite THEN 90 WHEN b.bucket = 'street' THEN 84
            WHEN b.bucket = 'officer' THEN 80 WHEN b.bucket = 'person' THEN 68 ELSE 55
        END + b.jitter
        ELSE CASE b.bucket
            WHEN 'ssn' THEN 96 + least(b.jitter, 2)
            WHEN 'phone' THEN 90 + b.jitter + least(b.docs, 3)
            WHEN 'dob' THEN 90 + b.jitter + least(b.docs, 3)
            WHEN 'person' THEN 70 + least(b.docs, 5) * 4 + b.jitter
            WHEN 'address' THEN 84 + b.jitter WHEN 'citation' THEN 86 + b.jitter
            WHEN 'street' THEN 74 + least(b.docs, 4) + b.jitter
            WHEN 'officer' THEN 62 + b.jitter ELSE 52 + b.jitter END
    END)::INTEGER AS score,
    CASE j.judge_id
        WHEN 1 THEN CASE b.bucket
            WHEN 'ssn' THEN 'hard SSN digit pattern' WHEN 'phone' THEN 'hard phone digit pattern'
            WHEN 'dob' THEN 'DOB pattern match' WHEN 'address' THEN 'address-shaped span'
            WHEN 'person' THEN 'person-name token shape' WHEN 'citation' THEN 'citation form, not subject PII'
            WHEN 'street' THEN 'street label, not a person' WHEN 'officer' THEN 'officer line, weak person pattern'
            WHEN 'fp' THEN 'seed-tagged non-PII pattern hit' ELSE 'weak / ambiguous pattern' END
        WHEN 2 THEN CASE
            WHEN b.bucket = 'ssn' THEN 'SSN kind — context does not override'
            WHEN b.bucket = 'phone' THEN 'phone kind — context does not override'
            WHEN b.bucket = 'dob' THEN 'DOB kind — context does not override'
            WHEN b.bucket = 'address' THEN 'address field context'
            WHEN b.bucket = 'citation' OR b.ctx_cite THEN 'citation wording in surrounding text'
            WHEN b.bucket = 'street' OR (b.bucket = 'person' AND b.txt_st) THEN 'street-name context, not subject'
            WHEN b.bucket = 'officer' OR (b.bucket = 'person' AND b.ctx_ofc) THEN 'officer/badge context'
            WHEN b.bucket = 'person' AND b.ctx_subj THEN 'subject/witness context nearby'
            WHEN b.bucket = 'person' THEN 'name needs human context call'
            WHEN b.bucket = 'fp' THEN 'seed-tagged non-PII context'
            WHEN b.ctx_id THEN 'identifier cue in surrounding text' ELSE 'context inconclusive' END
        ELSE CASE b.bucket
            WHEN 'ssn' THEN 'SSN prior: almost always redact'
            WHEN 'phone' THEN 'phone prior · seen in ' || b.docs || ' doc(s)'
            WHEN 'dob' THEN 'DOB prior: redact'
            WHEN 'person' THEN CASE WHEN b.docs >= 2
                THEN 'person prior · corroborated across ' || b.docs || ' docs'
                ELSE 'person prior · single-doc only' END
            WHEN 'address' THEN 'address prior: redact' WHEN 'citation' THEN 'citation prior: keep'
            WHEN 'street' THEN 'street-name prior · ' || b.docs || ' docs (often FP bait)'
            WHEN 'officer' THEN 'officer prior: usually not subject PII' ELSE 'no strong entity prior' END
    END AS reason
FROM buck b
CROSS JOIN UNNEST([1, 2, 3]) AS j(judge_id);

CREATE OR REPLACE VIEW v_judge_votes AS
SELECT suggestion_id, judge_id, judge_name, factor, verdict, score, reason FROM judge_votes;

-- Aggregate votes ONCE (no correlated subselects).
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

CREATE OR REPLACE VIEW v_suggestions_judged AS
SELECT s.*, p.confidence AS judge_confidence, p.panel_signal, p.judge_count,
       p.redact_votes, p.keep_votes, p.unsure_votes, p.judges,
       CASE WHEN p.panel_signal IN ('split', 'conflict') THEN 'flagged'
            WHEN p.confidence >= 90 THEN 'high'
            WHEN p.confidence >= 60 THEN 'review' ELSE 'flagged' END AS judge_band
FROM v_suggestions s
LEFT JOIN v_judge_panel p ON p.suggestion_id = s.id;

SELECT 'judge ensemble ready' AS status,
       (SELECT count(*) FROM judge_votes) AS votes,
       (SELECT count(*) FROM v_judge_panel) AS panels,
       (SELECT count(*) FILTER (WHERE panel_signal = 'agree') FROM v_judge_panel) AS agree_n,
       (SELECT count(*) FILTER (WHERE panel_signal = 'split') FROM v_judge_panel) AS split_n,
       (SELECT count(*) FILTER (WHERE panel_signal = 'conflict') FROM v_judge_panel) AS conflict_n;
