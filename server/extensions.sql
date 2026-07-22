-- extensions.sql — the runtime the model stack assumes. One source of truth so
-- offline boots (tests, one-off scripts) load exactly what app.sql loads.
--   pdf          page/word extraction     tera         HTML templates
--   rapidfuzz    search + name matching   crypto       hashes
--   finetype     PII typing               splink_udfs  unaccent + entity grouping
--   us_address_standardizer               address canon
INSTALL pdf FROM community; LOAD pdf;
INSTALL tera FROM community; LOAD tera;
INSTALL rapidfuzz FROM community; LOAD rapidfuzz;
INSTALL crypto FROM community; LOAD crypto;
INSTALL finetype FROM community; LOAD finetype;
INSTALL us_address_standardizer FROM community; LOAD us_address_standardizer;
INSTALL splink_udfs FROM community; LOAD splink_udfs;
