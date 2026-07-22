-- extensions.sql — earned community pack (DuckDB ≥ 1.5.4).
-- Format rule: yaml for yaml files · json for json files · HTML via webbed · paths via scalarfs.
-- Not product: events (process hooks, not relations).

INSTALL quackapi FROM community; LOAD quackapi;
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
