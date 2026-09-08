#!/bin/sh
# pg_dump both DBs -> age-encrypt (recipient = BACKUP_AGE_PUBLIC_KEY, no
# private key on this box) -> rclone to R2. Sunday's daily copy doubles as
# that week's snapshot; retention is enforced by age, not a run counter.
set -eu

ts=$(date -u +%Y%m%dT%H%M%SZ)
day_of_week=$(date -u +%u) # 1=Monday .. 7=Sunday

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

export PGHOST=postgres
export PGPORT=5432
export PGUSER="$POSTGRES_USER"
export PGPASSWORD="$POSTGRES_PASSWORD"

for db in vibe_core vibe_agents; do
  echo "[backup] dumping ${db}"
  pg_dump -Fc "$db" >"$workdir/${db}.dump"
  age -r "$BACKUP_AGE_PUBLIC_KEY" -o "$workdir/${db}-${ts}.dump.age" "$workdir/${db}.dump"
  rm -f "$workdir/${db}.dump"

  rclone copy "$workdir/${db}-${ts}.dump.age" "r2:${BACKUP_R2_BUCKET}/daily/${db}/" --quiet

  if [ "$day_of_week" = "7" ]; then
    rclone copy "$workdir/${db}-${ts}.dump.age" "r2:${BACKUP_R2_BUCKET}/weekly/${db}/" --quiet
  fi
done

echo "[backup] pruning: 14 daily / 8 weekly retained"
for db in vibe_core vibe_agents; do
  rclone delete "r2:${BACKUP_R2_BUCKET}/daily/${db}/" --min-age 14d --quiet
  rclone delete "r2:${BACKUP_R2_BUCKET}/weekly/${db}/" --min-age 56d --quiet
done

echo "[backup] done: ${ts}"
