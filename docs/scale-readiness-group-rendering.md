# Scale readiness — group/channel list rendering (client)

**Status:** decision recorded 2026-07-23 · **Verdict: stay on UIKit, targeted patches — NOT forced into a Telegram-style async-layout list.**
**Scope:** CLIENT rendering/perf of a high-density group/channel (~2000 members, many msg/sec, heavy media). Backend fan-out / sockets / DB are a **separate track** and not covered here.

This doc is the standing plan for making the chat list production-grade under group density. It records what we have, what breaks first, the priority-ordered work, and the exact measured signal that would (and only then) force a renderer rewrite. Reviewed with the advisor (Fable); update it as items land.

---

## Verdict

UIKit can carry 2000-member high-throughput groups. The coalesced single-apply pipeline and the persisted height cache are the right foundation. We do **targeted patches**, not a node/async-layout rewrite. The custom list is a **measurement-gated** decision (see *Trigger* below), never a user-count milestone — and per-device data density, not total user count, is what stresses the client.

## What we have today (verified in code)

- **Renderer:** `UICollectionView`, **manual sizing** — every bubble self-sizes and its height is **measured on the main thread**, backed by a **persisted height cache**. Cells are virtualized/recycled by UIKit. Rich cells (attributed-text layout + view assembly); a screenful of rich cells has profiled at **100–500ms to *build*** (content build, not sizing).
- **Update path:** high-frequency stream/delivery/status ticks are **coalesced into ONE off-main engine read**, then applied via a diffed `setRows` (`reconfigureItems` for in-place stream growth; a height-reload path for growth). High-frequency updates are already throttled.
- **Crypto:** **per-row E2E decryption during parse** (agent runtime/actions/media) — real main-thread time per apply.
- **Windowing:** a **40-row rendered cap exists — but ONLY for agent DMs** (`agentTranscriptWindow`). Regular chats + **groups have NO hard rendered-row cap**; they keep the full loaded transcript in the rows array and page in on scroll-back.

## What breaks first at group density (ordered)

1. **Unbounded group rows array.** No rendered-window cap for groups → every coalesced `setRows` diff, height-cache scan, and reload scales with transcript length; media memory grows unbounded over a long-lived busy group. **This is the first wall.**
2. **Main-thread manual sizing.** At many msg/sec, each apply pays measure + rich-cell build on main.
3. **Cell overlap/settle correctness bug** (`[GroupCellIntegrity]`) — lives in exactly the manual-sizing + async-settle path we're about to stress harder. **Ship-blocker.**
4. **Per-row E2E decrypt on main** — a steady per-apply tax that compounds with throughput.
5. **Presence/typing/read-receipt fan-in** at 2000 members can out-message the messages themselves.

## Priority-ordered work (client, before live)

1. **Extend the rendered-window cap to groups/channels.** Reuse the agent-DM `agentTranscriptWindow` mechanism; target **~100–150 rows** with page-in on scroll-back. *Highest leverage, mostly reuse.*
2. **Fix the overlap/settle bug** (`[GroupCellIntegrity]`) before live. *Ship-blocker.*
3. **Move per-row decrypt fully into the off-main engine read** so the main-thread apply receives **plaintext** rows.
4. **Height discipline:** exact measure only for visible/near-visible rows; estimate-then-settle offscreen; **trust persisted heights on width** for live appends (we already do this for cold-open — extend the same pattern to appends).
5. **Throttle presence/typing/receipt UI application to ~1Hz**, separate from message applies.
6. **Add the prod tripwire metric:** main-thread ms per coalesced apply + hitch ratio, logged in production.

## Trigger — the ONLY signal that forces the custom list

After items 1–4 land, profile a live high-density group. Go custom **only if**: steady-state applies during active streaming still exceed **~8ms main-thread** (dropped frames while scrolling + receiving) **AND Instruments shows sizing/layout — `systemLayoutSizeFitting` / `preferredLayoutAttributesFitting` — dominating**, not content build.
- If **build** dominates instead → the fix is **cell-content caching**, not a rewrite.
- If neither dominates and we're under budget → done; UIKit carries it.

## If forced — what the rewrite plan doc must contain

- **Off-main layout ownership:** per-row layout spec computed in the engine; cells become dumb renderers.
- **Off-main text layout** via TextKit 2.
- **Migration seam:** per-cell-type, **groups first**.
- **Phase gate:** the metric above gates each migration phase (never migrate a cell type that's already under budget).

## Verification harness

Replay **20–50 msg/sec into a 2000-member test group** (`agent-bridge/bin/team-e2e.js`), scroll during streaming, measure with **Instruments → Hitches/Hangs**.
- **Targets:** < 5% hitch ratio; **flat memory over a 30-min soak.**
