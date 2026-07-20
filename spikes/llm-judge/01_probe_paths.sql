-- 01_probe_paths.sql — prove both call paths work against local Ollama.
-- Run from repo root:
--   duckdb -unsigned -markdown :memory: < spikes/llm-judge/01_probe_paths.sql
--
-- Paths: (A) community `ai` extension → Ollama  (B) `http_client`.http_post → /api/generate

INSTALL ai FROM community;
LOAD ai;
INSTALL http_client FROM community;
LOAD http_client;

SET duckdb_ai_provider = 'ollama';
SET duckdb_ai_model = 'llama3.2:3b';
SET duckdb_ai_base_url = 'http://127.0.0.1:11434';
SET duckdb_ai_timeout_seconds = 120;
SET duckdb_ai_allowed_hosts = '127.0.0.1,localhost';
SET duckdb_ai_cache = false;
SET duckdb_ai_max_concurrent_requests = 1;

SELECT 'path_A_ai_classify' AS path,
       ai_classify(
         'Candidate: Feeney v. Ohio, | Context: legal reference 387 U.S. 93 | Kind: CITATION · NOT PII. Is this protectable subject PII to redact?',
         ['redact', 'keep', 'unsure']
       ) AS result;

-- Note: SSN-flavored prompts sometimes trigger safety refusals on small models
-- (see docs/llm-judge.md). Probe uses a citation so the path itself is measurable.
SELECT 'path_A_ai_complete' AS path,
       ai_complete(
         'You are a FOIA redaction judge. Reply ONLY compact JSON {"verdict":"redact"|"keep","score":0-100,"reason":"one short line"}. Candidate: "Feeney v. Ohio," Kind: CITATION Context: legal reference 387 U.S. 93 (1990).'
       ) AS result;

SELECT 'path_B_http_post' AS path,
       json_extract_string(
         http_post(
           'http://127.0.0.1:11434/api/generate',
           map {'Content-Type': 'application/json'},
           {
             'model': 'llama3.2:3b',
             'prompt': 'Reply with only the word keep',
             'stream': false,
             'options': {'temperature': 0, 'num_predict': 4}
           }::JSON
         ) ->> 'body',
         '$.response'
       ) AS result;
