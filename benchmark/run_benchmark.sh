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

# Run a benchmark query and return elapsed time in seconds
run_timed_query() {
    local query="$1"
    local settings="${2:-}"
    local url="${CH_URL}/?database=mgbench"
    if [[ -n "$settings" ]]; then
        url="${url}&${settings}"
    fi
    # -w outputs timing, -o discards response body
    curl -s "${AUTH_OPTS[@]}" "${url}" -d "$query" \
        -o /dev/null -w '%{time_total}'
}

drop_caches() {
    run_query "SYSTEM DROP MARK CACHE" || true
    run_query "SYSTEM DROP UNCOMPRESSED CACHE" || true
    run_query "SYSTEM DROP COMPILED EXPRESSION CACHE" || true
}

# Parse queries from SQL file into parallel arrays
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
printf 'query_id\trun_type\trun_num\telapsed_sec\n' > "$RESULT_FILE"

parse_queries "${SCRIPT_DIR}/${QUERY_FILE}"
echo "Loaded ${#QUERY_IDS[@]} queries"
echo ""

for idx in "${!QUERY_IDS[@]}"; do
    query_id="${QUERY_IDS[$idx]}"
    query="${QUERY_SQLS[$idx]}"

    echo "--- ${query_id} ---"

    # Cold run
    for i in $(seq 1 "$COLD_RUNS"); do
        echo -n "  cold ${i}: "
        drop_caches

        elapsed=$(run_timed_query "${query} FORMAT Null" "max_execution_time=600")
        echo "${elapsed}s"
        printf '%s\tcold\t%s\t%s\n' "${query_id}" "${i}" "${elapsed}" >> "$RESULT_FILE"
    done

    # Warm runs
    for i in $(seq 1 "$WARM_RUNS"); do
        echo -n "  warm ${i}: "

        elapsed=$(run_timed_query "${query} FORMAT Null" "max_execution_time=600")
        echo "${elapsed}s"
        printf '%s\twarm\t%s\t%s\n' "${query_id}" "${i}" "${elapsed}" >> "$RESULT_FILE"
    done

    echo ""
done

echo "=== Benchmark Complete ==="
echo "Results saved to: ${RESULT_FILE}"
echo ""

# Print summary
echo "=== Summary ==="
printf '%-10s %12s %12s %12s\n' "query" "cold(s)" "warm_min(s)" "warm_max(s)"
printf '%-10s %12s %12s %12s\n' "-----" "-------" "----------" "----------"
while IFS=$'\t' read -r qid rtype rnum elapsed; do
    [[ "$qid" == "query_id" ]] && continue
    results["${qid}_${rtype}_${rnum}"]="$elapsed"
done < "$RESULT_FILE"

for idx in "${!QUERY_IDS[@]}"; do
    qid="${QUERY_IDS[$idx]}"
    cold="${results[${qid}_cold_1]:-N/A}"
    warm_min="999"
    warm_max="0"
    for i in $(seq 1 "$WARM_RUNS"); do
        w="${results[${qid}_warm_${i}]:-0}"
        if awk "BEGIN{exit(!($w < $warm_min))}"; then warm_min="$w"; fi
        if awk "BEGIN{exit(!($w > $warm_max))}"; then warm_max="$w"; fi
    done
    printf '%-10s %12s %12s %12s\n' "$qid" "$cold" "$warm_min" "$warm_max"
done
