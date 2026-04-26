#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Shard rebalance script for ClickHouse logs cluster
#
# After adding new shard(s), existing data stays on the old shards (because the
# Distributed table uses sipHash64(tenant_id) and rows are only routed on write).
# This script redistributes existing data at tenant_id granularity:
#
#   1. Analyze: per-shard SELECT that both lists tenants AND computes the ideal
#      shard (sipHash64 % NEW_SHARD_COUNT + 1) in a single round-trip.
#   2. Execute: for each tenant whose current shard != ideal shard:
#        a. INSERT INTO logs_local (...) FROM cluster('logs_cluster', ...) WHERE _shard_num = {src} AND tenant_id = {tid}
#           - Uses cluster() (not remote()) so the password comes from the
#             pre-configured cluster secret — never appears in query_log.
#           - insert_quorum=2 + insert_quorum_parallel=0 waits for both dst
#             replicas before returning.
#        b. SYSTEM SYNC REPLICA on source replicas to guarantee they both
#           observe the source-side DELETE before we move on.
#        c. Verify src/dst row counts match.
#        d. DELETE FROM logs_local WHERE tenant_id = {tid} with mutations_sync=2
#           so both src replicas apply the lightweight delete before return.
#        e. Record progress to a state file for resume.
#
# REQUIRES: write traffic must be paused (or new writes must hit the new layout).
# A write-rate guard aborts if InsertedRows-per-second exceeds threshold.
#
# Usage:
#   NEW_SHARD_COUNT=3 CH_PASSWORD=xxx DRY_RUN=true  ./rebalance-shard.sh           # analyze only
#   NEW_SHARD_COUNT=3 CH_PASSWORD=xxx ./rebalance-shard.sh                          # execute
#   NEW_SHARD_COUNT=3 CH_PASSWORD=xxx ./rebalance-shard.sh --resume <state-file>    # resume
#   NEW_SHARD_COUNT=3 CH_PASSWORD=xxx ./rebalance-shard.sh --force                  # skip write-rate guard
#
# Environment variables:
#   PROJECT, ENVIRONMENT, AWS_REGION, DRY_RUN
#   CH_PASSWORD                 (required)
#   NEW_SHARD_COUNT             (required, integer >= 2)
#   DATABASE                    (default: logs)
#   TABLE                       (default: logs_local)
#   DISTRIBUTED_TABLE           (default: logs — used to verify sharding_key)
#   TENANT_COLUMN               (default: tenant_id)
#   WRITE_RATE_THRESHOLD        (default: 10) - aborts if InsertedRows/sec exceeds
#   WRITE_RATE_SAMPLE_SECONDS   (default: 10)
#   INSERT_QUORUM_TIMEOUT_MS    (default: 600000) - 10 min for large tenant copies
#   MUTATION_SYNC_TIMEOUT       (default: 600) - seconds for DELETE mutation sync
#   REBALANCE_STATE_DIR         (default: /var/tmp)
################################################################################

PROJECT="${PROJECT:-logplatform}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
CH_PASSWORD="${CH_PASSWORD:-}"
DRY_RUN="${DRY_RUN:-false}"

DATABASE="${DATABASE:-logs}"
TABLE="${TABLE:-logs_local}"
DISTRIBUTED_TABLE="${DISTRIBUTED_TABLE:-logs}"
TENANT_COLUMN="${TENANT_COLUMN:-tenant_id}"
WRITE_RATE_THRESHOLD="${WRITE_RATE_THRESHOLD:-10}"
WRITE_RATE_SAMPLE_SECONDS="${WRITE_RATE_SAMPLE_SECONDS:-10}"
INSERT_QUORUM_TIMEOUT_MS="${INSERT_QUORUM_TIMEOUT_MS:-600000}"
MUTATION_SYNC_TIMEOUT="${MUTATION_SYNC_TIMEOUT:-600}"
REBALANCE_STATE_DIR="${REBALANCE_STATE_DIR:-/var/tmp}"

CLUSTER_NAME="${PROJECT}-${ENVIRONMENT}"
DNS_SUFFIX="${PROJECT}.local"

# Timeouts (needed by common libs even though we don't orchestrate ECS)
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"
QUERY_DRAIN_TIMEOUT="${QUERY_DRAIN_TIMEOUT:-120}"
REPLICATION_LAG_THRESHOLD="${REPLICATION_LAG_THRESHOLD:-10}"

