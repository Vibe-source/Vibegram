# Server security review + data-layer readiness — status 2026-09-08

Lead: Fable. Board: `.vibe/team/data-0908-board.md` (supersedes `.vibe/team/security-0908-board.md`).
Briefs: `.vibe/team/briefs/0908-w1..w5.md`. Notes: N000361–N000375 (`agix note list`). Branch: `server/agent-sender-auth`.

## Done (landed in the worktree, lead-reviewed, not yet committed)
| Item | Where | Status |
| --- | --- | --- |
| Outbox delivers a run's events in seq order; backoff exponent clamped | `agent-runtime/lib/vibe_agents/outbox.ex:53-103` | done, tests pass |
| `x-vibe-service` is part of the HMAC signing string (probe.js + docs synced) | `contracts/lib/vibe_contracts/service_auth.ex` | done, contracts 90/0 |
| Replay cache is a supervised `VibeContracts.NonceStore`; verify fails closed | `contracts/lib/vibe_contracts/nonce_store.ex`, `application.ex` | done |
| PublicRateLimit ETS table created in `Application.start` (was per-request, never limited) + X-Forwarded-For hop handling | `agent-runtime/lib/vibe_agents_web/plugs/public_rate_limit.ex` | done |
| Provider task status requires the provider secret | `agent-runtime/.../provider_controller.ex:66-76` | done; test at provider_controller_test.exs:65 rewritten, re-run needed |
| IDOR: body `user_id` must equal the session user | `business_controller.ex:38-44`, `subscription_controller.ex:60-66,92-98` | done |
| SafeURL blocks IPv4 private ranges, ::1, ::ffff:, fc00::/7, fe80::/10 | `server/lib/vibe/net/safe_url.ex` | done |
| Sandbox-side URL guard + egress filter | `deploy/sandbox/safe-url.js`, `deploy/egress-proxy/filter` | done |
| Container check: only Caddy publishes a port (loopback), `/internal/*` 403 on every vhost, one env file per service | `deploy/compose.yml`, `deploy/caddy/Caddyfile` | verified |

## Done — all five briefs landed 2026-09-08
Implemented in this tree rather than by the worker CLIs (`agy` was off the Bash allowlist, since added; `codex exec` was rate limited). Verified: server 491, contracts 90, agent-runtime 121 tests, 0 failures; `cargo check` clean and `runtime::files` 7 passed.

| Brief | What it fixes |
| --- | --- |
| W1 `0908-w1-receipts.md` | Durable run-event dedup: `agent_run_receipts(run_id, last_seq)` high-water mark replaces the ETS table that `internal_agent_controller.ex:204-209` creates inside the request process (it dies with every request, so duplicates were never caught: double text deltas, possible double usage). Also `agent_relay.ex:198-241` must not broadcast `text: ""` when the run has no state. |
| W2 `0908-w2-server-data.md` | `list_chats_uncached` ranked query (`chat.ex:358-379`) fetches the id+rank of every visible message in every chat of the user and filters in Elixir; move the limit into a SQL subquery. Stories hidden between blocked users (either direction). `Vibe.Retention`: prune `audit_events` (365d) and `agent_run_receipts` (30d) in 5000-row batches. |
| W3 `0908-w3-runtime-retention.md` | `VibeAgents.Retention`: prune delivered `outbox_events` (7d) and `agent_run_events` of runs finished > 30d; both tables grow without bound today. Confirm provider_controller_test passes. |
| W4 `0908-w4-deploy-db.md` | sandbox-gateway `cap_drop ALL`, `read_only`, healthcheck; `work_mem 8MB`; PgBouncer `default_pool_size 25`, `max_db_connections 80`; WAL archiving (`archive_mode on`, `/wal_archive` volume, `wal-ship.sh` every 15 min to R2, weekly `pg_basebackup`, PITR restore procedure) taking RPO from 6h to 5min; `postgres-exporter` + Prometheus scrape + Grafana alerts (pg down, archiver failures, connections, deadlocks, disk). |
| W5 `0908-w5-gateway.md` | `sandbox-gateway/src/runtime/files.rs:42-56` collects the container tar in memory unbounded; cap at 64 MiB → 413. Ensure the image has `wget` for the healthcheck. |

## Decisions (do not re-litigate)
- **RLS is inactive.** `vibe_core_app` runs migrations and serves traffic, so it owns every table; no table has `FORCE ROW LEVEL SECURITY`, so the messages/group_agents/group_agent_memory/group_agent_documents policies never apply. Do not flip FORCE: every `Repo` call outside `Vibe.RepoRLS.with_user` would break. Real fix later: separate migration-owner role, app role non-owner, audit call sites (N000371).
- **No read replica yet.** Single node, no read/write split in code. PITR via WAL archive is today's step; a streaming standby needs a second box.
- **Caches** (`Vibe.Cache`, `ChatHomeCache`, `TokenCache`) are node-local ETS with PubSub invalidation; fine while `CLUSTER_STRATEGY` is empty. Multi-node needs a Valkey-backed cache first.
- **Ecto stays `prepare: :unnamed`** behind PgBouncer transaction mode; no `max_prepared_statements` change.
- **Deferred, do not patch without a coordinated change:** per-direction HMAC subkeys (contracts + `sandbox-gateway/src/auth.rs` + `probe.js`), SafeURL DNS-rebinding pin (resolve → validate → pin IP, keep Host/SNI), team-computer run-id attestation and token revocation (N000361/N000362).

## Known pre-existing warnings
`mix compile --warnings-as-errors` in `server/` fails on `gettext.ex:5` (deprecated `use Gettext, otp_app:`) and `encryption_controller.ex:5` (unused `id`). Not regressions.

## Deploy notes — verified against the VPS 2026-09-08
- `postgres-exporter` has an `env_file` that does not exist on the box yet. Safe here: podman-compose 1.0.6 fails that one service (`exit code: 125`), starts every sibling, and exits 0, so `deploy.sh` `set -e` never trips. Docker-compose abort-the-whole-`up` semantics do not apply. Expect one `Error: parsing file` line in the deploy log and a Prometheus target-down alert until the box step runs.
- `postgresql.conf` is bind-mounted and `deploy.sh` starts postgres with `--no-recreate`, so `archive_mode = on` and the new `work_mem` do not take effect on merge. A later plain restart would read the new conf without the `/wal_archive` mount and fail every archive, retaining WAL until the disk fills. Recreate postgres (stop, rm, up) right after the deploy; same for pgbouncer, backup and sandbox-gateway, whose changes are deferred the same way.
- Containers run rootless as `vibe` (uid 1000); root has a separate, empty podman store. Run `ensure-readonly-role.sh` as root with `ENGINE` pointed at the rootless store. It now reads `/run/vibe/env/postgres.env` when the plaintext is sealed away, and writes `postgres-exporter.env` from the same password.
