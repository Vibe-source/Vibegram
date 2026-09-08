# Production-readiness audit — server + web client (2026-07-17)

Method: two read-only agent audits (Codex on `server/`, Grok on `client/`), each
finding cited to `file:line`; the top server security findings and two client
findings **re-verified against source by the reviewer** (noted ✓). Static only —
no production DB / Railway state inspected, so anything about *applied* migrations,
env values, or replica count is marked uncertain.

Overall verdict: the server is a **solid Phoenix foundation, not yet cleanly
production-hardened**. REST auth, chat/user-channel joins, webhook HMAC, core
indexes, and transactions are real and correct. The release-blocking gaps are in
the **bridge and relay channels (authorization), SSRF, plaintext in logs, DB TLS
default, and single-node scaling assumptions**. No confirmed CRIT (no hardcoded
prod secret, no SQL injection) — but several HIGHs are release-blockers. The web
client is a **companion/legacy surface** with real security debt (browser
localStorage key vault) and a lot of **dead censorship-transport scaffolding**.

---

## SERVER — release-blocking (HIGH)

| # | Area | Location | Finding | Verified |
|---|------|----------|---------|----------|
| S1 | Bridge authz | `agent_bridge_channel.ex` result/history/file/ask handlers | Join binds `bridge:<user_id>` correctly, but `result`/`history_result`/`file_result`/`ask_request` trust a payload-supplied `chatId`, and `result` trusts a payload `requesterUserId`, with **no check that the socket user belongs to that chat**. A user can pair their own bridge and inject an agent message / broadcast into a channel they aren't in. | ✓ confirmed |
| S2 | Relay takeover | `relay_channel.ex:39` (client join), `47`+ (register), `bridge_controller.ex:126` | `join("relay:<id>", role:"client")` is **unconditional** — any authed user joins any relay topic. Relay registration/`update_relay` don't compare owner, so an existing relay descriptor can be overwritten by id. Enables MITM of relay-resolved clients + forged peer/status events. | ✓ confirmed |
| S3 | SSRF | `agents.ex:1400`, `agent_delivery_scheduler.ex:46`, `image_editor.ex:31`, `ai/tools/vision.ex:140`, `document.ex:37` | User-controlled URLs (agent `callback_url`, image/doc fetch) are fetched/POSTed with no scheme/DNS/private-range/redirect validation → hit loopback, cloud metadata, internal Railway services; non-2xx bodies are persisted/logged (observation channel). | agent-side ✓ |
| S4 | Broadcast-before-persist + no channel rate limit | `chat_channel.ex:110-175`, persist at `Task.start` | `broadcast!` fires before Ecto validation/persist (persist is fire-and-forget in `Task.start`; failure only logged). Malformed/oversized payloads reach all clients; a failed persist = ghost message. WebSocket sends **bypass the REST rate limiter** → one socket can drive unlimited broadcast/DB/push. **NOTE (reviewer):** the async persist is the *intentional* send-ack fast path — do NOT make it synchronous. The real fixes are (a) validate before broadcast, (b) add a per-socket send rate limit. | ✓ confirmed; design-aware |
| S5 | Single-node scaling | `application.ex` (PubSub no cluster adapter), `rate_limiter.ex`, `chat_home_cache.ex`, relay GenServer | PubSub/Presence/rate counters/home-cache/relay state are all node-local ETS. A second Railway replica ⇒ split-brain: sender on A never reaches recipient on B; rate limits and caches disagree. Conditional on replica count (uncertain), but there's no safe horizontal-scale path today. | config ✓ |
| S6 | Plaintext in logs | `group_agent.ex:1176`, `image_editor.ex:23/84`, `ai_controller.ex:17`, `agent_bridge_channel.ex:433/463`, `config/prod.exs:10` (`:info`) | Prod `:info` logs contain user prompts, document bodies (first 200 chars), image-edit prompts + response (first 1000 chars), and whole bridge control payloads. On an E2E product, Railway logs + any log export become an unencrypted content store. | ✓ confirmed |
| S7 | DB TLS unverified | `runtime.exs:65/79` | `ssl_opts` defaults to `verify: :verify_none` unless `DB_SSL_VERIFY=peer` is set — encrypted but unauthenticated DB connection ⇒ on-path cert-spoofing captures credentials + all traffic. **Fix is ops (env + CA bundle), not code.** Prod env value uncertain. | code path ✓ |