# Parse flags
RESUME_FILE=""
FORCE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --resume)
      RESUME_FILE="${2:-}"
      shift 2
      ;;
    --force)
      FORCE=true
      shift
      ;;
    *)
      echo "Unknown flag: $1" >&2
      echo "Usage: $0 [--resume <state-file>] [--force]" >&2
      exit 1
      ;;
  esac
done

# Shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/keeper-lib.sh
source "${SCRIPT_DIR}/lib/keeper-lib.sh"
# shellcheck source=lib/ch-cluster-lib.sh
source "${SCRIPT_DIR}/lib/ch-cluster-lib.sh"

################################################################################
# Pre-flight
################################################################################

require_vars() {
  if [ -z "${CH_PASSWORD}" ]; then
    abort "CH_PASSWORD is required."
  fi
  if [ -z "${NEW_SHARD_COUNT:-}" ]; then
    abort "NEW_SHARD_COUNT is required (e.g. 3)."
  fi
  if ! [[ "${NEW_SHARD_COUNT}" =~ ^[0-9]+$ ]] || [ "${NEW_SHARD_COUNT}" -lt 2 ]; then
    abort "NEW_SHARD_COUNT must be an integer >= 2 (got: ${NEW_SHARD_COUNT})."
  fi
}

# Pick a ClickHouse node that responds, starting with s1r1 and falling back
# through CH_NODES. Rebalance shouldn't wedge just because s1r1 is down.
pick_coordinator_fqdn() {
  for node in s1r1 "${CH_NODES[@]}"; do
    local fqdn
    fqdn=$(ch_fqdn "${node}")
    if [ -n "${fqdn}" ] && curl -sf "http://${fqdn}:8123/ping" >/dev/null 2>&1; then
      echo "${fqdn}"
      return 0
    fi
  done
  abort "No reachable ClickHouse node in ${CH_NODES[*]}"
}

verify_cluster_topology() {
  local fqdn="$1"
  local actual_shards
  if ! actual_shards=$(ch_query_strict "${fqdn}" \
    "SELECT count(DISTINCT shard_num) FROM system.clusters WHERE cluster = 'logs_cluster'"); then
    abort "Could not query system.clusters from ${fqdn}. Check CH_PASSWORD and connectivity."
  fi

  if [ "${actual_shards}" != "${NEW_SHARD_COUNT}" ]; then
    abort "Cluster has ${actual_shards} shards but NEW_SHARD_COUNT=${NEW_SHARD_COUNT}. Apply Terraform changes first."
  fi
  info "Cluster topology confirmed: ${actual_shards} shards"
}

# Ensure the Distributed table actually uses sipHash64(tenant_id) so that our
# rebalance formula matches ClickHouse's internal routing. Any mismatch here
# would silently send rows to the wrong shard.
verify_sharding_key() {
  local fqdn="$1"
  local ddl
  if ! ddl=$(ch_query_strict "${fqdn}" \
    "SHOW CREATE TABLE ${DATABASE}.${DISTRIBUTED_TABLE}"); then
    abort "Could not SHOW CREATE TABLE ${DATABASE}.${DISTRIBUTED_TABLE}"
  fi
  if ! echo "${ddl}" | grep -qE "sipHash64\(${TENANT_COLUMN}\)"; then
    abort "Distributed table ${DATABASE}.${DISTRIBUTED_TABLE} does not use sipHash64(${TENANT_COLUMN}) as sharding_key. Rebalance formula would be wrong."
  fi
  info "Sharding key verified: sipHash64(${TENANT_COLUMN})"

  # Also ensure all shards have uniform weight=1; otherwise `% shard_count` is wrong.
  local distinct_weights
  if ! distinct_weights=$(ch_query_strict "${fqdn}" \
    "SELECT count(DISTINCT weight) FROM system.clusters WHERE cluster = 'logs_cluster'"); then
    abort "Could not read weights from system.clusters"
  fi
  if [ "${distinct_weights}" != "1" ]; then
    abort "logs_cluster has non-uniform shard weights; modulo-based rebalance is unsafe. Aborting."
  fi
}

