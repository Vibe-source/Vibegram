# Security & production-readiness gap analysis — 2026-08-28

Method: the server (`server/`), the agent path, and the deployment were checked against the
AssuranceBuild Runtime (ABR) production-readiness taxonomy (the research report in Downloads,
2026-08-13: §2.1–§2.33 platform controls, §3 AI controls, §8 launch blockers). Every row cites the
file that proves the status. "This run" = what the `agentv1-0828` delivery adds
(`docs/agent-platform-v1.md`). Earlier audits this builds on:
`production-readiness-audit-2026-07.md` (S1–S7), `mls-audit-2026-08-28.md`.

Legend: ✅ present · 🟡 partial · ❌ missing · 🆕 delivered/added in this run.

## 0. Verdict

The core is a **solid Phoenix foundation with real authorization, HMAC-verified webhooks,
parameterized queries and an E2E migration underway (MLS)** — but it was **never operated as a
production system**: no CI, no metrics, no audit log, no tested restore, one global 120 MB body
limit, 30-day bearer tokens with no logout, and the agent brain sharing the process, env and
database credentials of the messenger. The isolation, broker, budgets, sandbox, headers, body
limits, token lifecycle, audit log and deploy stack in this run close the architecture-level
blockers. What remains is mostly **operational evidence** (CI gates, restore drills, load tests,
alerting) and three product-level items (MFA/step-up, GDPR export/wipe, admin plane).

## 1. Identity, authentication, sessions (ABR §2.1, §2.3, §2.4)

| Control | Status | Evidence / gap | This run | Remaining |
|---|---|---|---|---|
| Password hashing | ✅ | PBKDF2-SHA512 600k iterations, salted (`auth_controller.ex:8-53`); legacy-iteration upgrade path (`Accounts.upgrade_password_hash`) | — | Consider Argon2id when the client key-wrap flow allows (docs claim it; code does not) |
| Auth secret split from key-wrap | ✅ | `authSecret = HKDF(recovery)` vs `kek`; raw recovery secret never reaches the server (`auth_controller.ex:57-67`, `upgrade_identity`) | — | — |
| Bearer token lifetime | 🟡 | UUIDv4 `login_token`, 30-day sliding expiry (`Accounts.maybe_slide_token_expiry`), **no absolute lifetime, no logout** | 🆕 `users.token_issued_at`, `AUTH_TOKEN_MAX_LIFETIME_DAYS` (90), `POST /api/auth/logout`, `/logout-all`, `Accounts.revoke_login_token/1` | Rotate token on privilege changes (identity upgrade already re-issues) |
| Brute force / credential stuffing | 🟡 | Rate limit 10/min per IP on `/login` (`rate_limiter.ex`); nothing per account | 🆕 `Vibe.Accounts.LoginThrottle` (10 failures / 15 min per username, generic 401) | Device-bound sessions for admins (none exist yet) |
| Account enumeration | 🟡 | Login is generic; **register leaks phone-number ownership** ("Phone number already in use", `auth_controller.ex:46`) and username (public by design) | 🆕 login/lock responses unified | Change phone conflict to a verification-code flow (needs SMS) — product decision |
| MFA / passkeys / step-up | ❌ | None. The account password also wraps the E2E private key, so MFA must not be a server-only gate | — | Phase 2: passkey-bound device sessions (`device_sessions` already exist) + step-up for `/user/delete`, secret rotation, device revoke |
| Session inventory / revocation | ✅ | `GET/DELETE /api/account/sessions`, `revoke_device`, `TokenCache.invalidate_user` on every user write (`accounts.ex:306`, `token_cache.ex`) | 🆕 audit events on revoke | — |
| Recovery | 🟡 | Recovery phrase is client-side; no email/SMS reset (nothing to attack server-side) | — | Document: lost phrase = lost account (privacy product), and test the multi-device link flow negative cases (`device_link_requests`) |
| Secrets in logs/URLs | 🟡 | Tokens in headers (`x-vibe-auth`, not query) ✅; July audit removed content from prod logs; nothing scrubs an accidental token | 🆕 `Vibe.LogScrub` Logger filter; `config :logger, level: :notice` in prod | — |

## 2. Authorization (ABR §2.2)

