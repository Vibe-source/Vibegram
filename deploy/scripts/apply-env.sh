#!/bin/bash
# Merge KEY=VALUE lines from stdin into the sealed deploy/env/<file>.cred (needs
# root), or the plaintext file before sealing. Values arrive over a
# pipe, never argv, so they stay out of `ps` and out of this output.
#
#   agix secret run --only R2_SECRET_ACCESS_KEY -- sh -c \
#     'printf "R2_SECRET_ACCESS_KEY=%s\n" "$R2_SECRET_ACCESS_KEY" |
#      ssh vibe@$VPS_HOST "/opt/vibe/deploy/scripts/apply-env.sh core.env"'
#
# Prints names only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_DIR="${REPO_ROOT}/deploy/env"
TARGET="${1:?usage: apply-env.sh <file.env>}"
FILE="${ENV_DIR}/${TARGET}"
CRED="${FILE}.cred"
RUN_DIR=/run/vibe/env

case "$TARGET" in
  */*|..*) echo "apply-env: name only, not a path" >&2; exit 1 ;;
  *.env) ;;
  *) echo "apply-env: must end in .env" >&2; exit 1 ;;
esac
[ -f "$FILE" ] || [ -f "$CRED" ] || { echo "apply-env: ${TARGET} does not exist — run init-env.sh first" >&2; exit 1; }

SEALED=0
[ -f "$CRED" ] && SEALED=1
if [ "$SEALED" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
  exec sudo -n "$0" "$@"
fi

umask 077
tmp="$(mktemp /dev/shm/apply-env.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
if [ "$SEALED" -eq 1 ]; then
  systemd-creds decrypt --name="vibe-env-${TARGET}" "$CRED" "$tmp"
else
  cp "$FILE" "$tmp"
fi
applied=()

while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in \#*) continue ;; esac
  case "$line" in
    -*) name="${line#-}"; grep -v "^${name}=" "$tmp" >"${tmp}.n" || true; mv "${tmp}.n" "$tmp"; applied+=("-${name}"); continue ;;
  esac
  name="${line%%=*}"
  [ "$name" != "$line" ] || { echo "apply-env: skipping malformed line" >&2; continue; }
  case "$name" in
    [A-Z_]*[A-Z0-9_]|[A-Z_]) ;;
    *) echo "apply-env: skipping non-env name" >&2; continue ;;
  esac
  # grep -v then append: rewriting in place would need the value on a sed line.
  grep -v "^${name}=" "$tmp" >"${tmp}.n" || true
  mv "${tmp}.n" "$tmp"
  printf '%s\n' "$line" >>"$tmp"
  applied+=("$name")
done

if [ "$SEALED" -eq 1 ]; then
  systemd-creds encrypt --with-key=host --name="vibe-env-${TARGET}" "$tmp" "${CRED}.new"
  chmod 600 "${CRED}.new"
  mv "${CRED}.new" "$CRED"
  [ -d "$RUN_DIR" ] && install -m 400 -o vibe -g vibe "$tmp" "${RUN_DIR}/${TARGET}"
else
  mv "$tmp" "$FILE"
fi
[ "$SEALED" -eq 1 ] || { trap - EXIT; chmod 600 "$FILE"; }
echo "${TARGET}: set ${#applied[@]} -> ${applied[*]:-none}"
