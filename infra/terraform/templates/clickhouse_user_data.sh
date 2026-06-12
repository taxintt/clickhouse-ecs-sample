#!/bin/bash
set -euo pipefail

################################################################################
# ClickHouse EC2 user_data
#
# 1. Attach + mount EBS at /mnt/clickhouse-data (persistent metadata)
# 2. Format + mount NVMe instance store at /mnt/clickhouse-data/s3cache
#    (nested inside EBS, holds S3 disk cache, ephemeral)
# 3. Configure ECS agent
#
# The container's /var/lib/clickhouse is bind-mounted from /mnt/clickhouse-data
# in the ECS task definition. The container therefore sees:
#   /var/lib/clickhouse/         → EBS  (metadata persists across EC2 replacement)
#   /var/lib/clickhouse/s3cache/ → NVMe (S3 cache, repopulated on cold start)
################################################################################

VOLUME_ID="${ebs_volume_id}"
DEVICE="/dev/xvdf"
MOUNT_POINT="/mnt/clickhouse-data"
REGION=$(ec2-metadata --availability-zone | awk '{print $2}' | sed 's/.$//')
INSTANCE_ID=$(ec2-metadata --instance-id | awk '{print $2}')

# 1. EBS attach + mount
# Wait for the volume to be available (may still be detaching from old instance)
for i in $(seq 1 60); do
  STATE=$(aws ec2 describe-volumes --volume-ids "$VOLUME_ID" --region "$REGION" \
    --query 'Volumes[0].State' --output text)
  if [ "$STATE" = "available" ]; then
    break
  fi
  echo "Waiting for volume $VOLUME_ID to become available (state: $STATE)... ($i/60)"
  sleep 5
done

aws ec2 attach-volume --volume-id "$VOLUME_ID" --instance-id "$INSTANCE_ID" \
  --device "$DEVICE" --region "$REGION"

for i in $(seq 1 30); do
  if [ -b "$DEVICE" ]; then
    break
  fi
  echo "Waiting for device $DEVICE... ($i/30)"
  sleep 2
done

# Format only if not already formatted (idempotent across instance refreshes)
if ! blkid "$DEVICE" &>/dev/null; then
  mkfs.ext4 -L clickhouse-data "$DEVICE"
fi

mkdir -p "$MOUNT_POINT"
mount -o noatime "$DEVICE" "$MOUNT_POINT"

if ! grep -q "$MOUNT_POINT" /etc/fstab; then
  echo "LABEL=clickhouse-data $MOUNT_POINT ext4 defaults,noatime 0 2" >> /etc/fstab
fi

# ClickHouse server runs as UID/GID 101 inside the container
chown 101:101 "$MOUNT_POINT"
chmod 750 "$MOUNT_POINT"

# 2. NVMe instance store → /mnt/clickhouse-data/s3cache (nested inside EBS)
NVME_DEVICE=$(lsblk -dpno NAME,MODEL | grep "Instance Storage" | awk '{print $1}' | head -1)

if [ -n "$NVME_DEVICE" ]; then
  mkfs.xfs -f "$NVME_DEVICE"
  mkdir -p "$MOUNT_POINT/s3cache"
  mount "$NVME_DEVICE" "$MOUNT_POINT/s3cache"
  echo "$NVME_DEVICE $MOUNT_POINT/s3cache xfs defaults,noatime 0 0" >> /etc/fstab
  chown 101:101 "$MOUNT_POINT/s3cache"
  chmod 750 "$MOUNT_POINT/s3cache"
fi

# 3. Configure ECS agent (must come last so the agent only starts accepting
# tasks after both volumes are mounted)
cat <<EOF >> /etc/ecs/ecs.config
ECS_CLUSTER=${cluster_name}
ECS_INSTANCE_ATTRIBUTES={"${node_attribute}":"${node_value}"}
ECS_ENABLE_CONTAINER_METADATA=true
EOF
