-- routes/triage.sql — triage funnel: high-conf auto-pass + residual groups.
--
-- Purpose: the review surface's organizing principle for throughput.
--   ~3k suggestions → high-conf auto-pass clears bulk → residual ~800
--   hand-reviewed GROUPED (entity / kind / pattern) for batch judgment.
--
-- Endpoints:
--   GET  /api/cases/:id/triage?threshold=90
--        Funnel math: total, resolved, auto_passable, residual (+ threshold).
--   GET  /api/cases/:id/triage/groups?threshold=90&scope=case|doc&doc_id=
--        Residual groups for batch judgment (one row per group).
--   POST /api/cases/:id/triage/accept-high?threshold=90&actor=
--        Accept all high-conf pending (NEVER flagged / false_positive).
--        One audit batch for the whole action.
--   POST /api/cases/:id/triage/group/decision?group_key=&status=&exclude_ids=&actor=&reason=
--        Accept/reject residual group; exclude_ids = per-instance exceptions.
--        One audit batch.
--
-- Auto-pass eligibility (hard rules):
--   status = 'pending'
--   confidence >= threshold
--   band <> 'flagged'          -- never auto-pass export-blocking band
--   coalesce(flag_tag,'') <> 'false_positive'
-- Residual = pending AND NOT auto-pass eligible.
-- Dependencies: v_suggestions, documents, entities. Mutations via COPY only.

-- ── Funnel snapshot (one row) ─────────────────────────────────────────────
CREATE OR REPLACE ROUTE api_case_triage GET '/api/cases/:id/triage'
  PARAM threshold INTEGER DEFAULT 90
AS
WITH params AS (
    SELECT
        $id::INTEGER AS case_id,
        greatest(0, least(100, coalesce($threshold::INTEGER, 90))) AS threshold
),
base AS (
    SELECT
        s.id,
        s.status,
        s.band,
        s.confidence,
        s.flag_tag,
        s.document_id
    FROM v_suggestions s
    JOIN documents d ON d.id = s.document_id
    CROSS JOIN params p
    WHERE d.case_id = p.case_id
),
flags AS (
    SELECT
        b.*,
        (
            b.status = 'pending'
            AND b.confidence >= (SELECT threshold FROM params)
            AND b.band <> 'flagged'
            AND coalesce(b.flag_tag, '') <> 'false_positive'
        ) AS is_auto,
        (
            b.status = 'pending'
            AND NOT (
                b.confidence >= (SELECT threshold FROM params)
                AND b.band <> 'flagged'
                AND coalesce(b.flag_tag, '') <> 'false_positive'
            )
        ) AS is_residual
    FROM base b
)
SELECT
    (SELECT case_id FROM params) AS case_id,
    (SELECT threshold FROM params) AS threshold,
    count(*)::BIGINT AS total,
    count(*) FILTER (WHERE status IN ('accepted', 'rejected'))::BIGINT AS resolved,
    count(*) FILTER (WHERE status = 'pending')::BIGINT AS pending,
    count(*) FILTER (WHERE is_auto)::BIGINT AS auto_passable,
    count(*) FILTER (WHERE is_residual)::BIGINT AS residual,
    count(*) FILTER (WHERE status = 'pending' AND band = 'high')::BIGINT AS high_pending,
    count(*) FILTER (WHERE status = 'pending' AND band = 'review')::BIGINT AS review_pending,
    count(*) FILTER (WHERE status = 'pending' AND band = 'flagged')::BIGINT AS flagged_pending,
    -- Residual that sit in multi-instance groups (batch-judgable).
    (
        SELECT count(*)::BIGINT
        FROM flags f
        WHERE f.is_residual
          AND EXISTS (
              SELECT 1
              FROM flags f2
              JOIN v_suggestions s2 ON s2.id = f2.id
              JOIN v_suggestions s1 ON s1.id = f.id
              WHERE f2.is_residual
                AND f2.id <> f.id
                AND (
                    (s1.entity_id IS NOT NULL AND s1.entity_id = s2.entity_id)
                    OR (
                        s1.entity_id IS NULL
                        AND s2.entity_id IS NULL
                        AND lower(coalesce(s1.text, '')) = lower(coalesce(s2.text, ''))
                        AND coalesce(s1.kind, '') = coalesce(s2.kind, '')
                    )
                )
          )
    ) AS residual_bulk_eligible,
    CASE
        WHEN count(*) = 0 THEN 0
        ELSE round(
            100.0 * count(*) FILTER (WHERE status IN ('accepted', 'rejected'))
            / count(*), 0
        )::INTEGER
    END AS progress_pct
FROM flags;

-- ── Residual groups (batch judgment units) ────────────────────────────────
CREATE OR REPLACE ROUTE api_case_triage_groups GET '/api/cases/:id/triage/groups'
  PARAM threshold INTEGER DEFAULT 90
  PARAM scope VARCHAR DEFAULT 'case'
  PARAM doc_id INTEGER DEFAULT 0
