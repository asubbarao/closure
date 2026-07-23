-- extensions.sql — earned pack. DuckDB is the app runtime (better FastAPI).
-- Format: yaml→yaml · json→json · HTML→webbed · paths→scalarfs/hostfs · zip→zipfs
-- HTTP stack (order matters):
--   httpfs → curl_httpfs (quackapi MultiCurl transport) → cache_httpfs (read cache)
--
-- Earned (product SELECTs):
--   dns          v_url_hosts (dns_lookup on extracted hostnames)
--   read_lines   v_suggestion_line_context (scalarfs page_uri + lateral window)
--   splink_udfs  unaccent only (normalize watchlist / tokens)
--   cache_httpfs v_http_cache_* status + remote https/s3 reads land on disk cache
-- Earned (runtime):
--   curl_httpfs  quackapi outbound HTTPUtil — LOAD before serve

INSTALL quackapi FROM community; LOAD quackapi;

-- Outbound stack: transport first, then read cache wrapping http/s3/hf.
INSTALL httpfs; LOAD httpfs;
INSTALL curl_httpfs FROM community; LOAD curl_httpfs;
INSTALL cache_httpfs FROM community; LOAD cache_httpfs;
INSTALL shellfs FROM community; LOAD shellfs;

-- Project-local on-disk cache (not /tmp). shellfs mkdir; then pin directory.
SELECT content AS cache_httpfs_mkdir
FROM read_text('mkdir -p .tmp/cache_httpfs |');
SET cache_httpfs_cache_directory = '.tmp/cache_httpfs';
-- on_disk default; profile temp for hit/miss observability
SET cache_httpfs_profile_type = 'temp';

INSTALL pdf FROM community; LOAD pdf;
INSTALL tera FROM community; LOAD tera;
-- shellfs already LOADed above for cache dir mkdir
INSTALL hostfs FROM community; LOAD hostfs;
INSTALL scalarfs FROM community; LOAD scalarfs;
INSTALL zipfs FROM community; LOAD zipfs;
INSTALL read_lines FROM community; LOAD read_lines;
INSTALL webbed FROM community; LOAD webbed;
INSTALL yaml FROM community; LOAD yaml;
INSTALL rapidfuzz FROM community; LOAD rapidfuzz;
INSTALL func_apply FROM community; LOAD func_apply;
INSTALL finetype FROM community; LOAD finetype;
INSTALL hashfuncs FROM community; LOAD hashfuncs;
INSTALL splink_udfs FROM community; LOAD splink_udfs;
INSTALL inflector FROM community; LOAD inflector;
INSTALL bitfilters FROM community; LOAD bitfilters;
INSTALL urlpattern FROM community; LOAD urlpattern;
INSTALL dns FROM community; LOAD dns;
INSTALL semantic_views FROM community; LOAD semantic_views;
