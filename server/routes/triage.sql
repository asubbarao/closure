-- routes/triage.sql — funnel: high-conf auto-pass + residual groups.
-- Spine: v_suggestions, documents. Mutations COPY → exports/decisions.
-- Auto-pass: pending ∧ conf≥thr ∧ band≠flagged ∧ flag_tag≠false_positive.
-- group_key: e:{entity_id} else t:{lower(text)}|{kind}. $id = case_no VARCHAR.
-- PARAM DEFAULTs bind when absent — no coalesce($param, default). Threshold
-- clamped at bind: GE 0 LE 100 → 422 if out of range.

CREATE OR REPLACE ROUTE api_case_triage GET '/api/cases/:id/triage'
  PARAM threshold INTEGER DEFAULT 90 GE 0 LE 100
AS
WITH marked AS (
    SELECT s.status, s.band, s.confidence, s.flag_tag, s.entity_id, s.text, s.kind,
           s.group_key,
           CASE
               WHEN s.status = 'pending'
                AND s.confidence >= $threshold
                AND s.band <> 'flagged'
                AND coalesce(s.flag_tag, '') <> 'false_positive'
               THEN 'auto'
               WHEN s.status = 'pending' THEN 'residual'
               ELSE 'done'
           END AS funnel
    FROM v_suggestions s
    JOIN documents d ON d.id = s.document_id
    WHERE d.case_id = $id
),
-- Tall grain first (funnel × status × band), then one-row map — no FILTER laundry.
counts_tall AS (
    SELECT funnel, status, band, count(*)::BIGINT AS n
    FROM marked
    GROUP BY ALL
),
counts AS (
    SELECT
        coalesce((SELECT sum(n) FROM counts_tall), 0)::BIGINT AS total,
        coalesce((SELECT sum(n) FROM counts_tall
                  WHERE status IN ('accepted', 'rejected')), 0)::BIGINT AS resolved,
        coalesce((SELECT sum(n) FROM counts_tall WHERE status = 'pending'), 0)::BIGINT AS pending,
        coalesce((SELECT sum(n) FROM counts_tall WHERE funnel = 'auto'), 0)::BIGINT AS auto_passable,
        coalesce((SELECT sum(n) FROM counts_tall WHERE funnel = 'residual'), 0)::BIGINT AS residual,
        coalesce((SELECT sum(n) FROM counts_tall
                  WHERE status = 'pending' AND band = 'high'), 0)::BIGINT AS high_pending,
        coalesce((SELECT sum(n) FROM counts_tall
                  WHERE status = 'pending' AND band = 'review'), 0)::BIGINT AS review_pending,
        coalesce((SELECT sum(n) FROM counts_tall
                  WHERE status = 'pending' AND band = 'flagged'), 0)::BIGINT AS flagged_pending
),
bulk AS (
    SELECT coalesce(sum(n), 0)::BIGINT AS residual_bulk_eligible
    FROM (
        SELECT count(*) AS n FROM marked WHERE funnel = 'residual'
        GROUP BY group_key
        HAVING count(*) > 1
    ) group_sizes
)
SELECT $id AS case_id, $threshold AS threshold,
       c.total, c.resolved, c.pending, c.auto_passable, c.residual,
       c.high_pending, c.review_pending, c.flagged_pending,
       (SELECT residual_bulk_eligible FROM bulk) AS residual_bulk_eligible,
       CASE WHEN c.total = 0 THEN 0
            ELSE round(100.0 * c.resolved / c.total, 0)::INTEGER END AS progress_pct
FROM counts c;

CREATE OR REPLACE ROUTE api_case_triage_groups GET '/api/cases/:id/triage/groups'
  PARAM threshold INTEGER DEFAULT 90 GE 0 LE 100
  PARAM scope VARCHAR DEFAULT 'case'
  PARAM doc_id VARCHAR DEFAULT ''
AS
WITH residual AS (
    SELECT s.id, s.document_id, s.page_no, s.text, s.context, s.confidence,
           s.band, s.kind, s.entity_id, s.entity_text, s.flag_tag, s.reason, d.filename,
           s.group_key,
           coalesce(nullif(s.entity_text, ''), s.text, '(unknown)') AS group_label
    FROM v_suggestions s
    JOIN documents d ON d.id = s.document_id
    WHERE d.case_id = $id AND s.status = 'pending'
      AND NOT (s.confidence >= $threshold
               AND s.band <> 'flagged' AND coalesce(s.flag_tag, '') <> 'false_positive')
      AND CASE
            WHEN lower($scope) <> 'doc' THEN true
            WHEN $doc_id IN ('', '0') THEN true
            ELSE s.document_id = $doc_id
          END
)
SELECT group_key, any_value(group_label) AS group_label, any_value(kind) AS kind,
       any_value(entity_id) AS entity_id, count(*)::BIGINT AS n,
       count(DISTINCT document_id)::BIGINT AS doc_count,
       count(DISTINCT page_no)::BIGINT AS page_count,
       min(confidence)::INTEGER AS min_conf, max(confidence)::INTEGER AS max_conf,
       bool_or(band = 'flagged') AS has_flagged,
       bool_or(coalesce(flag_tag, '') = 'false_positive') AS has_fp,
       any_value(reason) AS sample_reason,
       string_agg(id, ',' ORDER BY document_id, page_no, id) AS ids,
       list(struct_pack(
           id := id, document_id := document_id, filename := filename,
           page_no := page_no, text := text, context := context,
           confidence := confidence, band := band
       ) ORDER BY document_id, page_no, id) AS instances,
       CASE WHEN bool_or(band = 'flagged') THEN 'flagged'
            WHEN max(CASE band WHEN 'flagged' THEN 2 WHEN 'review' THEN 1 ELSE 0 END) = 1
            THEN 'review' ELSE 'high' END AS group_band
