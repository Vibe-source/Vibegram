# Scale-readiness — data layer, regions & sharding (task doc)

> Companion to `production-readiness-audit-2026-07.md` (code/arch) and
> `scale-readiness-group-rendering.md` (iOS list rendering). This one is the
> **backend data-layer scale plan**: DB latency, regions, caching, and the
> shard-key decision that must be made *before* launch.
>
> **Audience:** the agent (me) executing against it. Check items off, append a
> dated note per completed task. Items tagged **[USER]** need a human infra/product
> decision or a deploy; **[AGENT]** I can do in-repo.

## Context — measured, not guessed (2026-07-24)

From Railway server logs against the deployed backend:

- `/packet/bootstrap` (no auth, no DB) → **300µs**. Server CPU is instant; the app
  is **not** compute-bound and the phone→server leg is **not** the bottleneck.
- `/api/agent-bridge/status` (exactly 1 query), steady state → **~345ms every time**
  = one server→DB round trip. This was the cross-region cost.
- 2-query endpoints (`push_token`, `profile`) → ~700–780ms = 2 × 345ms.
- Burst endpoints (`/api/chats`, `/api/chat/:id/messages`) → **2–9s** during the
  ~12-call storm every socket reconnect fires — this is **connection-pool queueing**
  (`pool_size: 20`, `queue_target: 5000`), not fixed network cost (the same
  `/api/chats` returns in ~0.5ms when cached/uncontended).

**Verdict:** latency = (345ms server↔DB) × (N sequential queries) × (burst
contention). It is a **server↔database** problem, entirely behind the server — no
CDN/edge can touch it.

**Done:** app + DB co-located in **Singapore** (2026-07-24). Expect
`agent-bridge/status` to fall from ~345ms toward tens of ms. **Re-measure and
record the new floor before proceeding — it re-ranks everything below.**

## The three scaling axes (do not conflate)

1. **Edge / POP** (`packet` transport, Cloudflare) — scales *connection* latency
   globally. Supabase-independent. Does NOT move data or add write capacity.
2. **Vertical + read replicas + cache** — scales *throughput* on one writable
   primary. Gets to ~millions of users. **Do this first.**
3. **Sharding + regional routing** — scales *data capacity* across many DBs; the
   Telegram/Discord/Instagram model. Only when axis-2's ceiling is hit.
   **Design the shard key now; build the sharding later.**

Supabase = single **writable** primary + optional cross-region **read** replicas.
It does not do multi-region writes — that ceiling is axis-3, and hitting it means
either multiple Supabase projects (region = shard, app-routed) or a distributed
store (CockroachDB / Yugabyte / ScyllaDB for messages).

---

## Phase 0 — before launch (release-gating)

- [ ] **[AGENT] Re-measure the co-located floor.** Pull a fresh log; record the new
  `agent-bridge/status` (1-query) time and a `/api/chat/:id/messages` (N-query)
  time here. Everything below is re-ranked by this number.
- [ ] **[USER] Confirm pooler mode.** DB uses the Supabase **transaction** pooler
  (`:6543`, `prepare: :unnamed`). Verify transaction mode is intended (it disables
  prepared-statement caching — a per-query cost). Consider **session pooler** or a
  direct `:5432` app-owned pool now that app+DB are co-located; re-measure.
- [ ] **[AGENT] Kill the reconnect re-fetch storm.** Every socket reconnect re-fires
  ~12 HTTP calls with duplicates (`/api/chats` ×2, `/api/saved_messages` ×5 within
  seconds). Dedupe/coalesce client-side and lean on the socket. Biggest
  pre-migration relief for pool contention. *(client-only, no deploy)*
- [x] **[AGENT] Suppress the live `agent-bridge/status` poll.** ROOT CAUSE: server
  pushed `bridge-status` only on `bridge:` `presence_diff` — a user with NO paired
  computer has no presence → no push → `lastStatusFetchedAt` never stamped → the
  20s fallback polls forever. FIXED (`user_channel.ex`): push an initial
  `bridge-status` on join (computed off-channel in the existing after-join Task).
  **[USER] needs deploy.**
- [ ] **[AGENT] Cut the worst N+1 endpoints.** `/api/chats` and chat-history run
  6–14 **sequential** queries. Collapse to 1–2 (joins/preloads/batch). Helps
  regardless of region; at scale it is what saturates the pool.