| Control | Status | Evidence | This run | Remaining |
|---|---|---|---|---|
| Object-level checks on chat/message routes | ✅ | `Chat.is_participant?` before message reads/writes, delete (`chat_controller.ex`, July audit ✓) | 🆕 membership cache with cluster invalidation (`Vibe.Cache`) — same semantics | Negative tests: `security_auth_test.exs` (this run) + add IDOR tests for stories, saved messages, pinned messages |
| Bridge / relay channel authz | ✅ | `bridge_owns_chat?` on every chat-targeted bridge event (`agent_bridge_channel.ex:741`); relay client join now checks `client_authorized?` (`relay_channel.ex:44-62`) and `register_relay` returns `:forbidden` on ownership conflict | — | Add a test proving a second user cannot `update_relay` another user's relay id |
| Agent ownership | ✅ | Every agent mutation resolves `(agent_id, owner_user_id)` (`agents.ex:65-86`, `agent-turn-contract.md` rules) | 🆕 `Agent.owner_changeset/2` (owner cannot cast secret hashes/status) | — |
| Privileged fields in changesets | ❌→🆕 | `User.changeset` casts `login_token`, `password_hash`, `tier` (`user.ex:65-78`); `Agent.changeset` casts secret hashes; `Participant` casts `role` | 🆕 `User.profile_changeset/2` + `Accounts.update_profile/2`; `Agent.owner_changeset/2` | `Participant.role` still cast broadly — only set through `set_member_role` today; add a test |
| Row-level security | 🟡 | RLS **enabled** on `messages`, `group_agents`, `group_agent_memory`, `group_agent_documents`; `RepoRLS.with_user` sets `app.current_user_id`; **not FORCE'd**, so the table owner (the app role today) bypasses it | 🆕 VPS creates a separate owner role; the app keeps connecting as owner for now (documented in `vps-deployment.md`) | Decide: FORCE RLS + non-owner app role (requires auditing every `with_user(nil)` system path) or keep RLS as defense-in-depth. Not a launch blocker while app-level checks are complete |
| Service-to-service authz | ❌→🆕 | Agent runtime ran in-process with full env | 🆕 `vibe-internal-auth/v1` HMAC (timestamp + nonce + body hash), internal routes not exposed through Caddy, per-service secrets | mTLS between containers when a second host appears |
| Admin / support plane | ❌ (none exists) | No admin endpoints; operations go through the DB | — | Minimal audited ops CLI (`bin/vibe rpc`) for disable-user / disable-agent / kill-switch; never a web admin without step-up |

## 3. Secrets, keys, cryptography (ABR §2.5, §2.6)

| Control | Status | Evidence | This run | Remaining |
|---|---|---|---|---|
| No secrets in git | ✅ | `.env` untracked (`git ls-files`), `.railwayignore`/`.gitignore` cover it | — | Add pre-commit secret scan (gitleaks) once CI exists |
| Secret scanning in CI | ❌ | **No `.github/workflows` at all** | — | CI: `mix test`, `mix deps.audit`, `npm audit`, `cargo audit`, gitleaks, `mix format --check-formatted` — see §10 |
| Centralised secrets / scoping | 🟡 | Railway env; one process holds DB creds, Supabase service key, model keys, APNs key, HMAC pepper | 🆕 Three env files, three services: model keys move to the runtime, sandbox gets nothing, gateway gets one token | Vault/SOPS for the VPS env files; rotate `SUPABASE_SERVICE_KEY` to a least-privilege key |
| Agent secrets at rest | ✅ | Hash + AES-GCM-encrypted callback secret, one-time reveal, rotation with grace (`agents.ex:1239-1321`) | 🆕 provider ingress validates through the core; runtime never stores secrets | Scoped API keys (`vak_…`) with per-key scopes — phase 2 |
| Message crypto | 🟡 | 1:1 hybrid RSA-OAEP + AES-GCM (no FS) → MLS rollout (`mls-audit-2026-08-28.md`); groups/channels **plaintext on the server**; agent chats plaintext by design (`AgentMessageCrypto.encrypt_for_storage` is server-keyed) | — | MLS audit items 1–5 (downgrade pinning, safety-number UI, sealed MLS DB, retention forget hook, Android pushPreview) |
| DB TLS | ✅ | verify_peer with Supabase root + bundle by default (`runtime.exs:83-174`) | 🆕 VPS: Postgres on the internal network, `ssl off` documented; enable when the DB leaves the host | — |
| Key inventory & rotation | 🟡 | `VIBE_HMAC_SECRET` has a `_LEGACY` rotation path; callback-secret key derivation documented; no rotation runbook for `SECRET_KEY_BASE`, APNs, R2 | 🆕 `deploy/scripts/gen-secrets.sh`, rotation list in `vps-deployment.md` | Quarterly rotation calendar |

