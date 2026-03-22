-- Extended logs2 tables with raw_log String column for fulltext search benchmarking
-- Three patterns: no index, tokenbf_v1, ngrambf_v1

-- =============================================================================
-- Pattern A: No index on raw_log
-- =============================================================================

CREATE TABLE IF NOT EXISTS mgbench.logs2_ext_noidx_local ON CLUSTER 'logs_cluster'
(
    log_time    DateTime,
    client_ip   IPv4,
    request     String,
    status_code UInt16,
    object_size UInt64,
    raw_log     String
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/mgbench_logs2_ext_noidx_local',
    '{replica}'
)
PARTITION BY toYYYYMM(log_time)
ORDER BY (status_code, log_time)
SETTINGS
    storage_policy = 's3_policy',
    index_granularity = 8192;

CREATE TABLE IF NOT EXISTS mgbench.logs2_ext_noidx ON CLUSTER 'logs_cluster'
(
    log_time    DateTime,
    client_ip   IPv4,
    request     String,
    status_code UInt16,
    object_size UInt64,
    raw_log     String
)
ENGINE = Distributed('logs_cluster', 'mgbench', 'logs2_ext_noidx_local', rand());

-- =============================================================================
-- Pattern B: tokenbf_v1 index (good for hasToken / exact token matching)
-- =============================================================================

CREATE TABLE IF NOT EXISTS mgbench.logs2_ext_tokenbf_local ON CLUSTER 'logs_cluster'
(
    log_time    DateTime,
    client_ip   IPv4,
    request     String,
    status_code UInt16,
    object_size UInt64,
    raw_log     String,

    INDEX idx_raw_log raw_log TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 1
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/mgbench_logs2_ext_tokenbf_local',
    '{replica}'
)
PARTITION BY toYYYYMM(log_time)
ORDER BY (status_code, log_time)
SETTINGS
    storage_policy = 's3_policy',
    index_granularity = 8192;

CREATE TABLE IF NOT EXISTS mgbench.logs2_ext_tokenbf ON CLUSTER 'logs_cluster'
(
    log_time    DateTime,
    client_ip   IPv4,
    request     String,
    status_code UInt16,
    object_size UInt64,
    raw_log     String
)
ENGINE = Distributed('logs_cluster', 'mgbench', 'logs2_ext_tokenbf_local', rand());

-- =============================================================================
-- Pattern C: ngrambf_v1 index (good for substring / partial matching)
-- =============================================================================

CREATE TABLE IF NOT EXISTS mgbench.logs2_ext_ngrambf_local ON CLUSTER 'logs_cluster'
(
    log_time    DateTime,
    client_ip   IPv4,
    request     String,
    status_code UInt16,
    object_size UInt64,
    raw_log     String,

    INDEX idx_raw_log raw_log TYPE ngrambf_v1(4, 32768, 3, 0) GRANULARITY 1
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/mgbench_logs2_ext_ngrambf_local',
    '{replica}'
)
PARTITION BY toYYYYMM(log_time)
ORDER BY (status_code, log_time)
SETTINGS
    storage_policy = 's3_policy',
    index_granularity = 8192;

CREATE TABLE IF NOT EXISTS mgbench.logs2_ext_ngrambf ON CLUSTER 'logs_cluster'
(
    log_time    DateTime,
    client_ip   IPv4,
    request     String,
    status_code UInt16,
    object_size UInt64,
    raw_log     String
)
ENGINE = Distributed('logs_cluster', 'mgbench', 'logs2_ext_ngrambf_local', rand());

-- =============================================================================
-- Data population: Insert logs2 data with generated raw_log column
-- =============================================================================
-- Run these AFTER the tables are created and logs2_local has data.
--
-- The raw_log column simulates realistic application log lines:
--   "2012-10-01 08:30:00 [INFO] request_id=a1b2c3 service=web-gateway method=GET path=/courses/cs101 status=200 size=4096 client=192.168.1.1 duration_ms=42 error=null"

-- Pattern A: no index
-- INSERT INTO mgbench.logs2_ext_noidx_local
-- SELECT
--     log_time,
--     client_ip,
--     request,
--     status_code,
--     object_size,
--     concat(
--         toString(log_time), ' ',
--         multiIf(status_code >= 500, '[ERROR]', status_code >= 400, '[WARN]', '[INFO]'),
--         ' request_id=', hex(sipHash64(concat(toString(log_time), toString(client_ip), request))),
--         ' service=', arrayElement(['web-gateway', 'api-server', 'auth-service', 'data-pipeline', 'cache-proxy'], (cityHash64(request) % 5) + 1),
--         ' method=', arrayElement(['GET', 'POST', 'PUT', 'DELETE', 'PATCH'], (cityHash64(concat(request, 'method')) % 5) + 1),
--         ' path=', request,
--         ' status=', toString(status_code),
--         ' size=', toString(object_size),
--         ' client=', IPv4NumToString(toUInt32(client_ip)),
--         ' duration_ms=', toString(rand() % 5000),
--         multiIf(
--             status_code >= 500, concat(' error=InternalServerError stacktrace=java.lang.NullPointerException at com.app.service.Handler.process(Handler.java:', toString(rand() % 500), ')'),
--             status_code = 404, ' error=NotFound resource_missing=true',
--             status_code = 403, ' error=Forbidden auth_failed=true',
--             status_code = 429, ' error=TooManyRequests rate_limit_exceeded=true',
--             ' error=null'
--         )
--     ) AS raw_log
-- FROM mgbench.logs2_local;
--
-- Repeat the same INSERT for tokenbf and ngrambf tables:
--   INSERT INTO mgbench.logs2_ext_tokenbf_local SELECT ... (same query)
--   INSERT INTO mgbench.logs2_ext_ngrambf_local SELECT ... (same query)
