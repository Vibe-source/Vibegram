# Security fix map — where each open gap gets fixed

Actionable companion to `security-readiness-gap-2026-08.md` and `mls-audit-2026-08-28.md`:
one row per gap, the exact place to fix it, and the recipe. Written 2026-08-29 so any agent
can pick a row and execute it without re-deriving the diagnosis. Update the Status column
when you land a fix.

Status legend: ✅ fixed · 🔧 in flight (this run) · ⏳ open · 🧊 product decision needed.

## A. Fixed in this run (2026-08-29)

| Gap | Where | What was done | Status |
|---|---|---|---|
| `server/mix.lock` git-ignored → non-reproducible builds, silent upstream compromise | `.gitignore` (removed `server/mix.lock` line) | Lockfile now tracked; commit it with the next commit | ✅ |
| Scheduled-post dup delivery: post-then-mark race (every node posts on multi-node) | `server/lib/vibe/scheduler.ex` `execute_post/1`, `server/lib/vibe/chat.ex` | Atomic `claim_scheduled_post/1` (UPDATE … WHERE status='pending' RETURNING) before any side effect; `reopen_scheduled_post/1` on delivery failure; `mark_post_as_posted` removed | ✅ |
| `Participant.role` cast from generic attrs (future privilege-escalation foot-gun) | `server/lib/vibe/schemas/participant.ex`, call sites in `server/lib/vibe/chat.ex` (`add_member`, `set_member_role`, `insert_channel_subscriber`) | `role` removed from `cast`; new `role_changeset/2` guard-listed — role can only be set by explicit code | ✅ |
| `TRUSTED_PROXY_HOPS` absent from deploy env → XFF rate-limit bypass if prod forgets it | `deploy/env/core.env.example` | Added with comment (1 = Caddy only, 2 = CDN+Caddy). **Prod cutover: set to real depth** | ✅ |
| Relay impersonation (A1, July advisory) | `server/lib/vibe/relay_registry.ex:70-88`, `relay_channel.ex` | Verified already fixed: every `update_relay` passes `as_user`, ownership enforced, `user_id` reassignment dropped, negative tests exist (`relay_registry_test.exs:69`) | ✅ (stale advisory) |

## B. Also fixed this run (usage / routines slices)

Verified: server 408/408, agent-runtime 75/75, contracts 84/84 tests pass.

| Gap | Where | What was done | Status |
|---|---|---|---|
| Per-tenant (owner) cost ceilings across all agents — denial-of-wallet | `server/lib/vibe/agent_usage.ex` (new); gates in `agent_gateway.ex` `start_run` + `standalone_agent.ex` `invoke` | Monthly tier credits (env `AGENT_CREDITS_*_CENTS`), `agent_usage_events` ledger (idempotent on `run_id`), `check_entitlement` fail-closed before every model call; "out of credits" notice in chat. `responseMode: "post"` stays ungated (no model in path) | ✅ |
| Usage metering loss: runtime ledger insert error silently discarded | `agent-runtime/lib/vibe_agents/budget.ex` `record_usage` | Insert failures now logged; sandbox-seconds metered into the ledger and the `run.completed` payload | ✅ |
| Stale/orphaned runs (queued rows stranded at boot; abandoned waits forever) | `agent-runtime/lib/vibe_agents/runs/resumer.ex`, new `runs/janitor.ex` | Resumer re-arms `queued`; hourly janitor cancels waiting runs > 7 d and fails `running` rows with no live Registry entry | ✅ |
| Routine abuse (credit-burn loops, posting into foreign chats) | `server/lib/vibe/agent_routines.ex` (new) | Owner + both-participants checks on create, min interval 15 min, max 20/owner, auto-disable after 5 consecutive failures, `FOR UPDATE SKIP LOCKED` claim | ✅ |
| Rate table duplicated between services | `contracts/lib/vibe_contracts/model_rates.ex` (new) | Single shared `ModelRates`; core and runtime price identically | ✅ |

## C. Open — code-local, an agent can do each in one sitting

