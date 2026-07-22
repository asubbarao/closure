-- http_cache.sql — cache_httpfs surfaces (config / status / access).
-- Remote https/s3/hf reads use the cache FS automatically once LOADed.
-- Optional warm: SET VARIABLE remote_probe = 'https://…' before .read, then:
--   SELECT length(content) FROM read_text(getvariable('remote_probe'));

CREATE OR REPLACE VIEW v_http_cache_config AS
SELECT * FROM cache_httpfs_get_cache_config();

CREATE OR REPLACE VIEW v_http_cache_type AS
SELECT * FROM cache_httpfs_get_cache_type();

CREATE OR REPLACE VIEW v_http_cache_filesystems AS
SELECT * FROM cache_httpfs_list_registered_filesystems();

CREATE OR REPLACE VIEW v_http_cache_status AS
SELECT * FROM cache_httpfs_cache_status_query();

CREATE OR REPLACE VIEW v_http_cache_access AS
SELECT * FROM cache_httpfs_cache_access_info_query();

CREATE OR REPLACE VIEW v_http_cache AS
SELECT
    cache_httpfs_get_ondisk_data_cache_size() AS ondisk_bytes,
    (SELECT list(registered_filesystems)
     FROM cache_httpfs_list_registered_filesystems()) AS filesystems,
    (SELECT any_value("data cache type") FROM cache_httpfs_get_cache_config()) AS data_cache_type,
    (SELECT any_value("disk cache directories") FROM cache_httpfs_get_cache_config()) AS disk_dirs;

SELECT
    cache_httpfs_get_ondisk_data_cache_size() AS ondisk_bytes,
    'cache_httpfs ready' AS cache_httpfs_status;
