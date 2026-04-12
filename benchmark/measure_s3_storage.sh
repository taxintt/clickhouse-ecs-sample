#!/usr/bin/env bash
set -euo pipefail

# Measure S3 storage usage and compression ratios for cost estimation
#
# Usage:
#   ./measure_s3_storage.sh --host <clickhouse-host> [--port 8123] [--password <password>] [--tag <label>]

CH_HOST="${CH_HOST:-localhost}"
CH_PORT="${CH_PORT:-8123}"
CH_PASSWORD="${CH_PASSWORD:-}"
TAG="${TAG:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --host) CH_HOST="$2"; shift 2 ;;
        --port) CH_PORT="$2"; shift 2 ;;
        --password) CH_PASSWORD="$2"; shift 2 ;;
        --tag) TAG="$2"; shift 2 ;;
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

echo "=== S3 Storage Measurement ==="
echo "Host: ${CH_HOST}:${CH_PORT}"
if [[ -n "$TAG" ]]; then
    echo "Tag: ${TAG}"
fi
echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

# (A) Table-level compression ratio
echo "=== (A) Table-level Compression Ratio ==="
run_query "
    SELECT
        table,
        formatReadableQuantity(sum(rows)) AS total_rows,
        formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
        formatReadableSize(sum(data_compressed_bytes)) AS compressed,
        round(sum(data_compressed_bytes) / sum(data_uncompressed_bytes), 4) AS compression_ratio,
        formatReadableSize(sum(bytes_on_disk)) AS bytes_on_disk
    FROM system.parts
    WHERE database = 'otel' AND active
    GROUP BY table
    ORDER BY table
    FORMAT PrettyCompact
"
echo ""

# (B) Column-level compression ratio
echo "=== (B) Column-level Compression Ratio ==="
run_query "
    SELECT
        table,
        column,
        type,
        formatReadableSize(sum(column_data_uncompressed_bytes)) AS uncompressed,
        formatReadableSize(sum(column_data_compressed_bytes)) AS compressed,
        round(sum(column_data_compressed_bytes) / sum(column_data_uncompressed_bytes), 4) AS ratio
    FROM system.parts_columns
    WHERE database = 'otel' AND active
    GROUP BY table, column, type
    ORDER BY table, column
    FORMAT PrettyCompact
"
echo ""

# (C) Per-replica S3 usage (replica data increase rate)
echo "=== (C) Per-Replica S3 Usage ==="
run_query "
    SELECT
        hostName() AS host,
        table,
        formatReadableQuantity(sum(rows)) AS total_rows,
        formatReadableSize(sum(data_compressed_bytes)) AS compressed,
        formatReadableSize(sum(bytes_on_disk)) AS bytes_on_disk
    FROM clusterAllReplicas('logs_cluster', system.parts)
    WHERE database = 'otel' AND active
    GROUP BY host, table
    ORDER BY table, host
    FORMAT PrettyCompact
"
echo ""

# (D) Replica data increase rate calculation
echo "=== (D) Replica Data Increase Rate ==="
run_query "
    SELECT
        shard_num,
        table,
        count() AS replica_count,
        formatReadableSize(min(total_bytes)) AS min_replica_bytes,
        formatReadableSize(max(total_bytes)) AS max_replica_bytes,
        round(max(total_bytes) / min(total_bytes), 4) AS max_min_ratio,
        formatReadableSize(sum(total_bytes)) AS shard_total_bytes,
        round(sum(total_bytes) / min(total_bytes), 4) AS replica_multiplier
    FROM (
        SELECT
            getMacro('shard') AS shard_num,
            hostName() AS host,
            table,
            sum(bytes_on_disk) AS total_bytes
        FROM clusterAllReplicas('logs_cluster', system.parts)
        WHERE database = 'otel' AND active
        GROUP BY shard_num, host, table
    )
    GROUP BY shard_num, table
    ORDER BY table, shard_num
    FORMAT PrettyCompact
"
echo ""

# (E) CSV-equivalent size vs S3 stored size
echo "=== (E) Original CSV Size vs S3 Stored Size ==="
SAMPLE_ROWS=10000
TABLES=("otel_logs_local")

for table in "${TABLES[@]}"; do
    total_rows=$(run_query "SELECT count() FROM ${table}")
    if [[ "$total_rows" -eq 0 ]]; then
        echo "  ${table}: no data"
        continue
    fi

    # Export sample rows as CSV and measure byte size
    sample_bytes=$(run_query "SELECT * FROM ${table} LIMIT ${SAMPLE_ROWS} FORMAT CSV" | wc -c | tr -d ' ')
    actual_sample=$(( total_rows < SAMPLE_ROWS ? total_rows : SAMPLE_ROWS ))
    avg_row_bytes=$(( sample_bytes / actual_sample ))
    estimated_csv_bytes=$(( avg_row_bytes * total_rows ))

    bytes_on_disk=$(run_query "SELECT sum(bytes_on_disk) FROM system.parts WHERE database='otel' AND table='${table}' AND active")

    if [[ "$estimated_csv_bytes" -gt 0 ]]; then
        ratio=$(awk "BEGIN {printf \"%.4f\", ${bytes_on_disk} / ${estimated_csv_bytes}}")
    else
        ratio="N/A"
    fi

    echo "  ${table}:"
    echo "    total_rows:          ${total_rows}"
    echo "    avg_csv_row_bytes:   ${avg_row_bytes}"
    echo "    estimated_csv_size:  $(awk "BEGIN {printf \"%.2f GB\", ${estimated_csv_bytes} / 1073741824}")"
    echo "    s3_bytes_on_disk:    $(awk "BEGIN {printf \"%.2f GB\", ${bytes_on_disk} / 1073741824}")"
    echo "    csv_to_s3_ratio:     ${ratio} (S3 / CSV)"
    echo ""
done

# (F) Disk information
echo "=== (F) Disk Information ==="
run_query "
    SELECT
        name,
        path,
        type,
        formatReadableSize(free_space) AS free_space,
        formatReadableSize(total_space) AS total_space
    FROM system.disks
    FORMAT PrettyCompact
"
echo ""

# (G) Raw bytes for cost calculation
echo "=== (G) Raw Bytes Summary (for cost calculation) ==="
run_query "
    SELECT
        'single_node' AS scope,
        formatReadableSize(sum(data_uncompressed_bytes)) AS total_uncompressed,
        formatReadableSize(sum(data_compressed_bytes)) AS total_compressed,
        formatReadableSize(sum(bytes_on_disk)) AS total_on_disk,
        round(sum(data_compressed_bytes) / sum(data_uncompressed_bytes), 4) AS overall_compression_ratio,
        sum(bytes_on_disk) AS raw_bytes_on_disk
    FROM system.parts
    WHERE database = 'otel' AND active
    FORMAT PrettyCompact
"
echo ""

run_query "
    SELECT
        'all_replicas' AS scope,
        formatReadableSize(sum(bytes_on_disk)) AS total_on_disk,
        sum(bytes_on_disk) AS raw_bytes_on_disk
    FROM clusterAllReplicas('logs_cluster', system.parts)
    WHERE database = 'otel' AND active
    FORMAT PrettyCompact
"
echo ""

echo "=== Measurement Complete ==="
