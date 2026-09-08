# Capacity at 500k live requests

The founder's question — "what does the service do at 500,000 live requests"
— is evidence-based here: every claim cites a file+line. Numbers the code
doesn't fix are marked `MEASURED: <pending>`; run the harness in
`scripts/loadtest/` (see §6) to fill them in.

## 0. Measured results (2026-08-29, one local dev node, 12-core Intel/16 GB)

First real numbers from `scripts/loadtest/` against one core replica. A dev
Mac is not the VPS — treat these as the shape and the ceilings, not the final
per-node capacity — but the bottleneck ranking below is now measured, not
guessed.

| What | Measured |
|---|---|
| Idle RSS/connection | **~75 KB** (3,000 `--dm` sockets: BEAM RSS +224 MB → 75 KB/conn; ~2–3 processes/conn) |
| Base core RSS (3k users seeded, 0 sockets) | **~78 MB** |
| Join latency, 400 conns @ 200/s ramp | p50 **32 ms** · p95 68 ms · p99 77 ms |
| Join latency, 3,000 conns @ 400/s ramp | p50 **228 ms** · p95 1,235 ms · p99 **2,156 ms** — DB-bound, the real ceiling |
| Delivery latency, fan-out 400 (group) | p50 **41 ms** · p95 93 ms · p99 443 ms |
| Delivery latency, fan-out 2 (DM) | p50 **3 ms** · p95 9 ms · p99 11 ms |
| Fan-out correctness | 145 sent → 58,000 received, ratio **exactly 400**, 0 dropped, 0 errors |
| Query time mix (`:9568` histogram) | **~50 % < 10 ms, ~88 % < 25 ms**, mean ~16 ms incl. queue |
| BEAM limits (OTP 26 default, this build) | `process_limit` = **1,048,576** · `port_limit` = **1,048,576** |
| Rate limiter under concurrency | atomic — 310 concurrent `/api/health` → exactly the 300/min bucket allowed, 10× 429 |

**The headline:** steady-state fan-out and delivery are cheap and correct
(3–93 ms, zero drops). The ceiling was the **connect/join storm**: join ran
synchronous DB work, so p99 join latency climbed 32 ms → 2.15 s going 400 →
3,000 sockets at a fast ramp. Memory is linear and plannable: ~75 KB ×
500k ≈ **38 GB** of connection processes, so 500k on one node needs a bumped
`+P` and ~48–64 GB RAM, or a 2–3 node libcluster split (§3.4, §4).

### Join cost, after the 2026-08-29 fix

Why the cliff was there: at a 400/s ramp, ~4 queries per join is ~1,600
queries/s, and the pool sustains `POOL_SIZE(20) / 16 ms ≈ 1,250/s`. The ramp
was *over* the pool ceiling, so joins queued — which is exactly the 2.15 s p99.

`Chat.join_context/2` now returns role and room type in one round trip, and
`Vibe.Chat.JoinCache` caches the DM agent-shadow lookup per `{chat, user}`.
Role is deliberately **not** cached: authorization is never served stale.

| Join | Queries before | After (cold) | After (warm) |
|---|---|---|---|
| human DM | 4 | 2 | **1** |
| agent DM | 5 | 3 | **1** |
| group | 2 | 1 | **1** |

Measured by counting `[:vibe, :repo, :query]` telemetry around the old and new
paths on the same rows. At 1 query/join the same 400/s ramp is ~400 queries/s —
**3× under** the pool ceiling instead of over it. Re-run `ws-storm.js` at 3,000
conns to confirm the p99 cliff is gone; the arithmetic says it should be.

## 1. What "500k live requests" means

Two different axes, two different bottlenecks. Both matter and neither
substitutes for the other:

- **Concurrent sockets** — 500k phones with an open WebSocket
  (`ws://.../socket/websocket`), mostly idle, occasionally sending. Bounded by
  OS file descriptors, BEAM process/port limits, and per-connection memory.
  This is what `ws-storm.js` exercises.
- **Requests/sec** — 500k HTTP calls arriving over some window (a launch
  spike, a push-notification fan-out that triggers pull). Bounded by CPU and
  the DB connection pool, not FDs. This is what `http-flood.sh` exercises.

