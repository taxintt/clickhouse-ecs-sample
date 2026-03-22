#!/usr/bin/env bash
set -euo pipefail

# MgBench SELECT Benchmark Runner
#
# Runs each query with 1 cold run + 3 warm runs, records execution metrics.
#
# Usage:
#   ./run_benchmark.sh --host <clickhouse-host> [--port 8123] [--password <password>] [--tag baseline]

CH_HOST="${CH_HOST:-localhost}"
CH_PORT="${CH_PORT:-8123}"
CH_PASSWORD="${CH_PASSWORD:-}"
TAG="baseline"
COLD_RUNS=1
WARM_RUNS=3
QUERY_FILE="queries/mgbench_baseline.sql"

while [[ $# -gt 0 ]]; do
    case $1 in
        --host) CH_HOST="$2"; shift 2 ;;
        --port) CH_PORT="$2"; shift 2 ;;
        --password) CH_PASSWORD="$2"; shift 2 ;;
        --tag) TAG="$2"; shift 2 ;;
        --query-file) QUERY_FILE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_FILE="${RESULT_DIR}/${TAG}_${TIMESTAMP}.tsv"

CH_URL="http://${CH_HOST}:${CH_PORT}"

run_query() {
    local query="$1"
    local settings="${2:-}"
    local url="${CH_URL}/?database=mgbench"
    if [[ -n "$settings" ]]; then
        url="${url}&${settings}"
    fi
    local auth_opts=()
    if [[ -n "$CH_PASSWORD" ]]; then
        auth_opts=(--user "default:${CH_PASSWORD}")
    fi
    curl -s "${auth_opts[@]}" "${url}" -d "$query"
}

drop_caches() {
    run_query "SYSTEM DROP MARK CACHE" || true
    run_query "SYSTEM DROP UNCOMPRESSED CACHE" || true
    run_query "SYSTEM DROP COMPILED EXPRESSION CACHE" || true
}

# Parse queries from SQL file into parallel arrays
# Queries are separated by comments starting with "-- qN.N"
QUERY_IDS=()
QUERY_SQLS=()

parse_queries() {
    local file="$1"
    local current_id=""
    local current_query=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^--\ (q[0-9]+\.[0-9]+) ]]; then
            if [[ -n "$current_id" && -n "$current_query" ]]; then
                QUERY_IDS+=("$current_id")
                QUERY_SQLS+=("$current_query")
            fi
            current_id="${BASH_REMATCH[1]}"
            current_query=""
        elif [[ "$line" =~ ^--\ ==+ ]] || [[ "$line" =~ ^--\ .+:\ .+ ]]; then
            continue
        elif [[ -n "$current_id" ]]; then
            current_query="${current_query} ${line}"
        fi
    done < "$file"

    if [[ -n "$current_id" && -n "$current_query" ]]; then
        QUERY_IDS+=("$current_id")
        QUERY_SQLS+=("$current_query")
    fi
}

echo "=== MgBench SELECT Benchmark ==="
echo "Host: ${CH_HOST}:${CH_PORT}"
echo "Tag: ${TAG}"
echo "Output: ${RESULT_FILE}"
echo ""

# Header
printf 'query_id\trun_type\trun_num\telapsed_sec\trows_read\tbytes_read\tmemory_usage\n' > "$RESULT_FILE"

parse_queries "${SCRIPT_DIR}/${QUERY_FILE}"
echo "Loaded ${#QUERY_IDS[@]} queries"
echo ""

for idx in "${!QUERY_IDS[@]}"; do
    query_id="${QUERY_IDS[$idx]}"
    query="${QUERY_SQLS[$idx]}"

    echo "--- ${query_id} ---"

    # Cold run
    for i in $(seq 1 "$COLD_RUNS"); do
        echo "  cold run ${i}..."
        drop_caches

        run_id="${TAG}_${query_id}_cold_${i}_${RANDOM}"
        run_query "${query} FORMAT Null" \
            "max_execution_time=600&log_queries=1&query_id=${run_id}" > /dev/null || true

        # Flush query_log and get metrics
        run_query "SYSTEM FLUSH LOGS" > /dev/null || true
        metrics=$(run_query "
            SELECT
                round(query_duration_ms / 1000.0, 3) AS elapsed_sec,
                read_rows,
                read_bytes,
                memory_usage
            FROM system.query_log
            WHERE type = 'QueryFinish'
              AND query_id = '${run_id}'
            LIMIT 1
            FORMAT TabSeparated
        ") || true

        if [[ -n "$metrics" ]]; then
            printf '%s\tcold\t%s\t%s\n' "${query_id}" "${i}" "${metrics}" >> "$RESULT_FILE"
            echo "  ${metrics}"
        else
            echo "  WARNING: Could not retrieve metrics for cold run"
        fi
    done

    # Warm runs
    for i in $(seq 1 "$WARM_RUNS"); do
        echo "  warm run ${i}..."

        run_id="${TAG}_${query_id}_warm_${i}_${RANDOM}"
        run_query "${query} FORMAT Null" \
            "max_execution_time=600&log_queries=1&query_id=${run_id}" > /dev/null || true

        run_query "SYSTEM FLUSH LOGS" > /dev/null || true
        metrics=$(run_query "
            SELECT
                round(query_duration_ms / 1000.0, 3) AS elapsed_sec,
                read_rows,
                read_bytes,
                memory_usage
            FROM system.query_log
            WHERE type = 'QueryFinish'
              AND query_id = '${run_id}'
            LIMIT 1
            FORMAT TabSeparated
        ") || true

        if [[ -n "$metrics" ]]; then
            printf '%s\twarm\t%s\t%s\n' "${query_id}" "${i}" "${metrics}" >> "$RESULT_FILE"
            echo "  ${metrics}"
        else
            echo "  WARNING: Could not retrieve metrics for warm run ${i}"
        fi
    done

    echo ""
done

echo "=== Benchmark Complete ==="
echo "Results saved to: ${RESULT_FILE}"