## SERVER — MED / LOW (summary)

RLS not `FORCE`d so table-owner role bypasses it (`repo_rls.ex`, RLS migrations) —
depends on prod DB role, uncertain; unvalidated uploads to a public bucket up to
120 MB, no MIME/magic-byte check (`media_controller.ex`, `supabase_storage.ex`);
mesh-fragment reconstruction runs unbounded CPU in the channel process
(`mesh_assembler.ex`, `relay_channel.ex:202`) — DoS; scheduler post is non-atomic
(insert → fan-out → mark serially; crash = duplicate) and blocks on notifications
(`scheduler.ex`); unsupervised `Task.start` everywhere + on-demand team-run ETS
owned by a transient task (`application.ex:71`, `local_agent_worker.ex:3702`);
unbounded reads / missing indexes (saved messages, channel discovery N+1, bridge
polls `inserted_at` but index is `(chat_id, timestamp)`); home-cache invalidation
is node-local; broad changesets cast privileged fields (`user.ex:65` tokens/hashes,
`agent.ex:44` secrets, `participant.ex:20` role) — no confirmed exploit, hazardous
for future reuse; `check_origin: false` (`runtime.exs:121`).

## SERVER — architecture

**Clean:** router scoping, channel-join auth, webhook HMAC (constant-time),
parameterized fragments (no SQLi), history capped at 100, core indexes +
transactions present, `TeamRun.chat_id` migration exists. `packet_bootstrap`,
`mesh_assembler`, `relay_registry` are **reachable, not dead**.

**Not clean:** the domain layer calls `VibeWeb.Endpoint` directly, so persistence /
transport / notifications / serialization are interwoven. God-modules:
`local_agent_worker.ex` **7,647 lines**, `group_agent.ex` 4,270, `chat.ex` 1,858
(context + service both), `chat_channel.ex` 2,015. **Message serialization is
duplicated across ~9 paths with incompatible fields/casing** (history snake_case,
live client passthrough, bridge camelCase subset, per-agent variants differing on
`plaintext`/`plainContent`/`metadata`/identity/file/`replyToId`) — the same class
of asymmetry that caused the iOS reply-preview bug, on the server side.

**Top 3 structural moves (proposals):** (1) one canonical `MessageEnvelope` mapper
for every emit path; (2) authorization at capability boundaries — a `ChatAccess`
membership service, a bridge-event validator bound to `socket.assigns.user_id`, a
relay ownership model; context APIs take a verified actor, not an arbitrary
`acting_user_id` string; (3) split orchestration from execution — durable write +
outbox event in one transaction, supervised workers consume the outbox for
broadcast/push/agent-dispatch; decompose `LocalAgentWorker`.

---

## WEB CLIENT