## 4. API, input, SSRF, uploads (ABR §2.7–§2.10)

| Control | Status | Evidence | This run | Remaining |
|---|---|---|---|---|
| Request size limits | ❌→🆕 | One global 120 MB parser limit for every route (`endpoint.ex:4-7`) | 🆕 JSON 2 MB default (`MAX_JSON_BODY_BYTES`), multipart 120 MB only on the upload pipeline, `VibeWeb.Plugs.BodyLimit`; Caddy `request_body` caps | — |
| Security headers | ❌→🆕 | None set by the app | 🆕 `VibeWeb.Plugs.SecurityHeaders` (HSTS, nosniff, frame-deny, referrer, permissions, COOP, CSP on SPA routes) + Caddy headers | — |
| Input validation | 🟡 | Ecto changesets + explicit parsing; no shared schema layer; `vibe.content.v1` validator rejects only malformed frames by design | 🆕 `VibeContracts.RunEvent.validate/1`, `AskQuestion.normalize/1` for the agent contract | JSON schema for provider `invoke`/`events` bodies (phase 2 with API keys) |
| Endpoint-specific rate limits | ✅ | auth / api / strict / public_agent / ai_media buckets; per-socket `ChannelThrottle` (2026-08-28) | 🆕 backend behaviour, Valkey option for multi-node | Cost-weighted quotas (see §7) |
| Idempotency | 🟡 | Provider events unique `(agent_id, event_id)`; client message ids dedupe; LemonSqueezy webhook HMAC | 🆕 runtime `idempotencyKey` on runs, `Idempotency-Key` on `/v1` ingress, `(runId, seq)` dedupe on events | — |
| SSRF | ✅ | `Vibe.Net.SafeURL` on all user-URL fetches since July (`safe_url.ex`); yt-dlp URL resolve fixed (`prelaunch-security-audit`) | 🆕 `VibeContracts.SafeURL` for the runtime; sandbox egress default-deny via proxy allowlist; `browser.js` blocks private ranges | Redirect-following policy audit when Finch options change |
| Uploads | ❌→🆕 | No MIME/magic validation, 120 MB to a public bucket (`media_controller.ex`) | 🆕 magic-byte checks per type, per-type caps, random names, `attachment` disposition for unknown types | Malware scanning (ClamAV sidecar) — optional; isolated serving domain for user files |
| API versioning / inventory | 🟡 | `/api` unversioned; `router.ex` is the inventory | 🆕 `/v1` for the runtime; internal API under `/internal/v1` | Deprecation policy doc for `/api/agents/:identifier/*` once providers move |

## 5. Supply chain, CI/CD, infra, network (ABR §2.11–§2.14)

