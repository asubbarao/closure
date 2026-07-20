-- judge.sql — confidence as a simulated 2–3 judge ensemble (pure CTAS + views).
-- Depends on: suggestions, entities, documents, v_suggestions (from seed.sql).
--
-- Product model: humans do not read walls of rationale. They need a confidence %
-- plus a one-word panel signal (agree / split / conflict). Split + conflict are
-- the triage queue. Per-judge votes stay available on demand (2–3 short lines).
--
-- Deterministic: every score is pure SQL over suggestion_id / text / kind / context.
-- No LLM. No LIKE. No runtime writes.

DROP VIEW IF EXISTS v_suggestions_judged CASCADE;
DROP VIEW IF EXISTS v_judge_panel CASCADE;
DROP VIEW IF EXISTS v_judge_votes CASCADE;
DROP TABLE IF EXISTS judge_votes CASCADE;
DROP TABLE IF EXISTS _judge_entity_docs CASCADE;
DROP TABLE IF EXISTS _judge_base CASCADE;

-- Cross-document corroboration: how many docs host each entity (from suggestions).
CREATE OR REPLACE TABLE _judge_entity_docs AS
SELECT
    s.entity_id,
    count(DISTINCT s.document_id)::INTEGER AS doc_count,
    count(*)::INTEGER AS hit_count
FROM suggestions s
WHERE s.entity_id IS NOT NULL
GROUP BY s.entity_id;

-- Suggestion rows with kind + context features the judges share.
CREATE OR REPLACE TABLE _judge_base AS
SELECT
    s.id AS suggestion_id,
    s.document_id,
    s.text,
    s.context,
    s.confidence AS seed_confidence,
    s.flag_tag,
    s.entity_id,
    e.kind,
    coalesce(ed.doc_count, 1)::INTEGER AS entity_doc_count,
    coalesce(ed.hit_count, 1)::INTEGER AS entity_hit_count,
    -- Stable 0–4 jitter from suggestion id (not random; same every boot).
    (abs(hash(cast(s.id AS VARCHAR))) % 5)::INTEGER AS jitter
FROM suggestions s
LEFT JOIN entities e ON e.id = s.entity_id
LEFT JOIN _judge_entity_docs ed ON ed.entity_id = s.entity_id;

-- ── three judges × every suggestion ────────────────────────────────────────
-- Each vote: (verdict: redact|keep|unsure, score 0–100 strength, one-line reason).
-- Factors: pattern-match strength | surrounding-context | entity-type prior
--          (judge 3 also folds cross-document corroboration).

