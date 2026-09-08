# VPS deployment — Podman/Docker compose stack

Operational companion to [`agent-platform-v1.md`](agent-platform-v1.md) (architecture,
frozen contracts) and [`deploy/README.md`](../deploy/README.md) (file layout, first-deploy
command list). This doc covers sizing, DNS, the Railway/Supabase → VPS migration, day-2
operations, and security posture.

## 1. Architecture recap

One VPS, `podman compose` (rootless, preferred) or `docker compose`, no Kubernetes. Caddy
terminates TLS and is the only publicly-reachable service; everything else sits on an
internal Docker network. See `agent-platform-v1.md` §1 for the trust-boundary table — this
stack enforces the same boundaries, one compose network per boundary:

- `edge` — caddy, core, agent-runtime (Caddy → core:4000 / agent-runtime:4100)
- `internal` — everything except caddy and the sandboxes
- `sandbox-net` (`internal: true`, no default route out) — sandbox-gateway, egress-proxy,
  and the sandbox containers the gateway spins up on demand

Postgres holds two databases (`vibe_core`, `vibe_agents`) behind PgBouncer (transaction
pooling); Valkey is cache/rate-limit only, no persistence; the doc renderer and the
sandbox-gateway's container socket are each their own service so a crash or a compromise
in one doesn't take the chat core down with it.

## 2. Sizing

**Launch target: Hetzner CX33 — 4 vCPU / 8 GB / 80 GB (~$10/mo).** Numbers below are
measured, not estimated — the whole stack was built and loaded under compose on
2026-08-29. 4 vCPU is the number that matters; see the sandbox table below.

Compose v2 does enforce `deploy.resources.limits` (verified against
`HostConfig.Memory`), but they are ceilings, not reservations: they sum to ~6.6 GB
while the stack actually resides in far less.

| Service | Limit | Idle | Under load |
|---|---|---|---|
| postgres | 2 GB | **92 MB** | **1172 MB** |
| core | 1 GB | 177 MB | 204 MB (no sockets — see below) |
| doc-renderer | 1 GB | 62 MB | 199 MB typical export |
| agent-runtime | 1 GB | 133 MB | 136 MB |
| caddy / valkey / pgbouncer / backup / gateway / egress | 128-384 MB ea. | 35 MB | 43 MB |
| **Base stack** | | **~500 MB** | **~1.75 GB** |

Postgres idles at 92 MB, not 1 GB: `shared_buffers` is mapped lazily and only
materialises as pages are touched. Under 40 pooled clients each looping a 400k-row
sort it reached 1172 MB and stopped there — bounded by `shared_buffers`, well inside
its 2 GB limit.

Sandboxes sit entirely **on top** of that, one per computer-using agent, reaped after
`SANDBOX_IDLE_TTL_SECONDS` (30 min). Text-only agents allocate none. Measured peak
unreclaimable (anon) memory per sandbox:

| Sandbox | Peak anon |
|---|---|
| idle | ~1 MB |
| code/shell agent | **145 MB** |
| browser agent (Chromium) | **393 MB** — on a light page; real sites go higher |

Hence `SANDBOX_DEFAULT_MEMORY_MB=1024`, not 512: at a 512 cap a browsing sandbox
peaked at 501 MB, 98 % of its limit. The limit is a ceiling, so a code agent still
only costs its 145 MB.

**CPU binds before memory.** Each sandbox takes `SANDBOX_DEFAULT_CPUS` (1.0), so
`SANDBOX_MAX_CONTAINERS` × that must leave the base stack some vCPU. Memory would
allow far more sandboxes than the CPU does. `SANDBOX_MAX_CONTAINERS` is real
admission control — the N+1th create returns `sandbox capacity exceeded` rather than
overcommitting — so size it to the box and never leave it at the gateway's 32 default.

| Box | `SANDBOX_MAX_CONTAINERS` | Concurrent agents |
|---|---|---|
| **Hetzner CX33 — 4 vCPU / 8 GB / 80 GB** (launch) | **4** | ~4 code or 4 browser |
| CX43 — 8 vCPU / 16 GB | 8 | first scale step |
| 16 vCPU / 32 GB | 16 | |

