-- Create the logs database
CREATE DATABASE IF NOT EXISTS logs ON CLUSTER 'logs_cluster';

-- ReplicatedMergeTree table on each shard (local table)
CREATE TABLE IF NOT EXISTS logs.logs_local ON CLUSTER 'logs_cluster'
(
    tenant_id    String,
    timestamp    DateTime64(3),
    trace_id     String DEFAULT '',
    span_id      String DEFAULT '',
    severity     Enum8('TRACE'=0, 'DEBUG'=1, 'INFO'=2, 'WARN'=3, 'ERROR'=4, 'FATAL'=5),
    service      LowCardinality(String),
    host         LowCardinality(String),
    message      String,
    attributes   Map(String, String),
    resource     Map(String, String),

    INDEX idx_message message TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 1,
    INDEX idx_trace_id trace_id TYPE bloom_filter(0.01) GRANULARITY 1
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/logs_local',
    '{replica}'
)
PARTITION BY toYYYYMM(timestamp)
ORDER BY (tenant_id, service, severity, timestamp)
TTL toDateTime(timestamp) + INTERVAL 30 DAY DELETE
SETTINGS
    storage_policy = 's3_policy',
    index_granularity = 8192,
    ttl_only_drop_parts = 1;

-- Distributed table for cross-shard queries
CREATE TABLE IF NOT EXISTS logs.logs ON CLUSTER 'logs_cluster'
(
    tenant_id    String,
    timestamp    DateTime64(3),
    trace_id     String DEFAULT '',
    span_id      String DEFAULT '',
    severity     Enum8('TRACE'=0, 'DEBUG'=1, 'INFO'=2, 'WARN'=3, 'ERROR'=4, 'FATAL'=5),
    service      LowCardinality(String),
    host         LowCardinality(String),
    message      String,
    attributes   Map(String, String),
    resource     Map(String, String)
)
ENGINE = Distributed('logs_cluster', 'logs', 'logs_local', sipHash64(tenant_id));

-- Row Policy for multi-tenant isolation
-- Execute per-tenant during tenant provisioning:
--
-- CREATE ROW POLICY IF NOT EXISTS tenant_{tenant_id}_policy
--   ON logs.logs_local
--   FOR SELECT
--   USING tenant_id = '{tenant_id}'
--   TO tenant_{tenant_id}_user;
--
-- CREATE ROW POLICY IF NOT EXISTS tenant_{tenant_id}_dist_policy
--   ON logs.logs
--   FOR SELECT
--   USING tenant_id = '{tenant_id}'
--   TO tenant_{tenant_id}_user;
