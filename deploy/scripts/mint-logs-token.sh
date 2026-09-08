#!/bin/bash
# Mints a read-only Grafana service-account token for vibe-logs.sh. Runs ON the
# VPS. Prints the token once — Grafana never shows it again; store it with
# `agix secret set VIBE_LOGS_TOKEN`.
#
# Usage: deploy/scripts/mint-logs-token.sh [account-name]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAME="${1:-vibe-logs}"
GF="http://127.0.0.1:3000"

# The deployed env file is the runtime copy; the repo one only exists pre-deploy.
ENV_FILE=/run/vibe/env/monitoring.env
[ -r "$ENV_FILE" ] || ENV_FILE="${REPO_ROOT}/deploy/env/monitoring.env"
pw=""
while IFS='=' read -r k v; do [ "$k" = GF_SECURITY_ADMIN_PASSWORD ] && pw="$v"; done <"$ENV_FILE"
[ -n "$pw" ] || { echo "mint-logs-token: GF_SECURITY_ADMIN_PASSWORD empty" >&2; exit 1; }
auth="admin:${pw}"

id=$(curl -sS -u "$auth" -H 'Content-Type: application/json' \
      -d "{\"name\":\"${NAME}\",\"role\":\"Viewer\",\"isDisabled\":false}" \
      "${GF}/api/serviceaccounts" | jq -r '.id // empty')

if [ -z "$id" ]; then
  id=$(curl -sS -u "$auth" --get --data-urlencode "query=${NAME}" \
        "${GF}/api/serviceaccounts/search" | jq -r ".serviceAccounts[]? | select(.name==\"${NAME}\") | .id")
fi
[ -n "$id" ] || { echo "mint-logs-token: could not create or find service account" >&2; exit 1; }

token=$(curl -sS -u "$auth" -H 'Content-Type: application/json' \
         -d "{\"name\":\"${NAME}-$(date +%s)\"}" \
         "${GF}/api/serviceaccounts/${id}/tokens" | jq -r '.key // empty')
[ -n "$token" ] || { echo "mint-logs-token: token creation failed" >&2; exit 1; }

echo "$token"
