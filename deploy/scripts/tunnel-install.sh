#!/bin/bash
# Put the VPS behind an outbound Cloudflare tunnel: no inbound port, no A record,
# nothing to port-scan. Credentials arrive on stdin, never argv, never the disk.
#
#   cat ~/.cloudflared/<UUID>.json | ssh vibe-vps 'sudo /opt/vibe/deploy/scripts/tunnel-install.sh'
#
# Options: --domain <zone>, --origin <host:port>, --no-firewall, --firewall-only
set -euo pipefail

DOMAIN=vibegram.io
ORIGIN=127.0.0.1:8080
NO_FIREWALL=""
FIREWALL_ONLY=""
RECONFIGURE=""
REPO=/opt/vibe
ENV_DIR=$REPO/deploy/env
CRED=$ENV_DIR/tunnel.json.cred

while [ $# -gt 0 ]; do
  case "$1" in
    --domain)      DOMAIN="${2:?--domain needs a zone}"; shift 2 ;;
    --origin)      ORIGIN="${2:?--origin needs host:port}"; shift 2 ;;
    --no-firewall) NO_FIREWALL=1; shift ;;
    --firewall-only) FIREWALL_ONLY=1; shift ;;
    --reconfigure) RECONFIGURE=1; shift ;;
    -h|--help)     sed -n '2,8p' "$0"; exit 0 ;;
    *)             echo "tunnel-install: unknown option: $1" >&2; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "tunnel-install: run with sudo" >&2; exit 1; }

lock_firewall() {
  echo "==> firewall"
  ufw --force default deny incoming >/dev/null
  # Outbound is denied too: a box that can dial anywhere can be made to dial anywhere.
  ufw --force default deny outgoing >/dev/null
  ufw allow out 53 >/dev/null
  ufw allow out 80/tcp >/dev/null
  ufw allow out 443/tcp >/dev/null
  ufw allow out 7844 >/dev/null
  ufw allow out 587/tcp >/dev/null
  ufw allow out 465/tcp >/dev/null
  ufw allow out on lo >/dev/null
  ufw allow in on lo >/dev/null
  ufw limit OpenSSH >/dev/null 2>&1 || ufw limit 22/tcp >/dev/null
  ufw delete allow 80/tcp >/dev/null 2>&1 || true
  ufw delete allow 443/tcp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null
  echo "    inbound: SSH only (rate limited). outbound: DNS, 80, 443, 7844, 587, 465."
}

render_config() {
  echo "==> config"
  install -d -m 0755 /etc/cloudflared
  sed -e "s|TUNNEL_ID|${TUNNEL_ID}|" -e "s|DOMAIN|${DOMAIN}|g" -e "s|ORIGIN|${ORIGIN}|g" \
    "$REPO/deploy/cloudflared/config.yml" > /etc/cloudflared/config.yml.new
  cloudflared --config /etc/cloudflared/config.yml.new tunnel ingress validate
  chmod 0644 /etc/cloudflared/config.yml.new
  mv /etc/cloudflared/config.yml.new /etc/cloudflared/config.yml
}

if [ -n "$RECONFIGURE" ]; then
  TUNNEL_ID="$(awk "/^tunnel:/ {print \$2}" /etc/cloudflared/config.yml 2>/dev/null)"
  [ -n "$TUNNEL_ID" ] || { echo "tunnel-install: no installed tunnel to reconfigure" >&2; exit 1; }
  render_config
  systemctl restart cloudflared
  sleep 3
  systemctl is-active --quiet cloudflared && echo "cloudflared: reloaded" || {
    echo " !  cloudflared did not come back — journalctl -u cloudflared -n 40" >&2; exit 1; }
  exit 0
fi

if [ -n "$FIREWALL_ONLY" ]; then
  command -v ufw >/dev/null || { echo "tunnel-install: ufw is not installed" >&2; exit 1; }
  lock_firewall
  exit 0
fi

[ -t 0 ] && { echo "tunnel-install: pipe the tunnel credentials JSON on stdin" >&2; exit 1; }

tmp="$(mktemp -d /dev/shm/tun.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/tunnel.json"

TUNNEL_ID="$(grep -oE '"TunnelID"[[:space:]]*:[[:space:]]*"[0-9a-fA-F-]{36}"' "$tmp/tunnel.json" \
  | grep -oE '[0-9a-fA-F-]{36}' | head -1 || true)"
[ -n "$TUNNEL_ID" ] || { echo "tunnel-install: stdin is not a cloudflared credentials file" >&2; exit 1; }

echo "==> origin check"
curl -fsS -o /dev/null -H 'Host: localhost' "http://${ORIGIN}/" 2>/dev/null \
  || echo " !  ${ORIGIN} did not answer — start the stack first, or pass --origin"

echo "==> seal credentials"
systemd-creds encrypt --with-key=host --name=vibe-tunnel "$tmp/tunnel.json" "${CRED}.new"
systemd-creds decrypt --name=vibe-tunnel "${CRED}.new" "$tmp/verify.json"
cmp -s "$tmp/tunnel.json" "$tmp/verify.json" \
  || { rm -f "${CRED}.new"; echo "tunnel-install: seal verify failed, nothing installed" >&2; exit 1; }
chmod 600 "${CRED}.new"; mv "${CRED}.new" "$CRED"
install -m 400 -o root -g root "$tmp/tunnel.json" /run/vibe/tunnel.json

echo "==> cloudflared"
if ! command -v cloudflared >/dev/null; then
  case "$(uname -m)" in
    x86_64|amd64)  CF_ARCH=amd64 ;;
    aarch64|arm64) CF_ARCH=arm64 ;;
    *) echo "tunnel-install: no cloudflared build for $(uname -m)" >&2; exit 1 ;;
  esac
  curl -fsSL -o /usr/local/bin/cloudflared \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
  chmod 0755 /usr/local/bin/cloudflared
fi

render_config
install -m 0644 "$REPO/deploy/systemd/cloudflared.service" /etc/systemd/system/cloudflared.service
systemctl daemon-reload
echo "==> service"
install -m 0644 "$REPO/deploy/systemd/cloudflared.service" /etc/systemd/system/cloudflared.service
systemctl daemon-reload
systemctl enable --now cloudflared >/dev/null 2>&1 || true
systemctl restart cloudflared

if [ -z "$NO_FIREWALL" ] && command -v ufw >/dev/null; then
  lock_firewall
fi

sleep 3
systemctl is-active --quiet cloudflared && echo "cloudflared: active" || {
  echo " !  cloudflared is not active — journalctl -u cloudflared -n 40" >&2; exit 1; }

echo
echo "Tunnel up. Routes were written by 'cloudflared tunnel route dns' from your Mac;"
echo "there are no A records and the origin address is not in DNS."