| Gap | Where to fix | Recipe |
|---|---|---|
| MLS-1 hybrid downgrade: "no KeyPackage" → silent fallback to unpinned RSA-2048 (MITM on never-established DMs) | iOS `ios/ChatModule/VibeSecureEstablishment.swift` (`markPeerKeysUnavailable` path) + send paths in `ChatEngine.swift` | Never silently downgrade a *never-established* DM: hold the send and surface "establishing secure channel…" until a KeyPackage exists, or pin the RSA key to the MLS identity before first use. NOTE: `ChatEngine.swift`/`VibeSecureTrust.swift` are owned by the MLS session — coordinate, don't collide |
| MLS-4 retained plaintext has no forget hook (deleted/view-once recoverable) | core `core/vibe_secure` retained.v1 store + iOS delete/tombstone paths | Add `forget(messageId:)`; call it from delete + view-once tombstone handlers |
| MLS-3 MLS state DB plaintext at rest (signature/HPKE/epoch secrets in SQLite JSON) | iOS MLS storage setup (openmls_sqlite_storage path) | Seal like the core store: SQLCipher or app-level AES seal keyed from Keychain (`store-seal-at-rest` pattern) |
| MLS-5 Android sends `pushPreview` plaintext | `android/…/ChatEngine.kt` | Strip `pushPreview` from the wire payload exactly as iOS did |
| SafeURL DNS-rebind TOCTOU (A3) | `server/lib/vibe/net/safe_url.ex` + every Finch fetch of user URLs | Resolve once, pin the vetted IP for the actual connection (Finch `:transport_opts` custom `:inet` resolver or connect-by-IP with Host header), re-verify on redirect |
| Phone-number enumeration on register (A2) | `server/lib/vibe_web/controllers/auth_controller.ex:46` | Replace "Phone number already in use" with a generic response + verification-code flow (needs SMS provider) 🧊 product |
| TURN credential TTL 24 h (A4) | TURN cred minting (`turn` config in server) | Drop TTL to 1–4 h; creds are HMAC-derived so no state change |
| Media bucket public-read by URL | `server/lib/vibe/supabase_storage.ex` → `Vibe.Storage.backend/0 = :r2` | Part of the R2 migration in the VPS cutover: private R2 objects + presigned GET; kill public Supabase URLs |
| Audit events don't cover agent publish / secret rotation / approval decisions | `server/lib/vibe_web/controllers/agents_controller.ex` (`publish`, `rotate_secret`, `approve_task`, `reject_task`) | Emit `audit_events` rows (table exists, `20260828121000`); copy the login/revoke call pattern |
| Outbox has no dead-letter | `agent-runtime/lib/vibe_agents/outbox.ex` `backoff/1` | After N attempts (e.g. 50) set `delivered_at`-style `dead_at`, log at error, expose count in metrics |
| `Vibe.Scheduler` still loads ALL pending posts into node-local timers | `server/lib/vibe/scheduler.ex` | Now claim-safe (dup fixed); optional: move to DB polling like `ChannelAgentScheduler` to drop the timer map entirely |
| Finch receive-timeout audit | every `Finch.request` call site (`agix grep "Finch.request"`) | Explicit `receive_timeout:` on each outbound call; list + fix in one pass |
| `with_user(nil)` FORCE RLS decision | `server/lib/vibe/repo_rls.ex` + system call sites | Either FORCE RLS + non-owner app role (audit every `with_user(nil)` first) or document RLS as defense-in-depth only 🧊 |

## D. Open — operational (before/at VPS cutover)

| Gap | Where | Recipe |
|---|---|---|
| No CI | `.github/workflows/` (new) | `mix test` (server, agent-runtime, contracts) + `cargo test` (sandbox-gateway) + `mix deps.audit`, `npm audit --omit=dev`, `cargo audit`, gitleaks; protected `main`; `deploy.sh` refuses untested SHA |
| Restore never tested | `deploy/scripts/restore.sh` | Run against a scratch DB on the new VPS before cutover; record RPO/RTO |
| Load test | — | 500 sockets × 5 msg/s, 50 agent runs, 20 sandboxes; watch pool queue time + memory |
| Alert rules + on-call | `deploy/prometheus/` | Rules from gap doc §8 (5xx burn, pool saturation, auth spike, sandbox ≥90 %, cost/hour, backup fail, disk, cert expiry) |
| Prompt-injection red-team suite | `scripts/security-probe/` (extend) | 30 cases from gap doc §10.4; assert every case ends in deny/approval via `agent_run_events` |
| Secrets rotation calendar; Vault/SOPS for VPS env | `deploy/` docs | Quarterly; rotate `SUPABASE_SERVICE_KEY` out entirely at R2 cutover |

## E. Phase 2 (product)

MFA/passkey step-up (delete, secret rotation, device revoke) · GDPR export + real account
wipe (tombstone + purge job) · scoped provider API keys (`vak_…`) · admin ops CLI with audit
(disable-user/agent, kill-switch) · per-agent sandbox disk quota (gVisor if untrusted volume grows).