CREATE OR REPLACE TABLE judge_votes AS
WITH
-- Judge 1 — Pattern: how strongly the span itself looks like protectable PII.
pattern_judge AS (
    SELECT
        b.suggestion_id,
        1::INTEGER AS judge_id,
        'Pattern' AS judge_name,
        'pattern-match strength' AS factor,
        CASE
            WHEN b.kind = 'SSN'
              OR regexp_matches(b.text, '^[0-9]{3}[-.][0-9]{2}[-.][0-9]{4}$')
                THEN 'redact'
            WHEN starts_with(coalesce(b.kind, ''), 'PHONE')
              OR regexp_matches(b.text, '^\([0-9]{3}\)\s*[0-9]{3}-[0-9]{4}$')
              OR regexp_matches(b.text, '^[0-9]{3}[.-][0-9]{3}[.-][0-9]{4}$')
                THEN 'redact'
            WHEN b.kind = 'DATE OF BIRTH'
              OR regexp_matches(b.text, '^[0-9]{2}/[0-9]{2}/[0-9]{4}$')
                THEN 'redact'
            WHEN starts_with(coalesce(b.kind, ''), 'ADDRESS')
                THEN 'redact'
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON')
                THEN 'redact'
            WHEN position('NOT PII' IN coalesce(b.kind, '')) > 0
              OR b.flag_tag = 'false_positive'
                THEN 'keep'
            ELSE 'unsure'
        END AS verdict,
        CASE
            WHEN b.kind = 'SSN'
              OR regexp_matches(b.text, '^[0-9]{3}[-.][0-9]{2}[-.][0-9]{4}$')
                THEN least(99, 94 + b.jitter)
            WHEN starts_with(coalesce(b.kind, ''), 'PHONE')
              OR regexp_matches(b.text, '^\([0-9]{3}\)\s*[0-9]{3}-[0-9]{4}$')
              OR regexp_matches(b.text, '^[0-9]{3}[.-][0-9]{3}[.-][0-9]{4}$')
                THEN least(99, 90 + b.jitter)
            WHEN b.kind = 'DATE OF BIRTH'
                THEN least(99, 91 + b.jitter)
            WHEN starts_with(coalesce(b.kind, ''), 'ADDRESS')
                THEN least(99, 86 + b.jitter)
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON')
                THEN least(99, 82 + b.jitter)
            WHEN position('CITATION' IN coalesce(b.kind, '')) > 0
                THEN least(99, 88 + b.jitter)
            WHEN position('STREET' IN coalesce(b.kind, '')) > 0
                THEN least(99, 78 + b.jitter)
            WHEN position('OFFICER' IN coalesce(b.kind, '')) > 0
                THEN least(99, 72 + b.jitter)
            WHEN b.flag_tag = 'false_positive'
                THEN least(99, 70 + b.jitter)
            ELSE 50 + b.jitter
        END::INTEGER AS score,
        CASE
            WHEN b.kind = 'SSN'
              OR regexp_matches(b.text, '^[0-9]{3}[-.][0-9]{2}[-.][0-9]{4}$')
                THEN 'hard SSN digit pattern'
            WHEN starts_with(coalesce(b.kind, ''), 'PHONE')
              OR regexp_matches(b.text, '^\([0-9]{3}\)\s*[0-9]{3}-[0-9]{4}$')
              OR regexp_matches(b.text, '^[0-9]{3}[.-][0-9]{3}[.-][0-9]{4}$')
                THEN 'hard phone digit pattern'
            WHEN b.kind = 'DATE OF BIRTH'
                THEN 'DOB pattern match'
            WHEN starts_with(coalesce(b.kind, ''), 'ADDRESS')
                THEN 'address-shaped span'
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON')
                THEN 'person-name token shape'
            WHEN position('CITATION' IN coalesce(b.kind, '')) > 0
                THEN 'citation form, not subject PII'
            WHEN position('STREET' IN coalesce(b.kind, '')) > 0
                THEN 'street label, not a person'
            WHEN position('OFFICER' IN coalesce(b.kind, '')) > 0
                THEN 'officer line, weak person pattern'
            WHEN b.flag_tag = 'false_positive'
                THEN 'seed-tagged non-PII pattern hit'
            ELSE 'weak / ambiguous pattern'
        END AS reason
    FROM _judge_base b
),
-- Judge 2 — Context: surrounding words change the call.
-- Hard identifier kinds win first so "reporting officer recorded SSN …" stays redact.
context_judge AS (
    SELECT
        b.suggestion_id,
        2::INTEGER AS judge_id,
        'Context' AS judge_name,
        'surrounding-context' AS factor,
        CASE
            -- Hard PII kinds: context almost never overrides.
            WHEN b.kind = 'SSN'
              OR starts_with(coalesce(b.kind, ''), 'PHONE')
              OR b.kind = 'DATE OF BIRTH'
                THEN 'redact'
            WHEN starts_with(coalesce(b.kind, ''), 'ADDRESS')
                THEN 'redact'
            -- Explicit non-PII kinds.
            WHEN position('CITATION' IN coalesce(b.kind, '')) > 0
              OR regexp_matches(coalesce(b.context, ''), '(?i)\sv\.\s|u\.s\.')
                THEN 'keep'
            WHEN position('STREET' IN coalesce(b.kind, '')) > 0
                THEN 'keep'
            WHEN position('OFFICER' IN coalesce(b.kind, '')) > 0
                THEN 'keep'
            -- Person names: citation / officer / street context → keep; identity cues → redact.
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON')
             AND regexp_matches(coalesce(b.context, ''), '(?i)\sv\.\s|u\.s\.')
                THEN 'keep'
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON')
             AND regexp_matches(coalesce(b.text, ''), '(?i)street|avenue|ave\b|blvd|road|drive|lane')
                THEN 'keep'
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON')
             AND regexp_matches(coalesce(b.context, b.text, ''), '(?i)\bofc\.|\bdet\.|\bsgt\.|\bofficer of record\b')
                THEN 'keep'
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON')
             AND regexp_matches(coalesce(b.context, ''), '(?i)\bsubject\b|\bwitness\b|\bvictim\b|\bsuspect\b')
                THEN 'redact'
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON')
                THEN 'unsure'
            WHEN b.flag_tag = 'false_positive'
              OR position('NOT PII' IN coalesce(b.kind, '')) > 0
                THEN 'keep'
            WHEN regexp_matches(coalesce(b.context, ''), '(?i)\bssn\b|social security|\bdob\b|\bborn\b|\bphone\b|\bcalled\b|\bcontact\b')
                THEN 'redact'
            ELSE 'unsure'
        END AS verdict,
        CASE
            WHEN b.kind = 'SSN' OR starts_with(coalesce(b.kind, ''), 'PHONE') OR b.kind = 'DATE OF BIRTH'
                THEN least(99, 92 + b.jitter)
            WHEN starts_with(coalesce(b.kind, ''), 'ADDRESS')
                THEN least(99, 88 + b.jitter)
            WHEN position('CITATION' IN coalesce(b.kind, '')) > 0
              OR regexp_matches(coalesce(b.context, ''), '(?i)\sv\.\s|u\.s\.')
                THEN least(99, 90 + b.jitter)
            WHEN position('STREET' IN coalesce(b.kind, '')) > 0
                THEN least(99, 84 + b.jitter)
            WHEN position('OFFICER' IN coalesce(b.kind, '')) > 0
                THEN least(99, 80 + b.jitter)
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON')
                THEN least(99, 68 + b.jitter)
            ELSE 55 + b.jitter
        END::INTEGER AS score,
        CASE
            WHEN b.kind = 'SSN'
                THEN 'SSN kind — context does not override'
            WHEN starts_with(coalesce(b.kind, ''), 'PHONE')
                THEN 'phone kind — context does not override'
            WHEN b.kind = 'DATE OF BIRTH'
                THEN 'DOB kind — context does not override'
            WHEN starts_with(coalesce(b.kind, ''), 'ADDRESS')
                THEN 'address field context'
            WHEN position('CITATION' IN coalesce(b.kind, '')) > 0
              OR regexp_matches(coalesce(b.context, ''), '(?i)\sv\.\s|u\.s\.')
                THEN 'citation wording in surrounding text'
            WHEN position('STREET' IN coalesce(b.kind, '')) > 0
                THEN 'street-name context, not subject'
            WHEN position('OFFICER' IN coalesce(b.kind, '')) > 0
                THEN 'officer/badge context'
            -- Mirror verdict order for PERSON so reason never contradicts vote.
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON')
             AND regexp_matches(coalesce(b.context, ''), '(?i)\sv\.\s|u\.s\.')
                THEN 'citation wording in surrounding text'
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON')
             AND regexp_matches(coalesce(b.text, ''), '(?i)street|avenue|ave\b|blvd|road|drive|lane')
                THEN 'street-name token, not a person'
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON')
             AND regexp_matches(coalesce(b.context, b.text, ''), '(?i)\bofc\.|\bdet\.|\bsgt\.|\bofficer of record\b')
                THEN 'officer/badge context'
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON')
             AND regexp_matches(coalesce(b.context, ''), '(?i)\bsubject\b|\bwitness\b|\bvictim\b|\bsuspect\b')
                THEN 'subject/witness context nearby'
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON')
                THEN 'name needs human context call'
            WHEN b.flag_tag = 'false_positive'
              OR position('NOT PII' IN coalesce(b.kind, '')) > 0
                THEN 'seed-tagged non-PII context'
            WHEN regexp_matches(coalesce(b.context, ''), '(?i)\bssn\b|social security|\bdob\b|\bborn\b|\bphone\b|\bcalled\b|\bcontact\b')
                THEN 'identifier cue in surrounding text'
            ELSE 'context inconclusive'
        END AS reason
    FROM _judge_base b
),
-- Judge 3 — Prior + corroboration: entity-type base rate × multi-doc support.
prior_judge AS (
    SELECT
        b.suggestion_id,
        3::INTEGER AS judge_id,
        'Prior' AS judge_name,
        'entity-type prior + cross-document corroboration' AS factor,
        CASE
            WHEN b.kind = 'SSN' OR starts_with(coalesce(b.kind, ''), 'PHONE') OR b.kind = 'DATE OF BIRTH'
                THEN 'redact'
            WHEN starts_with(coalesce(b.kind, ''), 'ADDRESS')
                THEN 'redact'
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON') AND b.entity_doc_count >= 2
                THEN 'redact'
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON') AND b.entity_doc_count = 1
                THEN 'unsure'
            WHEN position('STREET' IN coalesce(b.kind, '')) > 0
                THEN 'keep'
            WHEN position('CITATION' IN coalesce(b.kind, '')) > 0
                THEN 'keep'
            WHEN position('OFFICER' IN coalesce(b.kind, '')) > 0
                THEN CASE WHEN b.entity_doc_count >= 3 THEN 'keep' ELSE 'unsure' END
            WHEN b.flag_tag = 'false_positive'
                THEN 'keep'
            ELSE 'unsure'
        END AS verdict,
        CASE
            WHEN b.kind = 'SSN'
                THEN least(99, 96 + least(b.jitter, 2))
            WHEN starts_with(coalesce(b.kind, ''), 'PHONE') OR b.kind = 'DATE OF BIRTH'
                THEN least(99, 90 + b.jitter + least(b.entity_doc_count, 3))
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON')
                THEN least(99, 70 + least(b.entity_doc_count, 5) * 4 + b.jitter)
            WHEN starts_with(coalesce(b.kind, ''), 'ADDRESS')
                THEN least(99, 84 + b.jitter)
            WHEN position('CITATION' IN coalesce(b.kind, '')) > 0
                THEN least(99, 86 + b.jitter)
            WHEN position('STREET' IN coalesce(b.kind, '')) > 0
                THEN least(99, 74 + least(b.entity_doc_count, 4) + b.jitter)
            WHEN position('OFFICER' IN coalesce(b.kind, '')) > 0
                THEN least(99, 62 + b.jitter)
            ELSE 52 + b.jitter
        END::INTEGER AS score,
        CASE
            WHEN b.kind = 'SSN'
                THEN 'SSN prior: almost always redact'
            WHEN starts_with(coalesce(b.kind, ''), 'PHONE')
                THEN 'phone prior · seen in ' || b.entity_doc_count || ' doc(s)'
            WHEN b.kind = 'DATE OF BIRTH'
                THEN 'DOB prior: redact'
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON') AND b.entity_doc_count >= 2
                THEN 'person prior · corroborated across ' || b.entity_doc_count || ' docs'
            WHEN starts_with(coalesce(b.kind, ''), 'PERSON')
                THEN 'person prior · single-doc only'
            WHEN starts_with(coalesce(b.kind, ''), 'ADDRESS')
                THEN 'address prior: redact'
            WHEN position('CITATION' IN coalesce(b.kind, '')) > 0
                THEN 'citation prior: keep'
            WHEN position('STREET' IN coalesce(b.kind, '')) > 0
                THEN 'street-name prior · ' || b.entity_doc_count || ' docs (often FP bait)'
            WHEN position('OFFICER' IN coalesce(b.kind, '')) > 0
                THEN 'officer prior: usually not subject PII'
            ELSE 'no strong entity prior'
        END AS reason
    FROM _judge_base b
)
SELECT * FROM pattern_judge
UNION ALL BY NAME
SELECT * FROM context_judge
UNION ALL BY NAME
SELECT * FROM prior_judge
ORDER BY suggestion_id, judge_id;

