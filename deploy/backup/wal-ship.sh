#!/bin/sh
set -eu

: "${BACKUP_AGE_PUBLIC_KEY:?BACKUP_AGE_PUBLIC_KEY is required}"
: "${BACKUP_R2_BUCKET:?BACKUP_R2_BUCKET is required}"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

for segment in /wal_archive/*; do
  [ -f "$segment" ] || continue
  case "$segment" in
    *.partial|*.tmp) continue ;;
  esac

  name=$(basename "$segment")
  encrypted="$workdir/${name}.age"
  echo "[wal-ship] encrypting ${name}"
  age -r "$BACKUP_AGE_PUBLIC_KEY" -o "$encrypted" "$segment"
  rclone copy "$encrypted" "r2:${BACKUP_R2_BUCKET}/wal/" --quiet
  rm -f "$segment" "$encrypted"
done

rclone delete "r2:${BACKUP_R2_BUCKET}/wal/" --min-age 35d --quiet
echo "[wal-ship] done"