A chat app is dominated by the first axis at rest (sockets held open all day)
and spikes into the second around reconnect storms and bursts (see §3).

## 2. Per-connection path today

```
client --TLS/WS--> Caddy --reverse_proxy--> Cowboy acceptor --> VibeWeb.UserSocket
                                                                     |
                                                          (channel join, per topic)
                                                                     v
                                                 VibeWeb.ChatChannel  VibeWeb.UserChannel
                                                  (chat:<id>)          (user:<id>)
                                                     |                     |
                                                Phoenix.PubSub  <-------- Presence.track
```

- **Cowboy acceptor** (`cowboy 2.14.2` / `plug_cowboy 2.8.0`, pinned in
  `server/mix.lock:6,40`) accepts the TCP connection and performs the HTTP
  upgrade. One OS socket / file descriptor per connection on both the Caddy
  hop and the core hop.
- **`VibeWeb.UserSocket.connect/3`** (`server/lib/vibe_web/channels/user_socket.ex:28-48`)
  resolves the token (`x-vibe-auth` header or `?token=` query param) and calls
  `Vibe.Accounts.get_user_by_token/1`. On a cache hit this is a pure ETS read;
  on a miss it is a full DB round trip (`server/lib/vibe/accounts.ex:117-166`,
  `TokenCache` at `server/lib/vibe/accounts/token_cache.ex:36-37` — 60s TTL,
  no negative caching, per-node table). The socket itself is one Erlang
  process + one port.
- **Joining `chat:<id>`** (`VibeWeb.ChatChannel.join/3`) spawns a **new**
  process and, since 2026-08-29, runs **one** query on a warm join:
  `Chat.join_context/2` returns role and room type together, and the DM
  agent-shadow lookup comes from `Vibe.Chat.JoinCache` (60 s TTL, keyed per
  `{chat, user}`). It was 2-5 uncached queries — see §0 for the measured drop.
  The role check itself is still a live query every time, by design.
- **Joining `user:<id>`** (a real client always does this;
  `VibeWeb.UserChannel.join/3` + `handle_info(:after_join, ...)`,
  `server/lib/vibe_web/channels/user_channel.ex:10-96`) spawns another
  process, calls `Presence.track/3` (an ETS-backed CRDT write + a
  `presence_diff` PubSub broadcast), then backgrounds `Chat.list_chats/1`
  — commented in the code as **"6 DB queries"** (`user_channel.ex:40`) — and
  for each friend, one `Presence.list/1` call and one `"friend-online"`
  broadcast (`user_channel.ex:50-62`). `ws-storm.js` in this harness joins
  only `chat:<id>` to isolate chat fan-out cost — it does **not** exercise
  this path; see the gap noted in §6.
- **A message send** (`ChatChannel.handle_in("message", ...)`,
  `chat_channel.ex:89-266`) checks `VibeWeb.ChannelThrottle` (ETS, per-user
  sliding window: 30 messages/10s — `channels/channel_throttle.ex:11-17`),
  broadcasts synchronously in the reply path
  (`broadcast!(socket, "message", ...)` — this is the number `ws-storm.js`
  times), then backgrounds **two** `Task.start`s: `maybe_dispatch_agent/3`
  (runs `Chat.get_room_type/1` + `Chat.get_participant_ids/1` again — on
  **every** message, agent-mentioned or not, `chat_channel.ex:839-847`) and
  `Chat.add_message/2` (persist + per-participant fan-out + push).
- **Cost per idle connection**: 1 FD/port + 1-3 BEAM processes (transport +
  chat channel [+ user channel]) + a handful of small ETS rows (throttle
  buckets, presence entry, token-cache entry). **MEASURED (2026-08-29):
  ~75 KB RSS/connection** (3,000 `--dm` sockets, BEAM RSS +224 MB), ~2–3
  processes/conn — see §0.

## 3. What breaks first, in order

Ranked by which ceiling a single core replica (today's only topology —
`CLUSTER_STRATEGY` defaults to `"none"`, see below) hits first as concurrent
sockets climb toward 500k.

