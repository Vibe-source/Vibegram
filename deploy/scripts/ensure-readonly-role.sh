#!/bin/bash
# Creates/refreshes the vibe_readonly SELECT-only role on a database that was
# already initialised (postgres/init/ only runs on an empty data dir).
# Idempotent. Generates the password on first run; prints names, never values.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_DIR="${REPO_ROOT}/deploy/env"
PG="${PG_CONTAINER:-deploy_postgres_1}"
ENGINE="${ENGINE:-podman}"
SRC="${ENV_DIR}/postgres.env"
[ -f "$SRC" ] || SRC=/run/vibe/env/postgres.env

pw="$(grep -m1 '^VIBE_READONLY_DB_PASSWORD=' "$SRC" 2>/dev/null | cut -d= -f2- || true)"
if [ -z "$pw" ]; then
  pw="$(openssl rand -base64 32 | tr -d '\n/+=' | cut -c1-24)"
  printf 'VIBE_READONLY_DB_PASSWORD=%s\n' "$pw" | "${REPO_ROOT}/deploy/scripts/apply-env.sh" postgres.env
fi

super="$(grep -m1 '^POSTGRES_USER=' "$SRC" 2>/dev/null | cut -d= -f2- || true)"
super="${super:-postgres}"

# The password goes down psql's stdin, never argv — argv is world-readable in ps.
$ENGINE exec -i "$PG" psql -v ON_ERROR_STOP=1 --username "$super" --dbname postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'vibe_readonly') THEN
    CREATE ROLE vibe_readonly LOGIN PASSWORD '${pw}';
  ELSE
    ALTER ROLE vibe_readonly PASSWORD '${pw}';
  END IF;
END
\$\$;
SQL

$ENGINE exec -i "$PG" psql -v ON_ERROR_STOP=1 --username "$super" --dbname postgres \
  -c "GRANT pg_monitor TO vibe_readonly"

for pair in "vibe_core:vibe_core_app" "vibe_agents:vibe_agents_app"; do
  db="${pair%%:*}"; owner="${pair##*:}"
  $ENGINE exec -i "$PG" psql -v ON_ERROR_STOP=1 --username "$super" --dbname postgres \
    -c "GRANT CONNECT ON DATABASE ${db} TO vibe_readonly"
  $ENGINE exec -i "$PG" psql -v ON_ERROR_STOP=1 --username "$super" --dbname "$db" \
    -c "GRANT USAGE ON SCHEMA public TO vibe_readonly" \
    -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO vibe_readonly" \
    -c "GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO vibe_readonly" \
    -c "ALTER DEFAULT PRIVILEGES FOR ROLE ${owner} IN SCHEMA public GRANT SELECT ON TABLES TO vibe_readonly"
  echo "granted SELECT on ${db} to vibe_readonly"
done

exporter="${ENV_DIR}/postgres-exporter.env"
if [ ! -f "$exporter" ] && [ ! -f "${exporter}.cred" ]; then
  cp "${exporter}.example" "$exporter"
  chmod 600 "$exporter"
fi
printf "DATA_SOURCE_NAME=postgresql://vibe_readonly:%s@postgres:5432/vibe_core?sslmode=disable\n" "$pw" |
  "${REPO_ROOT}/deploy/scripts/apply-env.sh" postgres-exporter.env
