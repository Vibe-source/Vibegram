#!/bin/bash
# Host hardening for the Vibe VPS: accounts, sshd, firewall, fail2ban, swap,
# journald caps, sysctl, rootless-podman ranges. Idempotent — safe to re-run.
#
# Usage: sudo ./vps-harden.sh              # everything
#        sudo ./vps-harden.sh ssh swap     # only these steps
# Called by vps-bootstrap.sh; also the thing to re-run after a kernel/OS upgrade.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
log() { echo "[harden] $*"; }

# --- accounts -------------------------------------------------------------
# ops: sudo, the human/agent login. vibe: runs the stack, no sudo, so a
# container escape lands on an account that cannot escalate.
step_accounts() {
  if ! id vibe >/dev/null 2>&1; then
    log "creating stack user 'vibe' (no sudo, on purpose)"
    adduser --disabled-password --gecos "" vibe
  fi
  if ! id ops >/dev/null 2>&1; then
    log "creating admin user 'ops' (sudo)"
    adduser --disabled-password --gecos "" ops
    usermod -aG sudo ops
  fi

  # Root is usually the only account holding a key on a fresh box. The key must
  # reach ops+vibe BEFORE sshd hardening, or PermitRootLogin=no locks us out.
  for u in ops vibe; do
    home=$(getent passwd "$u" | cut -d: -f6)
    install -d -m 700 -o "$u" -g "$u" "${home}/.ssh"
    if [ -s /root/.ssh/authorized_keys ]; then
      touch "${home}/.ssh/authorized_keys"
      cat /root/.ssh/authorized_keys "${home}/.ssh/authorized_keys" \
        | sort -u >"${home}/.ssh/authorized_keys.new"
      mv "${home}/.ssh/authorized_keys.new" "${home}/.ssh/authorized_keys"
    fi
    chown "$u:$u" "${home}/.ssh/authorized_keys"
    chmod 600 "${home}/.ssh/authorized_keys"
  done

  # NOPASSWD: ops has no password, and an agent over SSH has no TTY to type one at.
  printf 'ops ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/90-ops
  chmod 440 /etc/sudoers.d/90-ops
  visudo -c >/dev/null
  log "accounts ok (ops=sudo, vibe=stack)"
}

# --- sshd -----------------------------------------------------------------
# sshd_config Includes sshd_config.d/*.conf at the TOP and keeps the FIRST value
# it reads, so a 99-* drop-in silently loses to 50-cloud-init.conf. Sort ahead.
step_ssh() {
  if [ ! -s /home/ops/.ssh/authorized_keys ]; then
    echo "[harden] refusing to disable root login: ops has no authorized_keys" >&2
    exit 1
  fi
  mkdir -p /etc/ssh/sshd_config.d
  install -m 644 /dev/null /etc/ssh/sshd_config.d/00-vibe-hardening.conf
  {
    printf 'PasswordAuthentication no\n'
    printf 'KbdInteractiveAuthentication no\n'
    printf 'PermitRootLogin no\n'
    printf 'PermitEmptyPasswords no\n'
    printf 'MaxAuthTries 3\n'
    printf 'MaxSessions 10\n'
    printf 'LoginGraceTime 20\n'
    printf 'AllowUsers ops vibe\n'
    printf 'X11Forwarding no\n'
    printf 'AllowAgentForwarding no\n'
    printf 'AllowTcpForwarding yes\n'
    printf 'ClientAliveInterval 300\n'
    printf 'ClientAliveCountMax 2\n'
  } >/etc/ssh/sshd_config.d/00-vibe-hardening.conf
  sshd -t
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  log "sshd hardened (key-only, no root, AllowUsers ops vibe)"
}

# --- firewall -------------------------------------------------------------
# Only 22/80/443 inbound. Rootless podman publishes through the host netns, so
# ufw governs it — unlike docker, which writes its own chains past ufw.
step_firewall() {
  apt-get install -y -qq ufw
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw default deny routed
  ufw limit 22/tcp comment 'ssh (rate-limited)'
  ufw allow 80/tcp comment 'caddy acme + redirect'
  ufw allow 443/tcp comment 'caddy tls'
  ufw --force enable
  log "ufw active: 22 (limited), 80, 443 in; everything else denied"
}

step_fail2ban() {
  apt-get install -y -qq fail2ban
  mkdir -p /etc/fail2ban/filter.d /etc/fail2ban/jail.d
  {
    printf '# Caddy JSON access log: repeated 401/429 from one IP is abuse, not a client.\n'
    printf '[Definition]\n'
    printf 'failregex = "remote_ip":"<HOST>".*"status":(401|429)\n'
    printf 'journalmatch =\n'
  } >/etc/fail2ban/filter.d/caddy-auth.conf
  {
    printf '[sshd]\nenabled = true\nmaxretry = 4\nbantime = 3600\nfindtime = 600\n\n'
    printf '[caddy-auth]\nenabled = true\nfilter = caddy-auth\n'
    printf 'logpath = /opt/vibe/deploy/caddy-logs/access.log\n'
    printf 'maxretry = 20\nfindtime = 60\nbantime = 3600\n'
  } >/etc/fail2ban/jail.d/vibe.local
  # "enable --now" no-ops on the service apt just started, so the jails above
  # never loaded; and a missing logpath makes fail2ban drop the jail at start.
  mkdir -p /opt/vibe/deploy/caddy-logs
  [ -e /opt/vibe/deploy/caddy-logs/access.log ] || : >/opt/vibe/deploy/caddy-logs/access.log
  id vibe >/dev/null 2>&1 && chown -R vibe:vibe /opt/vibe/deploy/caddy-logs
  systemctl enable fail2ban
  systemctl restart fail2ban
  log "fail2ban enabled (sshd + caddy-auth jails)"
}