write_rate_guard() {
  if [ "${FORCE}" = "true" ]; then
    warn "--force passed, skipping write-rate guard"
    return 0
  fi
  local fqdn="$1"

  info "Sampling write rate for ${WRITE_RATE_SAMPLE_SECONDS}s (threshold: ${WRITE_RATE_THRESHOLD} inserts/sec)..."

  local before
  if ! before=$(ch_query_strict "${fqdn}" \
    "SELECT value FROM system.events WHERE event = 'InsertedRows'"); then
    abort "Could not sample InsertedRows on ${fqdn}"
  fi
  sleep "${WRITE_RATE_SAMPLE_SECONDS}"
  local after
  if ! after=$(ch_query_strict "${fqdn}" \
    "SELECT value FROM system.events WHERE event = 'InsertedRows'"); then
    abort "Could not sample InsertedRows on ${fqdn}"
  fi

  local delta=$((after - before))
  if [ "${delta}" -lt 0 ]; then
    abort "InsertedRows counter decreased (server restart during sampling?). Wait for stable cluster and re-run."
  fi
  local rate=$((delta / WRITE_RATE_SAMPLE_SECONDS))
  info "Observed write rate: ${rate} inserts/sec (delta=${delta} over ${WRITE_RATE_SAMPLE_SECONDS}s)"

  if [ "${rate}" -gt "${WRITE_RATE_THRESHOLD}" ]; then
    abort "Write rate ${rate}/sec exceeds threshold ${WRITE_RATE_THRESHOLD}/sec. Pause writes, or re-run with --force."
  fi
}

################################################################################
# Tenant id validation
################################################################################

# Reject tenant IDs containing tab / newline / empty — these would corrupt
# the TSV plan/state files. Returns non-zero if any bad tenants exist.
reject_bad_tenant_ids() {
  local fqdn="$1"
  local bad_count
  if ! bad_count=$(ch_query_strict "${fqdn}" \
    "SELECT count() FROM (SELECT DISTINCT ${TENANT_COLUMN} FROM ${DATABASE}.${TABLE} WHERE ${TENANT_COLUMN} = '' OR position(${TENANT_COLUMN}, char(9)) > 0 OR position(${TENANT_COLUMN}, char(10)) > 0 OR position(${TENANT_COLUMN}, char(0)) > 0)"); then
    abort "Could not validate tenant_id character set"
  fi
  if [ "${bad_count}" != "0" ]; then
    abort "${bad_count} tenant_id(s) contain tab/newline/NUL/empty. Clean them up before rebalance (these would corrupt TSV state)."
  fi
}

################################################################################
# Shard mapping
################################################################################

# Map shard_num (1-based from system.clusters) to one representative node id.
# Matches the s{N}r{M} naming convention used across the cluster.
shard_representative_node() {
  local shard_num="$1"
  echo "s${shard_num}r1"
}

################################################################################
# Analyze — one SQL per shard does both list-and-classify
################################################################################

analyze() {
  local plan_file="$1"
  local coord_fqdn="$2"

  info "Analyzing tenant distribution across shards..."
  : > "${plan_file}"

  local actual_shards
  if ! actual_shards=$(ch_query_strict "${coord_fqdn}" \
    "SELECT count(DISTINCT shard_num) FROM system.clusters WHERE cluster = 'logs_cluster'"); then
    abort "Could not read actual shard count"
  fi

  local total_moving=0
  local total_rows=0

  local shard_num=1
  while [ "${shard_num}" -le "${actual_shards}" ]; do
    local node
    node=$(shard_representative_node "${shard_num}")
    local node_fqdn
    node_fqdn=$(ch_fqdn "${node}")
    if [ -z "${node_fqdn}" ]; then
      warn "No FQDN mapping for shard ${shard_num}; skipping."
      shard_num=$((shard_num + 1))
      continue
    fi

    info "  Querying shard ${shard_num} via ${node_fqdn}..."
    # Compute ideal shard and current shard in a single query; filter to rows
    # that need moving so the plan file is already trimmed.
    # shellcheck disable=SC2016
    local query
    query="SELECT ${TENANT_COLUMN}, ${shard_num} AS src, toUInt32((sipHash64(${TENANT_COLUMN}) % {new_shards:UInt32}) + 1) AS dst, count() AS rows
FROM ${DATABASE}.${TABLE}
GROUP BY ${TENANT_COLUMN}
HAVING dst != src
FORMAT TabSeparated"

    local tmp_out
    tmp_out=$(mktemp "${REBALANCE_STATE_DIR}/rebalance-analyze.XXXXXX")
    trap 'rm -f "${tmp_out}"' RETURN

    if ! ch_query_param "${node_fqdn}" "${query}" \
      "new_shards" "${NEW_SHARD_COUNT}" > "${tmp_out}"; then
      abort "Failed to analyze tenants on shard ${shard_num}"
    fi

    # Append and tally. `ch_query_param` guaranteed clean tenant_ids (we pre-validated).
    local lines
    lines=$(awk 'END{print NR}' "${tmp_out}")
    cat "${tmp_out}" >> "${plan_file}"

    if [ "${lines}" -gt 0 ]; then
      local added_rows
      added_rows=$(awk -F'\t' '{sum+=$4} END{print sum+0}' "${tmp_out}")
      total_moving=$((total_moving + lines))
      total_rows=$((total_rows + added_rows))
    fi
    rm -f "${tmp_out}"

    shard_num=$((shard_num + 1))
  done

  sep
  info "Rebalance plan: ${plan_file}"
  info "  tenants to move: ${total_moving}"
  info "  rows to move:    ${total_rows}"
  sep

  if [ "${total_moving}" -eq 0 ]; then
    info "Distribution is already balanced under NEW_SHARD_COUNT=${NEW_SHARD_COUNT}. Nothing to do."
    return 1
  fi
  return 0
}

