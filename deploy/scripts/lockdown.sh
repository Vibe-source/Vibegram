#!/bin/bash
# Incident mode. Takes the public edge and the code-executing surface offline in
# one step, without touching data. Run as ops (needs sudo for ufw).
#
#   sudo deploy/scripts/lockdown.sh on                 # everything public closed
#   sudo deploy/scripts/lockdown.sh on --allow 1.2.3.4 # ...except this address
#   sudo deploy/scripts/lockdown.sh off
#   sudo deploy/scripts/lockdown.sh status
#
# Postgres, valkey and core keep running: the app stays reachable over an SSH
# tunnel so you can investigate while the world cannot reach it.
set -euo pipefail

APP_DIR="${VIBE_APP_DIR:-/opt/vibe}"
LOG="${APP_DIR}/deploy/agent-ops-logs/lockdown.log"
STATE=/var/lib/vibe-lockdown
# The AI surface: arbitrary code, arbitrary egress, provider credentials.
RISK_SERVICES="agent-runtime sandbox-gateway doc-renderer"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
mkdir -p "$(dirname "$LOG")"
note() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

as_vibe() { runuser -u vibe -- env XDG_RUNTIME_DIR=/run/user/1000 "$@"; }

stop_risk() {
  for svc in $RISK_SERVICES; do
    as_vibe podman stop -t 10 "deploy_${svc}_1" >/dev/null 2>&1 && note "stopped ${svc}" \
      || note "already stopped ${svc}"
  done
  # Ephemeral agent sandboxes are not compose services; kill them by network.
  for c in $(as_vibe podman ps --format '{{.Names}}' --filter network=deploy_sandbox-net 2>/dev/null); do
    as_vibe podman kill "$c" >/dev/null 2>&1 && note "killed sandbox ${c}"
  done
}

start_risk() {
  for svc in $RISK_SERVICES; do
    as_vibe podman start "deploy_${svc}_1" >/dev/null 2>&1 && note "started ${svc}" \
      || note "could not start ${svc} (recreate with deploy.sh)"
  done
}

case "${1:-status}" in
  on)
    allow=""
    [ "${2:-}" = "--allow" ] && allow="${3:?--allow needs an address or CIDR}"
    ufw --force delete allow 80/tcp >/dev/null 2>&1 || true
    ufw --force delete allow 443/tcp >/dev/null 2>&1 || true
    if [ -n "$allow" ]; then
      ufw allow from "$allow" to any port 80 proto tcp comment 'lockdown allow'
      ufw allow from "$allow" to any port 443 proto tcp comment 'lockdown allow'
      note "LOCKDOWN ON — public 80/443 closed except ${allow}"
    else
      note "LOCKDOWN ON — public 80/443 closed"
    fi
    stop_risk
    printf '%s\n' "${allow:-all}" >"$STATE"
    ;;
  off)
    [ -f "$STATE" ] || note "no lockdown state file — restoring defaults anyway"
    ufw --force delete allow from any to any port 80 proto tcp >/dev/null 2>&1 || true
    while ufw status numbered | grep -q 'lockdown allow'; do
      n=$(ufw status numbered | grep -m1 'lockdown allow' | tr -d '[]' | awk '{print $1}')
      ufw --force delete "$n" >/dev/null 2>&1 || break
    done
    ufw allow 80/tcp comment 'caddy acme + redirect'
    ufw allow 443/tcp comment 'caddy tls'
    start_risk
    rm -f "$STATE"
    note "LOCKDOWN OFF — public edge restored"
    ;;
  status)
    if [ -f "$STATE" ]; then echo "lockdown: ON (allow=$(cat "$STATE"))"; else echo "lockdown: off"; fi
    ufw status | grep -E '^(80|443)' || true
    for svc in $RISK_SERVICES; do
      printf '%-18s %s\n' "$svc" "$(as_vibe podman inspect "deploy_${svc}_1" \
        --format '{{.State.Status}}' 2>/dev/null || echo absent)"
    done
    ;;
  *) echo "usage: lockdown.sh on [--allow CIDR] | off | status" >&2; exit 1 ;;
esac
