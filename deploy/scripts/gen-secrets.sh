#!/bin/bash
# Prints fresh placeholder values, grouped by the env file they belong in.
# Paste them in by hand — this never writes to deploy/env/*.env directly, so
# it can't clobber a live deployment's secrets.
set -euo pipefail

b64() { openssl rand -base64 "$1"; }
hex() { openssl rand -hex "$1"; }

core_db_pw=$(b64 24)
agents_db_pw=$(b64 24)
readonly_db_pw=$(b64 24)
pg_superuser_pw=$(b64 24)
valkey_pw=$(b64 24)
hmac_key=$(hex 32)
sandbox_token=$(hex 32)
core_secret_base=$(b64 48)
runtime_secret_base=$(b64 48)

cat <<EOF
# ---- deploy/env/core.env ----
SECRET_KEY_BASE=${core_secret_base}
DATABASE_URL=postgresql://vibe_core_app:${core_db_pw}@pgbouncer:6432/vibe_core
MIGRATION_DATABASE_URL=postgresql://vibe_core_app:${core_db_pw}@postgres:5432/vibe_core
VALKEY_URL=redis://:${valkey_pw}@valkey:6379
VIBE_INTERNAL_HMAC_KEY=${hmac_key}

# ---- deploy/env/agent-runtime.env ----
SECRET_KEY_BASE=${runtime_secret_base}
DATABASE_URL=postgresql://vibe_agents_app:${agents_db_pw}@pgbouncer:6432/vibe_agents
MIGRATION_DATABASE_URL=postgresql://vibe_agents_app:${agents_db_pw}@postgres:5432/vibe_agents
VIBE_INTERNAL_HMAC_KEY=${hmac_key}
SANDBOX_GATEWAY_TOKEN=${sandbox_token}

# ---- deploy/env/sandbox-gateway.env ----
SANDBOX_GATEWAY_TOKEN=${sandbox_token}

# ---- deploy/env/postgres.env ----
POSTGRES_PASSWORD=${pg_superuser_pw}
VIBE_CORE_DB_PASSWORD=${core_db_pw}
VIBE_AGENTS_DB_PASSWORD=${agents_db_pw}
VIBE_READONLY_DB_PASSWORD=${readonly_db_pw}

# ---- deploy/env/postgres-exporter.env ----
DATA_SOURCE_NAME=postgresql://vibe_readonly:${readonly_db_pw}@postgres:5432/vibe_core?sslmode=disable

# ---- deploy/env/pgbouncer.env ----
VIBE_CORE_DB_PASSWORD=${core_db_pw}
VIBE_AGENTS_DB_PASSWORD=${agents_db_pw}

# ---- deploy/env/valkey.env ----
VALKEY_PASSWORD=${valkey_pw}

# ---- deploy/env/backup.env ----
POSTGRES_PASSWORD=${pg_superuser_pw}
# BACKUP_AGE_PUBLIC_KEY / BACKUP_AGE_PRIVATE_KEY: generate separately with
# 'age-keygen', keep the private key OFF this box (see docs/vps-deployment.md).
EOF