-- Flat votes for on-demand UI breakdown.
CREATE OR REPLACE VIEW v_judge_votes AS
SELECT
    suggestion_id,
    judge_id,
    judge_name,
    factor,
    verdict,
    score,
    reason
FROM judge_votes;

-- One row per suggestion: blended confidence + panel signal + judge list.
CREATE OR REPLACE VIEW v_judge_panel AS
SELECT
    j.suggestion_id,
    round(avg(
        CASE j.verdict
            WHEN 'redact' THEN j.score
            WHEN 'keep'   THEN 100 - j.score
            WHEN 'unsure' THEN 48 + (j.score % 5)
        END
    ))::INTEGER AS confidence,
    CASE
        WHEN bool_or(j.verdict = 'redact') AND bool_or(j.verdict = 'keep') THEN 'conflict'
        WHEN count(DISTINCT j.verdict) = 1 THEN 'agree'
        ELSE 'split'
    END AS panel_signal,
    count(*)::INTEGER AS judge_count,
    count(*) FILTER (WHERE j.verdict = 'redact')::INTEGER AS redact_votes,
    count(*) FILTER (WHERE j.verdict = 'keep')::INTEGER AS keep_votes,
    count(*) FILTER (WHERE j.verdict = 'unsure')::INTEGER AS unsure_votes,
    list(
        struct_pack(
            judge_id := j.judge_id,
            judge_name := j.judge_name,
            factor := j.factor,
            verdict := j.verdict,
            score := j.score,
            reason := j.reason
        )
        ORDER BY j.judge_id
    ) AS judges
