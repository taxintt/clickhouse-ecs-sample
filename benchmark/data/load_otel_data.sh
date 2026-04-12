#!/usr/bin/env bash
set -euo pipefail

# Generate and load synthetic OTel log data into otel.otel_logs_local
#
# Usage:
#   ./load_otel_data.sh --host <clickhouse-host> [--port 8123] [--password <password>] [--rows 10000000]

CH_HOST="${CH_HOST:-localhost}"
CH_PORT="${CH_PORT:-8123}"
CH_PASSWORD="${CH_PASSWORD:-}"
TARGET_ROWS="${TARGET_ROWS:-10000000}"
BATCH_SIZE="${BATCH_SIZE:-1000000}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --host) CH_HOST="$2"; shift 2 ;;
        --port) CH_PORT="$2"; shift 2 ;;
        --password) CH_PASSWORD="$2"; shift 2 ;;
        --rows) TARGET_ROWS="$2"; shift 2 ;;
        --batch-size) BATCH_SIZE="$2"; shift 2 ;;
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
    local url="${CH_URL}/?database=otel"
    if [[ -n "$settings" ]]; then
        url="${url}&${settings}"
    fi
    curl "${CURL_OPTS[@]}" "${url}" -d "$query"
}

get_count() {
    run_query "SELECT count() FROM otel_logs_local"
}

echo "=== OTel Logs Data Generator ==="
echo "Host: ${CH_HOST}:${CH_PORT}"
echo "Target rows: ${TARGET_ROWS}"
echo "Batch size: ${BATCH_SIZE}"
echo ""

current=$(get_count)
echo "Current rows: ${current}"

if [[ "$current" -ge "$TARGET_ROWS" ]]; then
    echo "Target already reached."
    exit 0
fi

batch_num=0
while true; do
    current=$(get_count)
    remaining=$((TARGET_ROWS - current))
    if [[ "$remaining" -le 0 ]]; then
        break
    fi

    insert_count=$((remaining < BATCH_SIZE ? remaining : BATCH_SIZE))
    batch_num=$((batch_num + 1))

    echo "Batch ${batch_num}: inserting ${insert_count} rows (current: ${current})..."
    start_time=$(date +%s)

    run_query "
        INSERT INTO otel_logs_local
        SELECT
            now64(9) - toIntervalSecond(rand() % 86400 + number % 86400) AS Timestamp,
            lower(hex(randomPrintableASCII(16))) AS TraceId,
            lower(hex(randomPrintableASCII(8))) AS SpanId,
            toUInt32(randBernoulli(0.1)) AS TraceFlags,
            arrayElement(
                ['TRACE','DEBUG','INFO','WARN','ERROR','FATAL'],
                toUInt8(1 + rand() % 6)
            ) AS SeverityText,
            arrayElement(
                [1, 5, 9, 13, 17, 21],
                toUInt8(1 + rand() % 6)
            ) AS SeverityNumber,
            arrayElement(
                ['api-gateway','user-service','order-service','payment-service',
                 'inventory-service','notification-service','auth-service','search-service'],
                toUInt8(1 + rand() % 8)
            ) AS ServiceName,
            concat(
                arrayElement(
                    ['Request processed','Connection established','Cache miss','Query executed',
                     'Timeout occurred','Rate limit exceeded','Authentication failed','Data validated',
                     'Retry attempt','Circuit breaker opened','Health check passed','Config reloaded'],
                    toUInt8(1 + rand() % 12)
                ),
                ' id=', toString(rand() % 100000),
                ' duration_ms=', toString(rand() % 5000)
            ) AS Body,
            'https://opentelemetry.io/schemas/1.24.0' AS ResourceSchemaUrl,
            map(
                'host.name', concat('node-', toString(rand() % 20)),
                'os.type', arrayElement(['linux','linux','linux','darwin'], toUInt8(1 + rand() % 4)),
                'deployment.environment', arrayElement(['production','staging','development'], toUInt8(1 + rand() % 3)),
                'cloud.region', arrayElement(['ap-northeast-1','us-east-1','eu-west-1'], toUInt8(1 + rand() % 3)),
                'cloud.provider', 'aws',
                'service.namespace', arrayElement(['platform','core','infra'], toUInt8(1 + rand() % 3))
            ) AS ResourceAttributes,
            '' AS ScopeSchemaUrl,
            arrayElement(
                ['io.opentelemetry.sdk','io.opentelemetry.instrumentation.http',
                 'io.opentelemetry.instrumentation.grpc','io.opentelemetry.instrumentation.db'],
                toUInt8(1 + rand() % 4)
            ) AS ScopeName,
            '1.24.0' AS ScopeVersion,
            map(
                'telemetry.sdk.language', arrayElement(['go','java','python','nodejs'], toUInt8(1 + rand() % 4))
            ) AS ScopeAttributes,
            map(
                'http.method', arrayElement(['GET','POST','PUT','DELETE','PATCH'], toUInt8(1 + rand() % 5)),
                'http.status_code', toString(arrayElement([200,200,200,201,204,301,400,401,403,404,500,502,503], toUInt8(1 + rand() % 13))),
                'http.url', concat('/', arrayElement(['api','v1','v2','internal'], toUInt8(1 + rand() % 4)),
                    '/', arrayElement(['users','orders','products','payments','health','metrics'], toUInt8(1 + rand() % 6))),
                'net.peer.ip', concat(toString(10 + rand() % 240), '.', toString(rand() % 256), '.', toString(rand() % 256), '.', toString(rand() % 256)),
                'thread.id', toString(rand() % 64)
            ) AS LogAttributes
        FROM numbers(${insert_count})
    " "max_execution_time=3600&max_insert_threads=4&max_memory_usage=40000000000"

    end_time=$(date +%s)
    echo "  Completed in $((end_time - start_time))s"
done

echo ""
echo "=== Load Complete ==="
final_count=$(get_count)
echo "Total rows: ${final_count}"

echo ""
echo "Waiting for replication to complete..."
pending=1
while [[ "$pending" -gt 0 ]]; do
    sleep 5
    pending=$(run_query "SELECT count() FROM system.replication_queue WHERE type = 'GET_PART'" 2>/dev/null || echo "0")
    if [[ "$pending" -gt 0 ]]; then
        echo "  Replication queue: ${pending} parts pending..."
    fi
done
echo "Replication complete."

echo ""
echo "=== Storage Summary ==="
run_query "
    SELECT
        table,
        formatReadableQuantity(sum(rows)) AS total_rows,
        formatReadableSize(sum(bytes_on_disk)) AS disk_size,
        count() AS parts
    FROM system.parts
    WHERE database = 'otel' AND active
    GROUP BY table
    ORDER BY table
    FORMAT PrettyCompact
"

echo ""
echo "=== Verifying replication ==="
run_query "
    SELECT
        hostName() AS host,
        count() AS rows
    FROM clusterAllReplicas('logs_cluster', otel.otel_logs_local)
    GROUP BY host
    ORDER BY host
"
echo "Done."
