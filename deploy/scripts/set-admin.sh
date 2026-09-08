#!/usr/bin/env bash
# Grant, revoke and list Vibe admin roles in the live database.
#
#   deploy/scripts/set-admin.sh list
#   deploy/scripts/set-admin.sh grant <username> <superadmin|admin> [reason]
#   deploy/scripts/set-admin.sh revoke <username> [by-username]
#   deploy/scripts/set-admin.sh scopes <username>
#
# Nothing here runs at deploy time: an admin exists only because someone ran this
# on purpose. Drives the box as the vibe stack user, same as team-setup.sh.
set -euo pipefail

SSH_HOST="${VPS_SSH_HOST:-vibe-vps}"
SSH_USER="${VPS_SSH_USER:-vibe}"
PG="${PG_CONTAINER:-deploy_postgres_1}"
DB="${VIBE_DB:-vibe_core}"
SSH_OPTS="-l ${SSH_USER} -o ConnectTimeout=25"
if [ -n "${VPS_SSH_KEY_FILE:-}" ]; then
  SSH_OPTS="-i ${VPS_SSH_KEY_FILE} -o IdentitiesOnly=yes $SSH_OPTS"
fi

green() { printf '\033[32m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }
die()   { printf '\033[31m%s\033[0m\n' "$1" >&2; exit 1; }

# The SQL reaches psql on stdin, so quotes survive both shells untouched.
run_sql() {
  printf '%s\n' "$1" | ssh $SSH_OPTS "$SSH_HOST" \
    "podman exec -i ${PG} psql -U postgres -d ${DB} -v ON_ERROR_STOP=1 -tAX -f -"
}

require_name() {
  case "${1:-}" in
    '' | *[!A-Za-z0-9_.-]*) die "invalid or missing username: ${1:-<none>}" ;;
  esac
}

cmd_list() {
  local out
  out="$(run_sql "
    select u.username || '  ' || a.role || '  ' || a.scopes::text || '  granted ' || a.inserted_at
    from admin_users a
    join users u on u.id = a.user_id
    where a.revoked_at is null
    order by a.role, u.username;")"
  if [ -z "$out" ]; then
    dim "no admins — grant one with: set-admin.sh grant <username> superadmin"
  else
    printf '%s\n' "$out"
  fi
}

cmd_grant() {
  local who="${1:-}" role="${2:-}" reason="${3:-}"
  require_name "$who"
  case "$role" in
    superadmin | admin) ;;
    *) die "role must be superadmin or admin" ;;
  esac

  local out
  out="$(run_sql "
    insert into admin_users (id, user_id, role, scopes, granted_reason, inserted_at, updated_at)
    select gen_random_uuid(), u.id, '${role}', '{}', nullif('${reason}', ''),
           now()::timestamp(0), now()::timestamp(0)
    from users u
    where u.username = '${who}' and not u.is_agent
    on conflict (user_id) where revoked_at is null
    do update set role = excluded.role,
                  granted_reason = coalesce(excluded.granted_reason, admin_users.granted_reason),
                  updated_at = now()::timestamp(0)
    returning role;")"

  [ -n "$out" ] || die "no non-agent user named ${who}"
  green "${who} is now ${out}"
}

cmd_revoke() {
  local who="${1:-}" by="${2:-}"
  require_name "$who"
  [ -z "$by" ] || require_name "$by"

  local out
  out="$(run_sql "
    update admin_users a
    set revoked_at = now()::timestamp(0),
        updated_at = now()::timestamp(0),
        revoked_by_user_id = (select id from users where username = nullif('${by}', ''))
    from users u
    where u.id = a.user_id and u.username = '${who}' and a.revoked_at is null
    returning a.role;")"

  [ -n "$out" ] || die "${who} holds no active admin grant"
  green "${who} revoked (was ${out})"
}

cmd_scopes() {
  local who="${1:-}"
  require_name "$who"
  run_sql "
    select coalesce(a.role, 'none') || '  ' || coalesce(a.scopes::text, '{}')
    from users u
    left join admin_users a on a.user_id = u.id and a.revoked_at is null
    where u.username = '${who}';"
  dim "  role scopes live in Vibe.Admins; this column is the per-row extras only"
}

case "${1:-list}" in
  list) cmd_list ;;
  grant) shift; cmd_grant "$@" ;;
  revoke) shift; cmd_revoke "$@" ;;
  scopes) shift; cmd_scopes "$@" ;;
  -h | --help) printf '%s\n' "usage: set-admin.sh list|grant|revoke|scopes" ;;
  *) die "unknown command: $1 (try: list, grant, revoke, scopes)" ;;
esac
