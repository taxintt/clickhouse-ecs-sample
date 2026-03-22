#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Health check script for ClickHouse cluster
# Usage: ./health-check.sh [endpoint] [password]
# Default endpoint: localhost
################################################################################

ENDPOINT="${1:-localhost}"
CH_PASSWORD="${2:-${CH_DEFAULT_PASSWORD:-}}"
CH_HTTP_PORT="${CH_HTTP_PORT:-8123}"
EXIT_CODE=0

if [ -z "$CH_PASSWORD" ]; then
  echo "WARN: No password provided. Set CH_DEFAULT_PASSWORD or pass as second argument."
fi

AUTH_OPTS=""
if [ -n "$CH_PASSWORD" ]; then
  AUTH_OPTS="--user default:${CH_PASSWORD}"
fi

echo "=== ClickHouse Cluster Health Check ==="
echo "Endpoint: ${ENDPOINT}:${CH_HTTP_PORT}"
echo ""

# 1. Basic ping (no auth required)
echo "--- Ping ---"
if curl -sf "http://${ENDPOINT}:${CH_HTTP_PORT}/ping" > /dev/null 2>&1; then
  echo "OK: ClickHouse is responding"
else
  echo "FAIL: ClickHouse is not responding"
  EXIT_CODE=1
fi

# 2. Cluster status
echo ""
echo "--- Cluster Status ---"
curl -sf "http://${ENDPOINT}:${CH_HTTP_PORT}" \
  ${AUTH_OPTS} \
  --data "SELECT cluster, shard_num, replica_num, host_name, is_local FROM system.clusters WHERE cluster = 'logs_cluster' FORMAT PrettyCompact" \
  2>/dev/null || { echo "FAIL: Cannot query cluster status"; EXIT_CODE=1; }

# 3. Replication status
echo ""
echo "--- Replication Queue ---"
QUEUE_SIZE=$(curl -sf "http://${ENDPOINT}:${CH_HTTP_PORT}" \
  ${AUTH_OPTS} \
  --data "SELECT count() FROM system.replication_queue" 2>/dev/null || echo "ERROR")
if [ "${QUEUE_SIZE}" = "ERROR" ]; then
  echo "FAIL: Cannot query replication queue"
  EXIT_CODE=1
elif [ "${QUEUE_SIZE}" -gt 100 ]; then
  echo "WARN: Replication queue size is ${QUEUE_SIZE} (threshold: 100)"
else
  echo "OK: Replication queue size: ${QUEUE_SIZE}"
fi

# 4. Keeper connectivity
echo ""
echo "--- Keeper Status ---"
curl -sf "http://${ENDPOINT}:${CH_HTTP_PORT}" \
  ${AUTH_OPTS} \
  --data "SELECT * FROM system.zookeeper WHERE path = '/' LIMIT 1 FORMAT PrettyCompact" \
  2>/dev/null && echo "OK: Keeper is connected" || { echo "FAIL: Keeper is not connected"; EXIT_CODE=1; }

# 5. S3 storage status
echo ""
echo "--- Storage Disks ---"
curl -sf "http://${ENDPOINT}:${CH_HTTP_PORT}" \
  ${AUTH_OPTS} \
  --data "SELECT name, type, path, free_space, total_space FROM system.disks FORMAT PrettyCompact" \
  2>/dev/null || { echo "FAIL: Cannot query disk status"; EXIT_CODE=1; }

echo ""
echo "=== Health check complete (exit code: ${EXIT_CODE}) ==="
exit ${EXIT_CODE}