| Control | Status | Evidence | This run | Remaining |
|---|---|---|---|---|
| Lockfiles | 🟡 | `package-lock.json` and `Cargo.lock` are committed; **`server/mix.lock` is git-ignored** (`.gitignore:141`), so every Docker build re-resolves Elixir deps — not reproducible, and a compromised upstream release lands silently | 🆕 the new `contracts/` and `agent-runtime/` lockfiles are committed | Un-ignore `server/mix.lock` and commit it (one-line change, no behaviour risk) |
| Dependency scanning / SBOM / provenance | ❌ | no CI | — | §10 CI plan; pin Docker base images by digest |
| CI/CD | ❌ | Railway deploys from `main` with no gate; no protected branch evidence | 🆕 `deploy/scripts/deploy.sh` with migration step, health gate and `--rollback` | GitHub Actions: build + test + scan + image publish; require green before `deploy.sh` |
| IaC / reviewed infra | ❌→🆕 | Railway UI config | 🆕 `deploy/compose.yml`, Caddyfile, postgres/pgbouncer/valkey config, bootstrap script, systemd unit — all in git | Terraform for DNS/R2 when there is more than one box |
| Least-privilege runtime | ❌→🆕 | One container as `nobody` with everything | 🆕 per-service containers, `cap_drop ALL`, `no-new-privileges`, read-only rootfs, internal networks, only Caddy publishes ports, sandboxes on an `internal: true` network | Rootless podman on the host (bootstrap does it); the gateway's socket mount is the one privileged edge — documented |
| Network segmentation / egress | ❌→🆕 | Flat Railway network | 🆕 `edge` / `internal` / `sandbox-net`; sandbox egress only through the allowlist proxy; metadata endpoints unreachable | WAF/CDN in front of Caddy (Cloudflare proxy) — ops decision |
| Public DB / storage exposure | 🟡 | Supabase DB behind pooler; **media bucket is public-read by URL** (`supabase_storage.ex`); R2 objects private with presigned GET | — | Move all media to the private R2 path (`Vibe.Storage.backend/0 = :r2`) before public launch |

## 6. Reliability, data, caching, jobs, backups (ABR §2.16–§2.23)

| Control | Status | Evidence | This run | Remaining |
|---|---|---|---|---|
| Timeouts | 🟡 | DB `timeout: 30_000`, Finch defaults; no `statement_timeout` | 🆕 `DB_STATEMENT_TIMEOUT_MS` (30 s), slow-query telemetry (`Vibe.Telemetry.SlowQuery`), gateway exec timeouts, run wall-clock cap | Explicit Finch receive timeouts on every outbound call (audit list) |
| Retries / backoff / circuit breakers | 🟡 | LLM fallback Claude→OpenAI; no circuit breakers; `Task.start` fire-and-forget in many paths (July) | 🆕 runtime outbox with exponential backoff; one retry only on idempotent calls | Supervised task pools for push/notification fan-out; breaker on provider 5xx storms |
| Backpressure / bulkheads | 🟡 | `Vibe.AI.WorkerTaskSupervisor` max 8; `ChannelThrottle` | 🆕 runtime `SANDBOX_MAX_CONTAINERS`, per-agent single computer, budgets | Queue-depth limits for the scheduler/outbox with alerts |
| Idempotent consumers | 🟡 | Scheduler post is non-atomic (July, still open: `scheduler.ex`) | 🆕 `(runId, seq)` dedupe in the core relay | Make `Vibe.Scheduler` lease rows atomically (`FOR UPDATE SKIP LOCKED`) |
| DB constraints / migrations | ✅ | Unique constraints on invocations, decision tokens, participants; 55 migrations run on boot via `Vibe.Release.migrate` | 🆕 migrations run against Postgres directly (`MIGRATION_DATABASE_URL`), never through PgBouncer; concurrent index migration | Backward-compatible migration policy for rolling deploys (document) |
| Connection pooling | ❌→🆕 | `pool_size 20`, Supabase pooler | 🆕 PgBouncer transaction pooling (`prepare: :unnamed` already set), sized pools, `application_name` | pg_stat_statements review after a week of traffic |
| Caching correctness | 🟡 | ETS caches keyed by user/chat/token with TTL + invalidation; **node-local** (split-brain on 2 replicas, July S5) | 🆕 `Vibe.Cache` with PubSub invalidation; libcluster wiring; Valkey rate-limit backend | Enable `CLUSTER_STRATEGY` only after a two-node soak |
| Queues / DLQ | 🟡 | `AgentDeliveryScheduler` retries; no DLQ | 🆕 `outbox_events` with attempts + `next_attempt_at` | Dead-letter after N attempts + alert |
| Backups / restore | ❌ | Supabase-managed; **restore never tested** | 🆕 `backup.sh` (encrypted `pg_dump` → R2, 6 h, retention) + `restore.sh` that restores to a scratch DB and verifies before swapping | Run the drill before cutover and monthly; RPO 6 h / RTO 1 h documented |
| Graceful degradation | 🟡 | LLM fallback; push failures logged | 🆕 kill switch for agents (`VIBE_AI_KILL_SWITCH`, `VIBE_AGENTS_KILL_SWITCH`) | Define behaviour for Valkey down (fails open to ETS ✅), runtime down (embedded fallback with warning ✅), R2 down |

