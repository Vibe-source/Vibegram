#!/bin/bash
# Quick operational snapshot: service status, health endpoints, disk, last backup.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/deploy/compose.yml"

if command -v podman >/dev/null 2>&1; then
  COMPOSE=(podman compose -f "$COMPOSE_FILE")
else
  COMPOSE=(docker compose -f "$COMPOSE_FILE")
fi

echo "=== services ==="
"${COMPOSE[@]}" ps

echo
echo "=== health ==="
"${COMPOSE[@]}" exec -T core wget -qO- http://127.0.0.1:4000/api/health && echo || echo "core: unreachable"
"${COMPOSE[@]}" exec -T agent-runtime wget -qO- http://127.0.0.1:4100/healthz && echo || echo "agent-runtime: unreachable"

echo
echo "=== disk ==="
df -h "$REPO_ROOT" 2>/dev/null || true

echo
echo "=== last backup log lines ==="
"${COMPOSE[@]}" logs --tail=10 backup 2>/dev/null || true
