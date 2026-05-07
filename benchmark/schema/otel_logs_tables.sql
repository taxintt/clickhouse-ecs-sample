-- OTel Logs tables for S3 storage cost estimation
-- Base: https://clickhouse.com/docs/jp/use-cases/observability/schema-design
--
-- This schema reflects ClickHouse OTel best practice with several refinements
-- inspired by Langfuse v4's observation-centric write-up
-- ( https://tubone-project24.xyz/2026/05/02/langfuse-v4-observation-centric-clickhouse-deep-dive/ ).
--
-- Note: not every Langfuse v4 optimization carries over to logs. Trace-
-- coherence tricks (xxHash32(TraceId) in ORDER BY, SAMPLE BY trace,
-- cityHash64(TraceId) sharding, an events_core-style preview MV) assume
--   * trace_id is populated on 100% of rows
--   * payloads are MB-scale
--   * trace-1-tree views are the dominant UI pattern
-- All three break for OTel logs (most logs have no trace_id, Body is KB-
-- scale, severity-filtered time-window queries dominate). Those tricks are
-- intentionally NOT applied here. What we keep are the v4 takeaways that
-- stand alone for logs too: skip indexes, narrow integer types,
-- LowCardinality coverage, MATERIALIZED columns hoisting hot Map keys,
-- prewarm caches, and ZooKeeper path templating.

CREATE DATABASE IF NOT EXISTS otel ON CLUSTER 'logs_cluster';

-- =============================================================================
-- otel_logs_local: Local ReplicatedMergeTree table
-- =============================================================================

CREATE TABLE IF NOT EXISTS otel.otel_logs_local ON CLUSTER 'logs_cluster'
(
    `Timestamp`          DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    `TraceId`            String CODEC(ZSTD(1)),
    `SpanId`             String CODEC(ZSTD(1)),
    `TraceFlags`         UInt8  CODEC(ZSTD(1)),
    `SeverityText`       LowCardinality(String) CODEC(ZSTD(1)),
    `SeverityNumber`     UInt8  CODEC(ZSTD(1)),
    `ServiceName`        LowCardinality(String) CODEC(ZSTD(1)),
    `Body`               String CODEC(ZSTD(3)),
    `ResourceSchemaUrl`  LowCardinality(String) CODEC(ZSTD(1)),
    `ResourceAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `ScopeSchemaUrl`     LowCardinality(String) CODEC(ZSTD(1)),
    `ScopeName`          LowCardinality(String) CODEC(ZSTD(1)),
    `ScopeVersion`       LowCardinality(String) CODEC(ZSTD(1)),
    `ScopeAttributes`    Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    `LogAttributes`      Map(LowCardinality(String), String) CODEC(ZSTD(1)),

    -- Hoist hot ResourceAttributes keys to dedicated columns so equality
    -- filters and group-bys skip Map lookup overhead.
    `Namespace`   LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.namespace.name'],
    `PodName`     LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.pod.name'],
    `Environment` LowCardinality(String) MATERIALIZED ResourceAttributes['deployment.environment'],
    `HostName`    LowCardinality(String) MATERIALIZED ResourceAttributes['host.name'],

    -- TraceId/SpanId are intentionally NOT in ORDER BY (most logs have no
    -- TraceId; putting it in the sort key would clump empty-TraceId rows on
    -- a hash collision). bloom_filter skip index handles trace lookups.
    INDEX idx_trace_id    TraceId TYPE bloom_filter(0.001)     GRANULARITY 1,
    INDEX idx_span_id     SpanId  TYPE bloom_filter(0.001)     GRANULARITY 1,
    INDEX idx_body_tokens Body    TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 1,
    INDEX idx_res_keys    mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_log_keys    mapKeys(LogAttributes)      TYPE bloom_filter(0.01) GRANULARITY 1
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/{database}/{table}',
    '{replica}'
)
PARTITION BY toDate(Timestamp)
-- Keys reflect log workloads: ServiceName narrows tenant, hour bucket
-- prunes time ranges, SeverityNumber sorts log levels (the dominant log
-- filter), Timestamp orders within. PRIMARY KEY is a short prefix to keep
-- the sparse index compact.
PRIMARY KEY (ServiceName, toStartOfHour(Timestamp))
ORDER BY    (ServiceName, toStartOfHour(Timestamp), SeverityNumber, Timestamp)
SETTINGS
    storage_policy            = 's3_policy',
    index_granularity         = 8192,
    prewarm_mark_cache        = 1,
    prewarm_primary_key_cache = 1;

-- =============================================================================
-- otel_logs: Distributed table over otel_logs_local
-- Sharded by rand() rather than by TraceId hash: a non-trivial fraction of
-- logs have no TraceId and would all collide on one shard under a hash
-- scheme. Trace lookups rely on the per-shard bloom_filter index.
-- =============================================================================

CREATE TABLE IF NOT EXISTS otel.otel_logs ON CLUSTER 'logs_cluster'
AS otel.otel_logs_local
ENGINE = Distributed('logs_cluster', 'otel', 'otel_logs_local', rand());
