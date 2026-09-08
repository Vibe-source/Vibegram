#!/bin/bash
# `railway logs` replacement — reads the VPS journal over HTTPS, no SSH.
# Goes through Grafana's Loki datasource proxy, so Grafana's auth is the only
# auth and Loki itself stays unpublished.
#
#   export VIBE_LOGS_URL=https://logs.<domain>
#   export VIBE_LOGS_TOKEN=<grafana service-account token>   # mint-logs-token.sh
#   deploy/scripts/vibe-logs.sh core -f
#   deploy/scripts/vibe-logs.sh core -n 500 -s 2h -g 'error|timeout'
#   deploy/scripts/vibe-logs.sh -u cloudflared -s 30m   # host unit, not a container
#   deploy/scripts/vibe-logs.sh --list                  # containers, then host units
set -euo pipefail

URL="${VIBE_LOGS_URL:?VIBE_LOGS_URL not set}"
TOKEN="${VIBE_LOGS_TOKEN:?VIBE_LOGS_TOKEN not set}"
PROXY="${URL%/}/api/datasources/proxy/uid/vibe-loki/loki/api/v1"
command -v jq >/dev/null || { echo "vibe-logs: needs jq" >&2; exit 1; }

SERVICE="" FOLLOW=0 LIMIT=200 SINCE="1h" PATTERN="" LIST=0 UNIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--follow) FOLLOW=1 ;;
    -n) LIMIT="$2"; shift ;;
    -s|--since) SINCE="$2"; shift ;;
    -g|--grep) PATTERN="$2"; shift ;;
    -u|--unit) UNIT="$2"; shift ;;
    --list) LIST=1 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    -*) echo "vibe-logs: unknown flag $1" >&2; exit 1 ;;
    *) SERVICE="$1" ;;
  esac
  shift
done

api() { curl -sS --fail-with-body -H "Authorization: Bearer ${TOKEN}" "$@"; }

if [ "$LIST" -eq 1 ]; then
  echo "containers (pass as the bare argument):"
  api --get "${PROXY}/label/container/values" | jq -r '.data[]? | "  " + .' | sort
  echo "host units (pass with -u):"
  api --get "${PROXY}/label/unit/values" | jq -r '.data[]? | "  " + .' | sort
  exit 0
fi

selector='{job="journal"'
# compose names containers deploy_<service>_1; accept the short service name too.
[ -n "$SERVICE" ] && selector="${selector}, container=~\"(deploy_)?${SERVICE}(_[0-9]+)?\""
# journald labels host units with the .service suffix; accept the bare name too.
[ -n "$UNIT" ] && selector="${selector}, unit=\"${UNIT%.service}.service\""
selector="${selector}}"
[ -n "$PATTERN" ] && selector="${selector} |~ \`(?i)${PATTERN}\`"

# Loki wants nanoseconds. Duration suffixes are resolved here, not by `date -d`,
# which the BSD date on macOS does not support.
now_ns() { printf '%s000000000\n' "$(date +%s)"; }
since_secs() {
  local n="${SINCE%[smhd]}" u="${SINCE: -1}"
  case "$u" in
    s) echo "$n" ;;
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
    d) echo $((n * 86400)) ;;
    *) echo $((SINCE)) ;;
  esac
}

# @tsv escapes embedded newlines; printf %b turns them back into real breaks.
hhmmss() { date -r "$1" '+%H:%M:%S' 2>/dev/null || date -d "@$1" '+%H:%M:%S'; }

emit() {
  jq -r '.data.result // [] | map(.stream.container as $c | .values[] |
         {ns: .[0], c: ($c // "host"), line: .[1]}) | sort_by(.ns) | .[] |
         [.ns, .c, .line] | @tsv' |
  while IFS=$'\t' read -r ns name line; do
    printf '%s  %-18s ' "$(hhmmss $((ns / 1000000000)))" "$name"
    printf '%b\n' "$line"
  done
}

newest_ns() { jq -r '[.data.result[]?.values[]?[0]] | max // empty'; }

start=$(( $(now_ns) - $(since_secs) * 1000000000 ))
out=$(api --get --data-urlencode "query=${selector}" --data "limit=${LIMIT}" \
        --data "start=${start}" --data "direction=backward" "${PROXY}/query_range")
printf '%s' "$out" | emit
cursor=$(printf '%s' "$out" | newest_ns)
[ -n "$cursor" ] || cursor="$start"

[ "$FOLLOW" -eq 1 ] || exit 0
trap 'exit 0' INT
while :; do
  sleep 2
  out=$(api --get --data-urlencode "query=${selector}" --data "limit=1000" \
          --data "start=$((cursor + 1))" --data "direction=forward" \
          "${PROXY}/query_range") || continue
  printf '%s' "$out" | emit
  next=$(printf '%s' "$out" | newest_ns)
  [ -n "$next" ] && cursor="$next"
done
