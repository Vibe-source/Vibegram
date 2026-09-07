#!/usr/bin/env bash
# Bring the Vibe agent team up on the server, and say exactly what is missing.
#
#   deploy/scripts/team-setup.sh              # report every gap, change nothing
#   deploy/scripts/team-setup.sh verify       # agent users, tiers and badges in the live DB
#   deploy/scripts/team-setup.sh env          # set the team env, then restart core
#   deploy/scripts/team-setup.sh install      # node + claude/codex into ~/.local on the box
#   deploy/scripts/team-setup.sh login        # run the CLI browser logins ON the box
#
# Runs on the Mac and drives the box over SSH; VPS_HOST comes from the agix
# broker, never argv. Never deploys — it prints the command and stops.
# See docs/agent-team-ops.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEST="${DEST:-/opt/vibe}"
USER_="${VPS_USER:-vibe}"
KEY="${VPS_SSH_KEY_FILE:-$HOME/.ssh/vibe_vps}"
SSH_OPTS="-o IdentitiesOnly=yes -o StrictHostKeyChecking=${VPS_SSH_STRICT:-accept-new} -o ConnectTimeout=20"
[ -f "$KEY" ] && SSH_OPTS="-i $KEY $SSH_OPTS"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
warn()  { printf '\033[33m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }
head_() { printf '\n\033[1m── %s ──\033[0m\n' "$1"; }

# Every remote call goes through the broker so the host name never reaches argv.
# $1 is a shell script run as `vibe` on the box; extra ssh flags ride $SSH_EXTRA.
on_box() {
  local script="$1"
  agix secret run --net --only VPS_HOST -- sh -c \
    'ssh '"${SSH_EXTRA:-}"' '"$SSH_OPTS"' "'"${USER_}"'@$VPS_HOST" '"$(printf '%q' "$script")"
}

psql_() {
  on_box "podman exec deploy_postgres_1 psql -U postgres -d vibe_core -tAX -c $(printf '%q' "$1")"
}

require_agix() {
  command -v agix >/dev/null || { red "agix is not on PATH — it holds VPS_HOST"; exit 1; }
}

# ---------------------------------------------------------------- check

cmd_check() {
  head_ "code"
  local local_sha deployed
  local_sha="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  deployed="$(on_box 'podman images --format "{{.Tag}}" localhost/vibe-core | grep -v -e latest -e previous -e "^<none>$" | head -1' || true)"
  deployed="${deployed//$'\r'/}"
  echo "local HEAD : ${local_sha}"
  echo "deployed   : ${deployed:-unknown}"
  if [ -n "$deployed" ] && ! git -C "$REPO_ROOT" merge-base --is-ancestor HEAD "${deployed%%-*}" 2>/dev/null; then
    if [ "${deployed%%-*}" != "$local_sha" ]; then
      warn "the box is behind — the role team (@boss @monitor @coder …) only exists in newer code"
      dim "  deploy by merging to main; see docs/deploy-pipeline.md"
    fi
  fi

  head_ "team env on core"
  on_box 'for v in VIBE_LOCAL_AGENT_WORKERS VIBE_AGENT_WORKER_ALLOWED_USERS VIBE_TEAM_WORKSPACE VIBE_TEAM_EXECUTOR VIBE_CLAUDE_COMMAND VIBE_CODEX_COMMAND; do val=$(podman exec deploy_core_1 printenv $v 2>/dev/null); if [ -n "$val" ]; then echo "  $v = set"; else echo "  $v = UNSET"; fi; done'

  head_ "team compute"
  on_box 'for b in node npm claude codex grok; do printf "  %-7s " $b; command -v $b >/dev/null 2>&1 && command -v $b || echo missing-on-host; done; printf "  %-7s " core; podman exec deploy_core_1 command -v claude >/dev/null 2>&1 && echo "claude present" || echo "no CLI inside deploy_core_1"'
  dim "  core runs read_only with cap_drop ALL and no mounts — it cannot exec a CLI."
  dim "  Server-side workers need the team sidecar; see docs/agent-team-ops.md."

  head_ "credentials staged on the box"
  on_box 'for d in "$HOME/.claude" "$HOME/.codex" "$HOME/.vibe/team-credentials"; do if [ -e "$d" ]; then echo "  present $d"; else echo "  absent  $d"; fi; done'

  cmd_verify
}

# ---------------------------------------------------------------- verify

cmd_verify() {
  head_ "agent users (tier drives the gold badge)"
  psql_ 'select rpad(username,12) || coalesce(tier,chr(45)) from users where is_agent order by username'
  local n
  n="$(psql_ 'select count(*) from users where is_agent' | tr -d ' \r')"
  if [ "${n:-0}" -lt 11 ]; then
    warn "  ${n:-0} of 11 agent users exist — ensure_agent_users/0 seeds the rest at boot"
    dim "  the 7 role workers arrive with the deploy, not with a DB write"
  fi

  head_ "badges"
  # No string literals: the SQL crosses two shells, and a quote would not survive.
  psql_ 'select rpad(u.username,12) || rpad(b.badge_type,10) || b.active::text from badges b join users u on u.id = b.user_id order by u.username'

  head_ "owner accounts"
  psql_ 'select rpad(username,12) || coalesce(tier,chr(45)) from users where not coalesce(is_agent,false) order by inserted_at'
}

# ---------------------------------------------------------------- env

cmd_env() {
  head_ "resolving the allowlist"
  local owners
  owners="$(psql_ 'select string_agg(id::text, chr(44)) from users where not coalesce(is_agent,false)' | tr -d ' \r')"
  [ -n "$owners" ] || { red "no owner account found — nothing to allow"; exit 1; }
  dim "  allowlisting every non-agent account on this box"

  head_ "applying to core.env"
  # apply-env.sh merges KEY=VALUE from stdin into the sealed file; values never hit argv.
  SSH_EXTRA="" on_box "printf '%s\n' 'VIBE_LOCAL_AGENT_WORKERS=1' 'VIBE_AGENT_WORKER_ALLOWED_USERS=${owners}' 'VIBE_TEAM_WORKSPACE=${DEST}' | ${DEST}/deploy/scripts/apply-env.sh core.env"

  head_ "recreating core"
  on_box "cd ${DEST}/deploy && podman rm -f deploy_core_1 >/dev/null 2>&1; podman-compose up -d --no-build >/dev/null 2>&1; podman inspect -f '{{.State.Status}}' deploy_core_1"
  green "core restarted — env_file is only re-read on create, so the recreate is the apply"
}

# ---------------------------------------------------------------- install

cmd_install() {
  head_ "node + CLIs into ~/.local (no root; vibe has sudo for apply-env.sh only)"
  on_box '
set -eu
PREFIX="$HOME/.local"
mkdir -p "$PREFIX/bin"
if ! "$PREFIX/node/bin/node" --version >/dev/null 2>&1; then
  tarname="$(curl -fsSL https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt | awk "/linux-x64\\.tar\\.xz\$/ {print \$2; exit}")"
  [ -n "$tarname" ] || { echo "could not resolve a node tarball" >&2; exit 1; }
  cd /tmp
  curl -fsSLO "https://nodejs.org/dist/latest-v22.x/$tarname"
  curl -fsSL "https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt" | sha256sum -c --ignore-missing -
  rm -rf "$PREFIX/node"; mkdir -p "$PREFIX/node"
  tar -xJf "$tarname" -C "$PREFIX/node" --strip-components=1
  rm -f "$tarname"
fi
export PATH="$PREFIX/node/bin:$PREFIX/bin:$PATH"
npm config set prefix "$PREFIX" >/dev/null
npm i -g @anthropic-ai/claude-code @openai/codex >/dev/null 2>&1 || npm i -g @anthropic-ai/claude-code @openai/codex
grep -qs "/.local/node/bin" "$HOME/.profile" || printf "export PATH=\"\$HOME/.local/node/bin:\$HOME/.local/bin:\$PATH\"\n" >> "$HOME/.profile"
echo "node   $("$PREFIX/node/bin/node" --version)"
for b in claude codex; do printf "%-7s " "$b"; "$PREFIX/bin/$b" --version 2>/dev/null || echo "installed, version unavailable"; done
'
  green "installed on the host"
  dim "next: deploy/scripts/team-setup.sh login"
}

# ---------------------------------------------------------------- login

cmd_login() {
  head_ "signing the CLIs in ON the box"
  dim "each CLI prints a URL — open it in your own browser and paste the code back here."
  dim "credentials land in the box's ~/.claude and ~/.codex, which is where the team reads them."
  SSH_EXTRA="-tt" on_box '
export PATH="$HOME/.local/node/bin:$HOME/.local/bin:$PATH"
for cli in claude codex; do
  command -v "$cli" >/dev/null 2>&1 || { echo "$cli is not installed — run team-setup.sh install"; continue; }
  case "$cli" in
    claude) status="claude auth status"; login="claude auth login" ;;
    codex)  status="codex login status"; login="codex login" ;;
  esac
  printf "\n── %s ──\n" "$cli"
  if $status >/dev/null 2>&1; then echo "already signed in"; else $login; fi
done'
}

case "${1:-check}" in
  check)   require_agix; cmd_check ;;
  verify)  require_agix; cmd_verify ;;
  env)     require_agix; cmd_env ;;
  install) require_agix; cmd_install ;;
  login)   require_agix; cmd_login ;;
  -h|--help) sed -n '2,12p' "$0" | cut -c3- ;;
  *) red "unknown command: $1 (try: check, verify, env, install, login)"; exit 2 ;;
esac
