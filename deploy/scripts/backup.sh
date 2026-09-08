#!/bin/bash
# On-demand backup run — the backup container also does this every 6h on its
# own (deploy/backup/crontab); use this to force one now, e.g. before a migration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/deploy/compose.yml"

if command -v podman >/dev/null 2>&1; then
  COMPOSE=(podman compose -f "$COMPOSE_FILE")
else
  COMPOSE=(docker compose -f "$COMPOSE_FILE")
fi

echo "[backup] triggering an on-demand run"
"${COMPOSE[@]}" exec -T backup /app/backup.sh
