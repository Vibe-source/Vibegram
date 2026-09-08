#!/bin/bash
# Ship secrets from the local agix store to the VPS. Values go
# agix -> pipe -> ssh -> apply-env.sh: never argv, never a temp file, never printed.
#
# Usage: deploy/scripts/sync-env.sh [--dry-run] [--restart] [FILE.env ...]
#   --dry-run   name what would be set, touch nothing
#   --restart   recreate the affected services (env_file is only re-read on create)
# Mapping: deploy/env/secret-map.tsv. Runs on the Mac, not on the box.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAP="${SECRET_MAP:-${REPO_ROOT}/deploy/env/secret-map.tsv}"
DEST="${DEST:-/opt/vibe}"
USER_="${VPS_USER:-vibe}"
KEY="${VPS_SSH_KEY_FILE:-$HOME/.ssh/vibe_vps}"
SSH_OPTS="-o IdentitiesOnly=yes -o StrictHostKeyChecking=${VPS_SSH_STRICT:-accept-new}"
[ -f "$KEY" ] && SSH_OPTS="-i $KEY $SSH_OPTS"

DRY=0; RESTART=0; WANT=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --restart) RESTART=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *.env)     WANT+=("$1") ;;
    *)         echo "sync-env: unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

[ -f "$MAP" ] || { echo "sync-env: no map at ${MAP}" >&2; exit 1; }
command -v agix >/dev/null || { echo "sync-env: agix not on PATH" >&2; exit 1; }

# Which env file each service reads, so --restart recreates the right ones.
services_for() {
  case "$1" in
    core.env)            echo core ;;
    agent-runtime.env)   echo agent-runtime ;;
    sandbox-gateway.env) echo sandbox-gateway ;;
    monitoring.env)      echo grafana ;;
    backup.env)          echo backup ;;
    caddy.env)           echo caddy ;;
    valkey.env)          echo "valkey valkey-exporter" ;;
    postgres.env)        echo postgres ;;
    pgbouncer.env)       echo pgbouncer ;;
    *)                   echo "" ;;
  esac
}

held="$(agix secret list 2>/dev/null | awk '{print $1}')"
is_held() { printf '%s\n' "$held" | grep -qx "$1"; }
wanted() {
  [ ${#WANT[@]} -eq 0 ] && return 0
  for w in "${WANT[@]}"; do [ "$w" = "$1" ] && return 0; done
  return 1
}

files="$(awk '!/^[[:space:]]*#/ && NF==3 {print $2}' "$MAP" | sort -u)"
touched=(); missing=()

for file in $files; do
  wanted "$file" || continue

  # Build the emitter for this file: one line per mapped name, values by $VAR.
  only=(--net --only VPS_HOST); body=""; names=""
  while read -r src dst_file dst_name; do
    [ "$dst_file" = "$file" ] || continue
    case "$src" in [A-Z_]*[A-Z0-9_]|[A-Z_]) ;; *) echo "sync-env: bad name ${src}" >&2; continue ;; esac
    if ! is_held "$src"; then missing+=("${src} -> ${file}"); continue; fi
    only+=(--only "$src")
    body="${body}emit '${dst_name}' \"\$${src}\""$'\n'
    names="${names}${dst_name} "
  done < <(awk '!/^[[:space:]]*#/ && NF==3 {print $1, $2, $3}' "$MAP")

  [ -n "$names" ] || continue
  echo "${file}: ${names}"
  [ "$DRY" -eq 1 ] && continue

  # emit refuses an empty or multi-line value rather than corrupt the .env,
  # which is one KEY=VALUE per line and cannot carry an embedded newline.
  agix secret run "${only[@]}" -- sh -c '
    NL="
"
    emit() {
      case "$2" in
        "")      echo "sync-env: $1 is empty upstream, skipped" >&2; return 0 ;;
        *"$NL"*) echo "sync-env: $1 is multi-line — set that one by hand" >&2; return 1 ;;
      esac
      printf "%s=%s\n" "$1" "$2"
    }
    { '"${body}"' } | ssh '"$SSH_OPTS"' "'"${USER_}"'@$VPS_HOST" \
      "'"${DEST}"'/deploy/scripts/apply-env.sh '"${file}"'"
  '
  touched+=("$file")
done

if [ ${#missing[@]} -gt 0 ]; then
  echo
  echo "not held by agix — set each, then re-run:"
  printf '  agix secret set %s\n' "${missing[@]%% *}" | sort -u
fi

[ ${#touched[@]} -gt 0 ] || exit 0

svcs=""
for f in "${touched[@]}"; do svcs="${svcs} $(services_for "$f")"; done
svcs="$(printf '%s\n' $svcs | sort -u | tr '\n' ' ')"

if [ "$RESTART" -eq 0 ]; then
  echo
  echo "not applied yet — a container only reads env_file when it is created:"
  echo "  deploy/scripts/sync-env.sh --restart   (or re-run with --restart)"
  echo "  affected: ${svcs}"
  exit 0
fi

# A whole-project `up` is what recreates the removed ones. It shouts about every
# neighbour whose name is still taken, then leaves it running — verified untouched.
echo
echo "recreating:${svcs}"
agix secret run --net --only VPS_HOST -- sh -c '
  ssh '"$SSH_OPTS"' "'"${USER_}"'@$VPS_HOST" \
    "cd '"${DEST}"'/deploy
     for s in '"${svcs}"'; do podman rm -f deploy_\${s}_1 >/dev/null 2>&1 || true; done
     podman-compose up -d --no-build >/dev/null 2>&1 || true
     for s in '"${svcs}"'; do
       printf \"  %-20s \" \"\$s\"
       podman inspect -f \"{{.State.Status}}  since {{.State.StartedAt}}\" deploy_\${s}_1 2>/dev/null || echo MISSING
     done"
'