## 7. Rate limits, quotas, denial-of-wallet, cost (ABR §2.15, §2.30, §3.9)

| Control | Status | Evidence | This run | Remaining |
|---|---|---|---|---|
| Layered limits | 🟡 | per-IP (unauth) / per-user (auth) / per-endpoint buckets; per-socket throttle | 🆕 per-secret public bucket on `/v1`; per-agent computer; `SANDBOX_MAX_CONTAINERS` | Per-tenant (owner) ceilings across all their agents |
| AI cost quotas | 🟡 | `ai_media` 10/5 min; agent `cost_budget_daily/monthly` enforced only on the event path (`agent_event_runtime.ex:1037`) | 🆕 runtime `VibeAgents.Budget`: per-run token ceiling, per-agent daily/monthly cents from `agent_usage_ledger`, max steps 24, wall clock 20 min, max tool failures 6, handoff depth 4 | Global monthly ceiling per provider key (provider-side hard limits + alert); cost-weighted request units on `/api/agent/chat` |
| Emergency stop | ❌→🆕 | none | 🆕 `VIBE_AI_KILL_SWITCH` (core dispatch), `VIBE_AGENTS_KILL_SWITCH` (runtime refuses + cancels) | One-command ops script that flips both and restarts (`deploy/scripts/status.sh` shows state) |
| Runaway loops | 🟡 | `max_depth 12` in the embedded loop | 🆕 runtime caps above; cancel from the phone | — |

## 8. Observability, SLOs, alerting, incident response (ABR §2.24–§2.27)

| Control | Status | Evidence | This run | Remaining |
|---|---|---|---|---|
| Structured logs | 🟡 | Logger with request_id; prod `:info` | 🆕 `:notice` + scrubbing; Caddy JSON access logs | JSON logger + shipping (Loki/Vector) — optional profile |
| Metrics | ❌→🆕 | none | 🆕 Prometheus exporter on `METRICS_PORT` (phoenix, repo, VM, rate-limit blocks); `monitoring` compose profile | Dashboards for the critical path (login, send, agent run) |
| Audit events | ❌→🆕 | none | 🆕 `audit_events` (login, logout, register, profile, device/session revoke, identity upgrade) + runtime `agent_run_events` (every tool call) | Extend to agent publish/secret rotation/approval decisions (partially via `agent_approval_tasks`) |
| Readiness / health | 🟡 | `/api/health` | 🆕 `/api/ready` (DB), runtime `/healthz` `/readyz`, gateway `/healthz`, compose healthchecks | — |
| SLOs | ❌ | none | proposed below | Adopt and wire alerts |
| Alerting | ❌ | none | monitoring profile ships Prometheus; no rules | Alert rules (below) + an on-call contact |
| Incident response | ❌ | none written | `vps-deployment.md` has rollback/restore/kill-switch runbooks | Severity levels, comms path, credential-rotation runbook |

Proposed SLOs (measure from the new metrics): login success ≥ 99.5 %; message send ack p95 ≤ 400 ms;
API 5xx ≤ 0.5 %; agent run completion ≥ 95 % (excluding user cancels); tool execution success ≥ 97 %.
Alerts: 5xx burn, DB pool saturation (`queue_time` p95 > 200 ms), rate-limit block spike ×10,
auth failure spike, sandbox container count ≥ 90 % of max, agent cost/hour > budget, backup job
failed, disk > 80 %, cert expiry < 14 d.

## 9. AI-specific controls (ABR §3)

