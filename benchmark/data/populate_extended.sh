#!/usr/bin/env bash
set -euo pipefail

# Populate extended logs2 tables with generated raw_log column
#
# Usage:
#   ./populate_extended.sh --host <clickhouse-host> [--port 8123] [--password <password>]

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

# The INSERT query that generates realistic raw_log content
INSERT_SELECT="
SELECT
    log_time,
    client_ip,
    request,
    status_code,
    object_size,
    concat(
        toString(log_time), ' ',
        multiIf(status_code >= 500, '[ERROR]', status_code >= 400, '[WARN]', '[INFO]'),
        ' request_id=', hex(sipHash64(concat(toString(log_time), toString(client_ip), request))),
        ' service=', arrayElement(['web-gateway', 'api-server', 'auth-service', 'data-pipeline', 'cache-proxy'], (cityHash64(request) % 5) + 1),
        ' method=', arrayElement(['GET', 'POST', 'PUT', 'DELETE', 'PATCH'], (cityHash64(concat(request, 'method')) % 5) + 1),
        ' path=', request,
        ' status=', toString(status_code),
        ' size=', toString(object_size),
        ' client=', IPv4NumToString(toUInt32(client_ip)),
        ' duration_ms=', toString(rand() % 5000),
        multiIf(
            status_code >= 500, concat(' error=InternalServerError stacktrace=java.lang.NullPointerException at com.app.service.Handler.process(Handler.java:', toString(rand() % 500), ')'),
            status_code = 404, ' error=NotFound resource_missing=true',
            status_code = 403, ' error=Forbidden auth_failed=true',
            status_code = 429, ' error=TooManyRequests rate_limit_exceeded=true',
            ' error=null'
        )
    ) AS raw_log
FROM mgbench.logs2_local
"

TABLES=("logs2_ext_noidx_local" "logs2_ext_tokenbf_local" "logs2_ext_ngrambf_local")

echo "=== Populating Extended Tables ==="
echo "Host: ${CH_HOST}:${CH_PORT}"
echo ""

source_count=$(run_query "SELECT count() FROM logs2_local")
echo "Source logs2_local: ${source_count} rows"
echo ""

for table in "${TABLES[@]}"; do
    echo "--- Populating ${table} ---"
    start_time=$(date +%s)

    run_query "INSERT INTO ${table} ${INSERT_SELECT}" \
        "max_execution_time=3600&max_insert_threads=4&max_memory_usage=40000000000"

    end_time=$(date +%s)
    elapsed=$((end_time - start_time))

    count=$(run_query "SELECT count() FROM ${table}")
    echo "  Loaded: ${count} rows in ${elapsed}s"
    echo ""
done

echo "=== Verification ==="
run_query "
    SELECT
        table,
        formatReadableQuantity(sum(rows)) AS total_rows,
        formatReadableSize(sum(bytes_on_disk)) AS disk_size
    FROM system.parts
    WHERE database = 'mgbench'
      AND table LIKE 'logs2_ext%'
      AND active
    GROUP BY table
    ORDER BY table
    FORMAT PrettyCompact
"

echo ""
echo "=== Sample raw_log entries ==="
run_query "SELECT raw_log FROM logs2_ext_noidx_local LIMIT 3 FORMAT TabSeparated"
echo ""
echo "Done."
