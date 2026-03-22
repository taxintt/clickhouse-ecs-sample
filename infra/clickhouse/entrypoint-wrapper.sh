#!/bin/bash
set -euo pipefail

# Validate required environment variables
if [ -z "${CH_DEFAULT_PASSWORD:-}" ]; then
  echo "ERROR: CH_DEFAULT_PASSWORD is not set"
  exit 1
fi
if [ -z "${CH_READONLY_PASSWORD:-}" ]; then
  echo "ERROR: CH_READONLY_PASSWORD is not set"
  exit 1
fi

# Escape a value for use as sed replacement text and XML content
escape_for_sed_xml() {
  printf '%s' "$1" | sed -e 's/[&/\]/\\&/g' | sed -e 's/</\&lt;/g; s/>/\&gt;/g'
}

# Replace placeholders in users.d/custom.xml with environment variables
USERS_FILE="/etc/clickhouse-server/users.d/custom.xml"

if [ -f "$USERS_FILE" ]; then
  ESCAPED_DEFAULT_PW=$(escape_for_sed_xml "$CH_DEFAULT_PASSWORD")
  ESCAPED_READONLY_PW=$(escape_for_sed_xml "$CH_READONLY_PASSWORD")
  ESCAPED_NETWORKS=$(escape_for_sed_xml "${CH_ALLOWED_NETWORKS:-::/0}")
  sed -i "s|PLACEHOLDER_DEFAULT_PASSWORD|${ESCAPED_DEFAULT_PW}|g" "$USERS_FILE"
  sed -i "s|PLACEHOLDER_READONLY_PASSWORD|${ESCAPED_READONLY_PW}|g" "$USERS_FILE"
  sed -i "s|PLACEHOLDER_ALLOWED_NETWORKS|${ESCAPED_NETWORKS}|g" "$USERS_FILE"
fi

# Ensure S3 cache directory exists (NVMe may not be mounted)
mkdir -p /var/lib/clickhouse/s3cache
chown clickhouse:clickhouse /var/lib/clickhouse/s3cache

# Wait for Keeper nodes to be reachable before starting ClickHouse
echo "Waiting for ClickHouse Keeper nodes..."
MAX_WAIT=300
ELAPSED=0
for host in "$CH_KEEPER_HOST_1" "$CH_KEEPER_HOST_2" "$CH_KEEPER_HOST_3"; do
  until nc -z "$host" 9181 2>/dev/null; do
    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
      echo "ERROR: Timed out waiting for $host:9181 after ${MAX_WAIT}s"
      exit 1
    fi
    echo "  Waiting for $host:9181... (${ELAPSED}s/${MAX_WAIT}s)"
    sleep 5
    ELAPSED=$((ELAPSED + 5))
  done
  echo "  $host:9181 is reachable"
done
echo "All Keeper nodes are reachable"

# Execute the original entrypoint
exec /entrypoint.sh "$@"
