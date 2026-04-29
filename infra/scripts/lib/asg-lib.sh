#!/usr/bin/env bash
# ASG / ECS container instance operations for EC2 instance replacement.
#
# Requires:
#   lib/common.sh sourced first (log/info/warn/err/abort/dry_run_guard)
#   Env vars: AWS_REGION, CLUSTER_NAME, INSTANCE_REFRESH_TIMEOUT, PROJECT, ENVIRONMENT

# ASG naming convention (matches Terraform: aws_autoscaling_group.clickhouse/keeper):
#   ClickHouse: ${PROJECT}-${ENVIRONMENT}-ch-${node}       (e.g. logplatform-dev-ch-s1r1)
#   Keeper:     ${PROJECT}-${ENVIRONMENT}-keeper-${id}     (e.g. logplatform-dev-keeper-1)
asg_name_for_ch_node() {
  local node="$1"
  echo "${PROJECT}-${ENVIRONMENT}-ch-${node}"
}

asg_name_for_keeper() {
  local id="$1"
  echo "${PROJECT}-${ENVIRONMENT}-keeper-${id}"
}

# Returns the single InService instance ID for the ASG (or empty if none).
get_asg_instance_id() {
  local asg_name="$1"
  aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "${asg_name}" \
    --region "${AWS_REGION}" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
    --output text 2>/dev/null | awk '{print $1}'
}

# Temporarily disable scale-in protection on the existing instance so
# instance-refresh can terminate it. With min=max=desired=1 ASGs, refresh
# must scale down to 0 before launching the replacement; scale-in protection
# blocks that step indefinitely (status sits at 0% with reason
# "is protected. Remove instance scale-in protection to continue.").
#
# The new instance launched after refresh inherits the ASG's
# NewInstancesProtectedFromScaleIn=true setting automatically, so no
# re-protection step is required.
disable_scale_in_protection() {
  local asg_name="$1"
  local instance_id="$2"
  if [ -z "${instance_id}" ] || [ "${instance_id}" = "None" ]; then
    warn "No instance to unprotect on ${asg_name} (instance_id empty)"
    return 0
  fi
  if dry_run_guard "set-instance-protection --no-protected-from-scale-in ${instance_id} (asg=${asg_name})"; then
    return 0
  fi
  info "Disabling scale-in protection on ${instance_id} (so refresh can terminate it)"
  aws autoscaling set-instance-protection \
    --instance-ids "${instance_id}" \
    --auto-scaling-group-name "${asg_name}" \
    --no-protected-from-scale-in \
    --region "${AWS_REGION}" \
    --no-cli-pager > /dev/null
}

# Kicks off an ASG instance-refresh and echoes the refresh ID.
# Uses MinHealthyPercentage=0 because each ASG runs a single instance.
# Caller MUST disable_scale_in_protection on the existing instance first
# (otherwise refresh stalls at 0% — see disable_scale_in_protection above).
start_instance_refresh() {
  local asg_name="$1"
  if dry_run_guard "aws autoscaling start-instance-refresh --auto-scaling-group-name ${asg_name}"; then
    echo "DRY_RUN_REFRESH_ID"
    return 0
  fi
  aws autoscaling start-instance-refresh \
    --auto-scaling-group-name "${asg_name}" \
    --preferences '{"MinHealthyPercentage":0,"InstanceWarmup":60,"SkipMatching":false}' \
    --region "${AWS_REGION}" \
    --query 'InstanceRefreshId' \
    --output text
}

# Polls start-instance-refresh status. Aborts on Failed / Cancelled.
wait_instance_refresh() {
  local asg_name="$1"
  local refresh_id="$2"
  local poll_interval=15
  local max_attempts=$((INSTANCE_REFRESH_TIMEOUT / poll_interval))
  local attempt=0

  if [ "${DRY_RUN}" = "true" ]; then
    info "[DRY RUN] Would wait for instance refresh ${refresh_id} on ${asg_name}"
    return 0
  fi

  info "Waiting for instance refresh on ${asg_name} (refresh_id=${refresh_id})..."
  while [ $attempt -lt $max_attempts ]; do
    local status
    status=$(aws autoscaling describe-instance-refreshes \
      --auto-scaling-group-name "${asg_name}" \
      --instance-refresh-ids "${refresh_id}" \
      --region "${AWS_REGION}" \
      --query 'InstanceRefreshes[0].Status' \
      --output text 2>/dev/null || echo "Unknown")

    case "${status}" in
      Successful)
        info "Instance refresh completed: ${asg_name}"
        return 0
        ;;
      Failed|Cancelled|RollbackFailed|RollbackSuccessful)
        abort "Instance refresh ${status} on ${asg_name} (refresh_id=${refresh_id})"
        ;;
      Pending|InProgress|Cancelling|RollbackInProgress)
        attempt=$((attempt + 1))
        if [ $((attempt % 4)) -eq 0 ]; then
          local pct
          pct=$(aws autoscaling describe-instance-refreshes \
            --auto-scaling-group-name "${asg_name}" \
            --instance-refresh-ids "${refresh_id}" \
            --region "${AWS_REGION}" \
            --query 'InstanceRefreshes[0].PercentageComplete' \
            --output text 2>/dev/null || echo "?")
          info "  ${asg_name}: ${status} (${pct}%) - $((attempt * poll_interval))s/${INSTANCE_REFRESH_TIMEOUT}s"
        fi
        sleep $poll_interval
        ;;
      *)
        warn "Unknown refresh status: ${status}"
        sleep $poll_interval
        attempt=$((attempt + 1))
        ;;
    esac
  done

  abort "Instance refresh on ${asg_name} did not complete within ${INSTANCE_REFRESH_TIMEOUT}s"
}

# Wait for ECS container instance to register from a fresh EC2 instance.
# `expected_attribute_name` and `expected_attribute_value` filter by user_data
# attribute (e.g. clickhouse_node=s1r1).
wait_ecs_container_instance_registered() {
  local attribute_name="$1"
  local attribute_value="$2"
  local poll_interval=10
  local max_attempts=$((INSTANCE_REFRESH_TIMEOUT / poll_interval))
  local attempt=0

  if [ "${DRY_RUN}" = "true" ]; then
    info "[DRY RUN] Would wait for ECS container instance (${attribute_name}=${attribute_value})"
    return 0
  fi

  info "Waiting for ECS container instance with ${attribute_name}=${attribute_value}..."
  while [ $attempt -lt $max_attempts ]; do
    local arns
    arns=$(aws ecs list-container-instances \
      --cluster "${CLUSTER_NAME}" \
      --filter "attribute:${attribute_name} == ${attribute_value}" \
      --status ACTIVE \
      --region "${AWS_REGION}" \
      --query 'containerInstanceArns' \
      --output text 2>/dev/null || echo "")

    if [ -n "${arns}" ] && [ "${arns}" != "None" ]; then
      info "ECS container instance registered: ${attribute_name}=${attribute_value}"
      return 0
    fi

    attempt=$((attempt + 1))
    if [ $((attempt % 3)) -eq 0 ]; then
      info "  Still waiting for container instance registration... ($((attempt * poll_interval))s/${INSTANCE_REFRESH_TIMEOUT}s)"
    fi
    sleep $poll_interval
  done

  abort "ECS container instance (${attribute_name}=${attribute_value}) did not register within ${INSTANCE_REFRESH_TIMEOUT}s"
}
