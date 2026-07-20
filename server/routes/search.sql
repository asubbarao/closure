-- routes/search.sql — search, stats, and audit read APIs.
--
-- Purpose: cross-cutting read endpoints (word search, boot stats, audit log).
-- Dependencies: words, documents, v_grams, v_audit, v_decision_log.
-- Substring: position() (LIKE family banned). Fuzzy: rapidfuzz community ext.
--
-- GET /api/search?q=TEXT&case=ID
--   Exact first (substring / full equality / separator-insensitive alnum),
--   then fuzzy (rapidfuzz_ratio >= 90) with scores. Response distinguishes
--   exact vs fuzzy so add-missed can show "N exact · M similar".

INSTALL rapidfuzz FROM community;
LOAD rapidfuzz;

-- Separator-insensitive key: "280 96 9531" / "280-96-9531" / "280.96.9531" → same.
CREATE OR REPLACE MACRO search_alnum(t) AS
    lower(regexp_replace(trim(cast(t AS VARCHAR)), '[^A-Za-z0-9]+', '', 'g'));

CREATE OR REPLACE ROUTE api_search GET '/api/search' AS
WITH
p AS (
    SELECT
        trim(cast($q AS VARCHAR)) AS q_raw,
        lower(trim(cast($q AS VARCHAR))) AS q,
        search_alnum($q) AS q_alnum,
        cast($case AS INTEGER) AS case_id,
        length(trim(cast($q AS VARCHAR))) AS q_len,
        length(search_alnum($q)) AS q_alnum_len
),
-- Same-line 1..4-grams for the requested case (covers multi-word names + spaced SSN).
grams AS (
    SELECT
        vg.document_id,
        d.filename,
        vg.page_no,
        vg.x0, vg.y0, vg.x1, vg.y1,
        vg.text_raw,
        lower(vg.text_raw) AS text_l,
        search_alnum(vg.text_raw) AS alnum,
        vg.n,
        length(vg.text_raw) AS t_len
    FROM v_grams vg
    JOIN documents d ON d.id = vg.document_id
    CROSS JOIN p
    WHERE d.case_id = p.case_id
      AND vg.text_raw IS NOT NULL
      AND trim(vg.text_raw) <> ''
),
-- Exact: single-token substring (legacy), full phrase equality, or alnum equality
-- (so dashed/spaced/dotted SSN variants count as exact, not merely similar).
exact_raw AS (
    SELECT
        g.document_id,
        g.filename,
        g.page_no,
        g.x0, g.y0, g.x1, g.y1,
        g.text_raw,
        100.0::DOUBLE AS score,
        'exact'::VARCHAR AS match_kind,
        g.n,
        g.t_len
    FROM grams g
    CROSS JOIN p
    WHERE p.q_len > 0
      AND (
            (g.n = 1 AND position(p.q IN g.text_l) > 0)
         OR g.text_l = p.q
         OR (p.q_alnum_len >= 5 AND g.alnum = p.q_alnum)
      )
),
exact_hits AS (
    SELECT document_id, filename, page_no, x0, y0, x1, y1, text_raw, score, match_kind
    FROM (
        SELECT
            e.*,
            row_number() OVER (
                PARTITION BY document_id, page_no,
                             round(x0, 2), round(y0, 2), round(x1, 2), round(y1, 2)
                ORDER BY n ASC, t_len ASC
            ) AS rn
        FROM exact_raw e
    ) z
    WHERE rn = 1
),
-- Score candidate grams once (length band keeps rapidfuzz off the full corpus).
fuzzy_scored AS (
    SELECT
        g.document_id,
        g.filename,
        g.page_no,
        g.x0, g.y0, g.x1, g.y1,
        g.text_raw,
        g.n,
        g.t_len,
        greatest(
            rapidfuzz_ratio(g.text_l, p.q),
            CASE
                WHEN p.q_alnum_len >= 5 AND length(g.alnum) >= 5
                THEN rapidfuzz_ratio(g.alnum, p.q_alnum)
                ELSE 0.0
            END
        ) AS score
    FROM grams g
    CROSS JOIN p
    WHERE p.q_len >= 4
      AND g.t_len BETWEEN greatest(1, p.q_len - 4) AND (p.q_len + 4)
      AND NOT EXISTS (
          SELECT 1
          FROM exact_hits e
          WHERE e.document_id = g.document_id
            AND e.page_no = g.page_no
            AND abs(e.x0 - g.x0) < 0.5
            AND abs(e.y0 - g.y0) < 0.5
      )
),
fuzzy_hits AS (
    SELECT document_id, filename, page_no, x0, y0, x1, y1, text_raw, score,
           'fuzzy'::VARCHAR AS match_kind
    FROM (
        SELECT
            f.*,
            row_number() OVER (
                PARTITION BY document_id, page_no,
                             round(x0, 2), round(y0, 2), round(x1, 2), round(y1, 2)
                ORDER BY score DESC, n ASC, t_len ASC
            ) AS rn
        FROM fuzzy_scored f
        WHERE f.score >= 90.0
    ) z
    WHERE rn = 1
),
combined AS (
    SELECT * FROM (
        SELECT document_id, filename, page_no, x0, y0, x1, y1, text_raw, score, match_kind
        FROM exact_hits
        UNION ALL BY NAME
        SELECT document_id, filename, page_no, x0, y0, x1, y1, text_raw, score, match_kind
        FROM fuzzy_hits
    ) u
    ORDER BY
        CASE WHEN match_kind = 'exact' THEN 0 ELSE 1 END,
        score DESC,
        document_id, page_no, y0, x0
    LIMIT 200
)
SELECT
    coalesce(list(struct_pack(
        document_id := document_id,
        filename := filename,
        page_no := page_no,
        x0 := x0, y0 := y0, x1 := x1, y1 := y1,
        text := text_raw,
        match_kind := match_kind,
        score := score
    )), []) AS matches,
    count(*)::INTEGER AS count,
    coalesce(count(*) FILTER (WHERE match_kind = 'exact'), 0)::INTEGER AS exact_count,
    coalesce(count(*) FILTER (WHERE match_kind = 'fuzzy'), 0)::INTEGER AS fuzzy_count
