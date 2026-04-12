-- OTel Logs tables for S3 storage cost estimation
-- Based on: https://clickhouse.com/docs/jp/use-cases/observability/schema-design
-- Adapted for ReplicatedMergeTree + Distributed on logs_cluster

CREATE DATABASE IF NOT EXISTS otel ON CLUSTER 'logs_cluster';

-- =============================================================================
-- otel_logs_local: Local ReplicatedMergeTree table
-- =============================================================================

CREATE TABLE IF NOT EXISTS otel.otel_logs_local ON CLUSTER 'logs_cluster'
(
    `Timestamp`          DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    `TraceId`            String CODEC(ZSTD(1)),
    `SpanId`             String CODEC(ZSTD(1)),
    `TraceFlags`         UInt32 CODEC(ZSTD(1)),
    `SeverityText`       LowCardinality(String) CODEC(ZSTD(1)),
    `SeverityNumber`     Int32 CODEC(ZSTD(1)),
    `ServiceName`        LowCardinality(String) CODEC(ZSTD(1)),
    `Body`               String CODEC(ZSTD(1)),
    `ResourceSchemaUrl`  String CODEC(ZSTD(1)),
    `ResourceAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `ScopeSchemaUrl`     String CODEC(ZSTD(1)),
    `ScopeName`          String CODEC(ZSTD(1)),
    `ScopeVersion`       String CODEC(ZSTD(1)),
    `ScopeAttributes`    Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `LogAttributes`      Map(LowCardinality(String), String) CODEC(ZSTD(1))
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/otel_logs_local',
    '{replica}'
)
PARTITION BY toDate(Timestamp)
ORDER BY (ServiceName, SeverityText, toUnixTimestamp(Timestamp), TraceId)
SETTINGS
    storage_policy = 's3_policy',
    index_granularity = 8192;

-- =============================================================================
-- otel_logs: Distributed table
-- =============================================================================

CREATE TABLE IF NOT EXISTS otel.otel_logs ON CLUSTER 'logs_cluster'
(
    `Timestamp`          DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    `TraceId`            String CODEC(ZSTD(1)),
    `SpanId`             String CODEC(ZSTD(1)),
    `TraceFlags`         UInt32 CODEC(ZSTD(1)),
    `SeverityText`       LowCardinality(String) CODEC(ZSTD(1)),
    `SeverityNumber`     Int32 CODEC(ZSTD(1)),
    `ServiceName`        LowCardinality(String) CODEC(ZSTD(1)),
    `Body`               String CODEC(ZSTD(1)),
    `ResourceSchemaUrl`  String CODEC(ZSTD(1)),
    `ResourceAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `ScopeSchemaUrl`     String CODEC(ZSTD(1)),
    `ScopeName`          String CODEC(ZSTD(1)),
    `ScopeVersion`       String CODEC(ZSTD(1)),
    `ScopeAttributes`    Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `LogAttributes`      Map(LowCardinality(String), String) CODEC(ZSTD(1))
)
ENGINE = Distributed('logs_cluster', 'otel', 'otel_logs_local', rand());
