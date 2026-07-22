-- smoke.sql — schema + product invariants (SQL checks, not a second type system).
-- Run after model load: .read server/smoke.sql
--
-- Presence = bind the surface (DESCRIBE). Missing relation/column fails in the binder.
-- Counts = tall (rel, n) grain — not scalar-subselect laundry, not query() theater.

-- Core tables / live views
FROM (DESCRIBE SELECT * FROM decisions);
FROM (DESCRIBE SELECT * FROM documents);
FROM (DESCRIBE SELECT * FROM suggestions);
FROM (DESCRIBE SELECT * FROM kind_rules);
FROM (DESCRIBE SELECT * FROM v_suggestions);
FROM (DESCRIBE SELECT * FROM v_hostfs);
FROM (DESCRIBE SELECT * FROM v_export_blocked);
FROM (DESCRIBE SELECT * FROM v_nav);
FROM (DESCRIBE SELECT * FROM v_cols);

-- Earned-extension surfaces (bind only — no dns_lookup / network cols)
FROM (DESCRIBE SELECT suggestion_id, hit_line, line_text, dist FROM v_suggestion_line_context);
FROM (DESCRIBE SELECT hostname, token_n FROM v_url_hosts);
FROM (DESCRIBE SELECT term, term_norm FROM watchlist);
FROM (DESCRIBE SELECT ondisk_bytes, filesystems, data_cache_type FROM v_http_cache);
FROM (DESCRIBE SELECT * FROM v_http_cache_config);
FROM (DESCRIBE SELECT * FROM v_http_cache_filesystems);

-- Nav shell: every case has library + stream + audit (docs alone is incomplete)
SELECT CASE
    WHEN count(*) FILTER (
        WHERE NOT has_lib OR NOT has_stream OR NOT has_audit
    ) > 0
    THEN error('smoke: v_nav missing library/stream/audit shell for a case')
    ELSE format('smoke nav: {} cases with shell', count(*))
END AS nav_ok
FROM (
    SELECT case_id,
           bool_or(href = '/cases/' || case_id) AS has_lib,
           bool_or(href = '/cases/' || case_id || '/stream') AS has_stream,
           bool_or(href = '/cases/' || case_id || '/audit') AS has_audit
    FROM v_nav
    GROUP BY case_id
);

-- Semantic: real measures + dims bind
FROM (
    SELECT * FROM semantic_view(
        'closure',
        dimensions := ['status', 'band'],
        metrics := ['n', 'avg_confidence', 'min_confidence', 'max_confidence']
    )
    LIMIT 0
);

WITH counts AS (
    SELECT 'cases' AS rel, count(*)::BIGINT AS n FROM cases
    UNION ALL BY NAME SELECT 'documents' AS rel, count(*)::BIGINT AS n FROM documents
    UNION ALL BY NAME SELECT 'words' AS rel, count(*)::BIGINT AS n FROM words
    UNION ALL BY NAME SELECT 'suggestions' AS rel, count(*)::BIGINT AS n FROM suggestions
    UNION ALL BY NAME SELECT 'kind_rules' AS rel, count(*)::BIGINT AS n FROM kind_rules
    UNION ALL BY NAME SELECT 'sample_pdfs' AS rel,
        coalesce(len(getvariable('sample_pdfs')), 0)::BIGINT AS n
    UNION ALL BY NAME SELECT 'v_cols' AS rel, count(*)::BIGINT AS n FROM v_cols
),
empty AS (
    SELECT list(rel ORDER BY rel) AS empty_rels FROM counts WHERE n = 0
)
SELECT CASE
    WHEN len(empty_rels) > 0
        THEN error(format('smoke: empty {}', empty_rels))
    ELSE format(
        'smoke ok: {}',
        (SELECT list(struct_pack(rel := rel, n := n) ORDER BY rel) FROM counts))
END AS smoke
FROM empty;
