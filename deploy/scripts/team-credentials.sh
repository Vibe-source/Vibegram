#!/usr/bin/env bash
# Stage the signed-in CLI credentials where the team's compute can mount them.
#
# deploy/scripts/team-login.sh puts our subscriptions on this machine. This copies
# the resulting credential files into one directory, 0700, so the team container
# gets exactly those and nothing else from $HOME.
#
#   deploy/scripts/team-credentials.sh           # stage all signed-in CLIs
#   deploy/scripts/team-credentials.sh --check   # report what would be staged
#
# Never inside the repo: the default lives under $HOME. See docs/agent-team.md.
set -euo pipefail

DEST="${VIBE_TEAM_CREDENTIALS_DIR:-$HOME/.vibe/team-credentials}"
CHECK_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    --dest) shift; DEST="${1:?--dest needs a path}" ;;
    -h|--help) sed -n '2,11p' "$0" | cut -c3-; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

case "$DEST" in
  "$PWD"/*|./*) echo "refusing to stage credentials inside the repo: $DEST" >&2; exit 2 ;;
esac

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }

# source:relative-destination. Paths match team-login.sh's creds_path().
SOURCES=(
  "$HOME/.claude/.credentials.json:claude/.credentials.json"
  "$HOME/.codex/auth.json:codex/auth.json"
  "$HOME/.grok:grok"
)

staged=0
absent=0

[ "$CHECK_ONLY" -eq 0 ] && { mkdir -p "$DEST"; chmod 700 "$DEST"; }

for entry in "${SOURCES[@]}"; do
  src="${entry%%:*}"
  rel="${entry#*:}"

  if [ ! -e "$src" ]; then
    red "absent  $rel"
    # Claude Code keeps credentials in the Keychain on macOS; the file form is Linux-only.
    [ "$rel" = "claude/.credentials.json" ] && [ "$(uname)" = "Darwin" ] &&
      dim "  expected on macOS — sign in inside the Linux container instead"
    absent=$((absent + 1))
    continue
  fi

  if [ "$CHECK_ONLY" -eq 1 ]; then
    green "would stage  $rel"
    staged=$((staged + 1))
    continue
  fi

  mkdir -p "$DEST/$(dirname "$rel")"
  cp -R "$src" "$DEST/$rel"
  chmod -R go-rwx "$DEST/$rel"
  green "staged  $rel"
  staged=$((staged + 1))
done

echo
if [ "$staged" -eq 0 ]; then
  red "nothing staged — run deploy/scripts/team-login.sh first"
  exit 1
fi

dim "destination: $DEST  ($staged staged, $absent absent)"
echo
dim "mount it read-only at the CLI home the team container runs as, e.g."
dim "  -v $DEST/claude:/home/vibe/.claude:ro"
dim "  -v $DEST/codex:/home/vibe/.codex:ro"