The 4 vCPU is what's being bought on CX33 — memory is not the constraint at that
size, and the 8 GB simply leaves ~5 GB spare over the measured 2.9 GB peak.

Whole stack under load plus 5 working sandboxes measured **2.9 GB**, so 4 GB is a real
launch box, not a demo one. Move to 8 GB when either concurrent sandboxes or connected
sockets grow — scale up before scaling out; phase 4 (`agent-platform-v1.md` §5) adds a
second VPS via libcluster only once one box is full.

**Untested here: websocket fan-out.** A messenger's real core-memory axis is connected
sockets. `docs/capacity-500k.md` §0 measures that separately at **~75 KB/connection**
(3,000 real sockets, BEAM RSS delta). Core's 204 MB above is a no-sockets floor; add
75 KB per concurrent user on top.

Disk: Postgres + the Chromium-bearing sandbox image (~1 GB) + per-sandbox volumes (no
per-agent quota yet — Phase 2). 80 GB is comfortable, 40 GB is not. Media moves to R2 at
cutover, so it does not grow the disk.

### What N users actually cost

**Agents at rest are rows, not processes.** 1,000 users × 5 agents = 5,000 Postgres rows
≈ 0 MB and $0. Nothing runs until a message arrives, so the axis that costs money is
**concurrent runs**, never agent count.

At 1,000 concurrent users (75 KB/socket):

| | Cost |
|---|---|
| 1,000 sockets | 73 MB |
| base stack under load | 1,750 MB |
| **total** | **~1.8 GB** — comfortable on 8 GB |
| 5,000 agents at rest | ~0 MB, $0 |

Concurrent runs at that size — 1 % of users messaging at once is ~10 runs, 10 % is ~100.
Each *text* run is a BEAM process plus a model call (cost is tokens, already pay-per-use);
only a *computer-using* run allocates a sandbox. So the limits that matter are
`VIBE_AGENTS_MAX_CONCURRENT_RUNS` (loop slots) and `SANDBOX_MAX_CONTAINERS` (sandboxes),
and beyond them work **queues** rather than failing or overcommitting the box.

Sockets are not the first ceiling either: per `capacity-500k.md` §0, the connect/join
storm is — join does synchronous DB work, and p99 join went 32 ms → 2.15 s between 400
and 3,000 sockets at a fast ramp. Fix that before adding RAM.

## 3. DNS

Three names, all pointed at the VPS's IP:

- `<domain>` — SPA (served by core)
- `api.<domain>` — core's API/websocket
- `agents.<domain>` — agent-runtime's provider ingress + voice sockets

Caddy provisions Let's Encrypt certs for all three automatically on first boot (needs 80
and 443 reachable from the internet for the ACME HTTP-01 challenge). Set a low TTL (300s)
on these records a day before any planned migration/cutover — see §5.

## 4. First deploy

Command-by-command list: [`deploy/README.md`](../deploy/README.md#first-deploy-in-10-commands).
In short: `vps-bootstrap.sh` hardens the box and installs the engine, `gen-secrets.sh` +
hand-editing `deploy/env/*.env` fills in real values, `deploy.sh` builds, migrates, and
brings the stack up, `status.sh` confirms it's healthy.

## 5. Migration: Railway/Supabase → VPS

A cutover, not a live migration — plan for a short write freeze.

1. **Provision the VPS** and run through §4 up to (not including) DNS cutover, so the new
   stack is fully up and reachable at its IP before any traffic moves.
2. **Freeze writes** on the Railway deployment (maintenance mode / scale to 0, whichever
   the app supports) — a single point-in-time dump is only consistent if nothing writes
   during it.
3. **Dump from Supabase's pooler**, not a direct connection (Supabase's session pooler
   handles the large `pg_dump` connection fine; the transaction pooler does not):
   ```bash
   pg_dump --no-owner --no-privileges -Fc \
     "postgresql://postgres.<project-ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/postgres" \
     -f vibe_core.dump
   ```
   `--no-owner --no-privileges` because Supabase's role names don't exist here; `--role`
   makes `vibe_core_app` own every restored table (the app connects as that role and, as
   owner, bypasses the non-forced RLS policies exactly as it does on Supabase today).