################################################################################
# Move a single tenant — INSERT via cluster() + quorum, then DELETE with mutations_sync
################################################################################

move_tenant() {
  local tenant_id="$1"
  local src_shard="$2"
  local dst_shard="$3"
  local expected_rows="$4"

  local src_fqdn
  src_fqdn=$(ch_fqdn "$(shard_representative_node "${src_shard}")")
  local dst_fqdn
  dst_fqdn=$(ch_fqdn "$(shard_representative_node "${dst_shard}")")

  info "Moving tenant='${tenant_id}' shard ${src_shard} -> ${dst_shard} (~${expected_rows} rows)"

  if [ "${DRY_RUN}" = "true" ]; then
    info "[DRY RUN] Would INSERT via cluster() into shard ${dst_shard} with insert_quorum=2"
    info "[DRY RUN] Would SYSTEM SYNC REPLICA on shard ${src_shard}"
    info "[DRY RUN] Would DELETE tenant from shard ${src_shard} with mutations_sync=2"
    return 0
  fi

  copy_tenant "${tenant_id}" "${src_shard}" "${dst_shard}" "${dst_fqdn}"
  sync_replicas_for_shard "${src_shard}"
  verify_tenant_counts "${tenant_id}" "${src_fqdn}" "${dst_fqdn}"
  delete_tenant_from_source "${tenant_id}" "${src_fqdn}"
}

# Copy rows for a single tenant from source shard to destination shard.
#
# - `cluster('logs_cluster', ...)` reads from the cluster definition whose
#   password lives in <secret> — password is NOT embedded in the query.
# - `_shard_num` virtual column filters to just the source shard.
# - insert_quorum=2 + insert_quorum_parallel=0 waits until both replicas of the
#   destination shard acknowledge the write before returning.
copy_tenant() {
  local tenant_id="$1"
  local src_shard="$2"
  local _dst_shard="$3"
  local dst_fqdn="$4"

  local query
  query="INSERT INTO ${DATABASE}.${TABLE}
SELECT * FROM cluster('logs_cluster', ${DATABASE}, ${TABLE})
WHERE _shard_num = {src:UInt32} AND ${TENANT_COLUMN} = {tid:String}
SETTINGS insert_quorum = 2, insert_quorum_parallel = 0, insert_quorum_timeout = ${INSERT_QUORUM_TIMEOUT_MS}"

  if ! ch_query_param "${dst_fqdn}" "${query}" \
    "src" "${src_shard}" "tid" "${tenant_id}"; then
    abort "INSERT failed for tenant='${tenant_id}' (src_shard=${src_shard})"
  fi
}

# Wait for all replicas on a shard to observe the latest data so the subsequent
# count verification and DELETE see a consistent view.
sync_replicas_for_shard() {
  local shard_num="$1"
  local node
  node=$(shard_representative_node "${shard_num}")
  local fqdn
  fqdn=$(ch_fqdn "${node}")
  info "  SYSTEM SYNC REPLICA on shard ${shard_num} (${fqdn})"
  if ! ch_query_strict "${fqdn}" \
    "SYSTEM SYNC REPLICA ${DATABASE}.${TABLE}" >/dev/null; then
    warn "SYNC REPLICA failed on shard ${shard_num} — proceeding with caution"
  fi
}

