-- MgBench (Brown University Benchmark) tables
-- Adapted for ReplicatedMergeTree + Distributed on logs_cluster

CREATE DATABASE IF NOT EXISTS mgbench ON CLUSTER 'logs_cluster';

-- =============================================================================
-- logs1: System performance metrics (CPU, memory, disk, network)
-- =============================================================================

CREATE TABLE IF NOT EXISTS mgbench.logs1_local ON CLUSTER 'logs_cluster'
(
    log_time      DateTime,
    machine_name  LowCardinality(String),
    machine_group LowCardinality(String),
    cpu_idle      Nullable(Float32),
    cpu_nice      Nullable(Float32),
    cpu_system    Nullable(Float32),
    cpu_user      Nullable(Float32),
    cpu_wio       Nullable(Float32),
    disk_free     Nullable(Float32),
    disk_total    Nullable(Float32),
    part_max_used Nullable(Float32),
    load_fifteen  Nullable(Float32),
    load_five     Nullable(Float32),
    load_one      Nullable(Float32),
    mem_buffers   Nullable(Float32),
    mem_cached    Nullable(Float32),
    mem_free      Nullable(Float32),
    mem_shared    Nullable(Float32),
    swap_free     Nullable(Float32),
    bytes_in      Nullable(Float32),
    bytes_out     Nullable(Float32)
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/mgbench_logs1_local',
    '{replica}'
)
PARTITION BY toYYYYMM(log_time)
ORDER BY (machine_group, machine_name, log_time)
SETTINGS
    storage_policy = 's3_policy',
    index_granularity = 8192;

CREATE TABLE IF NOT EXISTS mgbench.logs1 ON CLUSTER 'logs_cluster'
(
    log_time      DateTime,
    machine_name  LowCardinality(String),
    machine_group LowCardinality(String),
    cpu_idle      Nullable(Float32),
    cpu_nice      Nullable(Float32),
    cpu_system    Nullable(Float32),
    cpu_user      Nullable(Float32),
    cpu_wio       Nullable(Float32),
    disk_free     Nullable(Float32),
    disk_total    Nullable(Float32),
    part_max_used Nullable(Float32),
    load_fifteen  Nullable(Float32),
    load_five     Nullable(Float32),
    load_one      Nullable(Float32),
    mem_buffers   Nullable(Float32),
    mem_cached    Nullable(Float32),
    mem_free      Nullable(Float32),
    mem_shared    Nullable(Float32),
    swap_free     Nullable(Float32),
    bytes_in      Nullable(Float32),
    bytes_out     Nullable(Float32)
)
ENGINE = Distributed('logs_cluster', 'mgbench', 'logs1_local', rand());

-- =============================================================================
-- logs2: Web server access logs
-- =============================================================================

CREATE TABLE IF NOT EXISTS mgbench.logs2_local ON CLUSTER 'logs_cluster'
(
    log_time    DateTime,
    client_ip   IPv4,
    request     String,
    status_code UInt16,
    object_size UInt64
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/mgbench_logs2_local',
    '{replica}'
)
PARTITION BY toYYYYMM(log_time)
ORDER BY (status_code, log_time)
SETTINGS
    storage_policy = 's3_policy',
    index_granularity = 8192;

CREATE TABLE IF NOT EXISTS mgbench.logs2 ON CLUSTER 'logs_cluster'
(
    log_time    DateTime,
    client_ip   IPv4,
    request     String,
    status_code UInt16,
    object_size UInt64
)
ENGINE = Distributed('logs_cluster', 'mgbench', 'logs2_local', rand());

-- =============================================================================
-- logs3: IoT sensor/event logs
-- =============================================================================

CREATE TABLE IF NOT EXISTS mgbench.logs3_local ON CLUSTER 'logs_cluster'
(
    log_time     DateTime64,
    device_id    FixedString(15),
    device_name  LowCardinality(String),
    device_type  LowCardinality(String),
    device_floor UInt8,
    event_type   LowCardinality(String),
    event_unit   FixedString(1),
    event_value  Nullable(Float32)
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/mgbench_logs3_local',
    '{replica}'
)
PARTITION BY toYYYYMM(log_time)
ORDER BY (event_type, log_time)
SETTINGS
    storage_policy = 's3_policy',
    index_granularity = 8192;

CREATE TABLE IF NOT EXISTS mgbench.logs3 ON CLUSTER 'logs_cluster'
(
    log_time     DateTime64,
    device_id    FixedString(15),
    device_name  LowCardinality(String),
    device_type  LowCardinality(String),
    device_floor UInt8,
    event_type   LowCardinality(String),
    event_unit   FixedString(1),
    event_value  Nullable(Float32)
)
ENGINE = Distributed('logs_cluster', 'mgbench', 'logs3_local', rand());
