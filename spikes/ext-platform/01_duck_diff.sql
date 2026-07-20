-- Spike: duck_diff for decision-log + words corpus regression
-- Requires DuckDB >= v1.5.4 (community CDN has osx_arm64 signed build).
-- Run:
--   /tmp/duckdb154/duckdb -unsigned -markdown < spikes/ext-platform/01_duck_diff.sql
--   # or: duckdb -unsigned (once CLI is 1.5.4+)

INSTALL duck_diff FROM community;
LOAD duck_diff;

-- --- Decision-log style snapshot (audit_events / exports/decisions) ---
CREATE OR REPLACE TABLE decisions_v1 AS SELECT * FROM (VALUES
  ('dec1', 's1', 'accept', 'ai',  0.91, '2026-07-01'),
  ('dec2', 's2', 'reject', 'ai',  0.40, '2026-07-01'),
  ('dec3', 's3', 'accept', 'manual', 1.0, '2026-07-02')
) t(id, suggestion_id, action, source, confidence, day);

CREATE OR REPLACE TABLE decisions_v2 AS SELECT * FROM (VALUES
  ('dec1', 's1', 'accept', 'ai',  0.91, '2026-07-01'),  -- identical
  ('dec2', 's2', 'accept', 'ai',  0.55, '2026-07-01'),  -- action + confidence
  ('dec4', 's4', 'reject', 'manual', 1.0, '2026-07-03') -- right_only; dec3 left_only
) t(id, suggestion_id, action, source, confidence, day);

SELECT id, diff_status, diff_data
FROM table_diff('FROM decisions_v1', 'FROM decisions_v2', pk := 'id')
ORDER BY id;

SELECT * FROM table_diff_summary('FROM decisions_v1', 'FROM decisions_v2', pk := 'id');

-- Pass/fail gate for CI regression of a frozen decision projection:
SELECT (n_different + n_left_only + n_right_only) = 0 AS decisions_match
FROM table_diff_summary('FROM decisions_v1', 'FROM decisions_v2', pk := 'id');

-- --- Words corpus geometry drift (multi-column PK) ---
CREATE OR REPLACE TABLE words_a AS SELECT * FROM (VALUES
  (1, 1, 0, 'John', 10.0, 20.0, 40.0, 30.0),
  (1, 1, 1, 'Doe',  42.0, 20.0, 70.0, 30.0)
) t(document_id, page_no, seq, word, x0, y0, x1, y1);

CREATE OR REPLACE TABLE words_b AS SELECT * FROM (VALUES
  (1, 1, 0, 'John', 10.0, 20.0, 40.0, 30.0),
  (1, 1, 1, 'Doe',  43.0, 20.0, 71.0, 30.0)  -- x0/x1 drift
) t(document_id, page_no, seq, word, x0, y0, x1, y1);

SELECT document_id, page_no, seq, diff_status, diff_data
FROM table_diff(
  'FROM words_a',
  'FROM words_b',
  pk := ['document_id', 'page_no', 'seq']
);