AS
WITH params AS (
    SELECT
        $id::INTEGER AS case_id,
        greatest(0, least(100, coalesce($threshold::INTEGER, 90))) AS threshold,
        lower(coalesce($scope::VARCHAR, 'case')) AS scope,
        coalesce($doc_id::INTEGER, 0) AS doc_id
),
residual AS (
    SELECT
        s.id,
        s.document_id,
        s.page_no,
        s.text,
        s.context,
        s.confidence,
        s.band,
        s.kind,
        s.entity_id,
        s.entity_text,
        s.flag_tag,
        s.reason,
        d.filename,
        CASE
            WHEN s.entity_id IS NOT NULL THEN 'e:' || cast(s.entity_id AS VARCHAR)
            -- Entity-less bucket key: NULL text/kind and '' are both "no value"
            -- for triage grouping (stated equivalence, not a lossy key trick).
            ELSE 't:' || lower(coalesce(s.text, '')) || '|' || coalesce(s.kind, '')
        END AS group_key,
        -- Display label only; blank entity_text falls through to text/(unknown).
        coalesce(nullif(s.entity_text, ''), s.text, '(unknown)') AS group_label
    FROM v_suggestions s
    JOIN documents d ON d.id = s.document_id
    CROSS JOIN params p
    WHERE d.case_id = p.case_id
      AND s.status = 'pending'
      AND NOT (
            s.confidence >= p.threshold
            AND s.band <> 'flagged'
            AND coalesce(s.flag_tag, '') <> 'false_positive'
      )
      AND (
            p.scope <> 'doc'
         OR p.doc_id = 0
         OR s.document_id = p.doc_id
      )
),
agg AS (
    SELECT
        group_key,
        any_value(group_label) AS group_label,
        any_value(kind) AS kind,
        any_value(entity_id) AS entity_id,
        count(*)::BIGINT AS n,
        count(DISTINCT document_id)::BIGINT AS doc_count,
        count(DISTINCT page_no)::BIGINT AS page_count,
        min(confidence)::INTEGER AS min_conf,
        max(confidence)::INTEGER AS max_conf,
        -- Worst band first for sorting: flagged > review > high
        max(CASE band WHEN 'flagged' THEN 2 WHEN 'review' THEN 1 ELSE 0 END) AS risk_rank,
        bool_or(band = 'flagged') AS has_flagged,
        bool_or(coalesce(flag_tag, '') = 'false_positive') AS has_fp,
        any_value(reason) AS sample_reason,
        -- Comma-separated ids for client batch actions (stable order).
        string_agg(cast(id AS VARCHAR), ',' ORDER BY document_id, page_no, id) AS ids,
        -- Compact instance list for expand-without-second-fetch (capped).
        list(
            struct_pack(
                id := id,
                document_id := document_id,
                filename := filename,
                page_no := page_no,
                text := text,
                context := context,
                confidence := confidence,
                band := band
            )
            ORDER BY document_id, page_no, id
        ) AS instances
    FROM residual
    GROUP BY group_key
)
SELECT
    group_key,
    group_label,
    kind,
    entity_id,
    n,
    doc_count,
    page_count,
    min_conf,
    max_conf,
    has_flagged,
    has_fp,
    sample_reason,
    ids,
    instances,
    CASE
        WHEN has_flagged THEN 'flagged'
        WHEN risk_rank = 1 THEN 'review'
        ELSE 'high'
    END AS group_band
FROM agg
ORDER BY risk_rank DESC, n DESC, group_label;

-- ── Accept all high-confidence (one audit batch; excludes flagged) ────────
CREATE OR REPLACE ROUTE api_case_triage_accept_high POST '/api/cases/:id/triage/accept-high'
  PARAM threshold INTEGER DEFAULT 90
  PARAM actor VARCHAR DEFAULT 'reviewer'
  PARAM reason VARCHAR DEFAULT 'triage high-confidence auto-pass'
AS
COPY (
    WITH params AS (
        SELECT
            $id::INTEGER AS case_id,
            greatest(0, least(100, coalesce($threshold::INTEGER, 90))) AS threshold,
            coalesce($actor::VARCHAR, 'reviewer') AS actor,
            coalesce($reason::VARCHAR, 'triage high-confidence auto-pass') AS reason
    ),
    targets AS (
        SELECT
            s.id AS suggestion_id,
            s.document_id,
            d.case_id,
            s.text,
            s.confidence
        FROM v_suggestions s
        JOIN documents d ON d.id = s.document_id
        CROSS JOIN params p
        WHERE d.case_id = p.case_id
          AND s.status = 'pending'
          AND s.confidence >= p.threshold
          AND s.band <> 'flagged'
          AND coalesce(s.flag_tag, '') <> 'false_positive'
    ),
    meta AS (
        SELECT
            cast(uuid() AS VARCHAR) AS batch_id,
            now() AS ts,
            (SELECT actor FROM params) AS actor,
            (SELECT reason FROM params) AS reason,
            (SELECT threshold FROM params) AS threshold,
            (SELECT count(*) FROM targets) AS n,
            (SELECT max(text) FROM targets) AS sample_text
    )
    SELECT
        'decision' AS kind,
        t.suggestion_id,
        'accepted' AS status,
        m.actor,
        m.reason,
        m.ts,
        t.document_id,
        t.case_id,
        t.text,
        m.batch_id,
        'Accepted all high-confidence ≥' || cast(m.threshold AS VARCHAR) ||
            ' ×' || cast(m.n AS VARCHAR) AS batch_label,
        NULL::VARCHAR AS undoes_batch_id
    FROM targets t
    CROSS JOIN meta m
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);

