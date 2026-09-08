# Reading production logs without SSH

`deploy/scripts/vibe-logs.sh` is the `railway logs` replacement. It reads the VPS
journal over HTTPS, so **an agent never needs SSH to look at logs**. SSH is for
changing the box, not for reading it.

## The endpoint

```
https://logs.<domain>          →  Caddy  →  Grafana  →  Loki datasource proxy
```

`logs.<domain>` is a normal public Caddy site block (`deploy/caddy/Caddyfile`)
reverse-proxying `grafana:3000`. Loki itself has **no** published port and
`auth_enabled: false` — it is reachable only through Grafana's datasource proxy,
so Grafana's auth is the single gate in front of it.

Logs arrive there via promtail, which tails the systemd journal. Podman is
configured with the journald log driver, so every container's stdout lands in the
journal and is shipped with a `container` label.

## Setup

Both values are already in the agix secret broker — `VIBE_LOGS_URL` and
`VIBE_LOGS_TOKEN`. Nothing to configure:

```bash
agix secret run --net --only VIBE_LOGS_TOKEN --only VIBE_LOGS_URL -- \
  deploy/scripts/vibe-logs.sh core -n 200
```

Outside agix, export the two variables and call the script directly. The token is
a Grafana **Viewer** service account, mintable on the VPS with
`deploy/scripts/mint-logs-token.sh` — it prints the token once and Grafana never
shows it again.

The script needs `jq` on whatever machine runs it.

## Usage

```bash
vibe-logs.sh core                       # last 1h, 200 lines
vibe-logs.sh core -f                    # follow
vibe-logs.sh core -n 500 -s 2h          # 500 lines, last 2h
vibe-logs.sh -s 6h -g 'error|timeout'   # all services, case-insensitive regex
vibe-logs.sh agent-runtime -s 30m
vibe-logs.sh --list                     # what is actually queryable right now
```

| flag | meaning |
| --- | --- |
| *(bare arg)* | service name — `core`, or the full `deploy_core_1` |
| `-f`, `--follow` | poll forward every 2s |
| `-n <n>` | line limit (default 200) |
| `-s`, `--since` | `30m`, `2h`, `7d` (default `1h`) |
| `-g`, `--grep` | case-insensitive regex, applied server-side by Loki |
| `-u`, `--unit` | filter by systemd unit instead of container |
| `--list` | list container and unit label values |

Compose names containers `deploy_<service>_1`; the script accepts either that or
the bare service name.

**Retention is 14 days** (`retention_period: 336h`). Queries may span at most 30
days. On a promtail restart only the last 12h of journal is backfilled.

## What you can and cannot see

Available without SSH — every container in the stack: `core`, `agent-runtime`,
`caddy`, `postgres`, `pgbouncer`, `valkey`, `doc-renderer`, `backup`,
`sandbox-gateway`, `egress-proxy`, the monitoring containers, and the ephemeral
sandbox containers (which carry random names — use `--list`).

**Host systemd units are not shipped, and `-u cloudflared` will return nothing.**
This is a deliberate security boundary, not a bug: promtail runs as the
unprivileged `vibe` user under rootless podman, and `/var/log/journal/*/system.journal`
is `root:systemd-journal` mode `0640`. Shipping host units would mean adding
`vibe` to the `systemd-journal` group, which would let anything running as the app
user read sshd, sudo and fail2ban logs. That trade is not worth it.

So `cloudflared`, `sshd`, `fail2ban` and other host units still need
`ssh vibe-vps` + `journalctl -u <unit>`. `-u` works today for the user-session
units that do reach Loki, and would cover host units if that decision is ever
revisited (a separate root-owned promtail scoped to one unit would be the safe
way to do it).

## Security model

- Grafana is the only auth. Anonymous access is off
  (`GF_AUTH_ANONYMOUS_ENABLED=false`), sign-up is off, cookies are
  secure/strict, HSTS on. An unauthenticated request to `logs.<domain>` gets a
  302 to `/login`; the datasource proxy returns `401`.
- The token is role **Viewer** and read-only. It cannot edit dashboards, add
  datasources or change Grafana config. It *can* read every provisioned
  datasource through the proxy, Prometheus included — treat it as "read all
  telemetry", not "read one log stream".
- Logs are application logs and may contain user identifiers. Do not paste raw
  output into places it should not go.
- To revoke: delete the `vibe-logs` service account in Grafana, then re-mint.

## Related

- Stack, sizing, operations: [`vps-deployment.md`](vps-deployment.md)
- What an agent may deploy alone: [`deploy-pipeline.md`](deploy-pipeline.md)
