#!/bin/bash
# Restore drill, not a blind overwrite: pulls an encrypted backup from R2,
# decrypts it, restores into a SCRATCH database, and diffs row counts against
# the live one. Only swaps the scratch DB in for real with --swap.
#
# Usage:
#   BACKUP_AGE_PRIVATE_KEY=<key> deploy/scripts/restore.sh <vibe_core|vibe_agents> [object-path] [--swap]
#
# object-path defaults to the newest object under daily/<db>/ in R2.
# BACKUP_AGE_PRIVATE_KEY is never stored on this box — see docs/vps-deployment.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/deploy/compose.yml"

# Convenience: pick up BACKUP_R2_BUCKET / POSTGRES_USER from the deployed env
# files if present. BACKUP_AGE_PRIVATE_KEY must still come from the operator.
for f in deploy/env/backup.env deploy/env/postgres.env; do
  [ -f "${REPO_ROOT}/${f}" ] && set -a && . "${REPO_ROOT}/${f}" && set +a
done

if command -v podman >/dev/null 2>&1; then
  COMPOSE=(podman compose -f "$COMPOSE_FILE")
else
  COMPOSE=(docker compose -f "$COMPOSE_FILE")
fi

DB="${1:?usage: restore.sh <vibe_core|vibe_agents> [object-path] [--swap]}"
shift || true
OBJECT_PATH=""
SWAP=0
for arg in "$@"; do
  case "$arg" in
    --swap) SWAP=1 ;;
    *) OBJECT_PATH="$arg" ;;
  esac
done

[ -n "${BACKUP_AGE_PRIVATE_KEY:-}" ] || { echo "set BACKUP_AGE_PRIVATE_KEY (kept offline)" >&2; exit 1; }
PGUSER="${POSTGRES_USER:-postgres}"
SCRATCH_DB="${DB}_restore_verify"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

if [ -z "$OBJECT_PATH" ]; then
  echo "[restore] finding newest backup for ${DB}"
  newest=$("${COMPOSE[@]}" exec -T backup rclone lsf --files-only "r2:${BACKUP_R2_BUCKET}/daily/${DB}/" | sort | tail -1)
  [ -n "$newest" ] || { echo "[restore] no backups found for ${DB}" >&2; exit 1; }
  OBJECT_PATH="daily/${DB}/${newest}"
fi
echo "[restore] using ${OBJECT_PATH}"

echo "[restore] downloading + decrypting"
"${COMPOSE[@]}" exec -T backup rclone cat "r2:${BACKUP_R2_BUCKET}/${OBJECT_PATH}" >"${workdir}/dump.age"
age -d -i <(echo "$BACKUP_AGE_PRIVATE_KEY") -o "${workdir}/dump" "${workdir}/dump.age"

echo "[restore] creating scratch database ${SCRATCH_DB}"
"${COMPOSE[@]}" exec -T postgres psql -U "$PGUSER" -c "DROP DATABASE IF EXISTS ${SCRATCH_DB}"
"${COMPOSE[@]}" exec -T postgres psql -U "$PGUSER" -c "CREATE DATABASE ${SCRATCH_DB}"

echo "[restore] pg_restore into ${SCRATCH_DB} as ${DB}_app (so the app role owns what it restores)"
"${COMPOSE[@]}" exec -T postgres psql -U "$PGUSER" -c "ALTER DATABASE ${SCRATCH_DB} OWNER TO ${DB}_app"
"${COMPOSE[@]}" exec -T postgres pg_restore -U "$PGUSER" --role="${DB}_app" -d "$SCRATCH_DB" --no-owner --no-privileges <"${workdir}/dump"

echo "[restore] row-count diff (live ${DB} vs ${SCRATCH_DB}, expected to differ if live has moved since the backup):"
count_sql="select relname, n_live_tup from pg_stat_user_tables order by relname"
"${COMPOSE[@]}" exec -T postgres psql -U "$PGUSER" -d "$DB" -c "$count_sql" >"${workdir}/live.txt"
"${COMPOSE[@]}" exec -T postgres psql -U "$PGUSER" -d "$SCRATCH_DB" -c "$count_sql" >"${workdir}/scratch.txt"
diff -u "${workdir}/live.txt" "${workdir}/scratch.txt" || true

if [ "$SWAP" -eq 1 ]; then
  echo "[restore] stopping core/agent-runtime for the swap"
  "${COMPOSE[@]}" stop core agent-runtime

  term_sql="select pg_terminate_backend(pid) from pg_stat_activity where datname in ('${DB}','${SCRATCH_DB}') and pid <> pg_backend_pid()"
  "${COMPOSE[@]}" exec -T postgres psql -U "$PGUSER" -c "$term_sql"

  old="${DB}_old_$(date +%s)"
  echo "[restore] swapping: ${DB} -> ${old}, ${SCRATCH_DB} -> ${DB}"
  "${COMPOSE[@]}" exec -T postgres psql -U "$PGUSER" -c "ALTER DATABASE ${DB} RENAME TO ${old}"
  "${COMPOSE[@]}" exec -T postgres psql -U "$PGUSER" -c "ALTER DATABASE ${SCRATCH_DB} RENAME TO ${DB}"

  "${COMPOSE[@]}" start core agent-runtime
  echo "[restore] swapped. Previous DB kept as ${old} — drop it by hand once verified."
else
  echo "[restore] drill complete — ${SCRATCH_DB} left in place for review. Re-run with --swap to promote it."
fi
