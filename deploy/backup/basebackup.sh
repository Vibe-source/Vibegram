#!/bin/sh
set -eu
set -o pipefail

: "${BACKUP_AGE_PUBLIC_KEY:?BACKUP_AGE_PUBLIC_KEY is required}"
: "${BACKUP_R2_BUCKET:?BACKUP_R2_BUCKET is required}"

ts=$(date -u +%Y%m%dT%H%M%SZ)
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

export PGHOST=postgres
export PGPORT=5432
export PGUSER="$POSTGRES_USER"
export PGPASSWORD="$POSTGRES_PASSWORD"

archive="$workdir/base-${ts}.tar.gz.age"
echo "[basebackup] creating base-${ts}"
pg_basebackup -D - -Ft -z -X none | age -r "$BACKUP_AGE_PUBLIC_KEY" -o "$archive"
rclone copy "$archive" "r2:${BACKUP_R2_BUCKET}/base/" --quiet
rclone delete "r2:${BACKUP_R2_BUCKET}/base/" --min-age 42d --quiet
echo "[basebackup] done: ${ts}"
