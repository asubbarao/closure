-- model.sql — load order for the domain stack.
--   store (durable) → raw/ → typed/ → domain/ → serve/

.read server/store.sql
.read server/raw/sources.sql
.read server/typed/sources.sql
.read server/domain/facts.sql
.read server/domain/detect.sql
.read server/domain/fold.sql
.read server/serve/marts.sql
.read server/serve/extras.sql

SELECT 'model loaded' AS phase;
