# deploy/ — Vibe VPS stack

Podman-or-Docker compose stack that replaces Railway. Full architecture,
sizing, migration and operations runbooks: [`docs/vps-deployment.md`](../docs/vps-deployment.md).

## Layout

- `compose.yml` — the stack. `caddy core agent-runtime sandbox-gateway
  egress-proxy postgres pgbouncer valkey doc-renderer backup`, plus an opt-in
  `monitoring` profile (prometheus/grafana/node-exporter/loki/promtail).
- `core/` — Dockerfile + start.sh for the chat core (VPS variant of the root
  `Dockerfile`, minus the doc-renderer).
- `caddy/`, `postgres/`, `pgbouncer/`, `valkey/`, `doc-renderer/`, `backup/` —
  per-service config and, where needed, a Dockerfile.
- `env/*.env.example` — one template per service. Copy to `<name>.env`
  (gitignored) and fill in real values; never commit the real files.
- `scripts/` — `gen-secrets.sh`, `vps-bootstrap.sh`, `deploy.sh`, `backup.sh`,
  `restore.sh`, `status.sh`, plus `vibe-logs.sh` / `mint-logs-token.sh` for reading
  logs over HTTPS instead of SSH ([`docs/vps-logs.md`](../docs/vps-logs.md)).
- `systemd/` — user units that bring the stack up on boot (podman and docker
  variants).
- `sandbox/`, `egress-proxy/` — owned by the sandbox-gateway work; referenced
  here, not duplicated.

## Where secrets live

Real secrets only ever live in `deploy/env/*.env` on the VPS itself
(gitignored) — never in this repo, never in `compose.yml`. Generate values
with `deploy/scripts/gen-secrets.sh`; it prints, it doesn't write, so it can't
clobber a live deployment. The one exception: the backup encryption private
key (`BACKUP_AGE_PRIVATE_KEY`) never touches the VPS at all — keep it offline
and pass it to `restore.sh` only when actually restoring.

## Point-in-time restore

PITR is an offline recovery procedure because the age private key never resides on the VPS.
Stop the application, provision an empty PostgreSQL 16 data directory, and download the newest
`base/base-*.tar.gz.age` plus every later object under `wal/` from the backup bucket. Decrypt
the base archive and WAL segments with the offline private key, extract the base archive into
the empty data directory, and place the decrypted WAL files in `/wal_restore`.

Set these recovery parameters before starting PostgreSQL:

```conf
restore_command = 'cp /wal_restore/%f %p'
recovery_target_time = '<ISO-8601 UTC time>'
recovery_target_action = 'promote'
```

Start PostgreSQL in isolation, confirm it reaches the requested timestamp and promotes, then
run application smoke tests before reconnecting traffic. Keep the source backups until the
recovered cluster has passed verification. `restore.sh` remains the logical-dump drill and
is not used for PITR.

## First deploy, in 10 commands

```bash
# 1. On the VPS, as root:
curl -fsSL https://raw.githubusercontent.com/<org>/vibe/main/deploy/scripts/vps-bootstrap.sh | bash -s -- --repo-url https://github.com/<org>/vibe.git
# 2.
su - vibe && cd /opt/vibe
# 3.
deploy/scripts/gen-secrets.sh > /tmp/secrets.txt
# 4. Copy each block from /tmp/secrets.txt into the matching file, then:
for f in deploy/env/*.env.example; do cp "$f" "${f%.example}"; done
# 5. Edit deploy/env/*.env: paste secrets, set VIBE_DOMAIN/ACME_EMAIL, provider
#    keys, R2/Supabase creds, push keys — see docs/vps-deployment.md.
$EDITOR deploy/env/core.env deploy/env/agent-runtime.env deploy/env/caddy.env …
# 6. Point DNS (api.<domain>, agents.<domain>, <domain>) at this VPS's IP.
# 7.
rm /tmp/secrets.txt
# 8.
deploy/scripts/deploy.sh
# 9.
deploy/scripts/status.sh
# 10. Start on boot:
systemctl --user start vibe-stack
```
