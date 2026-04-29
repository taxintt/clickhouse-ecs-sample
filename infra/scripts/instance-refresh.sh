#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Instance refresh script for ClickHouse / Keeper on ECS
#
# Replaces the underlying EC2 instance in each ASG (e.g. for AMI upgrade, OS
# patching, instance-type change). Unlike rolling-update.sh — which only
# force-deploys ECS tasks on the same EC2 host — this rebuilds the EC2
# instance itself via ASG instance-refresh.
#
# Prerequisite: the desired Launch Template version must already be applied
# via Terraform (updated AMI, instance_type, block_device_mappings, etc.)
#
# Usage:
#   ./instance-refresh.sh [keeper|clickhouse|all]            # refresh everything of that type
#   ./instance-refresh.sh clickhouse --only s1r1             # refresh a single ClickHouse node
#   ./instance-refresh.sh keeper --only 1                    # refresh a single Keeper node
#
# Environment variables:
#   PROJECT, ENVIRONMENT, AWS_REGION, CH_PASSWORD, DRY_RUN,
#   HEALTH_TIMEOUT, QUERY_DRAIN_TIMEOUT, REPLICATION_LAG_THRESHOLD
#   INSTANCE_REFRESH_TIMEOUT (default: 1200) - seconds to wait for refresh
#
# Prerequisites:
#   - aws CLI with autoscaling + ecs permissions
#   - nc (nmap-ncat) reachable to Keeper/ClickHouse FQDNs
################################################################################

TARGET="${1:-all}"
ONLY_NODE=""
# Parse `--only <node>` (optional second flag)
if [ "${2:-}" = "--only" ]; then
  ONLY_NODE="${3:-}"
  if [ -z "${ONLY_NODE}" ]; then
    echo "Error: --only requires a node id (e.g. s1r1 for clickhouse, 1 for keeper)" >&2
    exit 1
  fi
fi

PROJECT="${PROJECT:-logplatform}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
CH_PASSWORD="${CH_PASSWORD:-}"
DRY_RUN="${DRY_RUN:-false}"

# Timeouts (seconds)
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
QUERY_DRAIN_TIMEOUT="${QUERY_DRAIN_TIMEOUT:-120}"
REPLICATION_LAG_THRESHOLD="${REPLICATION_LAG_THRESHOLD:-10}"
INSTANCE_REFRESH_TIMEOUT="${INSTANCE_REFRESH_TIMEOUT:-1200}"

CLUSTER_NAME="${PROJECT}-${ENVIRONMENT}"
DNS_SUFFIX="${PROJECT}.local"

# Shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/keeper-lib.sh
source "${SCRIPT_DIR}/lib/keeper-lib.sh"
# shellcheck source=lib/ch-cluster-lib.sh
source "${SCRIPT_DIR}/lib/ch-cluster-lib.sh"
# shellcheck source=lib/asg-lib.sh
source "${SCRIPT_DIR}/lib/asg-lib.sh"

# Best-effort topology discovery so newly added shards (s3r1, s3r2, ...) are
# also refreshed. On failure, falls back to the static 2-shard layout.
attempt_topology_discovery() {
  if [ -z "${CH_PASSWORD}" ] || [ "${DRY_RUN}" = "true" ]; then
    warn "Skipping topology discovery (CH_PASSWORD not set or DRY_RUN); using static node list."
    return 0
  fi
  local boot_fqdn
  boot_fqdn=$(ch_fqdn "s1r1")
  if [ -z "${boot_fqdn}" ] || ! curl -sf "http://${boot_fqdn}:8123/ping" >/dev/null 2>&1; then
    warn "Bootstrap node s1r1 unreachable; using static node list."
    return 0
  fi
  if ! discover_ch_topology "${boot_fqdn}"; then
    warn "Topology discovery failed; using static node list."
  fi
  return 0
}

################################################################################
# ECS wait helpers
################################################################################

wait_ecs_stable() {
  local service_name="${CLUSTER_NAME}-$1"
  if [ "${DRY_RUN}" = "true" ]; then return 0; fi
  info "Waiting for service to stabilize: ${service_name}"
  aws ecs wait services-stable \
    --cluster "${CLUSTER_NAME}" \
    --services "${service_name}" \
    --region "${AWS_REGION}"
  info "Service stabilized: ${service_name}"
}

################################################################################
# Keeper refresh
################################################################################

