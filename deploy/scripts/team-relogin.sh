#!/usr/bin/env bash
# Point the box's Claude CLI at the right account.
#
#   deploy/scripts/team-relogin.sh status   # which credential wins, and what the CLI says
#   deploy/scripts/team-relogin.sh token    # install a subscription token read on stdin
#   deploy/scripts/team-relogin.sh login    # interactive OAuth inside the core container
#
# `token` is the one that survives a redeploy. On a Mac already signed in to the
# right account:
#
#   claude setup-token | deploy/scripts/team-relogin.sh token
#
# ANTHROPIC_API_KEY is blanked at the same time: while it is set the CLI bills the
# API account (that is the "credit balance is too low" reply) and ignores the plan.
set -euo pipefail

SSH_HOST="${VPS_SSH_HOST:-vibe-vps}"
SSH_USER="${VPS_SSH_USER:-vibe}"
CORE="${CORE_CONTAINER:-deploy_core_1}"
SSH_OPTS="-l ${SSH_USER} -o ConnectTimeout=25"
[ -n "${VPS_SSH_KEY_FILE:-}" ] && SSH_OPTS="-i ${VPS_SSH_KEY_FILE} -o IdentitiesOnly=yes $SSH_OPTS"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }
die()   { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

on_box() { ssh $SSH_OPTS "$SSH_HOST" "$1"; }

recreate_core() {
  dim "recreating core (compose only re-reads env_file on create)"
  on_box "podman rm -f ${CORE} >/dev/null 2>&1 || true; cd /opt/vibe/deploy && podman-compose up -d --no-build --no-recreate core >/dev/null 2>&1; sleep 5; podman ps --filter name=${CORE} --format '{{.Names}} {{.Status}}'"
}

cmd_status() {
  on_box "podman exec ${CORE} sh -c '
    for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN; do
      val=\$(printenv \$v); [ -n \"\$val\" ] && echo \"\$v set (\${#val} chars)\" || echo \"\$v unset\"
    done
    echo \"cli      : \$(claude --version 2>&1 | head -1)\"
    echo \"home     : \$HOME\"
    [ -f \$HOME/.claude/.credentials.json ] && echo \"oauth    : signed in on disk\" || echo \"oauth    : no credential file\"
    echo \"live test:\"
    cd /tmp && timeout 60 claude -p \"reply with exactly: TEAM-OK\" 2>&1 | head -3
  '"
}

cmd_token() {
  # setup-token wraps the value in a banner and colour codes; keep the token itself.
  local raw token
  [ -t 0 ] && die "read the token on stdin: claude setup-token | $0 token"
  raw="$(tr -d "\r" | tr "\n" " ")"
  case "$raw" in
    *sk-ant-*) ;;
    *) die "no sk-ant- token on stdin" ;;
  esac
  token="sk-ant-${raw##*sk-ant-}"
  token="${token%%[![:alnum:]_-]*}"

  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nANTHROPIC_API_KEY=\n' "$token" |
    ssh $SSH_OPTS "$SSH_HOST" "/opt/vibe/deploy/scripts/apply-env.sh core.env"

  recreate_core
  green "token installed — checking it"
  cmd_status
}

cmd_login() {
  dim "interactive: the CLI prints a URL, you open it, you paste the code back"
  ssh -tt $SSH_OPTS "$SSH_HOST" "podman exec -it -e ANTHROPIC_API_KEY= ${CORE} claude /login"
  dim "a login only survives while the env has no ANTHROPIC_API_KEY — use 'token' to make it stick"
}

case "${1:-status}" in
  status) cmd_status ;;
  token)  cmd_token ;;
  login)  cmd_login ;;
  -h | --help) printf '%s\n' "usage: team-relogin.sh status|token|login" ;;
  *) die "unknown command: $1 (try: status, token, login)" ;;
esac
