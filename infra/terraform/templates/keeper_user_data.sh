#!/bin/bash
set -euo pipefail

# Attach and mount the persistent EBS volume for Keeper data
VOLUME_ID="${ebs_volume_id}"
DEVICE="/dev/xvdf"
MOUNT_POINT="/mnt/keeper-data"
REGION=$(ec2-metadata --availability-zone | awk '{print $2}' | sed 's/.$//')
INSTANCE_ID=$(ec2-metadata --instance-id | awk '{print $2}')

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

# Attach the volume
aws ec2 attach-volume --volume-id "$VOLUME_ID" --instance-id "$INSTANCE_ID" \
  --device "$DEVICE" --region "$REGION"

# Wait for the device to appear
for i in $(seq 1 30); do
  if [ -b "$DEVICE" ]; then
    break
  fi
  echo "Waiting for device $DEVICE... ($i/30)"
  sleep 2
done

# Format only if not already formatted
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
