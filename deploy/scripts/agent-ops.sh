#!/bin/bash
# The only surface an agent gets on this box. Fixed verbs, no free-form shell,
# no secret ever printed. Runs as `vibe` (no sudo), so it cannot touch the host.
#
# Interactive:  deploy/scripts/agent-ops.sh status
# Over SSH, pin it as a forced command so the key can do nothing else:
#   command="/opt/vibe/deploy/scripts/agent-ops.sh $SSH_ORIGINAL_COMMAND",\
#   no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding ssh-ed25519 AAAA... agent
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/vibe}"
COMPOSE_FILE="${APP_DIR}/deploy/compose.yml"
SERVICES="caddy core agent-runtime sandbox-gateway egress-proxy postgres pgbouncer valkey doc-renderer backup prometheus grafana node-exporter"

if command -v podman >/dev/null 2>&1; then ENGINE=podman; else ENGINE=docker; fi
COMPOSE=("$ENGINE" compose -f "$COMPOSE_FILE")
PROJECT="$(basename "$(dirname "$COMPOSE_FILE")")"

die() { echo "agent-ops: $*" >&2; exit 2; }

# One rejection point for every argument. A verb is a fixed word and an argument
# is a service name or a small integer — nothing here ever reaches a shell.
valid_service() {
  case " $SERVICES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
valid_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# podman-compose 1.0.6 has no --format on ps and no --no-color on logs, so every
# read verb goes to the engine directly and resolves the container by name.
container_for() {
  "$ENGINE" ps -a --filter "name=^${PROJECT}_$1_[0-9]+$" --format '{{.Names}}' | head -1
}

# Redacts anything that looks like a credential before it can reach a transcript.
scrub() {
  sed -E \
    -e 's/(password|passwd|secret|token|api[_-]?key|authorization|bearer)([^A-Za-z0-9]{1,3})[^[:space:]"'"'"']+/\1\2<redacted>/Ig' \
    -e 's#(postgres(ql)?|redis|rediss)://[^:]+:[^@]+@#\1://<redacted>@#g' \
    -e 's/\b(sk|xai|pk|rk|eyJ)[A-Za-z0-9_.\-]{16,}/<redacted>/g'
}

usage() {
  cat <<'USAGE'
agent-ops <verb> [arg]

read-only
  status              containers, health, restart counts
  health              HTTP readiness of core + agent-runtime
  ps                  process/resource use per container
  capacity            memory, swap, disk, cpu load vs the stack's limits
  logs <svc> [n]      last n (default 200) log lines of one service, scrubbed
  errors [n]          last n error/crash lines across the stack, scrubbed
  db-size             per-database size and top tables
  audit               run the security audit
  version             deployed git sha per image

state-changing (allowed, and each one is logged)
  restart <svc>       restart one service
  deploy              pull, build, migrate, roll out
  rollback <sha>      retag a previous build and restart core + agent-runtime
  backup-now          take an off-box encrypted backup immediately

never available: shell, exec, env, cat, psql, secrets, host sudo, DNS, firewall.
USAGE
}

audit_log() {
  # State changes leave a trail the owner can read even if the agent never says.
  mkdir -p "${APP_DIR}/deploy/agent-ops-logs"
  printf '%s  %s  %s\n' "$(date -uIs)" "${SSH_CLIENT%% *}" "$*" \
    >>"${APP_DIR}/deploy/agent-ops-logs/actions.log"
}

verb="${1:-help}"
arg="${2:-}"

case "$verb" in
  help|"")   usage ;;

  status)
    # podman-compose 1.0.6 has no --format on ps, so ask the engine by project label.
    "$ENGINE" ps -a --filter "label=io.podman.compose.project=${PROJECT}" \
      --format '{{.Names}}\t{{.Status}}' | scrub
    ;;

  health)
    for pair in "core:4000:/api/ready" "agent-runtime:4100:/readyz"; do
      svc="${pair%%:*}"; rest="${pair#*:}"; port="${rest%%:*}"; path="${rest#*:}"
      if "${COMPOSE[@]}" exec -T "$svc" wget -qO- "http://127.0.0.1:${port}${path}" >/dev/null 2>&1; then
        echo "${svc}: ready"
      else
        echo "${svc}: NOT READY"
      fi
    done
    ;;

  ps)
    if command -v podman >/dev/null 2>&1; then
      podman stats --no-stream --format 'table {{.Name}} {{.CPUPerc}} {{.MemUsage}} {{.MemPerc}}'
    else
      docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'
    fi
    ;;

  capacity)
    echo "--- memory ---";  free -m
    echo "--- swap ---";    swapon --show || echo "no swap"
    echo "--- disk ---";    df -h / /var 2>/dev/null | grep -v tmpfs
    echo "--- load ---";    uptime
    echo "--- images ---";  du -sh "${HOME}/.local/share/containers" 2>/dev/null || true
    ;;

  logs)
    valid_service "$arg" || die "unknown service: ${arg:-<none>}"
    n="${3:-200}"; valid_int "$n" || die "line count must be a number"
    [ "$n" -gt 2000 ] && n=2000
    c="$(container_for "$arg")"
    [ -n "$c" ] || die "service ${arg} has no container"
    "$ENGINE" logs --tail "$n" "$c" 2>&1 | scrub
    ;;

  errors)
    n="${arg:-200}"; valid_int "$n" || die "line count must be a number"
    [ "$n" -gt 2000 ] && n=2000
    for c in $("$ENGINE" ps -a --filter "label=io.podman.compose.project=${PROJECT}" --format '{{.Names}}'); do
      "$ENGINE" logs --tail "$n" "$c" 2>&1 | sed "s#^#${c}  #"
    done \
      | grep -iE '\[error\]|\berror\b|exception|crash|CRASH REPORT|GenServer .* terminating|OOM|killed|panic|fatal' \
      | scrub | tail -n "$n" || true
    ;;

  db-size)
    "${COMPOSE[@]}" exec -T postgres psql -U postgres -tAX \
      -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datistemplate = false ORDER BY pg_database_size(datname) DESC" \
      | scrub
    ;;

  audit)
    bash "${APP_DIR}/deploy/scripts/audit.sh" ;;

  version)
    for image in vibe-core vibe-agent-runtime; do
      if command -v podman >/dev/null 2>&1; then
        echo "${image}: $(podman images --format '{{.Tag}}' "$image" | grep -v latest | head -1)"
      else
        echo "${image}: $(docker images --format '{{.Tag}}' "$image" | grep -v latest | head -1)"
      fi
    done
    ;;

  restart)
    valid_service "$arg" || die "unknown service: ${arg:-<none>}"
    audit_log "restart $arg"
    "${COMPOSE[@]}" restart "$arg"
    ;;

  deploy)
    audit_log "deploy"
    bash "${APP_DIR}/deploy/scripts/deploy.sh" | scrub
    ;;

  rollback)
    case "$arg" in [0-9a-f]*) : ;; *) die "rollback needs a git sha" ;; esac
    audit_log "rollback $arg"
    bash "${APP_DIR}/deploy/scripts/deploy.sh" --rollback "$arg" | scrub
    ;;

  backup-now)
    audit_log "backup-now"
    "${COMPOSE[@]}" exec -T backup /usr/local/bin/backup.sh | scrub
    ;;

  *)
    die "unknown verb: ${verb} (try: help)"
    ;;
esac