FROM combined;

CREATE OR REPLACE ROUTE api_case_audit GET '/api/cases/:id/audit' AS
SELECT
    coalesce(ts, now()) AS ts,
    coalesce(actor, 'system') AS actor,
    coalesce(action, kind) AS action,
    suggestion_id,
    case_id,
    coalesce(target, text, '') AS target,
    coalesce(reason, '') AS reason
FROM (
    SELECT a.ts, a.actor, a.action, a.suggestion_id, a.case_id, a.target, a.reason,
           NULL::VARCHAR AS kind, NULL::VARCHAR AS text
    FROM v_audit a
    WHERE a.case_id = $id::INTEGER
    UNION ALL BY NAME
    SELECT
        d.ts, d.actor, d.kind AS action, d.suggestion_id,
        coalesce(d.case_id, doc.case_id) AS case_id,
        d.text AS target, d.reason, d.kind, d.text
    FROM v_decision_log d
    LEFT JOIN documents doc ON doc.id = d.document_id
    WHERE coalesce(d.case_id, doc.case_id) = $id::INTEGER
) u
ORDER BY coalesce(ts, TIMESTAMP '1970-01-01') DESC
LIMIT 500;

CREATE OR REPLACE ROUTE api_stats GET '/api/stats' AS SELECT
    (SELECT count(*) FROM cases) AS cases,
    (SELECT count(*) FROM documents) AS documents,
    (SELECT count(*) FROM pages) AS pages,
    (SELECT count(*) FROM words) AS words,
    (SELECT count(*) FROM entities) AS entities,
    (SELECT count(*) FROM suggestions) AS suggestions,
    (SELECT count(*) FROM v_suggestions) AS v_suggestions;
