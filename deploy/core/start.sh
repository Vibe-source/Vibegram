#!/bin/sh
set -euo pipefail

# Migrate against MIGRATION_DATABASE_URL (direct to postgres:5432) — Ecto's
# migration lock is a session-scoped Postgres advisory lock, which pgbouncer's
# transaction pooling (DATABASE_URL) cannot hold. Falls back to DATABASE_URL
# if unset, so this still works against a non-pooled DATABASE_URL.
echo "[start.sh] Running database migrations..."
DATABASE_URL="${MIGRATION_DATABASE_URL:-$DATABASE_URL}" /app/bin/vibe eval "Vibe.Release.migrate"

# Doc renderer now runs as its own container (deploy/doc-renderer); nothing to
# start here — core reaches it at DOC_RENDERER_URL over the compose network.

if command -v yt-dlp >/dev/null 2>&1; then
  echo "[start.sh] yt-dlp: $(command -v yt-dlp) ($(yt-dlp --version 2>/dev/null || echo unknown))"
  export YTDLP_PATH="${YTDLP_PATH:-$(command -v yt-dlp)}"
elif python3 -c "import yt_dlp" >/dev/null 2>&1; then
  echo "[start.sh] yt-dlp: python3 -m yt_dlp ($(python3 -m yt_dlp --version 2>/dev/null || echo module-ok))"
else
  echo "[start.sh] WARNING: yt-dlp missing — SoundCloud/YouTube music resolve will fail"
fi

# Allowlist only: the tree also carries deploy config, and .git a credentialed remote.
seed_team_workspace() {
  ws="${VIBE_TEAM_WORKSPACE:-/home/agent/workspace}"
  src="/opt/vibe-src"
  mkdir -p "$ws" 2>/dev/null || return 0

  if [ -e "$ws/.git" ]; then
    echo "[start.sh] team workspace: $ws already holds a checkout"
    return 0
  fi

  if [ -n "${VIBE_TEAM_REPO_URL:-}" ]; then
    if git clone --depth 50 "$VIBE_TEAM_REPO_URL" "$ws" >/dev/null 2>&1; then
      git -C "$ws" remote remove origin >/dev/null 2>&1 || true
      echo "[start.sh] team workspace: cloned into $ws"
      return 0
    fi
    echo "[start.sh] team workspace: clone failed, using the deployed tree"
  fi

  if [ ! -d "$src" ]; then
    echo "[start.sh] team workspace: no source at $src, leaving $ws as is"
    return 0
  fi

  want=""
  for d in AGENTS.md CLAUDE.md README.md agent-bridge agent-runtime client contracts docs ios sandbox-gateway server; do
    if [ -e "$src/$d" ]; then want="$want $d"; fi
  done
  if [ -z "$want" ]; then return 0; fi

  ( cd "$src" && tar -cf - --exclude=.git --exclude="*/.git" \
      --exclude=node_modules --exclude="*/node_modules" \
      --exclude=_build --exclude="*/_build" --exclude=deps --exclude="*/deps" \
      --exclude=DerivedData --exclude="*/DerivedData" \
      --exclude=".env*" --exclude="*/.env*" --exclude="*.pem" --exclude="*.key" \
      $want ) | ( cd "$ws" && tar -xf - ) ||
    { echo "[start.sh] team workspace: seed incomplete"; return 0; }

  echo "[start.sh] team workspace: seeded $ws from the deployed tree"
}

seed_team_workspace || echo "[start.sh] team workspace: seed skipped"

export PHX_SERVER=true
exec /app/bin/vibe start
