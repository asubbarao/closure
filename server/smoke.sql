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

-- ── declared-but-dead: every scorer wired in must actually fire ───────────
-- The bug class the "is it empty" checks above cannot see. A UNION arm that
-- matches nothing still leaves its table non-empty, so the arm looks alive.
-- A phonetic name detector shipped here comparing double_metaphone of a WHOLE
-- term ('kaleb johnson' -> KLPJNS) against a single token's code ('kaleb' ->
-- KLP). It could never match, produced zero rows for the life of the repo, and
-- every emptiness check still passed. It was finally deleted as "noise" — it
-- had never fired once. See docs/DETECTION.md.
--
-- Assert on the TRACE (name_rule_hits), not on the winners
-- (name_token_match): on a corpus where names are spelled correctly, edit and
-- jaro legitimately outrank phonetic and it wins nothing. Producing zero trace
-- rows is the real "this code is dead" signal.
SELECT CASE
    WHEN (SELECT string_agg(scorer, ', ' ORDER BY scorer)
          FROM name_scorers ANTI JOIN name_rule_hits USING (scorer)) IS NOT NULL
        THEN error(format('smoke: name scorer(s) declared but never fired: {}',
             (SELECT string_agg(scorer, ', ' ORDER BY scorer)
              FROM name_scorers ANTI JOIN name_rule_hits USING (scorer))))
    ELSE format('smoke scorers: {} declared, all firing',
                (SELECT count(*) FROM name_scorers))
END AS smoke_name_scorers;

-- A NULL discriminator means a UNION ALL BY NAME arm lost its alias and is
-- silently contributing unlabelled rows. BY NAME matches on column names, so a
-- missing `AS scorer` does not error — it nulls the column.
SELECT CASE
    WHEN (SELECT count(*) FROM name_rule_hits WHERE scorer IS NULL) > 0
        THEN error('smoke: name_rule_hits has NULL scorer — a UNION ALL BY NAME arm is missing an alias')
    WHEN (SELECT count(*) FROM token_rule_hits WHERE rule IS NULL) > 0
        THEN error('smoke: token_rule_hits has NULL rule — a UNION ALL BY NAME arm is missing an alias')
    ELSE 'smoke traces: discriminators complete'
END AS smoke_trace_labels;

-- Geometry is a type with operations; a box that is not a box is a UI bug.
SELECT CASE
    WHEN (SELECT count(*) FROM suggestions
          WHERE bbox.x1 <= bbox.x0 OR bbox.y1 <= bbox.y0) > 0
        THEN error('smoke: degenerate bbox in suggestions (x1<=x0 or y1<=y0)')
    ELSE 'smoke bbox: all boxes positive-area'
END AS smoke_bbox;

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
