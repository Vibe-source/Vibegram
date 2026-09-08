#!/bin/bash
# Read-only psql into a Vibe database. SELECT only — the role holds no INSERT,
# UPDATE, DELETE or DDL, so a mistyped statement cannot change production data.
#
#   deploy/scripts/psql-ro.sh                       # interactive, vibe_core
#   deploy/scripts/psql-ro.sh vibe_agents
#   deploy/scripts/psql-ro.sh vibe_core -c 'select count(*) from users'
#
# Not part of agent-ops.sh on purpose: the agent surface does not get a shell
# over user data.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PG="${PG_CONTAINER:-deploy_postgres_1}"
ENGINE="${ENGINE:-podman}"
DB="${1:-vibe_core}"
[ $# -gt 0 ] && shift

case "$DB" in
  vibe_core|vibe_agents) ;;
  *) echo "psql-ro: database must be vibe_core or vibe_agents" >&2; exit 1 ;;
esac

# The box seals env into /run/vibe/env; the repo copy only exists before bootstrap.
ENV_FILE="${PG_ENV_FILE:-/run/vibe/env/postgres.env}"
[ -r "$ENV_FILE" ] || ENV_FILE="${REPO_ROOT}/deploy/env/postgres.env"
pw="$(grep -m1 '^VIBE_READONLY_DB_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
[ -n "$pw" ] || { echo "psql-ro: no VIBE_READONLY_DB_PASSWORD in $ENV_FILE — run ensure-readonly-role.sh first" >&2; exit 1; }

exec $ENGINE exec -it -e PGPASSWORD="$pw" "$PG" \
  psql --username vibe_readonly --dbname "$DB" "$@"
