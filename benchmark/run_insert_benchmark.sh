#!/usr/bin/env bash
set -euo pipefail

# MgBench INSERT Performance Benchmark
#
# Measures:
#   A) Batch INSERT (INSERT INTO ... SELECT) with varying batch sizes
#   B) HTTP streaming INSERT via curl pipe
#
# Usage:
#   ./run_insert_benchmark.sh --host <clickhouse-host> [--port 8123] [--password <password>]

CH_HOST="${CH_HOST:-localhost}"
CH_PORT="${CH_PORT:-8123}"
CH_PASSWORD="${CH_PASSWORD:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --host) CH_HOST="$2"; shift 2 ;;
        --port) CH_PORT="$2"; shift 2 ;;
        --password) CH_PASSWORD="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_FILE="${RESULT_DIR}/insert_${TIMESTAMP}.tsv"

CH_URL="http://${CH_HOST}:${CH_PORT}"

AUTH_OPTS=()
if [[ -n "$CH_PASSWORD" ]]; then
    AUTH_OPTS=(--user "default:${CH_PASSWORD}")
fi

run_query() {
    local query="$1"
    local settings="${2:-}"
    local url="${CH_URL}/?database=mgbench"
    if [[ -n "$settings" ]]; then
        url="${url}&${settings}"
    fi
    curl -s "${AUTH_OPTS[@]}" "${url}" -d "$query"
}

# Run query and return elapsed time via curl -w
run_timed_query() {
    local query="$1"
    local settings="${2:-}"
    local url="${CH_URL}/?database=mgbench"
    if [[ -n "$settings" ]]; then
        url="${url}&${settings}"
    fi
    curl -s "${AUTH_OPTS[@]}" "${url}" -d "$query" \
        -o /dev/null -w '%{time_total}'
}

echo "=== MgBench INSERT Benchmark ==="
echo "Host: ${CH_HOST}:${CH_PORT}"
echo "Output: ${RESULT_FILE}"
echo ""

# Header
printf 'test_type\ttable\tbatch_size\telapsed_sec\trows_inserted\trows_per_sec\n' > "$RESULT_FILE"

# =========================================================================
# A) Batch INSERT (INSERT INTO ... SELECT)
# =========================================================================
echo "=== A) Batch INSERT Benchmark ==="

# Create temporary target table (same schema as logs2, simplest table)
run_query "DROP TABLE IF EXISTS mgbench.logs2_insert_bench ON CLUSTER 'logs_cluster'"
run_query "
    CREATE TABLE IF NOT EXISTS mgbench.logs2_insert_bench ON CLUSTER 'logs_cluster'
    (
        log_time    DateTime,
        client_ip   IPv4,
        request     String,
        status_code UInt16,
        object_size UInt64
    )
    ENGINE = ReplicatedMergeTree(
        '/clickhouse/tables/{shard}/mgbench_logs2_insert_bench',
        '{replica}'
    )
    PARTITION BY toYYYYMM(log_time)
    ORDER BY (status_code, log_time)
    SETTINGS storage_policy = 's3_policy', index_granularity = 8192
"

BATCH_SIZES=(1000000 10000000 100000000)

for batch_size in "${BATCH_SIZES[@]}"; do
    echo ""
    echo "--- Batch size: ${batch_size} ---"

    # Truncate target table
    run_query "TRUNCATE TABLE mgbench.logs2_insert_bench ON CLUSTER 'logs_cluster'"
    sleep 2

    elapsed_sec=$(run_timed_query "
        INSERT INTO logs2_insert_bench
        SELECT * FROM logs2_local
        LIMIT ${batch_size}
    " "max_execution_time=3600&max_insert_threads=4")

    actual_rows=$(run_query "SELECT count() FROM logs2_insert_bench")
    rows_per_sec=$(awk "BEGIN { printf \"%.0f\", ${actual_rows} / ${elapsed_sec} }" 2>/dev/null || echo "N/A")

    echo "  Rows: ${actual_rows}, Time: ${elapsed_sec}s, Rate: ${rows_per_sec} rows/sec"
    printf 'batch_insert\tlogs2\t%s\t%s\t%s\t%s\n' "${batch_size}" "${elapsed_sec}" "${actual_rows}" "${rows_per_sec}" >> "$RESULT_FILE"
done

# Cleanup batch insert table
run_query "DROP TABLE IF EXISTS mgbench.logs2_insert_bench ON CLUSTER 'logs_cluster'"

# =========================================================================
# B) HTTP Streaming INSERT
# =========================================================================
echo ""
echo "=== B) HTTP Streaming INSERT Benchmark ==="

# Create temporary target table
run_query "DROP TABLE IF EXISTS mgbench.logs2_stream_bench ON CLUSTER 'logs_cluster'"
run_query "
    CREATE TABLE IF NOT EXISTS mgbench.logs2_stream_bench ON CLUSTER 'logs_cluster'
    (
        log_time    DateTime,
        client_ip   IPv4,
        request     String,
        status_code UInt16,
        object_size UInt64
    )
    ENGINE = ReplicatedMergeTree(
        '/clickhouse/tables/{shard}/mgbench_logs2_stream_bench',
        '{replica}'
    )
    PARTITION BY toYYYYMM(log_time)
    ORDER BY (status_code, log_time)
    SETTINGS storage_policy = 's3_policy', index_granularity = 8192
"

STREAM_SIZES=(100000 1000000 10000000)

for stream_size in "${STREAM_SIZES[@]}"; do
    echo ""
    echo "--- Stream size: ${stream_size} ---"

    # Truncate target table
    run_query "TRUNCATE TABLE mgbench.logs2_stream_bench ON CLUSTER 'logs_cluster'"
    sleep 2

    # Read from source as TSV and pipe to target via HTTP, measure total time
    start_sec=$(date +%s)

    select_query="SELECT * FROM logs2_local LIMIT ${stream_size} FORMAT TabSeparated"
    insert_query="INSERT INTO logs2_stream_bench FORMAT TabSeparated"

    curl -s "${AUTH_OPTS[@]}" \
        "${CH_URL}/?database=mgbench" -d "${select_query}" \
    | curl -s "${AUTH_OPTS[@]}" \
        "${CH_URL}/?database=mgbench&query=${insert_query// /+}" \
        --data-binary @-

    end_sec=$(date +%s)
    elapsed_sec=$((end_sec - start_sec))
    if [[ "$elapsed_sec" -eq 0 ]]; then elapsed_sec=1; fi

    actual_rows=$(run_query "SELECT count() FROM logs2_stream_bench")
    rows_per_sec=$(awk "BEGIN { printf \"%.0f\", ${actual_rows} / ${elapsed_sec} }" 2>/dev/null || echo "N/A")

    echo "  Rows: ${actual_rows}, Time: ${elapsed_sec}s, Rate: ${rows_per_sec} rows/sec"
    printf 'http_stream\tlogs2\t%s\t%s\t%s\t%s\n' "${stream_size}" "${elapsed_sec}" "${actual_rows}" "${rows_per_sec}" >> "$RESULT_FILE"
done

# Cleanup
run_query "DROP TABLE IF EXISTS mgbench.logs2_stream_bench ON CLUSTER 'logs_cluster'"

echo ""
echo "=== INSERT Benchmark Complete ==="
echo "Results saved to: ${RESULT_FILE}"
