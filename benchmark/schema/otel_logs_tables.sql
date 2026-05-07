-- OTel Logs tables for S3 storage cost estimation
-- Base: https://clickhouse.com/docs/jp/use-cases/observability/schema-design
-- Refined per Langfuse v4 (observation-centric) design principles:
--   https://tubone-project24.xyz/2026/05/02/langfuse-v4-observation-centric-clickhouse-deep-dive/
--
-- Key changes from the initial v3-style schema:
--   1. ORDER BY redesigned: SeverityText removed (mirrors v4 dropping `type`),
--      time grain switched to per-minute, xxHash32(TraceId) added so spans of
--      one trace land in the same granule.
--   2. PRIMARY KEY trimmed to a prefix of ORDER BY to keep the sparse index
--      compact while still supporting SAMPLE BY.
--   3. SAMPLE BY xxHash32(TraceId) for trace-aware sampling.
--   4. index_granularity_bytes raised to 64 MiB — Body can be multi-KB JSON,
--      same trade-off as Langfuse's input/output columns.
--   5. Type narrowing: TraceFlags UInt32 -> UInt8 (OTel spec is 8-bit),
--      SeverityNumber Int32 -> UInt8 (spec values 1-24), low-cardinality
--      schema/scope columns marked LowCardinality.
--   6. Body compressed with ZSTD(3) — bigger CPU cost, smaller S3 footprint.
--   7. Materialized columns hoist commonly-filtered ResourceAttributes keys
--      (analogous to v4 propagating user_id/session_id onto observations).
--   8. Skip indexes for TraceId/SpanId lookups, Body token search, Map keys.
--   9. Distributed shard key changed from rand() to cityHash64(TraceId) so
--      all logs of one trace stay on one shard.
--  10. otel_logs_core_mv added — slim copy with truncated Body for list UIs,
--      mirroring Langfuse v4's events_core_mv pattern.

CREATE DATABASE IF NOT EXISTS otel ON CLUSTER 'logs_cluster';

-- =============================================================================
-- otel_logs_local: Local ReplicatedMergeTree table (full payload)
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

    -- Hoist hot ResourceAttributes keys to top-level columns so filters and
    -- group-bys avoid Map lookup overhead. Cf. Langfuse v4 propagating
    -- user_id/session_id onto each observation.
    `Namespace`   LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.namespace.name'],
    `PodName`     LowCardinality(String) MATERIALIZED ResourceAttributes['k8s.pod.name'],
    `Environment` LowCardinality(String) MATERIALIZED ResourceAttributes['deployment.environment'],
    `HostName`    LowCardinality(String) MATERIALIZED ResourceAttributes['host.name'],

    INDEX idx_trace_id    TraceId        TYPE bloom_filter(0.001)     GRANULARITY 1,
    INDEX idx_span_id     SpanId         TYPE bloom_filter(0.001)     GRANULARITY 1,
    INDEX idx_severity    SeverityNumber TYPE minmax                  GRANULARITY 1,
    INDEX idx_body_tokens Body           TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 1,
    INDEX idx_res_keys    mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
    INDEX idx_log_keys    mapKeys(LogAttributes)      TYPE bloom_filter(0.01) GRANULARITY 1
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/{database}/{table}',
    '{replica}'
)
PARTITION BY toDate(Timestamp)
PRIMARY KEY (ServiceName, toStartOfMinute(Timestamp), xxHash32(TraceId))
ORDER BY    (ServiceName, toStartOfMinute(Timestamp), xxHash32(TraceId), Timestamp)
SAMPLE BY xxHash32(TraceId)
SETTINGS
    storage_policy             = 's3_policy',
    index_granularity          = 8192,
    index_granularity_bytes    = 67108864,    -- 64 MiB; Body can be multi-KB
    merge_max_block_size_bytes = 67108864,
    enable_block_number_column = 1,
    enable_block_offset_column = 1,
    prewarm_mark_cache         = 1,
    prewarm_primary_key_cache  = 1;

-- =============================================================================
-- otel_logs: Distributed table over otel_logs_local
-- Sharding by cityHash64(TraceId) keeps every log of a single trace on one
-- shard so trace-id lookups don't fan out across the cluster.
-- =============================================================================

CREATE TABLE IF NOT EXISTS otel.otel_logs ON CLUSTER 'logs_cluster'
AS otel.otel_logs_local
ENGINE = Distributed('logs_cluster', 'otel', 'otel_logs_local', cityHash64(TraceId));

-- =============================================================================
-- otel_logs_core_local: slim preview table for list/dashboard views.
-- Body is truncated to 256 chars; detail views still hit otel_logs_local.
-- Modeled on Langfuse v4 events_core_mv.
-- =============================================================================

CREATE TABLE IF NOT EXISTS otel.otel_logs_core_local ON CLUSTER 'logs_cluster'
(
    `Timestamp`      DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    `TraceId`        String CODEC(ZSTD(1)),
    `SpanId`         String CODEC(ZSTD(1)),
    `ServiceName`    LowCardinality(String) CODEC(ZSTD(1)),
    `SeverityText`   LowCardinality(String) CODEC(ZSTD(1)),
    `SeverityNumber` UInt8 CODEC(ZSTD(1)),
    `BodyPreview`    String CODEC(ZSTD(1)),

    INDEX idx_trace_id TraceId TYPE bloom_filter(0.001) GRANULARITY 1
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/{database}/{table}',
    '{replica}'
)
PARTITION BY toDate(Timestamp)
PRIMARY KEY (ServiceName, toStartOfMinute(Timestamp), xxHash32(TraceId))
ORDER BY    (ServiceName, toStartOfMinute(Timestamp), xxHash32(TraceId), Timestamp)
SAMPLE BY xxHash32(TraceId)
SETTINGS
    storage_policy             = 's3_policy',
    index_granularity          = 8192,
    index_granularity_bytes    = 67108864,
    merge_max_block_size_bytes = 67108864;

CREATE MATERIALIZED VIEW IF NOT EXISTS otel.otel_logs_core_mv ON CLUSTER 'logs_cluster'
TO otel.otel_logs_core_local AS
SELECT
    Timestamp,
    TraceId,
    SpanId,
    ServiceName,
    SeverityText,
    SeverityNumber,
    leftUTF8(Body, 256) AS BodyPreview
FROM otel.otel_logs_local;

CREATE TABLE IF NOT EXISTS otel.otel_logs_core ON CLUSTER 'logs_cluster'
AS otel.otel_logs_core_local
ENGINE = Distributed('logs_cluster', 'otel', 'otel_logs_core_local', cityHash64(TraceId));
