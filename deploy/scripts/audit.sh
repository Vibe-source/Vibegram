#!/bin/bash
# Security + capacity audit of a running Vibe VPS. Read-only: it changes
# nothing, prints no secret, and exits non-zero if any FAIL was recorded.
#
# Usage: deploy/scripts/audit.sh [host|stack|agent]   (default: all three)
set -uo pipefail

APP_DIR="${APP_DIR:-/opt/vibe}"
COMPOSE_FILE="${APP_DIR}/deploy/compose.yml"
if command -v podman >/dev/null 2>&1; then ENGINE=podman; else ENGINE=docker; fi
# The stack is rootless under 'vibe': root's own engine sees no containers, so
# from root we ask the stack user's engine rather than report an empty stack.
STACK_USER="${STACK_USER:-vibe}"
AS_STACK=()
if [ "$(id -u)" -eq 0 ] && id "$STACK_USER" >/dev/null 2>&1; then
  AS_STACK=(sudo -u "$STACK_USER" env \
    "XDG_RUNTIME_DIR=/run/user/$(id -u "$STACK_USER")" \
    "HOME=$(getent passwd "$STACK_USER" | cut -d: -f6)")
  cd / || true  # sudo -u cannot chdir into another user's home
fi
COMPOSE=("${AS_STACK[@]}" "$ENGINE" compose -f "$COMPOSE_FILE")
ENGINE_BIN="$ENGINE"
ENGINE="${AS_STACK[*]} $ENGINE"
SUDO=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && SUDO="sudo -n"
# vibe has no sudo by design, so sshd/ufw probes come back empty rather than false.
# Reporting that as a FAIL would be the audit lying about what it could not read.
if [ "$(id -u)" -eq 0 ]; then PRIV=1
elif [ -n "$SUDO" ] && $SUDO true 2>/dev/null; then PRIV=1
else PRIV=0; fi

FAILS=0; WARNS=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; WARNS=$((WARNS+1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS+1)); }
head2() { printf '\n\033[1m%s\033[0m\n' "$*"; }
check() { if [ "$1" = ok ]; then pass "$2"; else "$1" "$2"; fi; }

sshd_val() { $SUDO sshd -T 2>/dev/null | grep -i "^$1 " | head -1 | cut -d' ' -f2-; }

audit_host() {
  head2 "HOST — access"
  if [ "$PRIV" -eq 1 ]; then
    [ "$(sshd_val passwordauthentication)" = "no" ] \
      && pass "sshd: password auth off" || fail "sshd: password auth is ON"
    case "$(sshd_val permitrootlogin)" in
      no) pass "sshd: root login off" ;;
      *)  fail "sshd: PermitRootLogin=$(sshd_val permitrootlogin)" ;;
    esac
    [ -n "$(sshd_val allowusers)" ] \
      && pass "sshd: AllowUsers $(sshd_val allowusers)" || warn "sshd: no AllowUsers allowlist"
    for u in ops vibe; do
      if id "$u" >/dev/null 2>&1; then
        $SUDO test -s "/home/${u}/.ssh/authorized_keys" \
          && pass "user ${u}: has an ssh key" || warn "user ${u}: no authorized_keys"
      else
        fail "user ${u}: missing"
      fi
    done
  else
    warn "sshd and key state need root — re-run as: sudo $0 host"
    for u in ops vibe; do
      id "$u" >/dev/null 2>&1 || fail "user ${u}: missing"
    done
  fi
  id -nG vibe 2>/dev/null | grep -qw sudo \
    && fail "vibe is in sudo — a container escape would reach root" \
    || pass "vibe has no sudo (container escape stays unprivileged)"

  head2 "HOST — network"
  if [ "$PRIV" -eq 0 ]; then
    warn "ufw state needs root — re-run as: sudo $0 host"
  elif $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
    pass "ufw active"
    open=$($SUDO ufw status 2>/dev/null | awk '/ALLOW|LIMIT/ {print $1}' | cut -d/ -f1 | sort -un | tr '\n' ' ')
    case "$open" in
      *80*|*443*|*22*) pass "ufw open ports: ${open}" ;;
    esac
    for p in $open; do
      case "$p" in 22|80|443|Anywhere*|"") ;; *) warn "ufw allows unexpected port ${p}" ;; esac
    done
  else
    fail "ufw is not active"
  fi
  if ! systemctl is-active fail2ban >/dev/null 2>&1; then
    fail "fail2ban not running"
  elif [ "$PRIV" -eq 0 ]; then
    warn "fail2ban running — jail list needs root, re-run as: sudo $0 host"
  else
    jails=$($SUDO fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr -d ' ')
    pass "fail2ban running (jails: ${jails:-none})"
    for j in sshd caddy-auth; do
      case ",${jails}," in *",${j},"*) ;; *) fail "fail2ban: ${j} jail is not loaded" ;; esac
    done
  fi

  # Anything bound to 0.0.0.0 beyond ssh and the two web ports is an accident.
  head2 "HOST — listening sockets"
  ss -tlnH 2>/dev/null | awk '{print $4}' | while read -r a; do
    port="${a##*:}"; addr="${a%:*}"
    case "$addr" in 127.0.0.*|"[::1]"|127.0.0.53%lo) continue ;; esac
    case "$port" in 22|80|443|53) printf '  \033[32mPASS\033[0m  public %s\n' "$a" ;;
                    *) printf '  \033[31mFAIL\033[0m  unexpected public listener %s\n' "$a" ;;
    esac
  done

  head2 "HOST — capacity"
  mem=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  swap=$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)
  avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
  echo "  ram=${mem}MB  available=${avail}MB  swap=${swap}MB"
  [ "$swap" -ge 2048 ] && pass "swap >= 2G" || fail "swap is ${swap}MB — an OOM kills a neighbour instead of paging"
  [ "$avail" -ge 512 ] && pass "memory headroom ok" || fail "only ${avail}MB available"
  root_pct=$(df / --output=pcent | tail -1 | tr -dc '0-9')
  [ "${root_pct:-100}" -lt 80 ] && pass "disk ${root_pct}% used" || warn "disk ${root_pct}% used"
  jsize=$($SUDO journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[MG]' | head -1)
  [ -n "$jsize" ] && echo "  journal on disk: ${jsize}"
  grep -q SystemMaxUse /etc/systemd/journald.conf.d/99-vibe.conf 2>/dev/null \
    && pass "journald capped" || warn "journald uncapped — logs can fill the disk"
  systemctl is-enabled unattended-upgrades >/dev/null 2>&1 \
    && pass "unattended security upgrades on" || warn "no unattended-upgrades"
}