4. **Restore** into the VPS's `vibe_core` database:
   ```bash
   podman compose -f deploy/compose.yml exec -T postgres \
     pg_restore -U "$POSTGRES_USER" --role=vibe_core_app -d vibe_core --no-owner --no-privileges <vibe_core.dump
   ```
5. **Sequence check** — `pg_restore` restores sequence values as of the dump, but any row
   inserted between the dump and the freeze (there should be none if step 2 held) would
   desync them. Verify: for each table with a serial/identity PK, confirm
   `select setval('<seq>', (select max(id) from <table>))` is a no-op (already at max).
6. **Storage stays put.** Media lives in Supabase Storage / R2 buckets, addressed by URL —
   nothing in the app writes to local disk for uploads, so there is no file migration step.
   Keep `SUPABASE_*`/`R2_*` credentials pointed at the same buckets in `core.env`.
7. **DNS cutover.** With the low TTL from §3 already in place, repoint `<domain>`,
   `api.<domain>`, `agents.<domain>` to the VPS. Caddy issues certs on first request to
   each name — expect a few seconds of ACME latency on the very first hit per host.
8. **Rollback = DNS back.** Nothing on Railway is torn down until the VPS has been
   observed healthy for a real traffic window (hours, not minutes) — repointing DNS back
   to Railway is the entire rollback procedure as long as Railway's deployment is still
   running and its Supabase database wasn't touched (it wasn't; the VPS reads its own copy).

### Secret rotation on cutover

| Secret | Action |
|---|---|
| `SECRET_KEY_BASE` | **Keep the Railway value.** It signs/encrypts existing sessions and cookies; rotating it logs every user out. |
| DB credentials | **New.** `vibe_core_app`/`vibe_agents_app` passwords are generated fresh by `gen-secrets.sh` for the VPS's own Postgres — never reuse the Supabase password. |
| Agent provider keys (`ANTHROPIC_API_KEY` etc.) | **Unchanged** — same keys, just also present in `agent-runtime.env` now (see the `# remove after cutover` markers in `core.env.example` for phase 3). |
| `VIBE_INTERNAL_HMAC_KEY` | New — this is a VPS-only concept, Railway never had it. |
| Push/Lemon Squeezy/R2/Supabase-storage credentials | Unchanged — same external services, just read from a new box. |

## 6. Operations

**Upgrade:** `deploy/scripts/deploy.sh` — pulls, builds, tags the build with the current
git short SHA, migrates (core then agent-runtime), brings the stack up, waits for
`/api/ready` and `/readyz`.

**Rollback:** `deploy/scripts/deploy.sh --rollback <tag>` retags a previous build (the SHA
printed by the deploy that shipped it) back onto `vibe-core:latest` /
`vibe-agent-runtime:latest` and restarts — no rebuild. Does not reverse migrations; a
migration that must be undone needs `Vibe.Release.rollback/2` run by hand.

**Backups:** automatic every 6h (`deploy/backup/crontab` inside the `backup` container) —
`pg_dump -Fc` both databases, `age`-encrypted to `BACKUP_AGE_PUBLIC_KEY`, uploaded to R2
under `daily/<db>/` (14-day retention) and, on the weekly Sunday run, also under
`weekly/<db>/` (56-day retention). Trigger one on demand with `deploy/scripts/backup.sh`.

