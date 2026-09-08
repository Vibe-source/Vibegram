#!/bin/bash
# Ship the source the VPS actually builds from. The box holds no git credential,
# so this rsync (and the identical step in .github/workflows/deploy-vps.yml) is
# the only delivery path. core/ and ios/ are iOS-only and never leave this Mac.
#
# Excludes are anchored (/core, /ios): unanchored, they also drop deploy/core/.
# Usage: VPS_HOST=... [VPS_USER=vibe] [DEST=/opt/vibe] deploy/scripts/push-tree.sh
# In practice: agix secret run --only VPS_HOST -- deploy/scripts/push-tree.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST="${VPS_HOST:?VPS_HOST not set}"
USER_="${VPS_USER:-vibe}"
DEST="${DEST:-/opt/vibe}"
KEY="${VPS_SSH_KEY_FILE:-$HOME/.ssh/vibe_vps}"

# CI pins the host key and sets VPS_SSH_STRICT=yes; accept-new would weaken that pin.
SSH_OPTS="-o IdentitiesOnly=yes -o StrictHostKeyChecking=${VPS_SSH_STRICT:-accept-new}"
[ -f "$KEY" ] && SSH_OPTS="-i $KEY $SSH_OPTS"

cd "$REPO_ROOT"

# --delete keeps the box a mirror, but env/ and caddy-logs live only there.
rsync -az --delete \
  -e "ssh $SSH_OPTS" \
  --exclude '.git' \
  --exclude '.agix' \
  --exclude '/ios' \
  --exclude '/core' \
  --exclude 'target' \
  --exclude '_build' \
  --exclude 'deps' \
  --exclude 'node_modules' \
  --exclude 'client/dist' \
  --exclude '.DS_Store' \
  --exclude '.env' \
  --exclude '.env.*' \
  --exclude 'deploy/env/*.env' \
  --exclude 'deploy/env/*.cred' \
  --exclude 'deploy/caddy-logs' \
  --exclude 'deploy/agent-ops-logs' \
  ./ "${USER_}@${HOST}:${DEST}/"

# The box has no .git, so without this every build tags itself with a timestamp
# and a rollback tag points at no commit. -dirty means uncommitted source shipped.
sha="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git diff --quiet 2>/dev/null || sha="${sha}-dirty"
ssh $SSH_OPTS "${USER_}@${HOST}" "printf %s\\\\n ${sha} > ${DEST}/.vibe-sha"

echo "[push-tree] synced ${sha} to ${USER_}@<vps>:${DEST}"
