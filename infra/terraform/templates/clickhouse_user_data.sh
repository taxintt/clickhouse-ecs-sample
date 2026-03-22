#!/bin/bash
set -euo pipefail

# Configure ECS agent
cat <<EOF >> /etc/ecs/ecs.config
ECS_CLUSTER=${cluster_name}
ECS_INSTANCE_ATTRIBUTES={"${node_attribute}":"${node_value}"}
ECS_ENABLE_CONTAINER_METADATA=true
EOF

# Format and mount NVMe instance store for S3 cache
NVME_DEVICE=$(lsblk -dpno NAME,MODEL | grep "Instance Storage" | awk '{print $1}' | head -1)

if [ -n "$NVME_DEVICE" ]; then
  mkfs.xfs -f "$NVME_DEVICE"
  mkdir -p /var/lib/clickhouse/s3cache
  mount "$NVME_DEVICE" /var/lib/clickhouse/s3cache
  echo "$NVME_DEVICE /var/lib/clickhouse/s3cache xfs defaults,noatime 0 0" >> /etc/fstab
  chown 101:101 /var/lib/clickhouse/s3cache
  chmod 750 /var/lib/clickhouse/s3cache
fi
