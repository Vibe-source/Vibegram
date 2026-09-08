#!/bin/sh
# Runs once, on first init of an empty data dir (docker-entrypoint-initdb.d
# convention). Creates the core/agent-runtime databases + app roles from env.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
	DO \$\$
	BEGIN
	  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'vibe_core_app') THEN
	    CREATE ROLE vibe_core_app LOGIN PASSWORD '${VIBE_CORE_DB_PASSWORD}';
	  END IF;
	  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'vibe_agents_app') THEN
	    CREATE ROLE vibe_agents_app LOGIN PASSWORD '${VIBE_AGENTS_DB_PASSWORD}';
	  END IF;
	  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'vibe_readonly') THEN
	    CREATE ROLE vibe_readonly LOGIN PASSWORD '${VIBE_READONLY_DB_PASSWORD}';
	  END IF;
	END
	\$\$;
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -c "GRANT pg_monitor TO vibe_readonly"

for pair in "vibe_core:vibe_core_app" "vibe_agents:vibe_agents_app"; do
  db="${pair%%:*}"
  role="${pair##*:}"

  exists=$(psql -tA --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -c "SELECT 1 FROM pg_database WHERE datname = '${db}'")
  if [ "$exists" != "1" ]; then
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
      -c "CREATE DATABASE ${db} OWNER ${role}"
  fi

  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" \
    -c "GRANT ALL PRIVILEGES ON DATABASE ${db} TO ${role}"

  # PUBLIC gets CONNECT on every new database by default, which would let the
  # agent role open the core database. Only the owning role may connect.
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -c "REVOKE CONNECT ON DATABASE ${db} FROM PUBLIC"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" \
    -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"

  # Human read path (deploy/scripts/psql-ro.sh). Explicit CONNECT because PUBLIC
  # lost it above; SELECT only, including on tables created by later migrations.
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -c "GRANT CONNECT ON DATABASE ${db} TO vibe_readonly"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" \
    -c "GRANT USAGE ON SCHEMA public TO vibe_readonly"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" \
    -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO vibe_readonly"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$db" \
    -c "ALTER DEFAULT PRIVILEGES FOR ROLE ${role} IN SCHEMA public GRANT SELECT ON TABLES TO vibe_readonly"
done
