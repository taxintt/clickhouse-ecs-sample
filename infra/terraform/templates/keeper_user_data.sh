#!/bin/bash
set -euo pipefail

# Configure ECS agent
cat <<EOF >> /etc/ecs/ecs.config
ECS_CLUSTER=${cluster_name}
ECS_INSTANCE_ATTRIBUTES={"${node_attribute}":"${node_value}"}
ECS_ENABLE_CONTAINER_METADATA=true
EOF
