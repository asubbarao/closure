-- routes/search.sql — case word/phrase search + audit trail.
-- Exact + fuzzy (rapidfuzz) over words; multi-token via splink ngrams (n const).
-- Contract: matches[], count, exact_count, fuzzy_count. Params VARCHAR (case_no).
-- CREATE ROUTE rebinds without SET VARIABLE → audit uses fold-safe getenv path.

INSTALL rapidfuzz FROM community; LOAD rapidfuzz;
INSTALL splink_udfs FROM community; LOAD splink_udfs;

-- GET /api/search?q=TEXT&case=CASE_NO — find-all exact then similar hits in a case.
CREATE OR REPLACE ROUTE api_search GET '/api/search' AS
WITH
query AS (
    SELECT
        lower(trim(unaccent(cast($q AS VARCHAR)))) AS query_norm,
        cast($case AS VARCHAR) AS case_id,
        length(trim(cast($q AS VARCHAR))) AS query_len,
        greatest(1, len(string_split(trim(cast($q AS VARCHAR)), ' '))) AS query_token_count
),
line_bags AS (
    SELECT w.document_id, d.filename, w.page_no,
           list(w.word ORDER BY w.x0) AS word_list,
           list(struct_pack(word := w.word, x0 := w.x0, y0 := w.y0, x1 := w.x1, y1 := w.y1)
                ORDER BY w.x0) AS word_meta
    FROM words w
    JOIN documents d ON d.id = w.document_id
    JOIN query ON d.case_id = query.case_id
    WHERE w.word IS NOT NULL AND trim(w.word) <> ''
    GROUP BY w.document_id, d.filename, w.page_no, round(w.y0, 0)
),
-- ngrams(n) needs a constant n — emit 1..4, keep rows matching query_token_count.
span_raw AS (
    SELECT b.*, 1 AS token_count, g.gram AS tokens, g.idx AS start_idx
    FROM line_bags b, UNNEST(ngrams(b.word_list, 1)) WITH ORDINALITY AS g(gram, idx)
    UNION ALL BY NAME
    SELECT b.*, 2, g.gram, g.idx
    FROM line_bags b, UNNEST(ngrams(b.word_list, 2)) WITH ORDINALITY AS g(gram, idx)
    WHERE len(b.word_list) >= 2
    UNION ALL BY NAME
    SELECT b.*, 3, g.gram, g.idx
    FROM line_bags b, UNNEST(ngrams(b.word_list, 3)) WITH ORDINALITY AS g(gram, idx)
    WHERE len(b.word_list) >= 3
    UNION ALL BY NAME
    SELECT b.*, 4, g.gram, g.idx
    FROM line_bags b, UNNEST(ngrams(b.word_list, 4)) WITH ORDINALITY AS g(gram, idx)
    WHERE len(b.word_list) >= 4
),
spans AS (
    SELECT
        r.document_id, r.filename, r.page_no, r.token_count, query.query_norm,
        array_to_string(list_transform(r.tokens, lambda t: cast(t AS VARCHAR)), ' ') AS text_raw,
        lower(trim(unaccent(array_to_string(
            list_transform(r.tokens, lambda t: cast(t AS VARCHAR)), ' ')))) AS text_norm,
        r.word_meta[r.start_idx].x0 AS x0,
        r.word_meta[r.start_idx].y0 AS y0,
        r.word_meta[r.start_idx + r.token_count - 1].x1 AS x1,
        list_max(list_transform(
            list_slice(r.word_meta, r.start_idx::BIGINT, (r.start_idx + r.token_count - 1)::BIGINT),
            lambda meta: meta.y1)) AS y1
    FROM span_raw r
    JOIN query ON query.query_len > 0 AND r.token_count = query.query_token_count
),
hits AS (
    SELECT document_id, filename, page_no, x0, y0, x1, y1, text_raw, score,
           CASE WHEN score = 100.0 THEN 'exact' ELSE 'fuzzy' END AS match_kind
    FROM (
        SELECT document_id, filename, page_no, x0, y0, x1, y1, text_raw,
               CASE
                   WHEN text_norm = query_norm THEN 100.0
                   WHEN token_count = 1 AND position(query_norm IN text_norm) > 0 THEN 100.0
                   ELSE rapidfuzz_ratio(text_norm, query_norm)
               END AS score
        FROM spans
    ) scored
    WHERE score >= 90.0
)
SELECT
    coalesce(list(struct_pack(
        document_id := document_id, filename := filename, page_no := page_no,
        x0 := x0, y0 := y0, x1 := x1, y1 := y1,
        text := text_raw, match_kind := match_kind, score := score
    ) ORDER BY CASE match_kind WHEN 'exact' THEN 0 ELSE 1 END,
              score DESC, document_id, page_no, y0, x0), []) AS matches,
    count(*)::INTEGER AS count,
    count(*) FILTER (WHERE match_kind = 'exact')::INTEGER AS exact_count,
    count(*) FILTER (WHERE match_kind = 'fuzzy')::INTEGER AS fuzzy_count
FROM hits;

-- GET /api/cases/:id/audit — decision trail (VARCHAR case_no). Fold-safe glob.
CREATE OR REPLACE ROUTE api_case_audit GET '/api/cases/:id/audit' AS
SELECT
    coalesce(try_cast(dl.ts AS TIMESTAMP), now()) AS ts,
    coalesce(cast(dl.actor AS VARCHAR), 'system') AS actor,
    coalesce(cast(dl.kind AS VARCHAR), 'event') AS action,
    dl.suggestion_id,
    coalesce(cast(dl.case_id AS VARCHAR), d.case_id) AS case_id,
    coalesce(cast(dl.text AS VARCHAR), '') AS target,
    coalesce(cast(dl.reason AS VARCHAR), '') AS reason
FROM read_json_auto(
    CASE WHEN getenv('CLOSURE_EXPORTS_DIR') IS NOT NULL
          AND length(getenv('CLOSURE_EXPORTS_DIR')) > 0
         THEN getenv('CLOSURE_EXPORTS_DIR') || '/decisions/*.json'
         ELSE 'exports/decisions/*.json' END,
    union_by_name := true, ignore_errors := true) dl
LEFT JOIN documents d ON cast(d.id AS VARCHAR) = cast(dl.document_id AS VARCHAR)
WHERE dl.kind IS DISTINCT FROM 'sentinel'
  AND coalesce(cast(dl.case_id AS VARCHAR), d.case_id) = cast($id AS VARCHAR)
ORDER BY coalesce(try_cast(dl.ts AS TIMESTAMP), TIMESTAMP '1970-01-01') DESC;

-- GET /api/stats — global corpus counters (one row).
-- v_suggestions is a getvariable view (CREATE ROUTE cannot bind it) → suggestions table.
CREATE OR REPLACE ROUTE api_stats GET '/api/stats' AS
SELECT
    (SELECT count(*)::BIGINT FROM cases) AS cases,
    (SELECT count(*)::BIGINT FROM documents) AS documents,
    (SELECT count(*)::BIGINT FROM pages) AS pages,
    (SELECT count(*)::BIGINT FROM words) AS words,
    (SELECT count(*)::BIGINT FROM entities) AS entities,
    (SELECT count(*)::BIGINT FROM suggestions) AS suggestions,
    (SELECT count(*)::BIGINT FROM suggestions) AS v_suggestions;
