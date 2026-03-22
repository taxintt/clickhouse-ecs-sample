#!/usr/bin/env bash
set -euo pipefail

# Load MgBench data from ClickHouse public datasets
#
# Usage:
#   ./load_data.sh --host <clickhouse-host> [--port 8123] [--password <password>]
#
# The script uses ClickHouse's url() table function to load data directly
# from the public dataset URLs.

CH_HOST="${CH_HOST:-localhost}"
CH_PORT="${CH_PORT:-8123}"
CH_PASSWORD="${CH_PASSWORD:-}"
CH_DATABASE="mgbench"

while [[ $# -gt 0 ]]; do
    case $1 in
        --host) CH_HOST="$2"; shift 2 ;;
        --port) CH_PORT="$2"; shift 2 ;;
        --password) CH_PASSWORD="$2"; shift 2 ;;
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
    local url="${CH_URL}/?database=${CH_DATABASE}"
    if [[ -n "$settings" ]]; then
        url="${url}&${settings}"
    fi
    curl "${CURL_OPTS[@]}" "${url}" -d "$query"
}

echo "=== MgBench Data Loader ==="
echo "Host: ${CH_HOST}:${CH_PORT}"
echo ""

# Dataset URLs
DATASETS=(
    "logs1:https://datasets.clickhouse.com/mgbench1.csv.xz"
    "logs2:https://datasets.clickhouse.com/mgbench2.csv.xz"
    "logs3:https://datasets.clickhouse.com/mgbench3.csv.xz"
)

for entry in "${DATASETS[@]}"; do
    table="${entry%%:*}"
    url="${entry#*:}"

    echo "--- Loading ${table} from ${url} ---"
    start_time=$(date +%s)

    run_query "INSERT INTO ${table}_local SELECT * FROM url('${url}', 'CSVWithNames')" \
        "max_execution_time=3600&max_insert_threads=4"

    end_time=$(date +%s)
    elapsed=$((end_time - start_time))

    count=$(run_query "SELECT count() FROM ${table}_local")
    echo "  Loaded: ${count} rows in ${elapsed}s"
    echo ""
done

echo "=== Load Summary ==="
for entry in "${DATASETS[@]}"; do
    table="${entry%%:*}"
    count=$(run_query "SELECT count() FROM ${table}_local")
    size=$(run_query "SELECT formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE database='mgbench' AND table='${table}_local' AND active")
    echo "  ${table}: ${count} rows, ${size}"
done

echo ""
echo "=== Verifying replication ==="
run_query "SELECT hostName() AS host, count() AS rows FROM clusterAllReplicas('logs_cluster', mgbench.logs1_local) GROUP BY host ORDER BY host"
run_query "SELECT hostName() AS host, count() AS rows FROM clusterAllReplicas('logs_cluster', mgbench.logs2_local) GROUP BY host ORDER BY host"
run_query "SELECT hostName() AS host, count() AS rows FROM clusterAllReplicas('logs_cluster', mgbench.logs3_local) GROUP BY host ORDER BY host"
echo "Done."
