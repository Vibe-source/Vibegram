#!/bin/bash
# Is this a Cloudflare account id with R2 provisioned? Cloudflare issues a
# per-account cert, so an unknown id is refused at the TLS handshake.
# Reads the id from a prompt: it never reaches argv or shell history.
read -r -p "R2 account id: " id
[ -n "$id" ] || { echo "nothing entered"; exit 1; }
h="$id.r2.cloudflarestorage.com"
if echo | openssl s_client -connect "$h:443" -servername "$h" 2>&1 | grep -q "Verify return code: 0"; then
  echo "VALID — Cloudflare serves this account. Store it with:"
  echo "  deploy/scripts/set-missing-env.sh R2_ACCOUNT_ID --restart"
else
  echo "REFUSED — wrong id, or R2 is not enabled on that account."
fi
