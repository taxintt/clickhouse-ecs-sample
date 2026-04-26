#!/usr/bin/env bash
# ClickHouse cluster operations: node metadata, health checks, query drain,
# cluster exclude/include, replication checks.
#
# Requires:
#   lib/common.sh sourced first (log/info/warn/err/abort/dry_run_guard)
#   Env vars: DNS_SUFFIX, CH_PASSWORD, HEALTH_TIMEOUT, QUERY_DRAIN_TIMEOUT,
#             REPLICATION_LAG_THRESHOLD

# ClickHouse nodes keyed by short id (e.g. s1r1).
# Callers: read CH_NODES / CH_ROUND_1 / CH_ROUND_2 via `"${CH_NODES[@]}"`
CH_NODES=(s1r1 s1r2 s2r1 s2r2)
# Rolling order: update one replica per shard at a time to maintain availability
CH_ROUND_1=(s1r1 s2r1)
CH_ROUND_2=(s1r2 s2r2)

ch_fqdn() {
  local node="$1"
  case "${node}" in
    s1r1) echo "clickhouse-shard1-replica1.${DNS_SUFFIX}" ;;
    s1r2) echo "clickhouse-shard1-replica2.${DNS_SUFFIX}" ;;
    s2r1) echo "clickhouse-shard2-replica1.${DNS_SUFFIX}" ;;
    s2r2) echo "clickhouse-shard2-replica2.${DNS_SUFFIX}" ;;
  esac
}

ch_query() {
  local fqdn="$1"
  local query="$2"
  curl -sf "http://${fqdn}:8123" \
    --user "default:${CH_PASSWORD}" \
    --data "${query}" 2>/dev/null
}

# Strict variant: returns non-zero on HTTP/query failure instead of silently
# returning empty. Use in safety-critical paths where empty must not be
# mistaken for a legitimate "0".
ch_query_strict() {
  local fqdn="$1"
  local query="$2"
  local out
  if ! out=$(curl -sf "http://${fqdn}:8123" \
    --user "default:${CH_PASSWORD}" \
    --data "${query}" 2>/dev/null); then
    return 1
  fi
  echo "${out}"
}

