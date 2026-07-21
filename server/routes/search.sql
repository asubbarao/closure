-- routes/search.sql — case word/phrase search + audit trail.
-- Exact + fuzzy (rapidfuzz) over words; multi-token via splink ngrams (n const).
-- Contract: matches[], count, exact_count, fuzzy_count. Params VARCHAR (case_no).

-- GET /api/search?q=TEXT&case=CASE_NO — find-all exact then similar hits in a case.
CREATE OR REPLACE ROUTE api_search GET '/api/search' AS
WITH
query AS (
    SELECT
        lower(trim(unaccent($q))) AS query_norm,
        $case AS case_id,
        length(trim($q)) AS query_len,
        greatest(1, len(string_split(trim($q), ' '))) AS query_token_count
),
line_bags AS (
    SELECT w.document_id, d.filename, w.page_no,
           list(w.word ORDER BY w.bbox.x0) AS word_list,
           list(struct_pack(word := w.word, x0 := w.bbox.x0, y0 := w.bbox.y0,
                            x1 := w.bbox.x1, y1 := w.bbox.y1)
                ORDER BY w.bbox.x0) AS word_meta
    FROM words w
    JOIN documents d ON d.id = w.document_id
    JOIN query ON d.case_id = query.case_id
    WHERE w.word IS NOT NULL AND trim(w.word) <> ''
    GROUP BY w.document_id, d.filename, w.page_no, round(w.bbox.y0, 0)
),
-- ngrams(n) needs a constant n — the four calls are ONE list literal (each
-- fixed-size ARRAY(n) cast to VARCHAR[] so they unify); projection written once.
-- n > len(word_list) yields an empty gram list and vanishes — no length guards.
span_raw AS (
    SELECT b.*, len(g.gram) AS token_count, g.gram AS tokens, g.idx AS start_idx
    FROM line_bags b,
         UNNEST([ngrams(b.word_list, 1)::VARCHAR[][],
                 ngrams(b.word_list, 2)::VARCHAR[][],
                 ngrams(b.word_list, 3)::VARCHAR[][],
                 ngrams(b.word_list, 4)::VARCHAR[][]]) AS gs(grams),
         UNNEST(gs.grams) WITH ORDINALITY AS g(gram, idx)
),
spans AS (
    SELECT
        r.document_id, r.filename, r.page_no, r.token_count, query.query_norm,
        array_to_string(r.tokens, ' ') AS text_raw,
        lower(trim(unaccent(array_to_string(r.tokens, ' ')))) AS text_norm,
        struct_pack(
            x0 := r.word_meta[r.start_idx].x0,
            y0 := r.word_meta[r.start_idx].y0,
            x1 := r.word_meta[r.start_idx + r.token_count - 1].x1,
            y1 := list_max(list_transform(
                list_slice(r.word_meta, r.start_idx::BIGINT,
                           (r.start_idx + r.token_count - 1)::BIGINT),
                lambda meta: meta.y1))
        ) AS bbox
    FROM span_raw r
    JOIN query ON query.query_len > 0 AND r.token_count = query.query_token_count
),
hits AS (
    SELECT document_id, filename, page_no, bbox, text_raw, score,
           CASE WHEN score = 100.0 THEN 'exact' ELSE 'fuzzy' END AS match_kind
    FROM (
        SELECT document_id, filename, page_no, bbox, text_raw,
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
        x0 := bbox.x0, y0 := bbox.y0, x1 := bbox.x1, y1 := bbox.y1,
        text := text_raw, match_kind := match_kind, score := score
    ) ORDER BY CASE match_kind WHEN 'exact' THEN 0 ELSE 1 END,
              score DESC, document_id, page_no, bbox.y0, bbox.x0), []) AS matches,
    count(*)::INTEGER AS count,
    count(*) FILTER (WHERE match_kind = 'exact')::INTEGER AS exact_count,
    count(*) FILTER (WHERE match_kind = 'fuzzy')::INTEGER AS fuzzy_count
FROM hits;

-- GET /api/cases/:id/audit — decision trail (VARCHAR case_no); v_audit is the
-- one decision-log display projection (routes/pages.sql).
CREATE OR REPLACE ROUTE api_case_audit GET '/api/cases/:id/audit' AS
SELECT ts, actor, action, suggestion_id, case_id, target, reason
FROM v_audit
WHERE case_id = $id
ORDER BY ts DESC;

-- GET /api/stats — global corpus counters (one row).
CREATE OR REPLACE ROUTE api_stats GET '/api/stats' AS
SELECT
    (SELECT count(*)::BIGINT FROM cases) AS cases,
    (SELECT count(*)::BIGINT FROM documents) AS documents,
    (SELECT count(*)::BIGINT FROM pages) AS pages,
    (SELECT count(*)::BIGINT FROM words) AS words,
    (SELECT count(*)::BIGINT FROM entities) AS entities,
    (SELECT count(*)::BIGINT FROM suggestions) AS suggestions;