-- ── Residual group decision (one batch; exclude_ids = exceptions) ─────────
CREATE OR REPLACE ROUTE api_case_triage_group_decision POST '/api/cases/:id/triage/group/decision'
  PARAM group_key VARCHAR
  PARAM status VARCHAR
  PARAM exclude_ids VARCHAR DEFAULT ''
  PARAM actor VARCHAR DEFAULT 'reviewer'
  PARAM reason VARCHAR DEFAULT ''
  PARAM threshold INTEGER DEFAULT 90
AS
COPY (
    WITH params AS (
        SELECT
            $id::INTEGER AS case_id,
            trim(coalesce($group_key::VARCHAR, '')) AS group_key,
            lower(trim(coalesce($status::VARCHAR, ''))) AS status,
            coalesce($actor::VARCHAR, 'reviewer') AS actor,
            coalesce($reason::VARCHAR, '') AS reason,
            greatest(0, least(100, coalesce($threshold::INTEGER, 90))) AS threshold
    ),
    excluded AS (
        SELECT DISTINCT try_cast(trim(u) AS INTEGER) AS suggestion_id
        FROM unnest(string_split(coalesce($exclude_ids::VARCHAR, ''), ',')) AS t(u)
        WHERE try_cast(trim(u) AS INTEGER) IS NOT NULL
    ),
    residual AS (
        SELECT
            s.id AS suggestion_id,
            s.document_id,
            d.case_id,
            s.text,
            s.entity_id,
            s.entity_text,
            s.kind,
            CASE
                WHEN s.entity_id IS NOT NULL THEN 'e:' || cast(s.entity_id AS VARCHAR)
                ELSE 't:' || lower(coalesce(s.text, '')) || '|' || coalesce(s.kind, '')
            END AS group_key
        FROM v_suggestions s
        JOIN documents d ON d.id = s.document_id
        CROSS JOIN params p
        WHERE d.case_id = p.case_id
          AND s.status = 'pending'
          AND NOT (
                s.confidence >= p.threshold
                AND s.band <> 'flagged'
                AND coalesce(s.flag_tag, '') <> 'false_positive'
          )
    ),
    targets AS (
        SELECT r.*
        FROM residual r
        CROSS JOIN params p
        WHERE r.group_key = p.group_key
          AND NOT EXISTS (
              SELECT 1 FROM excluded e WHERE e.suggestion_id = r.suggestion_id
          )
          AND p.status IN ('accepted', 'rejected', 'pending')
    ),
    meta AS (
        SELECT
            cast(uuid() AS VARCHAR) AS batch_id,
            now() AS ts,
            (SELECT status FROM params) AS status,
            (SELECT actor FROM params) AS actor,
            (SELECT reason FROM params) AS reason,
            (SELECT group_key FROM params) AS group_key,
            (SELECT count(*) FROM targets) AS n,
            (SELECT max(coalesce(entity_text, text)) FROM targets) AS sample_text
    )
    SELECT
        'decision' AS kind,
        t.suggestion_id,
        m.status,
        m.actor,
        m.reason,
        m.ts,
        t.document_id,
        t.case_id,
        t.text,
        m.batch_id,
        CASE m.status
            WHEN 'accepted' THEN
                'Accepted group ×' || cast(m.n AS VARCHAR) || ' — ' ||
                coalesce(m.sample_text, m.group_key)
            WHEN 'rejected' THEN
                'Rejected group ×' || cast(m.n AS VARCHAR) || ' — ' ||
                coalesce(m.sample_text, m.group_key)
            WHEN 'pending' THEN
                'Restored group ×' || cast(m.n AS VARCHAR) || ' to pending'
            ELSE
                'Updated group ×' || cast(m.n AS VARCHAR)
        END AS batch_label,
        NULL::VARCHAR AS undoes_batch_id
    FROM targets t
    CROSS JOIN meta m
) TO 'exports/decisions'
(FORMAT JSON, FILE_SIZE_BYTES '100KB', FILENAME_PATTERN 'dec_{uuid}', OVERWRITE_OR_IGNORE true);
