#!/bin/bash
set -euo pipefail

# Format and mount EBS volume for Keeper data persistence
DEVICE="/dev/xvdf"
MOUNT_POINT="/mnt/keeper-data"

if ! blkid "$DEVICE" &>/dev/null; then
  mkfs.ext4 -L keeper-data "$DEVICE"
fi

mkdir -p "$MOUNT_POINT"
mount -o noatime "$DEVICE" "$MOUNT_POINT"

# Ensure mount survives reboot
if ! grep -q "$MOUNT_POINT" /etc/fstab; then
  echo "LABEL=keeper-data $MOUNT_POINT ext4 defaults,noatime 0 2" >> /etc/fstab
fi

# Configure ECS agent
cat <<EOF >> /etc/ecs/ecs.config
ECS_CLUSTER=${cluster_name}
ECS_INSTANCE_ATTRIBUTES={"${node_attribute}":"${node_value}"}
ECS_ENABLE_CONTAINER_METADATA=true
EOF