FROM residual
GROUP BY group_key
ORDER BY max(CASE band WHEN 'flagged' THEN 2 WHEN 'review' THEN 1 ELSE 0 END) DESC,
         n DESC, group_label;

CREATE OR REPLACE ROUTE api_case_triage_accept_high POST '/api/cases/:id/triage/accept-high'
  PARAM threshold INTEGER DEFAULT 90 GE 0 LE 100
  PARAM actor VARCHAR DEFAULT 'reviewer'
  PARAM reason VARCHAR DEFAULT 'triage high-confidence auto-pass'
AS
COPY (
    WITH targets AS (
        SELECT s.id AS suggestion_id, s.document_id, d.case_id, s.text
        FROM v_suggestions s
        JOIN documents d ON d.id = s.document_id
        WHERE d.case_id = $id AND s.status = 'pending'
          AND s.confidence >= $threshold
          AND s.band <> 'flagged' AND coalesce(s.flag_tag, '') <> 'false_positive'
    ),
    meta AS (
        SELECT cast(uuid() AS VARCHAR) AS batch_id, now() AS ts,
               $actor AS actor, $reason AS reason, $threshold AS threshold,
               (SELECT count(*) FROM targets) AS n
    )
    SELECT 'decision' AS kind, t.suggestion_id, 'accepted' AS status,
           m.actor, m.reason, m.ts, t.document_id, t.case_id, t.text, m.batch_id,
           'Accepted all high-confidence ≥' || cast(m.threshold AS VARCHAR) ||
               ' ×' || cast(m.n AS VARCHAR) AS batch_label,
           NULL::VARCHAR AS undoes_batch_id
    FROM targets t JOIN meta m ON true
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

CREATE OR REPLACE ROUTE api_case_triage_group_decision POST '/api/cases/:id/triage/group/decision'
  PARAM group_key VARCHAR
  PARAM status VARCHAR
  PARAM exclude_ids VARCHAR DEFAULT ''
  PARAM actor VARCHAR DEFAULT 'reviewer'
  PARAM reason VARCHAR DEFAULT ''
  PARAM threshold INTEGER DEFAULT 90 GE 0 LE 100
AS
COPY (
    WITH excluded AS (
        SELECT DISTINCT trim(token) AS suggestion_id
        FROM unnest(string_split($exclude_ids, ',')) AS _(token)
        WHERE trim(token) <> ''
    ),
    targets AS (
        SELECT s.id AS suggestion_id, s.document_id, d.case_id, s.text, s.entity_text
        FROM v_suggestions s
        JOIN documents d ON d.id = s.document_id
        WHERE d.case_id = $id AND s.status = 'pending'
          AND NOT (s.confidence >= $threshold
                   AND s.band <> 'flagged' AND coalesce(s.flag_tag, '') <> 'false_positive')
          AND s.group_key = trim($group_key)
          AND s.id NOT IN (SELECT suggestion_id FROM excluded)
          AND lower(trim($status)) IN ('accepted', 'rejected', 'pending')
    ),
    meta AS (
        SELECT cast(uuid() AS VARCHAR) AS batch_id, now() AS ts,
               lower(trim($status)) AS status,
               $actor AS actor, $reason AS reason,
               trim($group_key) AS group_key,
               (SELECT count(*) FROM targets) AS n,
               (SELECT max(coalesce(entity_text, text)) FROM targets) AS sample_text
    )
    SELECT 'decision' AS kind, t.suggestion_id, m.status, m.actor, m.reason, m.ts,
           t.document_id, t.case_id, t.text, m.batch_id,
           CASE m.status
               WHEN 'accepted' THEN 'Accepted group ×' || cast(m.n AS VARCHAR) || ' — ' ||
                                    coalesce(m.sample_text, m.group_key)
               WHEN 'rejected' THEN 'Rejected group ×' || cast(m.n AS VARCHAR) || ' — ' ||
                                    coalesce(m.sample_text, m.group_key)
               WHEN 'pending'  THEN 'Restored group ×' || cast(m.n AS VARCHAR) || ' to pending'
               ELSE 'Updated group ×' || cast(m.n AS VARCHAR)
           END AS batch_label,
           NULL::VARCHAR AS undoes_batch_id
    FROM targets t JOIN meta m ON true
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);