# --- capacity -------------------------------------------------------------
# 7.7 GB with no swap: a doc-renderer or sandbox spike OOM-kills a neighbour
# instead of paging. Low swappiness keeps it a safety net, not a slow path.
step_swap() {
  if swapon --show 2>/dev/null | grep -q .; then
    log "swap already present"
  else
    fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
    log "4G swapfile active"
  fi
}

# Podman logs to journald by default, so an uncapped journal is how this disk fills.
step_journald() {
  mkdir -p /etc/systemd/journald.conf.d
  {
    printf '[Journal]\n'
    printf 'SystemMaxUse=1G\n'
    printf 'SystemMaxFileSize=100M\n'
    printf 'MaxRetentionSec=2week\n'
  } >/etc/systemd/journald.conf.d/99-vibe.conf
  systemctl restart systemd-journald
  log "journald capped at 1G / 2 weeks"
}

step_sysctl() {
  {
    printf 'net.ipv4.ip_unprivileged_port_start=80\n'
    printf 'net.core.somaxconn=4096\n'
    printf 'net.ipv4.tcp_max_syn_backlog=8192\n'
    printf 'net.ipv4.tcp_syncookies=1\n'
    printf 'net.ipv4.conf.all.rp_filter=1\n'
    printf 'net.ipv4.conf.all.accept_redirects=0\n'
    printf 'net.ipv4.conf.all.send_redirects=0\n'
    printf 'net.ipv4.conf.all.accept_source_route=0\n'
    printf 'net.ipv6.conf.all.accept_redirects=0\n'
    printf 'kernel.kptr_restrict=2\n'
    printf 'kernel.dmesg_restrict=1\n'
    printf 'fs.file-max=200000\n'
    printf 'fs.inotify.max_user_instances=1024\n'
    printf 'vm.swappiness=10\n'
    printf 'vm.overcommit_memory=1\n'
    # cloudflared's QUIC tunnel asks for a 7.5MB UDP buffer; the 208KB default
    # starves it and the edge connection dies with "no recent network activity".
    printf 'net.core.rmem_max=7500000\n'
    printf 'net.core.wmem_max=7500000\n'
  } >/etc/sysctl.d/99-vibe.conf
  sysctl --system >/dev/null
  log "sysctl applied (net hardening + swappiness 10 + QUIC buffers)"
}

# Rootless podman needs a subordinate uid/gid range for vibe and an unprivileged
# ping range; without them `podman compose up` fails before it pulls anything.
step_podman() {
  grep -q '^vibe:' /etc/subuid || usermod --add-subuids 200000-265535 vibe
  grep -q '^vibe:' /etc/subgid || usermod --add-subgids 200000-265535 vibe
  {
    printf 'net.ipv4.ping_group_range=0 2147483647\n'
    printf 'user.max_user_namespaces=28633\n'
  } >/etc/sysctl.d/98-vibe-rootless.conf
  sysctl --system >/dev/null
  # Podman has no implicit docker.io, so every short image name fails to resolve.
  mkdir -p /etc/containers
  printf 'unqualified-search-registries = ["docker.io"]\n' >/etc/containers/registries.conf.d/00-vibe.conf 2>/dev/null \
    || { mkdir -p /etc/containers/registries.conf.d; printf 'unqualified-search-registries = ["docker.io"]\n' >/etc/containers/registries.conf.d/00-vibe.conf; }

  # One log driver for every container, so promtail has a single source to read.
  mkdir -p /etc/containers/containers.conf.d
  {
    printf '[containers]\n'
    printf 'log_driver = "journald"\n'
  } >/etc/containers/containers.conf.d/00-vibe-logging.conf

  # Ubuntu ships podman-compose 1.0.6, which cannot resolve `dockerfile:` against
  # a parent `context:` — deploy.sh builds explicitly, but `up` needs a newer one.
  pip3 install --quiet --break-system-packages --upgrade podman-compose 2>/dev/null || true

  # Rootless containers die with the login session unless lingering is on.
  loginctl enable-linger vibe
  # Per-user FD/proc ceilings; the compose ulimits cannot exceed these.
  {
    printf 'vibe soft nofile 65536\n'
    printf 'vibe hard nofile 65536\n'
    printf 'vibe soft nproc  8192\n'
    printf 'vibe hard nproc  8192\n'
  } >/etc/security/limits.d/90-vibe.conf
  log "rootless podman ranges + limits set for vibe"
}

step_upgrades() {
  apt-get install -y -qq unattended-upgrades apt-listchanges
  dpkg-reconfigure -f noninteractive unattended-upgrades
  log "unattended security upgrades on"
}

step_logrotate() {
  {
    printf '/opt/vibe/deploy/caddy-logs/*.log {\n'
    printf '  weekly\n  rotate 8\n  compress\n  missingok\n  notifempty\n  copytruncate\n'
    printf '}\n'
  } >/etc/logrotate.d/vibe
  log "logrotate policy installed"
}

ALL_STEPS="accounts ssh firewall fail2ban swap journald sysctl podman upgrades logrotate"

main() {
  local steps="${*:-$ALL_STEPS}"
  apt-get update -qq
  for s in $steps; do
    if ! type "step_${s}" >/dev/null 2>&1; then
      echo "[harden] unknown step: ${s} (have: ${ALL_STEPS})" >&2
      exit 1
    fi
    "step_${s}"
  done
  log "done"
}

main "$@"
