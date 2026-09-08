# Smooth-UI hardening backlog (bridge → engine → list)

Standing backlog for the recurring hardening loop: each `@team` iteration picks the
top unchecked item, diagnoses with device logs, and dispatches codex/grok workers.
Evidence lines come from the 2026-07-18 device session (group chat ccd43b50-2e1).

## Open

- [ ] **setRows main-thread stalls 50–80ms** — `[MainThreadStall] setRows took 74ms …
  mergeMs=3 parseMs=15 applyMs=54`. Parse/apply run on main during streaming; target
  <32ms: move parse off-main (parseMs), batch apply, profile applyMs hot path.
- [ ] **ChatEngine syncOnQueue main-thread stalls** — `[MAIN-THREAD-SYNC-STALL]
  syncOnQueue blocked main thread for 77ms at getStatus() (ChatEngine.swift:1297)`
  and `agentProgress(chatId:) (:5186)`. Main thread blocks behind the engine serial
  queue during stream bursts; cache snapshots (read-only copies) for these getters.
- [ ] **Settle key-swap reorder fallback** — `[ChatListView] ⚠️ reorder fallback —
  mismatchAt:126 old:'m-lan-…' new:'m-d93dc91f…'`. The lan→durable settle should be
  a keyed replace, not a full reorder fallback (full-table rebuild risk).
- [ ] **Heights persist churn on settle** — `heights PERSIST total=129↔130` with
  `rejStream=1 rejKeys=[…:chat:codex]` repeating for tens of seconds after settle;
  retired stream keys should stop entering the persist pipeline immediately.
- [ ] **Settled agent cell re-applies text every setRows** — `[VibeAgentKitStreamingText]
  apply streaming=false … target=843 delta=843` repeatedly for the same settled
  message; content-signature guard should no-op re-applies.
- [ ] **`bridgeReachable:false` while LAN transport is "direct"** — status flag
  disagrees with the active transport; align the flag or the transport picker.
- [ ] **ChatsViewModel refresh cancelled** — FIXED 2026-07-19 (run smoothgroup-0719:
  VM-owned in-flight task + retry-after-cancel). Verify on device: expect
  `refresh applied` / `skipped-identical` instead of `error=cancelled` streaks.
- [ ] **Reconnect history gap** — FIXED 2026-07-19 (backfillNewest on chat_joined).
  Verify: `[ChatEngine] backfillNewest OK … ins=N` after airplane-mode round trip.
- [ ] **Duplicate agent response after missed settle** — FIXED 2026-07-19
  (retireLiveRowsSupersededByDurable, taskId match). Verify: `retireSupersededLive`
  in logs; no dual codex bubbles after reconnect.

## Loop protocol

1. Pull fresh device logs (or user-pasted log excerpt) → confirm the symptom line.
2. Diagnose root cause in code BEFORE dispatch; write the board under
   `.vibe/team/<run>-board.md`.
3. Dispatch codex (engine/server) / grok (web/docs) per the routing table in
   `agent-bridge/instructions/team-lead.md`; integrator owns ChatEngine.swift and
   list internals.
4. One verify pass; append the run entry to `.vibe/memory.md`; check the item off
   here with the run id.
