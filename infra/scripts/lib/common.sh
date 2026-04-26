#!/usr/bin/env bash
# Common utilities for ClickHouse/Keeper operational scripts.
# Source this file from the caller: source "$(dirname "$0")/lib/common.sh"

# Logging. Writes to stderr so function return values captured via `$(...)`
# are not contaminated with log lines.
log()  { echo "[$(date '+%H:%M:%S')] $*" >&2; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; }
sep()  { echo "────────────────────────────────────────────────────────" >&2; }

abort() {
  err "$1"
  err "Operation aborted. Fix the issue and re-run the script to continue."
  exit 1
}

# Returns 0 (and logs) when DRY_RUN=true, otherwise 1.
# Callers use: `if dry_run_guard "would do X"; then return 0; fi`
dry_run_guard() {
  if [ "${DRY_RUN:-false}" = "true" ]; then
    info "[DRY RUN] Would execute: $*"
    return 0
  fi
  return 1
}
