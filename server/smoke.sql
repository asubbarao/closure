-- smoke.sql — bind + raw SUMMARIZE only.
-- Empty table ⇒ SUMMARIZE.count = 0 (no separate count(*) laundry).
-- COLUMNS(*) / native SUMMARIZE replace hand-rolled min/max/count boards.

FROM (DESCRIBE SELECT * FROM decisions);
FROM (DESCRIBE SELECT * FROM documents);
FROM (DESCRIBE SELECT * FROM suggestions);
FROM (DESCRIBE SELECT * FROM kind_rules);
FROM (DESCRIBE SELECT * FROM watchlist);
FROM (DESCRIBE SELECT * FROM suggestion_judges);
FROM (DESCRIBE SELECT * FROM v_suggestions);
FROM (DESCRIBE SELECT * FROM v_hostfs);
FROM (DESCRIBE SELECT * FROM v_export_blocked);
FROM (DESCRIBE SELECT * FROM v_nav);
FROM (DESCRIBE SELECT * FROM v_cols);
FROM (DESCRIBE SELECT * FROM v_audit);
FROM (DESCRIBE SELECT * FROM v_suggestion_line_context);
FROM (DESCRIBE SELECT * FROM v_url_hosts);
FROM (DESCRIBE SELECT * FROM v_http_cache);

-- Full column profiles (Duck's SUMMARIZE already uses COLUMNS under the hood)
FROM (SUMMARIZE cases);
FROM (SUMMARIZE documents);
FROM (SUMMARIZE words);
FROM (SUMMARIZE suggestions);
FROM (SUMMARIZE decisions);
FROM (SUMMARIZE watchlist);
FROM (SUMMARIZE suggestion_judges);
FROM (SUMMARIZE v_suggestions);

-- Non-empty: SUMMARIZE.count is the row count for every column
SELECT CASE
    WHEN (SELECT min(count) FROM (SUMMARIZE cases)) = 0
        THEN error('smoke: cases empty')
    WHEN (SELECT min(count) FROM (SUMMARIZE documents)) = 0
        THEN error('smoke: documents empty')
    WHEN (SELECT min(count) FROM (SUMMARIZE words)) = 0
        THEN error('smoke: words empty')
    WHEN (SELECT min(count) FROM (SUMMARIZE suggestions)) = 0
        THEN error('smoke: suggestions empty')
    WHEN (SELECT min(count) FROM (SUMMARIZE kind_rules)) = 0
        THEN error('smoke: kind_rules empty')
    WHEN coalesce(len(getvariable('sample_pdfs')), 0) = 0
        THEN error('smoke: sample_pdfs pin empty')
    ELSE 'smoke: corpus non-empty'
END AS smoke_corpus;

SELECT CASE
    WHEN bool_and(has_lib AND has_stream AND has_audit)
        THEN 'smoke nav: shell ok'
    ELSE error('smoke: v_nav missing library/stream/audit for a case')
END AS smoke_nav
FROM (
    FROM v_nav
    SELECT case_id,
           bool_or(href = '/cases/' || case_id) AS has_lib,
           bool_or(href = '/cases/' || case_id || '/stream') AS has_stream,
           bool_or(href = '/cases/' || case_id || '/audit') AS has_audit
    GROUP BY ALL
);
