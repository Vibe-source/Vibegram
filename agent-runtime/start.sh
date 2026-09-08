#!/bin/sh
set -euo pipefail

echo "[start.sh] Running migrations..."
/app/bin/vibe_agents eval "VibeAgents.Release.migrate()"

export PHX_SERVER=true
echo "[start.sh] Starting vibe_agents..."
exec /app/bin/vibe_agents start