1. **Container file-descriptor ulimit.** *(FIXED 2026-08-29 — `core`, `caddy`
   and `agent-runtime` now set `nofile` 65536; kept here for the reasoning.)*
   `deploy/compose.yml` set no `ulimits:` key on **any** service. Each socket
   is 1 FD; the container inherits whatever the engine/host defaults to,
   which is not guaranteed to be high (this dev Mac's shell shows
   `ulimit -n` = 1,048,576, but that is this machine, not the deploy host or
   the container's own limit — `docker inspect <container> --format
   '{{.HostConfig.Ulimits}}'` on the real host is the only trustworthy
   answer). This is the single easiest ceiling to hit by accident and the
   cheapest to fix.
2. **Cowboy/Ranch `max_connections`.** *(FIXED 2026-08-29 — both endpoints now
   set `transport_options`; kept here for the reasoning.)*
   Nothing in `server/config/{dev,prod}.exs`
   or `server/config/runtime.exs` sets `transport_options` on the endpoint's
   `socket/2` or `http` block (grep confirms no `max_connections` anywhere in
   `server/config`). Ranch's own default (`ranch_conns_sup.erl`,
   `maps:get(max_connections, TransOpts, 1024)`, pinned at `ranch 2.2.0` per
   `server/mix.lock:43`) is **1,024 connections per listener** — a *soft*
   limit: past it, Ranch queues new accepts instead of rejecting them, so it
   reads as rising connect latency, not errors. On the order of the default
   FD ulimit (#1) — these two likely bite together, both ~500x below a
   500k-socket target, both silent until measured.
3. **BEAM `+P` / `+Q` (process / port limits).** No `ERL_FLAGS` anywhere in
   this repo (`deploy/env/core.env.example`, `deploy/compose.yml`) and no
   custom `rel/vm.args.eex` — `server/` has none; the release ships Phoenix's
   generated template with every flag commented out (`##+Q 65536`, confirmed
   at `server/_build/dev/rel/vibe/releases/*/vm.args`). OTP 26.2.1 (pinned in
   `deploy/core/Dockerfile:16`) defaults apply — **MEASURED (2026-08-29):
   `process_limit` = 1,048,576, `port_limit` = 1,048,576**. At ~2-3 processes
   per real connection (§2), 500k clients is 1-1.5M processes — so the default
   1M process cap is the ceiling around ~350-500k sockets on ONE node and must
   be raised (`+P 2000000`, `+Q`) before then, or the load split across nodes.
4. **There is only one core node.** `Vibe.Cluster.strategy/0` reads
   `CLUSTER_STRATEGY`, default `"none"` (`server/lib/vibe/cluster.ex:8-30`);
   `deploy/env/core.env.example:23` ships it blank. With no strategy,
   `Vibe.Cluster.child_specs/0` returns `[]` — no libcluster, no node
   discovery, `Phoenix.PubSub` runs local-only
   (`server/lib/vibe/application.ex:47`). **All of #1-#3 apply to one
   machine.** There is no tested path in this repo to spread sockets across
   replicas — clustering here is a config flag that has never been exercised
   by the code as shipped.
5. **Ecto `pool_size` (20) vs PgBouncer `default_pool_size` (40).** Doesn't
   bound idle sockets, but bounds request throughput once sockets are doing
   something (message sends, reconnect bursts). `POOL_SIZE` env, default
   `"20"` (`server/config/runtime.exs:184`, same default shipped in
   `deploy/env/core.env.example:11`). `deploy/pgbouncer/pgbouncer.ini:13-16`:
   `pool_mode = transaction`, `default_pool_size = 40`, `max_client_conn =
   500`. One replica's 20 fits inside PgBouncer's 40 today; a **third**
   replica (3×20=60) would already oversubscribe PgBouncer and start
   queueing app-side connection checkouts.