**Restore drill:** `deploy/scripts/restore.sh <vibe_core|vibe_agents>` downloads the newest
backup, decrypts it (needs `BACKUP_AGE_PRIVATE_KEY`, which is never stored on the VPS —
export it from wherever it's kept offline before running), restores into a scratch
database, and prints a row-count diff against the live one. It does **not** touch the live
database unless re-run with `--swap`, which stops core/agent-runtime, terminates
connections, and renames the scratch DB into place. Run this drill on a schedule (monthly,
at minimum) — an untested backup is a hope, not a plan.

**Logs:** no SSH needed — `deploy/scripts/vibe-logs.sh core -f` reads the journal over
HTTPS through Grafana's Loki proxy. Full guide, including what is deliberately not shipped:
[`vps-logs.md`](vps-logs.md). On the box itself,
`podman compose -f deploy/compose.yml logs -f <service>` still works. Caddy's JSON access
log is additionally written to `deploy/caddy-logs/access.log` on the host (fail2ban's
caddy jail and host logrotate both read it from there — see `vps-bootstrap.sh`).

**Health/metrics:** `deploy/scripts/status.sh` for a one-shot snapshot. `core:9568` and
`agent-runtime:9568` expose Prometheus metrics on the `internal` network only; bring up
`prometheus`/`grafana`/`node-exporter`/`loki`/`promtail` with
`podman compose --profile monitoring up -d`. Prometheus and Loki are never published —
no host port, and Loki runs `auth_enabled: false`, so Grafana's proxy is their only door.
Grafana binds `127.0.0.1:3000` and is also served at `logs.<domain>` behind its own login;
reach it in a browser or over an SSH tunnel (`ssh -L 3000:localhost:3000 vibe@<vps>`).

## 7. Security notes

**Public surface:** only Caddy, on 80/443 — serving `api.`, `agents.`, `logs.`, `www.` and
the apex. `logs.` fronts Grafana, which is the sole auth for the log stack (anonymous
access and sign-up are both off; the read token is a Viewer service account). Everything else — postgres, pgbouncer, valkey,
sandbox-gateway, egress-proxy, doc-renderer, backup — has no `ports:` mapping and is
reachable only from other containers on the same compose network. `/internal/*` is blocked
at the edge on all three Caddy site blocks (belt-and-suspenders: the routes underneath
still require a valid `vibe-internal-auth/v1` HMAC signature even if this block were
bypassed).

**Internal-only:** the `internal` network carries plaintext HTTP/Postgres-wire/Redis-wire
traffic between containers — this is standard practice for a single-box compose stack (the
alternative, mTLS between every container, is real complexity for a threat model — another
container escaping onto the same bridge network — that `cap_drop: [ALL]` and
`no-new-privileges` on every application container already narrow considerably). Valkey has
no separate network ACL beyond this; its `requirepass` (set from `VALKEY_PASSWORD` at
container start, never written to the static `valkey.conf`) is defense-in-depth on top of
the network boundary, not a substitute for it.

**The sandbox-gateway's socket mount is the highest-value target in this stack** — anything
that can write to the mounted container socket can create arbitrary containers, which on a
naive setup means root-equivalent access to the host. Rootless Podman is why this deploy
uses it by default rather than Docker: the mounted socket
(`${XDG_RUNTIME_DIR}/podman/podman.sock`) belongs to the unprivileged `vibe` user's own
Podman instance, not a root daemon, so a container escape through that socket lands as
`vibe`, not root — it can create/destroy other containers owned by `vibe` (still a real
blast radius: it could tear down the whole stack, or spin up sandboxes of its own) but
cannot read arbitrary host files, install a kernel module, or touch other users' processes.
The Docker variant (`CONTAINER_SOCKET_HOST_PATH=/var/run/docker.sock`, the default when
`--docker` is used) does **not** have this property — Docker's daemon runs as root, so
anything that reaches that socket has effectively root on the host. Prefer rootless podman
for this reason; if Docker is a hard requirement, treat sandbox-gateway's compromise as
equivalent to a host compromise in your incident-response plan.

**What never leaves the box:** `BACKUP_AGE_PRIVATE_KEY` (backup decryption — only the
public key lives in `backup.env`), the Postgres data directory (only its encrypted,
off-site `pg_dump` output does), and MLS key material (never touches the server at all —
out of scope for this doc, see `crypto-audit-and-mls-direction` in agent memory).
