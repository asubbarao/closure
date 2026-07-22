-- extensions.sql — earned pack. DuckDB is the app runtime (better FastAPI).
-- Format: yaml→yaml · json→json · HTML→webbed · paths→scalarfs/hostfs · zip→zipfs
-- Outbound HTTP: curl_httpfs (pool + HTTP/2 + async). Inbound: quackapi httplib.

INSTALL quackapi FROM community; LOAD quackapi;

-- Outbound: core httpfs (not community — origin clash if FORCE INSTALL). curl_httpfs optional.
INSTALL httpfs; LOAD httpfs;
INSTALL curl_httpfs FROM community; LOAD curl_httpfs;

INSTALL pdf FROM community; LOAD pdf;
INSTALL tera FROM community; LOAD tera;
INSTALL shellfs FROM community; LOAD shellfs;
INSTALL hostfs FROM community; LOAD hostfs;
INSTALL scalarfs FROM community; LOAD scalarfs;
INSTALL zipfs FROM community; LOAD zipfs;
INSTALL read_lines FROM community; LOAD read_lines;
INSTALL webbed FROM community; LOAD webbed;
INSTALL yaml FROM community; LOAD yaml;
INSTALL rapidfuzz FROM community; LOAD rapidfuzz;
INSTALL finetype FROM community; LOAD finetype;
INSTALL hashfuncs FROM community; LOAD hashfuncs;
INSTALL splink_udfs FROM community; LOAD splink_udfs;
INSTALL inflector FROM community; LOAD inflector;
INSTALL bitfilters FROM community; LOAD bitfilters;
INSTALL urlpattern FROM community; LOAD urlpattern;
INSTALL dns FROM community; LOAD dns;
INSTALL semantic_views FROM community; LOAD semantic_views;

-- Optional: pure-SQL quality tests (skip if community pin missing for this build)
-- INSTALL dqtest FROM community; LOAD dqtest;
