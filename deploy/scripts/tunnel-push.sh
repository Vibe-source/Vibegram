#!/bin/bash
# Mac side: resolve the tunnel's credentials by name and pipe them to the VPS installer.
# Exists so the install is one short command instead of a line a terminal will truncate.
#
#   ./deploy/scripts/tunnel-push.sh --no-firewall
#
# Env: TUNNEL_NAME (vibe-prod), SSH_HOST (vibe-vps), TUNNEL_ORIGIN_CERT
set -euo pipefail

NAME="${TUNNEL_NAME:-vibe-prod}"
SSH_HOST="${SSH_HOST:-vibe-vps}"
CF_DIR="$HOME/.cloudflared"

if [ -z "${TUNNEL_ORIGIN_CERT:-}" ] && [ -f "$CF_DIR/cert-vibegram.pem" ]; then
  export TUNNEL_ORIGIN_CERT="$CF_DIR/cert-vibegram.pem"
fi

command -v cloudflared >/dev/null || { echo "tunnel-push: cloudflared not installed" >&2; exit 1; }

id="$(cloudflared tunnel list 2>/dev/null | awk -v n="$NAME" '$2 == n {print $1; exit}')"
[ -n "$id" ] || { echo "tunnel-push: no tunnel named '$NAME' — cloudflared tunnel list" >&2; exit 1; }

creds="$CF_DIR/$id.json"
[ -f "$creds" ] || { echo "tunnel-push: no credentials at $creds" >&2; exit 1; }

echo "==> $NAME ($id) -> $SSH_HOST"
cat "$creds" | ssh "$SSH_HOST" "sudo /opt/vibe/deploy/scripts/tunnel-install.sh $*"
