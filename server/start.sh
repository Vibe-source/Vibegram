#!/bin/sh
set -euo pipefail

# Start Python doc renderer in background on port 5050
python3 /app/python/doc_renderer.py 5050 &
DOC_RENDERER_PID=$!
echo "[start.sh] Doc renderer started (PID $DOC_RENDERER_PID)"

# Music tools (SoundCloud/YouTube): log yt-dlp availability for Railway diagnostics
if command -v yt-dlp >/dev/null 2>&1; then
  echo "[start.sh] yt-dlp: $(command -v yt-dlp) ($(yt-dlp --version 2>/dev/null || echo unknown))"
  export YTDLP_PATH="${YTDLP_PATH:-$(command -v yt-dlp)}"
elif python3 -c "import yt_dlp" >/dev/null 2>&1; then
  echo "[start.sh] yt-dlp: python3 -m yt_dlp ($(python3 -m yt_dlp --version 2>/dev/null || echo module-ok))"
else
  echo "[start.sh] WARNING: yt-dlp missing — SoundCloud/YouTube music resolve will fail"
fi

# Enable Phoenix server
export PHX_SERVER=true

# Run database migrations before serving (idempotent; already-applied
# migrations are skipped). Aborting here on failure is safer than booting the
# app against a schema that is missing newly-added columns.
echo "[start.sh] Running migrations..."
/app/bin/vibe eval "Vibe.Release.migrate()"
echo "[start.sh] Migrations complete"

# Start Elixir release (foreground)
exec /app/bin/vibe start