# podman-compose 1.0.6 has no --format on `ps`, so ask the engine by project label.
# Also keeps ephemeral agent sandboxes out of the stack audit.
stack_ps() {
  local proj fmt="$1"
  proj="$(basename "$(dirname "$COMPOSE_FILE")")"
  $ENGINE ps -a --filter "label=io.podman.compose.project=${proj}" --format "$fmt" 2>/dev/null \
    || true
}

audit_stack() {
  head2 "STACK — containers"
  local running
  running=$(stack_ps '{{.Names}} {{.Status}}')
  [ -z "$running" ] && running=$($ENGINE ps -a --filter "label=com.docker.compose.project=$(basename "$(dirname "$COMPOSE_FILE")")" --format '{{.Names}} {{.Status}}' 2>/dev/null)
  [ -z "$running" ] && { fail "no containers running (is the stack up?)"; return; }
  echo "$running" | while read -r name state _; do
    case "$state" in
      running|Up*) pass "${name}: ${state}" ;;
      *)           fail "${name}: ${state}" ;;
    esac
  done

  head2 "STACK — container hardening"
  for c in $(stack_ps '{{.Names}}'); do
    ro=$($ENGINE inspect "$c" --format '{{.HostConfig.ReadonlyRootfs}}' 2>/dev/null)
    nnp=$($ENGINE inspect "$c" --format '{{.HostConfig.SecurityOpt}}' 2>/dev/null)
    mem=$($ENGINE inspect "$c" --format '{{.HostConfig.Memory}}' 2>/dev/null)
    line="${c}: read_only=${ro:-?}"
    case "$nnp" in *no-new-privileges*) line="${line} no-new-priv=yes" ;;
                   *) line="${line} no-new-priv=NO" ;; esac
    if [ "${mem:-0}" -gt 0 ] 2>/dev/null; then
      line="${line} mem_limit=$((mem/1024/1024))M"; pass "$line"
    else
      line="${line} mem_limit=NONE"; fail "$line"
    fi
  done

  head2 "STACK — data tier exposure"
  for svc in postgres pgbouncer valkey; do
    if ss -tlnH 2>/dev/null | grep -qE "0\.0\.0\.0:(5432|6432|6379)"; then
      fail "${svc}-class port is bound on a public address"
    else
      pass "${svc}: not reachable from outside the compose network"
    fi
  done

  head2 "STACK — secrets at rest"
  for f in "${APP_DIR}"/deploy/env/*.env; do
    [ -e "$f" ] || continue
    perm=$(stat -c '%a' "$f" 2>/dev/null)
    case "$perm" in
      600|400) pass "$(basename "$f"): mode ${perm}" ;;
      *)       fail "$(basename "$f"): mode ${perm} — should be 600" ;;
    esac
  done
  if ! git -C "$APP_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    pass "deploy/env/*.env: no git checkout here, nothing to leak"
  elif git -C "$APP_DIR" check-ignore -q deploy/env/core.env 2>/dev/null; then
    pass "deploy/env/*.env is gitignored"
  else
    fail "deploy/env/*.env is NOT gitignored — secrets can reach the repo"
  fi

  head2 "STACK — backups"
  last=$(ls -t "${APP_DIR}"/deploy/backup/*.log 2>/dev/null | head -1)
  if [ -n "$last" ]; then
    age=$(( ($(date +%s) - $(stat -c %Y "$last")) / 3600 ))
    [ "$age" -lt 48 ] && pass "last backup ${age}h ago" || fail "last backup ${age}h ago"
  else
    warn "no backup log yet — run agent-ops backup-now once to prove the path"
  fi

  head2 "STACK — tls"
  local domain="${VIBE_DOMAIN:-}"
  [ -z "$domain" ] && domain=$(grep -m1 "^VIBE_DOMAIN=" "${APP_DIR}/deploy/env/caddy.env" 2>/dev/null | cut -d= -f2-)
  [ -z "$domain" ] && { warn "no VIBE_DOMAIN — cannot check certificates"; return; }
  for host in "$domain" "api.${domain}" "agents.${domain}" "logs.${domain}"; do
    exp=$(echo | openssl s_client -connect "${host}:443" -servername "$host" 2>/dev/null \
          | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -n "$exp" ] && pass "${host}: cert until ${exp}" || warn "${host}: no cert answer yet"
  done
}

audit_agent() {
  head2 "AGENT BOUNDARY — what a sandboxed run can reach"
  nets=$($ENGINE network ls --format '{{.Name}}' 2>/dev/null)
  echo "$nets" | grep -q sandbox-net \
    && pass "sandbox-net exists" || fail "sandbox-net missing"
  internal=$($ENGINE network inspect deploy_sandbox-net --format '{{.Internal}}' 2>/dev/null)
  [ "$internal" = "true" ] \
    && pass "sandbox-net is internal (no direct route off the box)" \
    || fail "sandbox-net is NOT internal — a sandbox can reach the internet directly"

  [ -f "${APP_DIR}/deploy/egress-proxy/filter" ] \
    && pass "egress denylist present ($(grep -cvE '^#|^$' "${APP_DIR}/deploy/egress-proxy/filter") rules)" \
    || fail "egress denylist missing"

  # The gateway is the only container holding the container socket. Anything
  # else with that mount can start a privileged container and own the host.
  head2 "AGENT BOUNDARY — container socket"
  for c in $($ENGINE ps --format '{{.Names}}' 2>/dev/null); do
    if $ENGINE inspect "$c" --format '{{range .Mounts}}{{.Source}} {{end}}' 2>/dev/null | grep -q 'podman.sock\|docker.sock'; then
      case "$c" in
        *sandbox-gateway*) pass "${c}: holds the container socket (expected)" ;;
        *)                 fail "${c}: holds the container socket and should not" ;;
      esac
    fi
  done
  if [ "$ENGINE_BIN" = podman ]; then
    pass "engine is rootless podman — a socket holder is uid $(id -u vibe 2>/dev/null || echo vibe), not root"
  else
    warn "engine is docker — the socket is host root; prefer rootless podman"
  fi

  head2 "AGENT BOUNDARY — database"
  for role in vibe_core_app vibe_agents_app; do
    su=$("${COMPOSE[@]}" exec -T postgres psql -U postgres -tAX \
         -c "SELECT rolsuper FROM pg_roles WHERE rolname='${role}'" 2>/dev/null | tr -d ' ')
    case "$su" in
      f) pass "${role}: not a superuser" ;;
      t) fail "${role}: IS a superuser" ;;
      *) warn "${role}: could not check (postgres not up?)" ;;
    esac
  done
  x=$("${COMPOSE[@]}" exec -T postgres psql -U postgres -tAX -d vibe_core \
      -c "SELECT has_database_privilege('vibe_agents_app','vibe_core','CONNECT')" 2>/dev/null | tr -d ' ')
  case "$x" in
    f) pass "agent-runtime role cannot connect to the core database" ;;
    t) fail "agent-runtime role CAN connect to the core database" ;;
    *) warn "cross-database privilege not checked" ;;
  esac
}

case "${1:-all}" in
  host)  audit_host ;;
  stack) audit_stack ;;
  agent) audit_agent ;;
  all)   audit_host; audit_stack; audit_agent ;;
  *)     echo "usage: audit.sh [host|stack|agent]" >&2; exit 2 ;;
esac

printf '\n\033[1mresult:\033[0m %d fail, %d warn\n' "$FAILS" "$WARNS"
[ "$FAILS" -eq 0 ]