- [ ] **[USER] Raise `pool_size`** 20 → ~60–80 and lower `queue_target` so bursts
  fail fast instead of 9s waits. *(config + deploy; band-aid until N+1 is cut)*
- [ ] **[USER+AGENT] DECIDE THE SHARD KEY.** The one irreversible-if-wrong decision.
  Proposal: **messages/chats sharded by `chat_id`**, **user-scoped data by
  `user_id`**. Document the rule for where a 1:1 chat lives (by `chat_id`, both
  members route to it) and how cross-user reads work. Write it down here before any
  new tables land.
- [ ] **[AGENT] Route ALL DB access through one abstraction** (a `Repo` wrapper /
  context boundary that takes the shard key). Even pointing at a single DB today,
  this is what makes future sharding a config change instead of a full rewrite.
  Pairs with the audit's "canonical MessageEnvelope" + "outbox" moves.
- [ ] **[AGENT] Load-test before launch.** Simulate N concurrent users doing the
  launch burst + steady messaging; find the pool/CPU/DB ceiling and the tip-over
  point. Record numbers here so we know the real headroom.

## Phase 1 — early growth (~10k → ~1M users)

- [ ] **[USER] Add a read replica** in-region; route read-heavy endpoints
  (`/api/chats`, history, profile) to it, writes to primary.
- [ ] **[AGENT/USER] Introduce Redis** (co-located) for shared hot cache + cross-node
  state once the app runs on **>1 instance**: presence, recent-message reads,
  counts, rate limiting (currently ETS = per-node, not shared). NOTE: single-node,
  ETS is *faster* than Redis — Redis is a multi-node requirement, not a latency fix.
- [ ] **[AGENT] Outbox pattern** — durable write + outbox event in one transaction,
  supervised workers fan out to broadcast/push/agent-dispatch (see audit move #3).
  Decouples the hot write from slow side-effects.
- [ ] **[AGENT] Backpressure + circuit breakers** on the DB pool so a slow DB sheds
  load gracefully instead of the cascading 34–53s timeouts already seen in logs.
- [ ] **[USER] Edge POPs** (`packet` transport) for global *connection* latency —
  terminate client TLS/WebSocket near the user, backbone to Singapore. Independent
  of the DB; do when you have users far from Singapore.

## Phase 2 — scale-out (design now, build when triggered)

**Trigger:** the co-located single primary + replicas + cache is at its write/CPU
ceiling (load test tells you the number). Do NOT build ahead of this.

- [ ] **[AGENT] Implement sharding** on the Phase-0 shard key: N logical shards →
  fewer physical DBs, a shard-map/router, and a rebalancing plan. Messages are the
  volume driver — evaluate moving the messages table to a horizontally-scalable
  store (ScyllaDB/Cassandra, sharded by `chat_id`) while metadata stays in Postgres
  (the Discord path).
- [ ] **[USER+AGENT] Regional home-routing** (the Telegram model): pin each user to a
  home region where their data lives; cross-region only for cross-region chats.
  This is the "multiple databases in multiple regions" answer — but it is a large
  commitment, only past the single-region ceiling.
- [ ] **[AGENT] Cross-shard/cross-region query strategy** — fan-out reads,
  denormalized per-user inboxes, or a search index; never a live cross-shard JOIN
  on the hot path.

---

## Decisions needed from you (blocking Phase 0)

1. **Shard key** — confirm `chat_id` for messages / `user_id` for user data, or
   propose otherwise.
2. **Pooler mode** — keep transaction pooler, or move to session/direct now that
   app+DB are co-located?
3. **Launch scale target** — expected concurrent users at launch and in month 1?
   That sets the load-test target and the `pool_size`.

## Log / progress

- 2026-07-24 — app+DB co-located to Singapore (user). Latency root cause measured &
  documented (see Context). Client-side heartbeat false-positive teardown +
  voice-re-upload-on-replay already fixed this session (separate). This doc created.
- 2026-07-24 — **Post-region-change log CONFIRMS the fix**: socket connect 350ms→13ms,
  `agent-bridge/status` 345ms→7ms, `/api/chats` 4.6s→86ms (cold) / <1ms (cached),
  `/api/chat/:id/messages` 2–9s→63ms. Cross-region server↔DB latency was the entire
  problem. Fixed the leftover `bridge-status` push-on-join poll bug (server, needs
  deploy). Open: `/packet/bootstrap` ~1Hz cadence (correlates with foreground
  activity — investigate trigger before patching, low cost now at 300µs).