| Control | Status | Evidence | This run | Remaining |
|---|---|---|---|---|
| Prompt injection isolation | 🟡 | Prompt policy text (`agentic_policy.ex`); tool results are data; no explicit trust labels | 🆕 broker decides authority, not prompts; retrieved text can never grant a capability; sandbox has no keys | Red-team suite (§10) |
| Capability broker | ❌→🆕 | none — the model called core functions directly | 🆕 `VibeAgents.Broker` risk matrix × autonomy modes, explicit `request_approval`, `credential` class always asks the human | — |
| Sandboxing | ❌→🆕 | tools ran inside the chat server process | 🆕 `sandbox-gateway`: rootless containers, cap-drop, read-only rootfs, pids/mem/cpu limits, no secrets, allowlisted egress, idle reaper | Per-agent disk quota; gVisor/microVM if untrusted code volume grows |
| Approval for irreversible actions | 🟡 | runbook approvals + declared decisions (event path only) | 🆕 approvals for every run: `run.approval.requested` → decision message → `POST /api/decisions/actions` → runtime; permission requests; cancel from the phone | Approval expiry sweeper for runtime decisions (runtime `Resumer`) |
| Model/provider failure | ✅ | Claude → OpenAI fallback, sticky per turn | 🆕 kill switch, budgets | Regression evals before model migrations |
| Memory privacy | 🟡 | `group_agent_memory` under RLS; standalone agent memory is chat history | 🆕 `agent_memories` scoped by `agent_id`, run-attributed | Deletion propagation when an agent is deleted (add to `archive_agent`) |
| Output validation | ✅ | typed tool schemas; `vibe.content.v1` validation; `AskQuestion` normalization | 🆕 `RunEvent` validation, redaction of tool inputs before they leave the runtime | — |
| Evals / red team | ❌ | none | — | §10 |

## 10. What is still missing after this run (owner · phase)

1. **CI pipeline** (ops · before cutover): GitHub Actions running `mix test` (core, runtime, contracts),
   `cargo test`, `mix deps.audit`, `npm audit --omit=dev` (bridge), `cargo audit`, gitleaks, Docker image build;
   protected `main`; `deploy.sh` refuses to deploy an untested SHA.
2. **Restore drill** (ops · before cutover): run `restore.sh` against a fresh VPS, record RPO/RTO.
3. **Load test** (eng · before cutover): 500 concurrent sockets sending 5 msg/s, 50 concurrent agent
   runs, 20 sandboxes — watch DB pool queue time, memory, sandbox CPU.
4. **Prompt-injection red-team suite** (eng · phase 1): 30 cases — web page instructing the agent to
   exfiltrate history, tool result containing `ignore previous`, hidden text in an uploaded document
   asking to `computer_run curl -X POST`, handoff loops between two agents, approval-bypass attempts
   through `browser_act` labels. Every case must end in `deny`/`approval` — assert on `agent_run_events`.
5. **MFA / step-up** (product · phase 2): passkey-bound device session + step-up on account delete,
   agent secret rotation, device revoke, payment changes.
6. **GDPR export + real account wipe** (product · phase 2): `/user/delete` today leaves messages,
   media, agent rows; needs a tombstone + purge job and an export bundle.
7. **Scoped provider API keys** (`vak_…`) with scopes, rotation, per-key limits — replaces the single
   agent secret on `/v1`.
8. **Media to private storage** — public Supabase bucket URLs are the last unguarded data path.
9. **FORCE RLS decision** and the `Participant.role` changeset split.
10. **Ops admin CLI** with audit for disable-user / disable-agent / kill-switch.

## 11. Launch-blocking conditions (ABR §8) — status

| Blocker | Status |
|---|---|
| Authentication bypass | none known ✅ |
| Broken tenant isolation / IDOR on sensitive objects | none known; negative tests partial 🟡 |
| Exposed production secrets | none in git ✅; env rotation on cutover required |
| Public database/storage unintended exposure | media bucket public-read by URL 🟡 (item 8) |
| Critical exploitable dependency without mitigation | unknown — no scanning ❌ (item 1) |
| Agent has unrestricted production credentials | **closed by this run** (isolated runtime, sandbox with no keys) 🆕 |
| Unsafe arbitrary outbound network from a privileged agent sandbox | **closed by this run** (allowlist proxy, internal network) 🆕 |
| High-impact action without authorization boundary | **closed by this run** (broker + approvals) 🆕 |
| No tested rollback | `deploy.sh --rollback` exists; untested until first VPS deploy 🟡 |
| Destructive migration without recovery plan | backups + restore script 🆕; drill pending 🟡 |
| Unbounded retry loop | outbox backoff 🆕; provider fan-out audit pending 🟡 |
| No timeout on critical external dependency | DB/LLM/gateway timeouts 🆕; Finch audit pending 🟡 |
| No production monitoring / owner / kill switch / cost ceiling | metrics + kill switches + budgets 🆕; alert rules + on-call ❌ |
