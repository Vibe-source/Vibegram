#!/bin/bash
# Fill in the secrets agix does not hold yet, one no-echo prompt at a time, then
# ship them to the VPS sealed. The value is typed straight into `agix secret set`,
# so it never reaches this script, argv, a file, or your shell history.
#
#   deploy/scripts/set-missing-env.sh                    prompt for every missing name
#   deploy/scripts/set-missing-env.sh TAVILY_API_KEY     just this one, held or not
#   deploy/scripts/set-missing-env.sh --list             name what is missing, ask nothing
#   deploy/scripts/set-missing-env.sh --add NAME core.env   register a new name, then ask
#   deploy/scripts/set-missing-env.sh --from-file NAME ~/AuthKey.p8   a PEM, escaped
#   deploy/scripts/set-missing-env.sh --restart          recreate the services afterwards
#   deploy/scripts/set-missing-env.sh --no-ship          store in agix only, touch no box
#
# Mapping: deploy/env/secret-map.tsv. Runs on the Mac, not on the box.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAP="${SECRET_MAP:-${REPO_ROOT}/deploy/env/secret-map.tsv}"
SYNC="${REPO_ROOT}/deploy/scripts/sync-env.sh"
SSH_HOST="${SSH_HOST:-vibe-vps-stack}"

LIST=0; SHIP=1; RESTART=""; WANT=""; PRESET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list)    LIST=1 ;;
    --no-ship) SHIP=0 ;;
    --restart) RESTART="--restart" ;;
    --add)
      [ $# -ge 3 ] || { echo "set-missing-env: --add NAME FILE.env" >&2; exit 1; }
      case "$2" in [A-Z_]*[A-Z0-9_]|[A-Z_]) ;; *) echo "set-missing-env: bad name $2" >&2; exit 1 ;; esac
      case "$3" in *.env) ;; *) echo "set-missing-env: $3 must end in .env" >&2; exit 1 ;; esac
      if awk -v n="$2" -v f="$3" '!/^[[:space:]]*#/ && NF==3 && $1==n && $2==f {found=1} END {exit !found}' "$MAP"; then
        echo "already mapped: $2 -> $3"
      else
        printf '%-29s %-18s %s\n' "$2" "$3" "$2" >> "$MAP"
        echo "mapped: $2 -> $3"
      fi
      WANT="${WANT} $2"; shift 2 ;;
    --from-file)
      [ $# -ge 3 ] || { echo "set-missing-env: --from-file NAME PATH" >&2; exit 1; }
      [ -f "$3" ] || { echo "set-missing-env: no file at $3" >&2; exit 1; }
      # A PEM cannot ride an .env line; store the escapes the server turns back into newlines.
      awk 'NR>1{printf "\\n"} {printf "%s", $0}' "$3" | agix secret set "$2"
      echo "stored ${2} from ${3##*/}, newlines escaped"
      PRESET="${PRESET} $2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    -*)        echo "set-missing-env: unknown option: $1" >&2; exit 1 ;;
    *)         WANT="${WANT} $1" ;;
  esac
  shift
done

[ -f "$MAP" ] || { echo "set-missing-env: no map at ${MAP}" >&2; exit 1; }
[ -x "$SYNC" ] || { echo "set-missing-env: ${SYNC} is not executable" >&2; exit 1; }
command -v agix >/dev/null || { echo "set-missing-env: agix not on PATH" >&2; exit 1; }

held="$(agix secret list 2>/dev/null | awk '{print $1}')"
is_held() { printf '%s\n' "$held" | grep -qx "$1"; }

# "<file.env> <NAME>" per line. Names carry digits (R2_*), so the class must too.
box=""
load_box() {
  [ -n "$box" ] && return 0
  box="$(agix secret run --only VPS_HOST -- ssh "$SSH_HOST" \
    'for f in /run/vibe/env/*.env; do n=${f##*/}; grep -oE "^[A-Z_0-9]+=" "$f" | tr -d "=" | sed "s|^|$n |"; done' \
    2>/dev/null | grep -E "^[a-z-]+\.env [A-Z_0-9]+$" || true)"
  [ -n "$box" ] || echo "set-missing-env: could not read the box (ssh $SSH_HOST) — server column omitted" >&2
}
on_box() { printf '%s\n' "$box" | grep -qx "$2 $1"; }
wanted()  { printf '%s\n' $WANT | grep -qx "$1"; }
files_for() {
  awk -v n="$1" '!/^[[:space:]]*#/ && NF==3 && $1==n {print $2}' "$MAP" | sort -u | tr '\n' ' '
}

todo=""
# Only the bare form sweeps for what is missing; naming a key means just that key.
if [ -z "$PRESET" ] || [ -n "$WANT" ]; then
for name in $(awk '!/^[[:space:]]*#/ && NF==3 {print $1}' "$MAP" | awk '!seen[$0]++'); do
  if printf '%s\n' $PRESET | grep -qx "$name"; then continue; fi
  if [ -n "$WANT" ]; then wanted "$name" || continue
  else is_held "$name" && continue; fi
  todo="${todo} ${name}"
done
fi

for w in $WANT; do
  printf '%s\n' $todo | grep -qx "$w" ||
    echo "set-missing-env: ${w} is in no map row — add it with: --add ${w} <file.env>" >&2
done

if [ "$LIST" -eq 1 ]; then
  load_box
  printf '  %-28s %-7s %-8s %s\n' NAME AGIX SERVER FILES
  for name in $(awk '!/^[[:space:]]*#/ && NF==3 {print $1}' "$MAP" | awk '!seen[$0]++'); do
    fs="$(files_for "$name")"; srv="yes"
    for f in $fs; do on_box "$name" "$f" || srv="NO"; done
    [ -n "$box" ] || srv="?"
    is_held "$name" && a="yes" || a="NO"
    printf '  %-28s %-7s %-8s %s\n' "$name" "$a" "$srv" "$fs"
  done
  exit 0
fi

[ -n "$todo" ] || [ -n "$PRESET" ] ||
  { echo "nothing to do — every mapped name is already in the agix store"; exit 0; }

if [ -n "$todo" ]; then
  echo "The prompt below is agix's own: it does not echo, and the value never"
  echo "reaches this script. Enter = set it, s = skip, q = stop."
  echo
fi

set_names=""; touched=""
for name in $todo; do
  is_held "$name" && suffix="  (already held — this replaces it)" || suffix=""
  printf '%s  ->  %s%s\n' "$name" "$(files_for "$name")" "$suffix"
  printf '  set it? [Enter/s/q] '
  read -r reply </dev/tty || reply=q
  case "$reply" in
    q|Q) echo "  stopped"; break ;;
    s|S) echo "  skipped"; echo; continue ;;
  esac
  if agix secret set "$name" </dev/tty; then
    set_names="${set_names} ${name}"
    touched="${touched} $(files_for "$name")"
  else
    echo "  not set" >&2
  fi
  echo
done

for name in $PRESET; do
  set_names="${set_names} ${name}"; touched="${touched} $(files_for "$name")"
done

[ -n "$set_names" ] || { echo "nothing set"; exit 0; }
echo "stored in agix:${set_names}"
[ "$SHIP" -eq 1 ] || exit 0

files="$(printf '%s\n' $touched | sort -u | tr '\n' ' ')"
echo
echo "sealing to the VPS:${files:+ }${files}"
# shellcheck disable=SC2086
exec "$SYNC" $RESTART $files