| # | Sev | Location | Finding | Verified |
|---|-----|----------|---------|----------|
| C1 | CRIT | `localKeyStore.ts` | Private keys + login token + secret key persisted as JSON in `localStorage`/IndexedDB. Any XSS/extension/shared-device/backup = full account + E2E compromise. Acceptable ONLY under an explicit "companion/dev" threat model. | — |
| C2 | HIGH | `localKeyStore.ts:147` vs `386` | `clearAll()` (account delete) removes only `vibe_keys_*`, but backups are written as `securechat_backup_<id>` — **delete-account leaves private keys in localStorage**. | ✓ confirmed |
| C3 | HIGH | `ConnectionManager.ts:264` | Auth token prefix logged to console (`substring(0,10)`) → leaks credential material to DevTools/log sinks. | — |
| C4 | HIGH | `Chat.tsx:1595` | DELETE chat sends `Authorization: Bearer ${userId}` (userId isn't a secret) — broken auth if server trusts it, wrong client if not; most REST calls omit the real `loginToken` entirely. | ✓ confirmed |
| C5 | HIGH | `V2RayManager.ts`, `SnowflakeManager.ts`, `DomainFronting.ts` | Censorship-bypass transports are **scaffolding**: V2Ray can't run in-browser (`no-cors` opaque "success"), Snowflake never fetches a broker (invents success), DomainFronting has empty worker URLs and zero importers. Product implies bypass the browser can't deliver. | — |

**MED/LOW:** no forward secrecy + PBKDF2 salt = username (`crypto.ts`); `exportKeys`
without password = base64 plaintext, `generateRecoveryPhrase` isn't reversible
(both UI-unwired); `dangerouslySetInnerHTML` in docs (static today, no DOMPurify);
hardcoded Giphy demo key; `CensorshipBypass` runs as a side-effect singleton that
never feeds the connect path; SW `event.data.json()` no null-check + base-unaware
icon paths; `Chat.tsx` never unsubscribes / never `revokeObjectURL` (long-session
leak); `handleConnectionFailure` can stick `isAutoSwitching=true`; hardcoded
STUN/TURN + ngrok/gist bootstrap leftovers.

**Dead files (import-graph):** `Chat.css.bak`, `DomainFronting.ts`,
`SnowflakeManager.ts`, `supabaseClient.ts`, `components/Layout.tsx`,
`components/HomeLeftAction.tsx(+css)`, `components/ProxySettings.tsx(+css)`,
`assets/react.svg`. Unused deps: `@react-three/*`, `three`, `howler`,
`html5-qrcode`, `classnames`, likely `@supabase/supabase-js`. (`components/Home.css`
and `pages/Home.css` are BOTH live — do not delete.)

**Build:** `tsc -b && vite build` with `strict` + `noUnusedLocals/Parameters` — no
error-swallowing; healthy on paper (build not executed).

---

## Remediation batches (proposed)

- **B-SEC-1 (server auth, behavioral, needs care):** S1 bridge membership check +
  bind `requesterUserId` to socket; S2 relay ownership/role guards. Risk: could
  reject legitimate team-run / relay traffic if the model is subtler than it looks
  — needs the bridge/relay flow mapped first, gated by a build + targeted test.
- **B-SEC-2 (server hardening, low behavioral risk):** S3 SSRF allowlist (block
  private ranges/metadata) on outbound fetch; S4 validate-before-broadcast + a
  per-socket send rate limit (keep async persist); S6 stop logging content /
  drop prod to `:notice` for those call sites.
- **B-OPS (no code / config):** S7 `DB_SSL_VERIFY=peer` + CA bundle; decide replica
  policy (stay 1 node, or add clustering) for S5; upload validation for the bucket.
- **B-CLIENT:** C2 fix `clearAll` to wipe `securechat_backup_*` (safe, high value);
  C3 remove token log; C4 fix DELETE auth; C5 wire-or-delete dead transports; dead-file
  + unused-dep sweep.
- **B-ARCH (large, staged like the iOS pipeline-v2):** `MessageEnvelope` unifier;
  `ChatAccess`; outbox pattern; `LocalAgentWorker` decomposition.

---

## 2026-07-17 — remediation progress (committed to branch, NOT deployed)

`git push` is always-blocked, so all of this landed on `team-payload-and-ui-skills`
only. **Production is unchanged until you deploy on Railway.**

**DONE (gated + committed):**
- `9c1cd8c` **B-SEC-2**: S3 SSRF guard `Vibe.Net.SafeURL` on all 5 user-URL fetches
  (blocks loopback/private/link-local/CGNAT/metadata/ULA + IPv4-mapped v6; Finch
  doesn't follow redirects so a 3xx→private isn't fetched). S6 plaintext removed from
  prod logs at the flagged sites (byte-counts/keys only). Real `mix compile` clean.
- `571e763` **B-CLIENT**: C2 `clearAll` now wipes `securechat_backup_*`; C3 token
  prefix no longer logged; 10 dead files deleted (0-importer verified) + 8 unused deps
  dropped. Real `npm run build` clean.
- `57cd71a` **iOS**: reply-preview seed↔flush symmetry (kills the 77-row re-parse +
  54ms stall that stuttered the reopen-snapshot fade). Simulator build SUCCEEDED.
- `610abc5` **B-SEC-1 / S1**: `bridge_owns_chat?` membership gate on every
  chat-targeted bridge relay/persist/spawn (result/history/file/usage/ask/ask_cancel/
  team_spawn/error + progress-line spawn). Preserves the legitimate owner use-case;
  blocks cross-chat injection. `mix compile` clean. **Behavioral — device-verify a
  team run before deploy.**

**CORRECTED finding — C4 is NOT a vuln:** the REST auth plug (`plugs/api_auth.ex`)
verifies the bearer via `Accounts.get_user_by_token`, and `ChatController.delete`
uses `conn.assigns.current_user.id` + `Chat.is_participant?`. So `Bearer <userId>`
simply 401s — the web client's DELETE is a broken (harmless) call on the legacy
surface, not a takeover. Backlog: send the real `login_token` to make it work.

**NEEDS YOUR DECISION (not safe to guess autonomously):**
- **S2 relay** (`relay_channel.ex` / `relay_registry.ex`): this is the VibeNet
  censorship-relay network. Its CLIENT transports are now confirmed dead (we deleted
  DomainFronting/Snowflake). The takeover fix (register + `update_relay` ownership +
  channel role) is multi-site and untestable. **Q: is the relay network still used by
  the native app, or is it legacy like the client transports — harden it, or remove
  the whole subsystem (with C5's V2Ray/CensorshipBypass/Proxy/P2P)?**
- **S4** (validate-before-broadcast + per-socket send rate limit): touches the hottest
  message path; needs on-device verification — do NOT change blind.

**B-OPS — operator checklist (you run these; no code):**
1. **S7 DB TLS:** set `DB_SSL_VERIFY=peer` in Railway env + provide the CA bundle, or
   the DB connection is encrypted-but-unauthenticated (`runtime.exs:65/79`).
2. **S5 replicas:** PubSub/Presence/rate-counters/home-cache/relay are node-local ETS.
   Stay at **1 web replica** until clustering is added, or senders/recipients split-brain.
3. **Uploads:** add MIME/magic-byte + size validation before the public bucket
   (`media_controller`/`supabase_storage`) — currently unvalidated to 120 MB.
4. **Prod log level:** consider `:notice` in `config/prod.exs` now that content is
   redacted, to shrink the log surface further.

**iOS list bugs (need your device — diagnosed, not blind-fixed):**
- *Empty-flash on first/cold open*: the reopen-snapshot disk-decode (~183ms) loses the
  race to the ~168ms push, so the shell flashes empty before the snapshot shows. Fix
  options (need device tuning): sync-decode at bind (adds push latency) vs. prewarm
  snapshot images for the top home chats at launch.
- *Jump-to-bottom "reset" feel*: it already Telegram-teleports (hop + animate last
  screen) to avoid gliding over unmounted rows; the hop reads as a reset. Tuning the
  hop distance/threshold needs your eyes.
- *Scroll-memory mid-history*: on a cold open that mounts only the bounded tail, a
  saved anchor older than the tail isn't found → falls back to bottom. Fix (retry
  restore after the full window mounts) risks the common case; needs device iteration.
