#!/bin/bash
# Creates deploy/env/*.env from the .example templates with freshly generated
# secrets. Runs ON the VPS. Prints variable NAMES only — never a value.
#
# Usage: deploy/scripts/init-env.sh [--force]
# Refuses to overwrite an existing .env unless --force, so a redeploy cannot
# silently rotate the database password out from under a running Postgres.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_DIR="${REPO_ROOT}/deploy/env"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

b64() { openssl rand -base64 "$1" | tr -d '\n/+=' | cut -c1-"$2"; }
hex() { openssl rand -hex "$1"; }

# set_var FILE NAME VALUE — replace in place, or append if the key is absent.
set_var() {
  local file="$1" name="$2" value="$3"
  if grep -q "^${name}=" "$file" 2>/dev/null; then
    python3 - "$file" "$name" "$value" <<'PY'
import sys
path, name, value = sys.argv[1], sys.argv[2], sys.argv[3]
out = []
for line in open(path):
    out.append(f"{name}={value}\n" if line.startswith(name + "=") else line)
open(path, "w").writelines(out)
PY
  else
    printf '%s=%s\n' "$name" "$value" >>"$file"
  fi
}

core_db_pw=$(b64 32 24)
agents_db_pw=$(b64 32 24)
readonly_db_pw=$(b64 32 24)
pg_superuser_pw=$(b64 32 24)
valkey_pw=$(b64 32 24)
hmac_key=$(hex 32)
sandbox_token=$(hex 32)
core_secret_base=$(openssl rand -base64 48 | tr -d '\n')
runtime_secret_base=$(openssl rand -base64 48 | tr -d '\n')

cd "$ENV_DIR"
for example in *.env.example; do
  target="${example%.example}"
  if [ -f "$target" ] && [ "$FORCE" -eq 0 ]; then
    echo "keep   ${target} (already exists)"
    continue
  fi
  cp "$example" "$target"
  echo "create ${target}"
done
chmod 600 ./*.env

set_var core.env SECRET_KEY_BASE "$core_secret_base"
set_var core.env DATABASE_URL "postgresql://vibe_core_app:${core_db_pw}@pgbouncer:6432/vibe_core"
set_var core.env MIGRATION_DATABASE_URL "postgresql://vibe_core_app:${core_db_pw}@postgres:5432/vibe_core"
set_var core.env VALKEY_URL "redis://:${valkey_pw}@valkey:6379"
set_var core.env VIBE_INTERNAL_HMAC_KEY "$hmac_key"

set_var agent-runtime.env SECRET_KEY_BASE "$runtime_secret_base"
set_var agent-runtime.env DATABASE_URL "postgresql://vibe_agents_app:${agents_db_pw}@pgbouncer:6432/vibe_agents"
set_var agent-runtime.env MIGRATION_DATABASE_URL "postgresql://vibe_agents_app:${agents_db_pw}@postgres:5432/vibe_agents"
set_var agent-runtime.env VIBE_INTERNAL_HMAC_KEY "$hmac_key"
set_var agent-runtime.env SANDBOX_GATEWAY_TOKEN "$sandbox_token"

set_var sandbox-gateway.env SANDBOX_GATEWAY_TOKEN "$sandbox_token"

set_var postgres.env POSTGRES_PASSWORD "$pg_superuser_pw"
set_var postgres.env VIBE_CORE_DB_PASSWORD "$core_db_pw"
set_var postgres.env VIBE_AGENTS_DB_PASSWORD "$agents_db_pw"
set_var postgres.env VIBE_READONLY_DB_PASSWORD "$readonly_db_pw"
set_var postgres-exporter.env DATA_SOURCE_NAME "postgresql://vibe_readonly:${readonly_db_pw}@postgres:5432/vibe_core?sslmode=disable"

set_var pgbouncer.env VIBE_CORE_DB_PASSWORD "$core_db_pw"
set_var pgbouncer.env VIBE_AGENTS_DB_PASSWORD "$agents_db_pw"

set_var valkey.env VALKEY_PASSWORD "$valkey_pw"
# Same value, second name: the redis_exporter reads REDIS_PASSWORD, not VALKEY_*.
set_var valkey.env REDIS_PASSWORD "$valkey_pw"
set_var backup.env POSTGRES_PASSWORD "$pg_superuser_pw"
set_var monitoring.env GF_SECURITY_ADMIN_PASSWORD "$(b64 32 20)"

# Host-specific names, from the environment so no domain is baked into the script.
DOMAIN="${VIBE_DOMAIN:-}"
if [ -n "$DOMAIN" ]; then
  set_var core.env PHX_HOST "api.${DOMAIN}"
  set_var core.env PHX_CHECK_ORIGIN "https://${DOMAIN},https://api.${DOMAIN}"
  set_var core.env CORS_ORIGINS "https://${DOMAIN}"
  set_var agent-runtime.env VIBE_AGENTS_HOST "agents.${DOMAIN}"
  set_var agent-runtime.env VIBE_AGENTS_PUBLIC_URL "https://agents.${DOMAIN}"
  set_var caddy.env VIBE_DOMAIN "$DOMAIN"
  set_var monitoring.env GF_SERVER_ROOT_URL "https://logs.${DOMAIN}"
  # Must be non-empty: Grafana fails ALL provisioning on an empty contact-point address.
  set_var monitoring.env ALERT_EMAIL_TO "alerts@${DOMAIN}"
  set_var monitoring.env GF_SMTP_FROM_ADDRESS "grafana@${DOMAIN}"
  [ -n "${ACME_EMAIL:-}" ] && set_var caddy.env ACME_EMAIL "$ACME_EMAIL"
  echo "host names set for ${DOMAIN}"
fi

chmod 600 ./*.env
echo
echo "generated (values never printed):"
echo "  core.env           SECRET_KEY_BASE DATABASE_URL MIGRATION_DATABASE_URL VALKEY_URL VIBE_INTERNAL_HMAC_KEY"
echo "  agent-runtime.env  SECRET_KEY_BASE DATABASE_URL MIGRATION_DATABASE_URL VIBE_INTERNAL_HMAC_KEY SANDBOX_GATEWAY_TOKEN"
echo "  postgres.env       POSTGRES_PASSWORD VIBE_CORE_DB_PASSWORD VIBE_AGENTS_DB_PASSWORD VIBE_READONLY_DB_PASSWORD"
echo "  postgres-exporter.env DATA_SOURCE_NAME"
echo "  pgbouncer.env      VIBE_CORE_DB_PASSWORD VIBE_AGENTS_DB_PASSWORD"
echo "  valkey.env         VALKEY_PASSWORD"
echo "  sandbox-gateway.env SANDBOX_GATEWAY_TOKEN"
echo "  backup.env         POSTGRES_PASSWORD"
echo
echo "still empty — carry from the old host with merge-railway-env.sh:"
grep -l '^[A-Z0-9_]*=$' ./*.env 2>/dev/null | while read -r f; do
  printf '  %-22s %s\n' "$(basename "$f")" "$(grep '^[A-Z0-9_]*=$' "$f" | cut -d= -f1 | tr '\n' ' ')"
done
