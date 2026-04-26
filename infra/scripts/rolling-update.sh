#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Rolling update script for ClickHouse / Keeper on ECS
#
# Usage:
#   ./rolling-update.sh [keeper|clickhouse|all]
#
# Environment variables:
#   PROJECT        (default: logplatform)
#   ENVIRONMENT    (default: dev)
#   AWS_REGION     (default: ap-northeast-1)
#   CH_PASSWORD    (required for ClickHouse health checks)
#   DRY_RUN        (default: false) - set to "true" to preview without deploying
#   HEALTH_TIMEOUT (default: 300)   - seconds to wait for health checks
#   QUERY_DRAIN_TIMEOUT   (default: 120) - seconds to wait for queries to drain
#   REPLICATION_LAG_THRESHOLD (default: 10) - max acceptable replication lag (sec)
#
# Prerequisites:
#   - aws CLI configured with appropriate credentials
#   - nc (nmap-ncat) available on a host that can reach Keeper/ClickHouse FQDNs
#     (run this script from CloudShell VPC environment or a bastion host)
################################################################################

TARGET="${1:-all}"
PROJECT="${PROJECT:-logplatform}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
CH_PASSWORD="${CH_PASSWORD:-}"
DRY_RUN="${DRY_RUN:-false}"

# Timeouts (seconds)
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
QUERY_DRAIN_TIMEOUT="${QUERY_DRAIN_TIMEOUT:-120}"
REPLICATION_LAG_THRESHOLD="${REPLICATION_LAG_THRESHOLD:-10}"

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

################################################################################
# ECS operations
################################################################################

deploy_ecs_service() {
  local service_name="${CLUSTER_NAME}-$1"
  if dry_run_guard "aws ecs update-service --force-new-deployment ${service_name}"; then
    return 0
  fi
  info "Deploying: ${service_name}"
  aws ecs update-service \
    --cluster "${CLUSTER_NAME}" \
    --service "${service_name}" \
    --force-new-deployment \
    --region "${AWS_REGION}" \
    --no-cli-pager > /dev/null
}

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
# Rolling update: Keeper
################################################################################

rolling_update_keeper() {
  sep
  info "Starting Keeper rolling update"
  sep

  # Pre-flight: verify quorum
  check_keeper_quorum

  # Record initial znode counts
  local initial_znodes=()
  for id in "${KEEPER_IDS[@]}"; do
    local count
    count=$(get_keeper_znode_count "$id")
    initial_znodes+=("${count}")
    info "keeper-${id} znode_count: ${count}"
  done

  # Roll one node at a time
  for i in "${!KEEPER_IDS[@]}"; do
    local id="${KEEPER_IDS[$i]}"
    sep
    info ">>> Updating keeper-${id} ($((i+1))/${#KEEPER_IDS[@]})"

    deploy_ecs_service "keeper-${id}"
    wait_ecs_stable "keeper-${id}"
    check_keeper_health "${id}"
    check_keeper_quorum

    # Verify znode count recovered
    if [ "${DRY_RUN}" != "true" ]; then
      local new_count
      new_count=$(get_keeper_znode_count "$id")
      info "keeper-${id} znode_count: ${new_count} (was: ${initial_znodes[$i]})"
      if [ -n "${new_count}" ] && [ -n "${initial_znodes[$i]}" ] && [ "${new_count}" -lt "${initial_znodes[$i]}" ]; then
        warn "znode_count decreased on keeper-${id} (${initial_znodes[$i]} -> ${new_count})"
      fi
    fi

    info "<<< keeper-${id} update complete"
  done

  sep
  info "Keeper rolling update complete"
  sep
}

################################################################################
# Rolling update: ClickHouse
################################################################################

rolling_update_clickhouse() {
  sep
  info "Starting ClickHouse rolling update"
  sep

  if [ -z "${CH_PASSWORD}" ]; then
    warn "CH_PASSWORD not set. Replication queue and readonly checks will be skipped."
  fi

  # Pre-flight: check all nodes healthy
  for node in "${CH_NODES[@]}"; do
    check_clickhouse_health "${node}"
  done

  # Round 1: one replica from each shard
  sep
  info ">>> Round 1: ${CH_ROUND_1[*]}"

  # Pre-update: exclude from cluster and drain queries
  for node in "${CH_ROUND_1[@]}"; do
    exclude_from_cluster "${node}"
    drain_queries "${node}"
  done

  # Deploy
  for node in "${CH_ROUND_1[@]}"; do
    deploy_ecs_service "ch-${node}"
  done

  # Post-update: wait for health, replication, then re-include
  for node in "${CH_ROUND_1[@]}"; do
    wait_ecs_stable "ch-${node}"
    check_clickhouse_health "${node}"
    check_replication_queue "${node}"
    check_replication_lag "${node}"
    check_no_readonly_replicas "${node}"
    include_in_cluster "${node}"
  done
  info "<<< Round 1 complete"

  # Round 2: the other replica from each shard
  sep
  info ">>> Round 2: ${CH_ROUND_2[*]}"

  # Pre-update: exclude from cluster and drain queries
  for node in "${CH_ROUND_2[@]}"; do
    exclude_from_cluster "${node}"
    drain_queries "${node}"
  done

  # Deploy
  for node in "${CH_ROUND_2[@]}"; do
    deploy_ecs_service "ch-${node}"
  done

  # Post-update: wait for health, replication, then re-include
  for node in "${CH_ROUND_2[@]}"; do
    wait_ecs_stable "ch-${node}"
    check_clickhouse_health "${node}"
    check_replication_queue "${node}"
    check_replication_lag "${node}"
    check_no_readonly_replicas "${node}"
    include_in_cluster "${node}"
  done
  info "<<< Round 2 complete"

  # Final verification
  sep
  info "Final verification: all nodes"
  for node in "${CH_NODES[@]}"; do
    check_no_readonly_replicas "${node}"
  done

  sep
  info "ClickHouse rolling update complete"
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

info "Rolling update target: ${TARGET}"
info "Cluster: ${CLUSTER_NAME} (region: ${AWS_REGION})"
if [ "${DRY_RUN}" = "true" ]; then
  info "*** DRY RUN MODE - no changes will be made ***"
fi
echo ""

case "${TARGET}" in
  keeper)
    rolling_update_keeper
    ;;
  clickhouse)
    rolling_update_clickhouse
    report_versions
    ;;
  all)
    # Official docs: upgrade ClickHouse Server before Keeper
    # https://clickhouse.com/docs/jp/operations/update
    rolling_update_clickhouse
    rolling_update_keeper
    report_versions
    ;;
  *)
    echo "Usage: $0 [keeper|clickhouse|all]"
    echo ""
    echo "Environment variables:"
    echo "  PROJECT        Project name (default: logplatform)"
    echo "  ENVIRONMENT    Environment (default: dev)"
    echo "  AWS_REGION     AWS region (default: ap-northeast-1)"
    echo "  CH_PASSWORD    ClickHouse default user password (required for full checks)"
    echo "  DRY_RUN        Set to 'true' to preview without deploying"
    echo "  HEALTH_TIMEOUT          Seconds to wait for health checks (default: 300)"
    echo "  QUERY_DRAIN_TIMEOUT     Seconds to wait for query drain (default: 120)"
    echo "  REPLICATION_LAG_THRESHOLD  Max acceptable replication lag in seconds (default: 10)"
    exit 1
    ;;
esac

info "Done."
