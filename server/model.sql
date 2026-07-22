-- model.sql — load order for the domain stack.
-- Folder layout mirrors layers:
--   raw/     wire readers
--   typed/   raw + typed siblings
--   domain/  facts, detect, decision fold
--   serve/   UI marts + optional panels
-- routes.sql is HTTP only (loaded by app.sql after this).

.read server/raw/sources.sql
.read server/typed/sources.sql
.read server/domain/facts.sql
.read server/domain/detect.sql
.read server/domain/fold.sql
.read server/serve/marts.sql
.read server/serve/extras.sql

SELECT 'model loaded' AS phase;
