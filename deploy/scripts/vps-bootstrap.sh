#!/bin/bash
# First-boot provisioning for a fresh Debian 12 / Ubuntu 24.04 VPS: container
# engine, /opt/vibe, and the systemd user unit. Host security is vps-harden.sh.
#
# Usage: sudo ./vps-bootstrap.sh [--docker] [--repo-url <git-url>]
# Default engine is rootless Podman; --docker installs Docker instead.
set -euo pipefail

ENGINE="podman"
REPO_URL=""
VIBE_HOME="/home/vibe"
APP_DIR="/opt/vibe"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    --docker) ENGINE="docker"; shift ;;
    --repo-url) REPO_URL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root (sudo ./vps-bootstrap.sh)" >&2
  exit 1
fi

log() { echo "[bootstrap] $*"; }

harden() {
  local steps="$*"
  bash "${SCRIPT_DIR}/vps-harden.sh" $steps
}

setup_app_dir() {
  # /opt is root:root by default — vibe needs it before it can clone / run compose there.
  mkdir -p "$APP_DIR"
  chown vibe:vibe "$APP_DIR"
}

setup_time_sync() {
  log "enabling systemd-timesyncd"
  timedatectl set-ntp true
}

install_podman() {
  log "installing podman + podman-compose"
  apt-get install -y -qq podman uidmap slirp4netns fuse-overlayfs passt || true
  apt-get install -y -qq podman-compose || pip3 install --break-system-packages podman-compose
  # The compose stack talks to a rootless podman socket, not the host docker one.
  su - vibe -c "systemctl --user enable --now podman.socket" || true
}

install_docker() {
  log "installing docker + compose plugin"
  apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  usermod -aG docker vibe
}

clone_repo() {
  if [ -n "$REPO_URL" ] && [ ! -d "$APP_DIR/.git" ]; then
    log "cloning ${REPO_URL} to ${APP_DIR}"
    su - vibe -c "git clone '${REPO_URL}' '${APP_DIR}'"
  fi
}

setup_linger_and_unit() {
  log "installing systemd user unit for vibe"
  mkdir -p "${VIBE_HOME}/.config/systemd/user"
  unit_src="${APP_DIR}/deploy/systemd/vibe-stack.service"
  [ "$ENGINE" = "docker" ] && unit_src="${APP_DIR}/deploy/systemd/vibe-stack-docker.service"
  if [ -f "$unit_src" ]; then
    cp "$unit_src" "${VIBE_HOME}/.config/systemd/user/vibe-stack.service"
    chown -R vibe:vibe "${VIBE_HOME}/.config"
    su - vibe -c "systemctl --user daemon-reload"
    su - vibe -c "systemctl --user enable vibe-stack.service"
    log "unit installed (not started — run deploy.sh first, then: systemctl --user start vibe-stack)"
  else
    log "WARNING: ${unit_src} not found yet — clone the repo to ${APP_DIR} first, then re-run this step"
  fi
}

main() {
  apt-get update -qq
  apt-get install -y -qq git curl ca-certificates jq

  # Accounts first: /opt/vibe is chowned to vibe, and sshd hardening refuses to
  # run until ops holds a key, so this ordering is what prevents a lockout.
  harden accounts ssh swap journald sysctl firewall fail2ban upgrades logrotate
  setup_app_dir
  setup_time_sync

  if [ "$ENGINE" = "docker" ]; then install_docker; else install_podman; fi
  [ "$ENGINE" = "podman" ] && harden podman

  clone_repo
  setup_linger_and_unit

  log "done. Next: ssh ops@host, sudo -u vibe -i, cd ${APP_DIR},"
  log "  deploy/scripts/gen-secrets.sh -> fill deploy/env/*.env -> deploy/scripts/deploy.sh"
  log "Audit the result any time with: deploy/scripts/audit.sh"
}

main
