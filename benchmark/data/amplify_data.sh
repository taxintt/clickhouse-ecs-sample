#!/usr/bin/env bash
set -euo pipefail

# Amplify MgBench data to hundreds of millions of rows
#
# Strategy: Doubles data each iteration by shifting timestamps and adding
# suffixes to identifiers. Repeats until target row count is reached.
#
# Usage:
#   ./amplify_data.sh --host <clickhouse-host> [--port 8123] [--password <password>] \
#                     [--target-logs1 300000000] [--target-logs2 500000000] [--target-logs3 300000000]

CH_HOST="${CH_HOST:-localhost}"
CH_PORT="${CH_PORT:-8123}"
CH_PASSWORD="${CH_PASSWORD:-}"
TARGET_LOGS1="${TARGET_LOGS1:-300000000}"
TARGET_LOGS2="${TARGET_LOGS2:-500000000}"
TARGET_LOGS3="${TARGET_LOGS3:-300000000}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --host) CH_HOST="$2"; shift 2 ;;
        --port) CH_PORT="$2"; shift 2 ;;
        --password) CH_PASSWORD="$2"; shift 2 ;;
        --target-logs1) TARGET_LOGS1="$2"; shift 2 ;;
        --target-logs2) TARGET_LOGS2="$2"; shift 2 ;;
        --target-logs3) TARGET_LOGS3="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

CURL_OPTS=(-s --fail-with-body)
if [[ -n "$CH_PASSWORD" ]]; then
    CURL_OPTS+=(--user "default:${CH_PASSWORD}")
fi

CH_URL="http://${CH_HOST}:${CH_PORT}"

run_query() {
    local query="$1"
    local settings="${2:-}"
    local url="${CH_URL}/?database=mgbench"
    if [[ -n "$settings" ]]; then
        url="${url}&${settings}"
    fi
    curl "${CURL_OPTS[@]}" "${url}" -d "$query"
}

get_count() {
    run_query "SELECT count() FROM $1"
}

wait_replication() {
    echo "  Waiting for replication to complete..."
    local pending=1
    while [[ "$pending" -gt 0 ]]; do
        sleep 5
        pending=$(run_query "SELECT count() FROM system.replication_queue WHERE type = 'GET_PART'" 2>/dev/null || echo "0")
        if [[ "$pending" -gt 0 ]]; then
            echo "    Replication queue: ${pending} parts pending..."
        fi
    done
    echo "  Replication complete."
}

echo "=== MgBench Data Amplification ==="
echo "Host: ${CH_HOST}:${CH_PORT}"
echo "Targets: logs1=${TARGET_LOGS1}, logs2=${TARGET_LOGS2}, logs3=${TARGET_LOGS3}"
echo ""

# --- logs1: System metrics ---
echo "=== Amplifying logs1 (target: ${TARGET_LOGS1}) ==="
iteration=0
while true; do
    current=$(get_count "logs1_local")
    echo "  Current: ${current} rows"
    if [[ "$current" -ge "$TARGET_LOGS1" ]]; then
        echo "  Target reached."
        break
    fi

    iteration=$((iteration + 1))
    echo "  Iteration ${iteration}: doubling data..."
    start_time=$(date +%s)

    # Shift timestamps by a random interval (3-12 months) and add suffix to machine_name
    run_query "
        INSERT INTO logs1_local
        SELECT
            log_time + toIntervalMonth(${iteration} * 3 + rand() % 6),
            concat(machine_name, '_v${iteration}'),
            machine_group,
            cpu_idle, cpu_nice, cpu_system, cpu_user, cpu_wio,
            disk_free, disk_total, part_max_used,
            load_fifteen, load_five, load_one,
            mem_buffers, mem_cached, mem_free, mem_shared, swap_free,
            bytes_in, bytes_out
        FROM logs1_local
    " "max_execution_time=3600&max_insert_threads=4&max_memory_usage=40000000000"

    end_time=$(date +%s)
    echo "  Completed in $((end_time - start_time))s"
    wait_replication
done

# --- logs2: Web access logs ---
echo ""
echo "=== Amplifying logs2 (target: ${TARGET_LOGS2}) ==="
iteration=0
while true; do
    current=$(get_count "logs2_local")
    echo "  Current: ${current} rows"
    if [[ "$current" -ge "$TARGET_LOGS2" ]]; then
        echo "  Target reached."
        break
    fi

    iteration=$((iteration + 1))
    echo "  Iteration ${iteration}: doubling data..."
    start_time=$(date +%s)

    # Shift timestamps and randomize client_ip
    run_query "
        INSERT INTO logs2_local
        SELECT
            log_time + toIntervalMonth(${iteration} * 2 + rand() % 4),
            toIPv4(toUInt32(client_ip) + rand() % 1000000),
            request,
            status_code,
            object_size
        FROM logs2_local
    " "max_execution_time=3600&max_insert_threads=4&max_memory_usage=40000000000"

    end_time=$(date +%s)
    echo "  Completed in $((end_time - start_time))s"
    wait_replication
done

# --- logs3: IoT event logs ---
echo ""
echo "=== Amplifying logs3 (target: ${TARGET_LOGS3}) ==="
iteration=0
while true; do
    current=$(get_count "logs3_local")
    echo "  Current: ${current} rows"
    if [[ "$current" -ge "$TARGET_LOGS3" ]]; then
        echo "  Target reached."
        break
    fi

    iteration=$((iteration + 1))
    echo "  Iteration ${iteration}: doubling data..."
    start_time=$(date +%s)

    # Shift timestamps and add suffix to device_id
    run_query "
        INSERT INTO logs3_local
        SELECT
            log_time + toIntervalMonth(${iteration} * 2),
            substring(concat(device_id, toString(${iteration})), 1, 15),
            device_name,
            device_type,
            device_floor,
            event_type,
            event_unit,
            event_value
        FROM logs3_local
    " "max_execution_time=3600&max_insert_threads=4&max_memory_usage=40000000000"

    end_time=$(date +%s)
    echo "  Completed in $((end_time - start_time))s"
    wait_replication
done

echo ""
echo "=== Amplification Complete ==="
echo "  logs1: $(get_count 'logs1_local') rows"
echo "  logs2: $(get_count 'logs2_local') rows"
echo "  logs3: $(get_count 'logs3_local') rows"

echo ""
echo "=== Storage Summary ==="
run_query "
    SELECT
        table,
        formatReadableQuantity(sum(rows)) AS total_rows,
        formatReadableSize(sum(bytes_on_disk)) AS disk_size,
        count() AS parts
    FROM system.parts
    WHERE database = 'mgbench' AND active
    GROUP BY table
    ORDER BY table
    FORMAT PrettyCompact
"

echo ""
echo "Running OPTIMIZE TABLE FINAL (this may take a while)..."
run_query "OPTIMIZE TABLE logs1_local ON CLUSTER 'logs_cluster' FINAL" "max_execution_time=7200" &
run_query "OPTIMIZE TABLE logs2_local ON CLUSTER 'logs_cluster' FINAL" "max_execution_time=7200" &
run_query "OPTIMIZE TABLE logs3_local ON CLUSTER 'logs_cluster' FINAL" "max_execution_time=7200" &
wait
echo "OPTIMIZE complete."