6. **Postgres `max_connections` (200).** `deploy/postgres/postgresql.conf:7`.
   Generous headroom as long as PgBouncer (#5) stays under it — PgBouncer's
   whole job is keeping the *real* Postgres connection count far below this.
7. **Rate-limiter ETS growth vs. the shipped Valkey backend.**
   `deploy/env/core.env.example:22` ships `RATE_LIMIT_BACKEND=valkey`, but
   `Vibe.RateLimit.Valkey.hit/3` **fails open to the node-local ETS backend**
   on any Redix error (`server/lib/vibe/rate_limit/valkey.ex:28-46`). A
   Valkey outage during a 500k-user peak silently reverts every core replica
   to counting independently — under-enforcing every limit by
   `(replica_count)×` for the duration, exactly when you want it least. The
   ETS fallback itself self-prunes above `RATE_LIMIT_MAX_KEYS` (default
   200,000, `server/lib/vibe/rate_limit/ets.ex:63-67`) so it cannot grow
   unbounded, but 200,000 < 500,000 distinct users.
8. **`ChatHomeCache` / Presence reconnect-storm amplification.** This is the
   sharpest edge in the whole system and it is **not** primarily a raw-socket
   problem — it fires on *reconnect*, e.g. after a rolling deploy or a
   network blip that drops and reopens 500k sockets in a short window. Every
   socket connect that joins `user:<id>` runs `Chat.list_chats/1` — "6 DB
   queries" per the code's own comment (`user_channel.ex:40`) — **uncached**
   at connect time, plus one `Presence.list/1` ETS read and one
   `"friend-online"` PubSub broadcast **per friend** of the connecting user
   (`user_channel.ex:50-62`). 500k simultaneous reconnects × 6 queries = 3M
   DB queries in one burst; × ~20 friends (illustrative) = 10M broadcasts.
   `ChatHomeCache` (`server/lib/vibe/chat_home_cache.ex`, 10s TTL, no entry
   cap) softens repeat reads within a 10s window but does nothing for the
   first wave. `docs/scale-readiness-data-layer.md` already measured this
   class of storm at much smaller N ("~12-call storm every socket
   reconnect").
9. **Single-node PubSub.** Already covered by #4 — flagged separately because
   it is the reason #4 cannot be worked around by just adding replicas
   without also standing up `CLUSTER_STRATEGY=gossip|dns`, which changes the
   PubSub broadcast cost model entirely (distributed Erlang, not local
   `:pg`).
10. **Caddy.** `deploy/caddy/Caddyfile` sets `request_body { max_size }`
    (130MB core / 8MB agent-runtime) but no explicit connection or rate
    limits — relies on Caddy 2's own (generous) defaults. Caddy's container
    also has no `ulimits:` override in `compose.yml`, so it shares the same
    unconfigured-default risk as #1, one hop earlier. In practice Caddy, a
    Go reverse proxy, is not expected to be the first thing to fall over —
    listed last because it hasn't been ruled out, not because it's likely.

## 4. Fix list

| Fix | Where | Value |
|---|---|---|
| ~~Set container FD ulimits~~ **DONE 2026-08-29** | `deploy/compose.yml` — `core`, `caddy`, `agent-runtime` | `ulimits: { nofile: { soft: 65536, hard: 65536 } }` on all three socket-facing services |
| Raise BEAM process/port limits | new `server/rel/vm.args.eex`, or `ERL_FLAGS` env in `deploy/env/core.env.example` | `+P 2000000 +Q 1000000` (or via `ERL_FLAGS="+P 2000000 +Q 1000000"`) — size `P` to `target_conns × processes_per_conn` from §2 |
| Raise BEAM scheduler count if under-provisioned | same `vm.args`/`ERL_FLAGS` | `+S <cores>:<cores>` matches the compose `cpus:` limit (`core:` is capped at `2.0` today — `deploy/compose.yml`) |
| Raise host + container ulimits at the OS level | `deploy/scripts/vps-bootstrap.sh:setup_sysctl` | add `fs.nr_open` / raise `fs.file-max` past 200,000 if targeting >200k total FDs system-wide (today's value, `vps-bootstrap.sh:97`), and set `LimitNOFILE=` in `deploy/systemd/vibe-stack*.service` (currently absent) |
| ~~Raise Cowboy's connection cap~~ **DONE 2026-08-29** | `server/config/runtime.exs` + `agent-runtime/config/runtime.exs` | `transport_options: [max_connections: …, num_acceptors: 100]`, via `RANCH_MAX_CONNECTIONS` (core 65536 / runtime 16384) |
| Ecto pool size | `POOL_SIZE` env (`server/config/runtime.exs:184`, `deploy/env/core.env.example:11`) | raise per replica; keep `replica_count × POOL_SIZE ≤` PgBouncer's `default_pool_size` |
| PgBouncer pool | `deploy/pgbouncer/pgbouncer.ini:14-15` | raise `default_pool_size` (40 today) and `max_client_conn` (500 today) together with replica count |
| Postgres connections | `deploy/postgres/postgresql.conf:7` | raise `max_connections` (200 today) only if PgBouncer's own pool must exceed it — normally PgBouncer absorbs the growth instead |
| Enable multi-node | `CLUSTER_STRATEGY` env → `server/lib/vibe/cluster.ex:8-30` | set `gossip` (same-host/LAN) or `dns` (k8s-style) **and load-test the PubSub fan-out cost this introduces** — unexercised today |
| Keep the rate limiter cluster-wide under a Valkey outage | `deploy/env/core.env.example:21-22`, `server/lib/vibe/rate_limit/valkey.ex` | make the ETS fail-open path alarm (it currently only logs once/min, `valkey.ex:37-43`) so an outage during peak is visible, not silent |
| ~~Cache chat-channel join reads~~ **DONE 2026-08-29** | `Vibe.Chat.join_context/2`, `Vibe.Chat.JoinCache` | one round trip for role+type, agent-shadow lookup cached per `{chat, user}`. 4–5 queries → **1** on a warm join (§0). Role stays uncached on purpose |
| Soften the reconnect-storm fan-out | `server/lib/vibe_web/channels/user_channel.ex:45-76` | batch/stagger the post-reconnect `Chat.list_chats` + friend-broadcast burst (e.g. jittered delay, or skip the friend-broadcast entirely when `ChatHomeCache` already has a fresh entry) |
| See live socket/process count | `server/lib/vibe/telemetry/metrics.ex` | add a gauge (`last_value`) for `Registry`/`Presence` size or BEAM process count — today's Prometheus metrics have endpoint duration, repo query time, and VM run-queue length, but nothing that answers "how many sockets are open right now" |

## 5. Sizing table

Formulas first, so each row is reproducible instead of a guess.

- **Sockets → nodes**: `nodes = ceil(target_conns / safe_conns_per_node)`,
  where `safe_conns_per_node = min(container_fd_ulimit − 500 headroom,
  cowboy_max_connections_configured, beam_process_limit / processes_per_conn,
  memory_budget_MB / (MB_per_1000_conns / 1000))`.
- **RAM per node**: `base_RSS_MB + target_conns_per_node × MB_per_conn` (base
  RSS and MB/conn are both `MEASURED:` — see §6).
- **Req/s → DB sizing**: `max_req_per_sec_per_replica ≈ (POOL_SIZE /
  avg_queries_per_request) × (1000 / avg_query_ms)`; `nodes =
  ceil(target_req_per_sec / max_req_per_sec_per_replica)`; keep `nodes ×
  POOL_SIZE ≤ pgbouncer.default_pool_size` (raise PgBouncer, §4, if not).

| Scenario | Nodes (formula input) | RAM (core, total) | DB sizing | Depends on |
|---|---|---|---|---|
| 100k concurrent sockets | `ceil(100_000 / safe_conns_per_node)` — ~1 node at a bumped `+P` | `~80 MB + 100_000 × 0.075 MB ≈ 7.6 GB` | unaffected at idle (sockets don't hold DB conns); reconnect burst = `100k × 6` queries once (§3.8) | **MEASURED**: 0.075 MB/conn, base ~80 MB (§0); extrapolated — largest real run was 3k conns, re-measure at 50k on the VPS |
| 500k concurrent sockets | `ceil(500_000 / safe_conns_per_node)` — **2–3 nodes** | `~38 GB` of conn processes → ~48–64 GB total, or split 2–3 ways | reconnect burst = `500k × 6` queries once; steady-state ETS rate-limit keys ≤ 200k default cap (§3.7) needs raising or Valkey confirmed up | **MEASURED**: 0.075 MB/conn (§0); default `+P` = 1,048,576 caps ONE node near 350-500k procs → bump `+P`/`+Q` (§3.3) and split nodes |
| 5k req/s | `ceil(5_000 / max_req_per_sec_per_replica)` | 1-2 replicas typically, at compose's `2.0` CPU / `1024M` cap each (`deploy/compose.yml`) | `nodes × POOL_SIZE(20)` vs PgBouncer `default_pool_size(40)` — fits in 1 replica, tight at 2 | **MEASURED**: query mix ~50 % < 10 ms / ~88 % < 25 ms, mean ~16 ms incl. queue (§0); the rate limiter caps a burst at the bucket limit *before* the DB saturates, so raw req/s here is limiter-bound by design, not DB-bound |
| 50k req/s | `ceil(50_000 / max_req_per_sec_per_replica)` | scales with node count at the same per-node CPU/RAM cap | almost certainly needs PgBouncer `default_pool_size` raised past 40 (§4) once `nodes × 20 > 40` | same as above, plus `MEASURED: <pending>` the req/s level at which `http-flood.sh` scenario 2's p99 visibly inflects (pool-queueing signature, per `docs/scale-readiness-data-layer.md`'s own diagnosis of this pattern) |

Today's compose stack (`deploy/compose.yml`) is **one** `core` replica (2
CPU / 1024M), **one** `postgres` (2 CPU / 2048M, `max_connections=200`), and
**one** `pgbouncer` (`default_pool_size=40`) — i.e. sized for well under
either 100k row above as shipped, before any fix in §4 is applied.

## 6. Run-book — which command produces which number

Run in order (`scripts/loadtest/README.md` has the full flags):

1. `node seed.js --users 5000 --group-size 5000 --prefix lt` — fixture data.
   No load signal itself.
2. `node ws-storm.js --seed results/seed-lt.json --conns <N> --ramp 200
   --hold 60 --senders 5 --msg-rate 2 --beam-pid <pid>`, run at increasing
   `<N>` (e.g. 1k, 5k, 20k, 50k, ...):
   - **connects ok/failed** — where FD/Cowboy/BEAM ceilings (§3.1-3.3) start
     biting; watch `errors` for `EMFILE`/`ECONNREFUSED` vs. HTTP `403`
     (bad/expired token — not a capacity signal) vs. Cowboy queueing (rising
     connect latency with no errors).
   - **join latency p50/p95/p99** — dominated by the 2-4 uncached DB queries
     in `ChatChannel.join/3` (§2); compare against
     `vibe.repo.query.total_time.milliseconds` in the sampled `/metrics` to
     separate DB time from BEAM scheduling time.
   - **delivery latency p50/p95/p99, fan-out ratio** — group-chat broadcast
     cost at the tested group size; re-run with `--dm` to isolate
     per-connection overhead from N-way fan-out (fan-out≈1 in `--dm` mode).
   - **rss before/after ÷ conns** — `MB_per_conn` input to §5's formulas.
   - **metrics before/after** (`results/metrics-*.txt`) —
     `vm.total_run_queue_lengths.*` (scheduler saturation),
     `vibe.rate_limit.blocked.count` (confirms §3.7 firing).
3. `./http-flood.sh --seed results/seed-lt.json --rps <N> -c 50 --duration
   30s`, run at increasing `--rps`:
   - Scenario 1 (`/api/health`) — pure Cowboy/BEAM req/s ceiling, no DB.
   - Scenario 2 (`/api/chats/:userId`) — DB-path ceiling; the req/s at which
     p99 inflects is the Ecto-pool/PgBouncer queueing point (§3.5, §5).
   - Scenario 3 (`/api/login` wrong password) — confirms the `:auth` rate
     bucket (10/min/IP, `server/lib/vibe_web/plugs/rate_limiter.ex:15`) caps
     this path by design; look at the first ~10 requests' own latency (not
     the 429-diluted aggregate) for the pbkdf2 CPU cost per attempt.

**Gap this harness does not cover**: `ws-storm.js` joins only `chat:<id>`
sockets, to isolate chat-broadcast fan-out cleanly. It does **not** open
`user:<id>` channels, so it never exercises the `Presence.track` +
`Chat.list_chats` + friend-broadcast reconnect-storm path in §3.8 — the
single riskiest item in this document. Measuring that needs a harness that
also joins `user:<id>` per connection and a realistic friend-graph in the
seed data; out of scope here (`seed.js` creates no friend relationships
beyond the DM pairs it seeds for `--dm` mode).
