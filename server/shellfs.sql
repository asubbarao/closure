-- shellfs.sql — host effects as query rows.
--
-- Prefer: DuckDB / hostfs / scalarfs / zipfs first.
-- Prefer: one-liner pipe. Bash for-loops → set-based SQL.
-- Multi-line → pure scripts/foo.sh then: read_text('bash scripts/foo.sh |')
-- Do NOT expose raw cmd over HTTP.
--
-- Pipe readers (filename ends with |):
--   read_csv / read_json / read_json_auto  — STREAMING
--   read_text                              — BATCH (whole stdout)
--
--   SELECT * FROM read_csv('cmd |', header := true);
--   SELECT * FROM read_json_auto('curl -fsSL … |');
--   SELECT content FROM read_text('uname -a |');
--   COPY (SELECT …) TO '| sink' (FORMAT csv);
--   'grep x f {allowed_exit_codes=0,1}|'

CREATE OR REPLACE VIEW v_shell_patterns AS
SELECT * FROM (VALUES
    ('stream_csv',
     'SELECT * FROM read_csv(''cmd |'', header := true)',
     'streaming CSV from process'),
    ('stream_json',
     'SELECT * FROM read_json_auto(''cmd |'')',
     'streaming JSON/NDJSON from process'),
    ('batch_text',
     'SELECT content FROM read_text(''cmd |'')',
     'batch — whole stdout'),
    ('script_file',
     'SELECT content FROM read_text(''bash scripts/name.sh |'')',
     'batch — pure bash on disk'),
    ('write_pipe',
     'COPY (SELECT …) TO ''| cmd > out'' (FORMAT csv)',
     'DuckDB → sink process'),
    ('exit_ok',
     'read_csv(''grep x f {allowed_exit_codes=0,1}|'', …)',
     'allow non-zero exit (e.g. grep miss)')
) AS t(kind, pattern, note);
