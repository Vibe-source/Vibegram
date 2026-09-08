#!/usr/bin/env bash
# Sign the Vibe agent team's CLIs into OUR subscriptions.
#
# The team (@boss @monitor @coder @researcher @marketing @social @media) runs the
# real Claude Code / Codex / Grok CLIs. They authenticate with a subscription, not
# an API key — this script is how that subscription gets onto a machine.
#
#   deploy/scripts/team-login.sh            # log in to whatever is not logged in
#   deploy/scripts/team-login.sh --check    # report status only, never prompt
#   deploy/scripts/team-login.sh claude     # just one CLI
#
# After logging in, deploy/scripts/team-credentials.sh copies the credentials into
# the team compute container. See docs/agent-team.md.
set -euo pipefail

CHECK_ONLY=0
WANTED=()

for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    claude|codex|grok) WANTED+=("$arg") ;;
    -h|--help) sed -n '2,12p' "$0" | cut -c3-; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[ ${#WANTED[@]} -eq 0 ] && WANTED=(claude codex grok)

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }

# Each CLI spells this differently; these are the real subcommands, checked
# against the installed binaries — do not swap them for a guess.
status_cmd() {
  case "$1" in
    claude) claude auth status ;;
    codex)  codex login status ;;
    grok)   grok --version ;;
  esac
}

login_cmd() {
  case "$1" in
    claude) claude auth login ;;
    codex)  codex login ;;
    grok)   grok login ;;
  esac
}

creds_path() {
  case "$1" in
    claude) echo "$HOME/.claude/.credentials.json" ;;
    codex)  echo "$HOME/.codex/auth.json" ;;
    grok)   echo "$HOME/.grok" ;;
  esac
}

missing=0
needs_login=0

for cli in "${WANTED[@]}"; do
  printf '\n%s\n' "── $cli ──"

  if ! command -v "$cli" >/dev/null 2>&1; then
    red "not installed"
    case "$cli" in
      claude) dim "  npm i -g @anthropic-ai/claude-code" ;;
      codex)  dim "  npm i -g @openai/codex" ;;
      grok)   dim "  see https://x.ai for the Grok CLI" ;;
    esac
    missing=$((missing + 1))
    continue
  fi

  if status_cmd "$cli" >/dev/null 2>&1; then
    green "signed in"
    dim "  credentials: $(creds_path "$cli")"
    continue
  fi

  if [ "$CHECK_ONLY" -eq 1 ]; then
    red "not signed in"
    needs_login=$((needs_login + 1))
    continue
  fi

  echo "not signed in — opening the browser flow"
  if login_cmd "$cli"; then
    green "signed in"
    dim "  credentials: $(creds_path "$cli")"
  else
    red "login failed"
    needs_login=$((needs_login + 1))
  fi
done

echo
if [ "$missing" -gt 0 ] || [ "$needs_login" -gt 0 ]; then
  red "$missing not installed · $needs_login not signed in"
  # Grok is optional; Claude and Codex are the two the team actually needs.
  exit 1
fi

green "all requested CLIs are signed in"
echo
dim "next: deploy/scripts/team-credentials.sh  (copy them into the team container)"