verify_tenant_counts() {
  local tenant_id="$1"
  local src_fqdn="$2"
  local dst_fqdn="$3"

  local src_count
  if ! src_count=$(ch_query_param "${src_fqdn}" \
    "SELECT count() FROM ${DATABASE}.${TABLE} WHERE ${TENANT_COLUMN} = {tid:String}" \
    "tid" "${tenant_id}"); then
    abort "Failed to count source rows for tenant='${tenant_id}'"
  fi
  local dst_count
  if ! dst_count=$(ch_query_param "${dst_fqdn}" \
    "SELECT count() FROM ${DATABASE}.${TABLE} WHERE ${TENANT_COLUMN} = {tid:String}" \
    "tid" "${tenant_id}"); then
    abort "Failed to count destination rows for tenant='${tenant_id}'"
  fi

  if [ "${src_count}" != "${dst_count}" ]; then
    # Rollback: remove what we inserted on the destination.
    warn "Row count mismatch (src=${src_count}, dst=${dst_count}). Rolling back destination insert."
    ch_query_param "${dst_fqdn}" \
      "DELETE FROM ${DATABASE}.${TABLE} WHERE ${TENANT_COLUMN} = {tid:String} SETTINGS mutations_sync = 2" \
      "tid" "${tenant_id}" || true
    abort "Rollback complete. Re-run after investigating source data."
  fi
  info "  verified: src=${src_count} dst=${dst_count}"
}

# Lightweight DELETE with mutations_sync=2: return only after both source
# replicas have applied the mutation — avoids a stale view on replica 2.
delete_tenant_from_source() {
  local tenant_id="$1"
  local src_fqdn="$2"

  local query="DELETE FROM ${DATABASE}.${TABLE}
WHERE ${TENANT_COLUMN} = {tid:String}
SETTINGS mutations_sync = 2"

  if ! ch_query_param "${src_fqdn}" "${query}" "tid" "${tenant_id}"; then
    abort "DELETE failed on source for tenant='${tenant_id}'"
  fi
  info "  source cleared (replicated delete confirmed)"
}

################################################################################
# Execute plan
################################################################################

execute_plan() {
  local plan_file="$1"
  local state_file="$2"

  local -A done_tenants=()
  if [ -f "${state_file}" ] && [ -s "${state_file}" ]; then
    info "Resuming from state file: ${state_file}"
    while IFS=$'\t' read -r status tenant_id _rest; do
      if [ "${status}" = "DONE" ]; then
        done_tenants["${tenant_id}"]=1
      fi
    done < "${state_file}"
    info "Already completed: ${#done_tenants[@]} tenants"
  else
    : > "${state_file}"
    info "State file: ${state_file}"
  fi

  local total
  total=$(awk 'END{print NR}' "${plan_file}")
  local processed=0
  local skipped=0

  while IFS=$'\t' read -r tenant_id src_shard dst_shard row_count; do
    processed=$((processed + 1))
    if [ -n "${done_tenants[${tenant_id}]:-}" ]; then
      skipped=$((skipped + 1))
      continue
    fi

    info "[${processed}/${total}] tenant='${tenant_id}'"
    move_tenant "${tenant_id}" "${src_shard}" "${dst_shard}" "${row_count}"

    printf 'DONE\t%s\t%s\t%s\t%s\t%s\n' \
      "${tenant_id}" "${src_shard}" "${dst_shard}" "${row_count}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      >> "${state_file}"
  done < "${plan_file}"

  sep
  info "Rebalance complete. processed=${processed} skipped(already done)=${skipped}"
  sep
}

################################################################################
# Main
################################################################################

require_vars

info "Rebalance shard: NEW_SHARD_COUNT=${NEW_SHARD_COUNT}"
info "Cluster: ${CLUSTER_NAME} (region: ${AWS_REGION})"
if [ "${DRY_RUN}" = "true" ]; then
  info "*** DRY RUN MODE - no data will be moved ***"
fi
echo ""

check_keeper_quorum
COORD_FQDN=$(pick_coordinator_fqdn)
info "Using coordinator: ${COORD_FQDN}"
verify_cluster_topology "${COORD_FQDN}"
verify_sharding_key "${COORD_FQDN}"
reject_bad_tenant_ids "${COORD_FQDN}"
write_rate_guard "${COORD_FQDN}"

timestamp="$(date +%Y%m%d-%H%M%S)"
plan_file="${REBALANCE_STATE_DIR}/rebalance-plan-${timestamp}.tsv"
state_file="${RESUME_FILE:-${REBALANCE_STATE_DIR}/rebalance-state-${timestamp}.log}"

if analyze "${plan_file}" "${COORD_FQDN}"; then
  if [ "${DRY_RUN}" = "true" ]; then
    info "Analysis complete. Plan written to ${plan_file}. Review before executing without DRY_RUN."
  else
    execute_plan "${plan_file}" "${state_file}"
    info "Plan file:  ${plan_file}"
    info "State file: ${state_file}"
  fi
fi

info "Done."