# HTTP parameter-bound query (guards against SQL injection via string values).
# Pass params as alternating name/value pairs starting at $3.
# Reference named params in the query as {name:Type}, e.g. {tid:String}.
ch_query_param() {
  local fqdn="$1"
  local query="$2"
  shift 2
  local -a args=(--data-urlencode "query=${query}")
  while [ $# -ge 2 ]; do
    args+=(--data-urlencode "param_$1=$2")
    shift 2
  done
  curl -sf "http://${fqdn}:8123" \
    --user "default:${CH_PASSWORD}" \
    "${args[@]}" 2>/dev/null
}

check_clickhouse_health() {
  local node="$1"
  local fqdn
  fqdn=$(ch_fqdn "${node}")
  local poll_interval=5
  local max_attempts=$((HEALTH_TIMEOUT / poll_interval))
  local attempt=0

  if [ "${DRY_RUN}" = "true" ]; then
    info "[DRY RUN] Would check ClickHouse ${node} health (${fqdn})"
    return 0
  fi

  info "Checking ClickHouse ${node} health (${fqdn})..."
  while [ $attempt -lt $max_attempts ]; do
    if curl -sf "http://${fqdn}:8123/ping" > /dev/null 2>&1; then
      info "ClickHouse ${node}: ping OK"
      return 0
    fi
    attempt=$((attempt + 1))
    if [ $((attempt % 6)) -eq 0 ]; then
      info "  Still waiting for ${node}... ($((attempt * poll_interval))s/${HEALTH_TIMEOUT}s)"
    fi
    sleep $poll_interval
  done

  abort "ClickHouse ${node} did not become healthy within ${HEALTH_TIMEOUT}s"
}

# Wait for in-flight queries to complete before stopping a node
# (equivalent to clickhouse-operator's host.wait.queries: true)
drain_queries() {
  local node="$1"
  local fqdn
  fqdn=$(ch_fqdn "${node}")
  local poll_interval=5
  local max_attempts=$((QUERY_DRAIN_TIMEOUT / poll_interval))
  local attempt=0

  if [ "${DRY_RUN}" = "true" ]; then
    info "[DRY RUN] Would drain queries on ${node}"
    return 0
  fi

  if [ -z "${CH_PASSWORD}" ]; then
    warn "CH_PASSWORD not set, skipping query drain"
    return 0
  fi

  info "Draining in-flight queries on ${node}..."
  while [ $attempt -lt $max_attempts ]; do
    local active_queries
    active_queries=$(ch_query "${fqdn}" \
      "SELECT count() FROM system.processes WHERE is_initial_query = 1 AND query NOT LIKE '%system.processes%'" \
      || echo "ERROR")

    if [ "${active_queries}" = "ERROR" ]; then
      attempt=$((attempt + 1))
      sleep $poll_interval
      continue
    fi

    if [ "${active_queries}" -eq 0 ]; then
      info "No active queries on ${node}"
      return 0
    fi

    attempt=$((attempt + 1))
    if [ $((attempt % 4)) -eq 0 ]; then
      info "  ${active_queries} active queries, waiting... ($((attempt * poll_interval))s/${QUERY_DRAIN_TIMEOUT}s)"
    fi
    sleep $poll_interval
  done

  warn "Query drain timed out on ${node} after ${QUERY_DRAIN_TIMEOUT}s (proceeding)"
}

# Stop flushing the Distributed insert buffer on this node (so writes queued
# via the Distributed engine don't leave pending async batches when the node
# restarts). Does NOT remove the node from cluster-wide SELECT routing —
# clients directly querying this node's host will still be served. For a full
# client-side drain, couple with an LB/Route53 weight change upstream.
exclude_from_cluster() {
  local node="$1"
  local fqdn
  fqdn=$(ch_fqdn "${node}")

  if [ "${DRY_RUN}" = "true" ]; then
    info "[DRY RUN] Would exclude ${node} from cluster"
    return 0
  fi

  if [ -z "${CH_PASSWORD}" ]; then
    return 0
  fi

  info "Excluding ${node} from distributed queries..."
  ch_query "${fqdn}" "SYSTEM STOP DISTRIBUTED SENDS" || true
  info "Stopped distributed sends on ${node}"
}

include_in_cluster() {
  local node="$1"
  local fqdn
  fqdn=$(ch_fqdn "${node}")

  if [ "${DRY_RUN}" = "true" ]; then
    return 0
  fi

  if [ -z "${CH_PASSWORD}" ]; then
    return 0
  fi

  info "Re-including ${node} in distributed queries..."
  ch_query "${fqdn}" "SYSTEM START DISTRIBUTED SENDS" || true
  info "Started distributed sends on ${node}"
}

check_replication_queue() {
  local node="$1"
  local fqdn
  fqdn=$(ch_fqdn "${node}")
  local poll_interval=5
  local max_attempts=$((HEALTH_TIMEOUT / poll_interval))
  local attempt=0

  if [ "${DRY_RUN}" = "true" ]; then
    info "[DRY RUN] Would check replication queue on ${node}"
    return 0
  fi

  if [ -z "${CH_PASSWORD}" ]; then
    warn "CH_PASSWORD not set, skipping replication queue check"
    return 0
  fi

  info "Waiting for replication queue to drain on ${node}..."
  while [ $attempt -lt $max_attempts ]; do
    local queue_size
    queue_size=$(ch_query "${fqdn}" \
      "SELECT count() FROM system.replication_queue" || echo "ERROR")

    if [ "${queue_size}" = "ERROR" ]; then
      attempt=$((attempt + 1))
      sleep $poll_interval
      continue
    fi

    if [ "${queue_size}" -le 10 ]; then
      info "Replication queue on ${node}: ${queue_size} (OK)"
      return 0
    fi

    attempt=$((attempt + 1))
    if [ $((attempt % 6)) -eq 0 ]; then
      info "  Queue size: ${queue_size}, waiting... ($((attempt * poll_interval))s/${HEALTH_TIMEOUT}s)"
    fi
    sleep $poll_interval
  done

  warn "Replication queue on ${node} did not drain within ${HEALTH_TIMEOUT}s (proceeding anyway)"
}

# Check replication lag in seconds (equivalent to clickhouse-operator's replicas.delay)
check_replication_lag() {
  local node="$1"
  local fqdn
  fqdn=$(ch_fqdn "${node}")
  local poll_interval=5
  local max_attempts=$((HEALTH_TIMEOUT / poll_interval))
  local attempt=0

  if [ "${DRY_RUN}" = "true" ]; then
    info "[DRY RUN] Would check replication lag on ${node}"
    return 0
  fi

  if [ -z "${CH_PASSWORD}" ]; then
    return 0
  fi

  info "Checking replication lag on ${node} (threshold: ${REPLICATION_LAG_THRESHOLD}s)..."
  while [ $attempt -lt $max_attempts ]; do
    # coalesce+toUInt32 handles: no rows in system.replicas and Float absolute_delay
    local max_lag
    if ! max_lag=$(ch_query_strict "${fqdn}" \
      "SELECT toUInt32(coalesce(max(absolute_delay), 0)) FROM system.replicas"); then
      attempt=$((attempt + 1))
      sleep $poll_interval
      continue
    fi

    if [ "${max_lag}" -le "${REPLICATION_LAG_THRESHOLD}" ]; then
      info "Replication lag on ${node}: ${max_lag}s (OK, threshold: ${REPLICATION_LAG_THRESHOLD}s)"
      return 0
    fi

    attempt=$((attempt + 1))
    if [ $((attempt % 4)) -eq 0 ]; then
      info "  Lag: ${max_lag}s, waiting... ($((attempt * poll_interval))s/${HEALTH_TIMEOUT}s)"
    fi
    sleep $poll_interval
  done

  warn "Replication lag on ${node} did not converge within ${HEALTH_TIMEOUT}s (proceeding)"
}

check_no_readonly_replicas() {
  local node="$1"
  local fqdn
  fqdn=$(ch_fqdn "${node}")

  if [ "${DRY_RUN}" = "true" ] || [ -z "${CH_PASSWORD}" ]; then
    return 0
  fi

  # Must use strict: silently returning "0" on query failure would mask real
  # readonly replicas and allow the update to proceed unsafely.
  local readonly_count
  if ! readonly_count=$(ch_query_strict "${fqdn}" \
    "SELECT count() FROM system.replicas WHERE is_readonly = 1"); then
    abort "Could not query system.replicas on ${node}"
  fi

  if [ "${readonly_count}" != "0" ]; then
    abort "ClickHouse ${node} has ${readonly_count} readonly replica(s)"
  fi
  info "ClickHouse ${node}: no readonly replicas"
}
