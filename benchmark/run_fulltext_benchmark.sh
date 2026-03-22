#!/usr/bin/env bash
set -euo pipefail

# Fulltext Search Benchmark Runner
#
# Runs each fulltext query against 3 table patterns (noidx, tokenbf, ngrambf)
# with 1 cold run + 3 warm runs.
#
# Usage:
#   ./run_fulltext_benchmark.sh --host <clickhouse-host> [--port 8123] [--password <password>]

CH_HOST="${CH_HOST:-localhost}"
CH_PORT="${CH_PORT:-8123}"
CH_PASSWORD="${CH_PASSWORD:-}"
COLD_RUNS=1
WARM_RUNS=3

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
RESULT_FILE="${RESULT_DIR}/fulltext_${TIMESTAMP}.tsv"
QUERY_FILE="${SCRIPT_DIR}/queries/fulltext_search.sql"

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

drop_caches() {
    run_query "SYSTEM DROP MARK CACHE" || true
    run_query "SYSTEM DROP UNCOMPRESSED CACHE" || true
    run_query "SYSTEM DROP COMPILED EXPRESSION CACHE" || true
}

# Table patterns to test
TABLES=(
    "noidx:mgbench.logs2_ext_noidx"
    "tokenbf:mgbench.logs2_ext_tokenbf"
    "ngrambf:mgbench.logs2_ext_ngrambf"
)

# Parse queries from SQL file (same logic as run_benchmark.sh)
parse_queries() {
    local file="$1"
    local current_id=""
    local current_query=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^--\ (ft[0-9]+) ]]; then
            if [[ -n "$current_id" && -n "$current_query" ]]; then
                echo "${current_id}|||${current_query}"
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
        echo "${current_id}|||${current_query}"
    fi
}

echo "=== Fulltext Search Benchmark ==="
echo "Host: ${CH_HOST}:${CH_PORT}"
echo "Output: ${RESULT_FILE}"
echo ""

# Header
echo -e "query_id\tindex_type\trun_type\trun_num\telapsed_sec\trows_read\tbytes_read\tmemory_usage" > "$RESULT_FILE"

parse_queries "$QUERY_FILE" | while IFS='|||' read -r query_id query_template; do
    query_template=$(echo "$query_template" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    if [[ -z "$query_template" ]]; then
        continue
    fi

    echo "=== ${query_id} ==="

    for table_entry in "${TABLES[@]}"; do
        index_type="${table_entry%%:*}"
        table_name="${table_entry#*:}"

        # Replace {TABLE} placeholder with actual table name
        query="${query_template//\{TABLE\}/${table_name}}"

        echo "  --- ${index_type} ---"

        # Cold run
        for i in $(seq 1 "$COLD_RUNS"); do
            echo "    cold run ${i}..."
            drop_caches

            run_id="ft_${query_id}_${index_type}_cold_${i}_$(date +%s%N)"
            run_query "${query} FORMAT Null" \
                "max_execution_time=600&log_queries=1&query_id=${run_id}" > /dev/null 2>&1

            run_query "SYSTEM FLUSH LOGS" > /dev/null 2>&1
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
            ")

            if [[ -n "$metrics" ]]; then
                echo -e "${query_id}\t${index_type}\tcold\t${i}\t${metrics}" >> "$RESULT_FILE"
                echo "    ${metrics}"
            fi
        done

        # Warm runs
        for i in $(seq 1 "$WARM_RUNS"); do
            echo "    warm run ${i}..."

            run_id="ft_${query_id}_${index_type}_warm_${i}_$(date +%s%N)"
            run_query "${query} FORMAT Null" \
                "max_execution_time=600&log_queries=1&query_id=${run_id}" > /dev/null 2>&1

            run_query "SYSTEM FLUSH LOGS" > /dev/null 2>&1
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
            ")

            if [[ -n "$metrics" ]]; then
                echo -e "${query_id}\t${index_type}\twarm\t${i}\t${metrics}" >> "$RESULT_FILE"
                echo "    ${metrics}"
            fi
        done
    done

    echo ""
done

echo "=== Fulltext Benchmark Complete ==="
echo "Results saved to: ${RESULT_FILE}"
