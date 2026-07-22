-- extensions.sql — earned pack only (every LOAD has a product SELECT).
-- Format: yaml→yaml · json→json · HTML→webbed · paths→scalarfs/hostfs · zip→zipfs
-- Inbound HTTP: quackapi. No outbound product fetch → no curl_httpfs.
--
-- Earned:
--   dns          v_url_hosts (dns_lookup on extracted hostnames)
--   read_lines   v_suggestion_line_context (scalarfs page_uri + lateral window)
--   splink_udfs  unaccent (norm) + double_metaphone (watchlist phonetic hits)

INSTALL quackapi FROM community; LOAD quackapi;

-- Core httpfs: ambient (INSTALL FROM community / remote readers). Not a product surface.
INSTALL httpfs; LOAD httpfs;

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
