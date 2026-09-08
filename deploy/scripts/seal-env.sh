#!/bin/bash
# Seal deploy/env/*.env into *.env.cred. Root, on the VPS. Values are never printed.
# Verifies every pair with cmp and keeps a sealed rollback before deleting plaintext.
set -euo pipefail

ENV_DIR=/opt/vibe/deploy/env
ROLLBACK=/root/vibe-env-preseal.tar.cred

[ "$(id -u)" -eq 0 ] || { echo "seal-env: run as root" >&2; exit 1; }
command -v systemd-creds >/dev/null || { echo "seal-env: systemd-creds missing" >&2; exit 1; }

shopt -s nullglob
plain=("$ENV_DIR"/*.env)
[ ${#plain[@]} -gt 0 ] || { echo "seal-env: no plaintext left, already sealed"; exit 0; }

tmp="$(mktemp -d /dev/shm/seal.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

for f in "${plain[@]}"; do
  n="$(basename "$f")"
  systemd-creds encrypt --with-key=host --name="vibe-env-$n" "$f" "$ENV_DIR/$n.cred"
  chmod 600 "$ENV_DIR/$n.cred"
  systemd-creds decrypt --name="vibe-env-$n" "$ENV_DIR/$n.cred" "$tmp/$n"
  cmp -s "$f" "$tmp/$n" || { echo "seal-env: MISMATCH on $n, nothing deleted" >&2; exit 1; }
  echo "sealed   $n"
done

tar -cf "$tmp/preseal.tar" -C "$ENV_DIR" "${plain[@]##*/}"
systemd-creds encrypt --with-key=host --name=vibe-env-preseal "$tmp/preseal.tar" "$ROLLBACK"
chmod 600 "$ROLLBACK"

shred -u "${plain[@]}"
echo "plaintext removed; sealed rollback at $ROLLBACK"
