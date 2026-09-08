#!/usr/bin/env bash
# http-flood.sh — three oha scenarios against the core REST API:
#   1. GET  /api/health           (no DB — floor cost)
#   2. GET  /api/chats/:userId    (Bearer auth, DB path — Chat.list_chats)
#   3. POST /api/login wrong pw   (pbkdf2 CPU path)
#
# Scenario 3 will surface mostly 429s once past the first ~10 requests: the
# :auth rate-limit bucket allows 10 req/min per IP (see
# server/lib/vibe_web/plugs/rate_limiter.ex @default_limits). That is the
# limiter working as designed, not a bug — this script prints it as a finding.
#
# Usage:
#   scripts/loadtest/http-flood.sh [--core-url URL] [--seed PATH] \
#     [--rps N] [-c N] [--duration 15s]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_URL="${VIBE_CORE_URL:-http://127.0.0.1:4000}"
SEED_PATH="$SCRIPT_DIR/results/seed-lt.json"
RPS=""
CONNS=50
DURATION="15s"
RESULTS_DIR="$SCRIPT_DIR/results"

while [ $# -gt 0 ]; do
  case "$1" in
    --core-url) CORE_URL="$2"; shift 2 ;;
    --seed) SEED_PATH="$2"; shift 2 ;;
    --rps) RPS="$2"; shift 2 ;;
    -c|--conns) CONNS="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    -h|--help)
      echo "usage: $0 [--core-url URL] [--seed PATH] [--rps N] [-c N] [--duration 15s]"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v oha >/dev/null 2>&1 || { echo "oha not found on PATH" >&2; exit 1; }
mkdir -p "$RESULTS_DIR"

OHA_RATE_ARGS=()
if [ -n "$RPS" ]; then
  OHA_RATE_ARGS+=(-q "$RPS")
fi

STAMP="$(date +%s)"

print_status_codes() {
  # oha's --output-format json writes a top-level statusCodeDistribution map.
  node -e "
    try {
      const j = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
      console.log('  status codes:', JSON.stringify(j.statusCodeDistribution));
      console.log('  requests/sec:', j.summary && j.summary.requestsPerSec);
    } catch (e) { console.log('  (could not parse oha output: ' + e.message + ')'); }
  " "$1"
}

echo "=== scenario 1/3: GET /api/health (no DB) ==="
HEALTH_OUT="$RESULTS_DIR/http-flood-health-$STAMP.json"
oha -c "$CONNS" -z "$DURATION" "${OHA_RATE_ARGS[@]}" \
  --no-tui --output-format json -o "$HEALTH_OUT" \
  "$CORE_URL/api/health"
echo "wrote $HEALTH_OUT"
print_status_codes "$HEALTH_OUT"

if [ -f "$SEED_PATH" ]; then
  USER_ID="$(node -e "console.log(JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).users[0].id)" "$SEED_PATH")"
  TOKEN="$(node -e "console.log(JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).users[0].token)" "$SEED_PATH")"
  USERNAME="$(node -e "console.log(JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).users[0].username)" "$SEED_PATH")"

  echo ""
  echo "=== scenario 2/3: GET /api/chats/:userId (DB path, user=$USERNAME) ==="
  CHATS_OUT="$RESULTS_DIR/http-flood-chats-$STAMP.json"
  oha -c "$CONNS" -z "$DURATION" "${OHA_RATE_ARGS[@]}" \
    --no-tui --output-format json -o "$CHATS_OUT" \
    -H "Authorization: Bearer $TOKEN" \
    "$CORE_URL/api/chats/$USER_ID"
  echo "wrote $CHATS_OUT"
  print_status_codes "$CHATS_OUT"

  echo ""
  echo "=== scenario 3/3: POST /api/login wrong password (pbkdf2 CPU path, user=$USERNAME) ==="
  echo "NOTE: :auth rate limit = 10 req/min/IP (server/lib/vibe_web/plugs/rate_limiter.ex)."
  echo "      Expect mostly 429s past the first ~10 requests — that is the limiter working."
  LOGIN_OUT="$RESULTS_DIR/http-flood-login-$STAMP.json"
  oha -c "$CONNS" -z "$DURATION" "${OHA_RATE_ARGS[@]}" \
    --no-tui --output-format json -o "$LOGIN_OUT" \
    -m POST -T "application/json" \
    -d "{\"credential\":\"$USERNAME\",\"password\":\"loadtest-wrong-password\"}" \
    "$CORE_URL/api/login"
  echo "wrote $LOGIN_OUT"
  print_status_codes "$LOGIN_OUT"
else
  echo ""
  echo "no seed file at $SEED_PATH — skipping scenarios 2 and 3 (run seed.js first)" >&2
fi
