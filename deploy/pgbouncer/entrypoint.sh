#!/bin/sh
# Writes userlist.txt from env (plaintext values — pgbouncer 1.14+ performs
# SCRAM to both the client and postgres from a plaintext-stored password, so
# nothing here needs pre-computed hashes) into a tmpfs, then execs pgbouncer.
set -eu

mkdir -p /run/pgbouncer
umask 077
{
  echo "\"vibe_core_app\" \"${VIBE_CORE_DB_PASSWORD}\""
  echo "\"vibe_agents_app\" \"${VIBE_AGENTS_DB_PASSWORD}\""
} > /run/pgbouncer/userlist.txt

exec pgbouncer /etc/pgbouncer/pgbouncer.ini