refresh_keeper_node() {
  local id="$1"
  local asg_name
  asg_name=$(asg_name_for_keeper "${id}")

  sep
  info ">>> Refreshing keeper-${id} (asg=${asg_name})"

  local old_instance_id
  old_instance_id=$(get_asg_instance_id "${asg_name}" || echo "")
  info "Current instance: ${old_instance_id:-<none>}"

  # ASG protect_from_scale_in=true blocks instance-refresh; unprotect first.
  disable_scale_in_protection "${asg_name}" "${old_instance_id}"

  local refresh_id
  refresh_id=$(start_instance_refresh "${asg_name}")
  info "Started instance refresh: ${refresh_id}"

  wait_instance_refresh "${asg_name}" "${refresh_id}"

  # After refresh, wait for the new container instance to register with ECS.
  # user_data sets attribute: keeper_node == ${id}
  wait_ecs_container_instance_registered "keeper_node" "${id}"

  # Wait for ECS to place the keeper task on the new instance.
  wait_ecs_stable "keeper-${id}"

  # Health and quorum checks.
  check_keeper_health "${id}"
  check_keeper_quorum

  info "<<< keeper-${id} refresh complete"
}

refresh_keeper_all() {
  sep
  info "Starting Keeper instance refresh"
  sep

  check_keeper_quorum

  local initial_znodes=()
  for id in "${KEEPER_IDS[@]}"; do
    local count
    count=$(get_keeper_znode_count "$id")
    initial_znodes+=("${count}")
    info "keeper-${id} znode_count: ${count}"
  done

  for i in "${!KEEPER_IDS[@]}"; do
    local id="${KEEPER_IDS[$i]}"
    refresh_keeper_node "${id}"

    if [ "${DRY_RUN}" != "true" ]; then
      local new_count
      new_count=$(get_keeper_znode_count "$id")
      info "keeper-${id} znode_count: ${new_count} (was: ${initial_znodes[$i]})"
      if [ -n "${new_count}" ] && [ -n "${initial_znodes[$i]}" ] && [ "${new_count}" -lt "${initial_znodes[$i]}" ]; then
        warn "znode_count decreased on keeper-${id} (${initial_znodes[$i]} -> ${new_count})"
      fi
    fi
  done

  sep
  info "Keeper instance refresh complete"
  sep
}

################################################################################
# ClickHouse refresh (round-based for availability)
################################################################################

refresh_clickhouse_round() {
  local -a nodes=("$@")
  sep
  info ">>> Round: ${nodes[*]}"

  # Pre-update: exclude + drain (one by one)
  for node in "${nodes[@]}"; do
    exclude_from_cluster "${node}"
    drain_queries "${node}"
  done

  # Start instance refresh on all nodes in this round in parallel.
  # Each ASG has its own refresh; we block until all complete.
  # Disable scale-in protection on the existing instance first
  # (otherwise refresh stalls at 0% on protected instances).
  local -a refresh_ids=()
  for node in "${nodes[@]}"; do
    local asg_name
    asg_name=$(asg_name_for_ch_node "${node}")
    local old_instance_id
    old_instance_id=$(get_asg_instance_id "${asg_name}" || echo "")
    info "Starting refresh on ${node} (asg=${asg_name}, old=${old_instance_id:-<none>})"
    disable_scale_in_protection "${asg_name}" "${old_instance_id}"
    local refresh_id
    refresh_id=$(start_instance_refresh "${asg_name}")
    refresh_ids+=("${refresh_id}")
  done

  # Wait for each refresh to complete.
  for i in "${!nodes[@]}"; do
    local node="${nodes[$i]}"
    local asg_name
    asg_name=$(asg_name_for_ch_node "${node}")
    wait_instance_refresh "${asg_name}" "${refresh_ids[$i]}"
  done

  # Wait for new container instances and task placement.
  for node in "${nodes[@]}"; do
    wait_ecs_container_instance_registered "clickhouse_node" "${node}"
    wait_ecs_stable "ch-${node}"
  done

  # Post-update health / replication checks + re-include.
  for node in "${nodes[@]}"; do
    check_clickhouse_health "${node}"
    check_replication_queue "${node}"
    check_replication_lag "${node}"
    check_no_readonly_replicas "${node}"
    include_in_cluster "${node}"
  done

  info "<<< Round complete: ${nodes[*]}"
}

refresh_clickhouse_all() {
  sep
  info "Starting ClickHouse instance refresh"
  sep

  if [ -z "${CH_PASSWORD}" ]; then
    warn "CH_PASSWORD not set. Replication queue and readonly checks will be skipped."
  fi

  for node in "${CH_NODES[@]}"; do
    check_clickhouse_health "${node}"
  done

  refresh_clickhouse_round "${CH_ROUND_1[@]}"
  refresh_clickhouse_round "${CH_ROUND_2[@]}"

  sep
  info "Final verification: all nodes"
  for node in "${CH_NODES[@]}"; do
    check_no_readonly_replicas "${node}"
  done

  sep
  info "ClickHouse instance refresh complete"
  sep
}

