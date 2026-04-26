#!/usr/bin/env bash
# Keeper cluster operations: health, quorum, znode count.
#
# Requires:
#   lib/common.sh sourced first (log/info/warn/err/abort/dry_run_guard)
#   Env vars: DNS_SUFFIX, HEALTH_TIMEOUT

KEEPER_IDS=(1 2 3)

check_keeper_health() {
  local keeper_id="$1"
  local fqdn="keeper-${keeper_id}.${DNS_SUFFIX}"
  local poll_interval=5
  local max_attempts=$((HEALTH_TIMEOUT / poll_interval))
  local attempt=0

  if [ "${DRY_RUN}" = "true" ]; then
    info "[DRY RUN] Would check keeper-${keeper_id} health"
    return 0
  fi

  info "Checking keeper-${keeper_id} health (${fqdn})..."
  while [ $attempt -lt $max_attempts ]; do
    if echo "ruok" | nc -w 2 "${fqdn}" 9181 2>/dev/null | grep -q "imok"; then
      info "keeper-${keeper_id}: healthy (imok)"
      return 0
    fi
    attempt=$((attempt + 1))
    if [ $((attempt % 6)) -eq 0 ]; then
      info "  Still waiting for keeper-${keeper_id}... ($((attempt * poll_interval))s/${HEALTH_TIMEOUT}s)"
    fi
    sleep $poll_interval
  done

  abort "keeper-${keeper_id} did not become healthy within ${HEALTH_TIMEOUT}s"
}

check_keeper_quorum() {
  if [ "${DRY_RUN}" = "true" ]; then
    info "[DRY RUN] Would verify Keeper quorum"
    return 0
  fi

  info "Verifying Keeper quorum..."
  local healthy=0
  for id in "${KEEPER_IDS[@]}"; do
    local fqdn="keeper-${id}.${DNS_SUFFIX}"
    if echo "ruok" | nc -w 2 "${fqdn}" 9181 2>/dev/null | grep -q "imok"; then
      healthy=$((healthy + 1))
    else
      warn "keeper-${id} is not responding"
    fi
  done

  if [ $healthy -lt 2 ]; then
    abort "Keeper quorum lost (${healthy}/3 healthy). Need at least 2."
  fi
  info "Keeper quorum OK (${healthy}/3 healthy)"
}

get_keeper_znode_count() {
  local keeper_id="$1"
  local fqdn="keeper-${keeper_id}.${DNS_SUFFIX}"
  echo "mntr" | nc -w 2 "${fqdn}" 9181 2>/dev/null | grep "zk_znode_count" | awk '{print $2}'
}