FROM judge_votes j
GROUP BY j.suggestion_id;

-- Convenience join: live suggestion status + judge ensemble (consumers use this).
CREATE OR REPLACE VIEW v_suggestions_judged AS
SELECT
    s.*,
    p.confidence AS judge_confidence,
    p.panel_signal,
    p.judge_count,
    p.redact_votes,
    p.keep_votes,
    p.unsure_votes,
    p.judges,
    -- Human triage band from the ensemble (same thresholds as seed bands).
    CASE
        WHEN p.panel_signal IN ('split', 'conflict') THEN 'flagged'
        WHEN p.confidence >= 90 THEN 'high'
        WHEN p.confidence >= 60 THEN 'review'
        ELSE 'flagged'
    END AS judge_band
FROM v_suggestions s
LEFT JOIN v_judge_panel p ON p.suggestion_id = s.id;

-- Scratch not needed at runtime.
DROP TABLE IF EXISTS _judge_base;
DROP TABLE IF EXISTS _judge_entity_docs;

SELECT 'judge ensemble ready' AS status,
       (SELECT count(*) FROM judge_votes) AS votes,
       (SELECT count(*) FROM v_judge_panel) AS panels,
       (SELECT count(*) FROM v_judge_panel WHERE panel_signal = 'agree') AS agree_n,
       (SELECT count(*) FROM v_judge_panel WHERE panel_signal = 'split') AS split_n,
       (SELECT count(*) FROM v_judge_panel WHERE panel_signal = 'conflict') AS conflict_n;