refresh_clickhouse_single() {
  local node="$1"
  # Validate node id
  local valid=0
  for n in "${CH_NODES[@]}"; do
    if [ "${n}" = "${node}" ]; then valid=1; break; fi
  done
  if [ $valid -ne 1 ]; then
    abort "Invalid ClickHouse node '${node}'. Valid: ${CH_NODES[*]}"
  fi

  sep
  info "Starting ClickHouse instance refresh (single node: ${node})"
  sep

  check_clickhouse_health "${node}"
  refresh_clickhouse_round "${node}"

  sep
  info "ClickHouse single-node refresh complete"
  sep
}

refresh_keeper_single() {
  local id="$1"
  local valid=0
  for k in "${KEEPER_IDS[@]}"; do
    if [ "${k}" = "${id}" ]; then valid=1; break; fi
  done
  if [ $valid -ne 1 ]; then
    abort "Invalid Keeper id '${id}'. Valid: ${KEEPER_IDS[*]}"
  fi

  sep
  info "Starting Keeper instance refresh (single node: keeper-${id})"
  sep

  check_keeper_quorum
  refresh_keeper_node "${id}"

  sep
  info "Keeper single-node refresh complete"
  sep
}

################################################################################
# Version reporting
################################################################################

report_versions() {
  if [ "${DRY_RUN}" = "true" ] || [ -z "${CH_PASSWORD}" ]; then
    return 0
  fi

  sep
  info "Cluster version report"
  sep
  for node in "${CH_NODES[@]}"; do
    local fqdn
    fqdn=$(ch_fqdn "${node}")
    local version
    version=$(curl -sf "http://${fqdn}:8123" \
      --user "default:${CH_PASSWORD}" \
      --data "SELECT version()" 2>/dev/null || echo "N/A")
    info "${node} (${fqdn}): ${version}"
  done

  for id in "${KEEPER_IDS[@]}"; do
    local fqdn="keeper-${id}.${DNS_SUFFIX}"
    local version
    version=$(echo "stat" | nc -w 2 "${fqdn}" 9181 2>/dev/null | head -1 || echo "N/A")
    info "keeper-${id} (${fqdn}): ${version}"
  done
}

################################################################################
# Main
################################################################################

info "Instance refresh target: ${TARGET}${ONLY_NODE:+ (only: ${ONLY_NODE})}"
info "Cluster: ${CLUSTER_NAME} (region: ${AWS_REGION})"
if [ "${DRY_RUN}" = "true" ]; then
  info "*** DRY RUN MODE - no changes will be made ***"
fi
echo ""

case "${TARGET}" in
  keeper)
    if [ -n "${ONLY_NODE}" ]; then
      refresh_keeper_single "${ONLY_NODE}"
    else
      refresh_keeper_all
    fi
    ;;
  clickhouse)
    attempt_topology_discovery
    if [ -n "${ONLY_NODE}" ]; then
      refresh_clickhouse_single "${ONLY_NODE}"
    else
      refresh_clickhouse_all
    fi
    report_versions
    ;;
  all)
    if [ -n "${ONLY_NODE}" ]; then
      abort "--only is not supported with target=all. Use 'clickhouse --only <node>' or 'keeper --only <id>'."
    fi
    attempt_topology_discovery
    # Match rolling-update.sh ordering: ClickHouse before Keeper
    refresh_clickhouse_all
    refresh_keeper_all
    report_versions
    ;;
  *)
    echo "Usage: $0 [keeper|clickhouse|all] [--only <node>]"
    echo ""
    echo "Examples:"
    echo "  $0 all                         # refresh all EC2 instances (CH first, then Keeper)"
    echo "  $0 clickhouse                  # refresh only ClickHouse instances"
    echo "  $0 clickhouse --only s1r1      # refresh only one ClickHouse instance"
    echo "  $0 keeper --only 1             # refresh only keeper-1"
    echo ""
    echo "Environment variables:"
    echo "  PROJECT                    Project name (default: logplatform)"
    echo "  ENVIRONMENT                Environment (default: dev)"
    echo "  AWS_REGION                 AWS region (default: ap-northeast-1)"
    echo "  CH_PASSWORD                ClickHouse default user password"
    echo "  DRY_RUN                    Set to 'true' to preview without changes"
    echo "  HEALTH_TIMEOUT             Health check timeout (default: 300s)"
    echo "  QUERY_DRAIN_TIMEOUT        Query drain timeout (default: 120s)"
    echo "  REPLICATION_LAG_THRESHOLD  Max replication lag (default: 10s)"
    echo "  INSTANCE_REFRESH_TIMEOUT   ASG refresh timeout (default: 1200s)"
    exit 1
    ;;
esac

info "Done."
