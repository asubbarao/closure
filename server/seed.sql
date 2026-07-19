-- seed.sql — DEFERRED. Do not .read this file in boot.
--
-- HARD RULE (owner): no fabricated/hardcoded redaction suggestions yet.
-- Seeding suggestion rows (confidence scores, PII boxes) is an explicit
-- later pass. Until then, `suggestions` stays empty and the review UI
-- shows empty queues honestly.
--
-- When enabled, this file will CTAS suggestions by matching identities.json
-- phrases against real word n-grams (v_grams) from read_pdf_words.
SELECT 'seed.sql is deferred — suggestions remain empty' AS status;
