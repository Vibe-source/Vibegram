#!/bin/bash
# Decrypt *.env.cred into /run/vibe/env (tmpfs, RAM only). Root, run by vibe-env.service.
set -euo pipefail

ENV_DIR=/opt/vibe/deploy/env
RUN_DIR=/run/vibe/env
OWNER=vibe

install -d -m 0755 /run/vibe
install -d -m 0700 -o "$OWNER" -g "$OWNER" "$RUN_DIR"

shopt -s nullglob
creds=("$ENV_DIR"/*.env.cred)
[ ${#creds[@]} -gt 0 ] || { echo "unseal-env: nothing sealed at $ENV_DIR" >&2; exit 1; }

for c in "${creds[@]}"; do
  n="$(basename "$c" .cred)"
  systemd-creds decrypt --name="vibe-env-$n" "$c" "$RUN_DIR/$n"
  chown "$OWNER:$OWNER" "$RUN_DIR/$n"
  chmod 400 "$RUN_DIR/$n"
done

# cloudflared runs as root, so its credential lands beside the env dir, not inside it.
if [ -f "$ENV_DIR/tunnel.json.cred" ]; then
  systemd-creds decrypt --name=vibe-tunnel "$ENV_DIR/tunnel.json.cred" /run/vibe/tunnel.json
  chown root:root /run/vibe/tunnel.json
  chmod 400 /run/vibe/tunnel.json
fi

echo "unsealed ${#creds[@]} file(s) into $RUN_DIR"
