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

drop_caches() {
    run_query "SYSTEM DROP MARK CACHE" || true
    run_query "SYSTEM DROP UNCOMPRESSED CACHE" || true
    run_query "SYSTEM DROP COMPILED EXPRESSION CACHE" || true
}

# Table patterns to test
TABLE_TYPES=("noidx" "tokenbf" "ngrambf")
TABLE_NAMES=("mgbench.logs2_ext_noidx" "mgbench.logs2_ext_tokenbf" "mgbench.logs2_ext_ngrambf")

# Parse queries from SQL file into parallel arrays
QUERY_IDS=()
QUERY_SQLS=()

parse_queries() {
    local file="$1"
    local current_id=""
    local current_query=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^--\ (ft[0-9]+) ]]; then
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

echo "=== Fulltext Search Benchmark ==="
echo "Host: ${CH_HOST}:${CH_PORT}"
echo "Output: ${RESULT_FILE}"
echo ""

# Header
printf 'query_id\tindex_type\trun_type\trun_num\telapsed_sec\n' > "$RESULT_FILE"

parse_queries "$QUERY_FILE"
echo "Loaded ${#QUERY_IDS[@]} queries"
echo ""

for idx in "${!QUERY_IDS[@]}"; do
    query_id="${QUERY_IDS[$idx]}"
    query_template="${QUERY_SQLS[$idx]}"

    echo "=== ${query_id} ==="

    for tidx in "${!TABLE_TYPES[@]}"; do
        index_type="${TABLE_TYPES[$tidx]}"
        table_name="${TABLE_NAMES[$tidx]}"

        # Replace {TABLE} placeholder with actual table name
        query="${query_template//\{TABLE\}/${table_name}}"

        echo "  --- ${index_type} ---"

        # Cold run
        for i in $(seq 1 "$COLD_RUNS"); do
            echo -n "    cold ${i}: "
            drop_caches

            elapsed=$(run_timed_query "${query} FORMAT Null" "max_execution_time=600")
            echo "${elapsed}s"
            printf '%s\t%s\tcold\t%s\t%s\n' "${query_id}" "${index_type}" "${i}" "${elapsed}" >> "$RESULT_FILE"
        done

        # Warm runs
        for i in $(seq 1 "$WARM_RUNS"); do
            echo -n "    warm ${i}: "

            elapsed=$(run_timed_query "${query} FORMAT Null" "max_execution_time=600")
            echo "${elapsed}s"
            printf '%s\t%s\twarm\t%s\t%s\n' "${query_id}" "${index_type}" "${i}" "${elapsed}" >> "$RESULT_FILE"
        done
    done

    echo ""
done

echo "=== Fulltext Benchmark Complete ==="
echo "Results saved to: ${RESULT_FILE}"
echo ""

# Print summary: warm average per query+index_type
echo "=== Summary (warm avg) ==="
awk -F'\t' '
NR == 1 { next }
$3 == "warm" {
    key = $1 "\t" $2
    sum[key] += $5; cnt[key]++
    if (!(key in order)) { order[key] = NR; keys[++n] = key }
}
END {
    printf "%-8s %-10s %12s\n", "query", "index", "warm_avg(s)"
    printf "%-8s %-10s %12s\n", "-----", "-----", "-----------"
    for (i = 1; i <= n; i++) {
        k = keys[i]
        split(k, a, "\t")
        printf "%-8s %-10s %12.6f\n", a[1], a[2], sum[k] / cnt[k]
    }
}' "$RESULT_FILE"
