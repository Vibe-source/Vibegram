# Timeline render architecture

**Goal:** a message list that holds tens of thousands of rows, with live agent turns
streaming into it, and never blocks the main thread — no scroll limit, no open latency,
no jank. This is a launch blocker: the list is the first thing a user touches, and a list
that stutters is the whole app's verdict.

The app is not a chat client that happens to render agents. It is an **agent rendering
surface**: rows mutate while mounted, tool steps append mid-turn, text grows token by
token, and every body is decrypted on the way in. That is strictly harder than a chat
transcript, and it is why the timeline model moved to Rust.

## The measured problem

All numbers from device runs on an iPhone 16 Pro Max, chat `176cdf92eec5` (998 messages).

| # | Cost | Evidence | Scales with |
|---|------|----------|-------------|
| P1 | Layout recomputed per commit | `setRows took 213ms rows=301 … applyMs=201` | mounted rows |
| P2 | Cell construction | `[CellCost] ChatListCell(WHOLE) 9468us` | cells entering viewport |
| P3 | Text measured on main | `estimateMessageHeight` → `boundingRect` | uncached rows |
| P4 | Rows re-parsed from dictionaries | `parseMs=4-8`, `mergeMs=2-4` per batch | batch size |
| P5 | Open blocked on mount | `seed-mount PUSH-COVERED waitMs=510`, `mountMs=181` | mounted rows |

P1 is the one that forced every previous dead end. At ~0.65ms per mounted row, a commit
costs 200ms at 300 rows, ~600ms at 1,000, seconds at 10,000 — and it is paid on **every**
commit, including the one a chat open waits on before lifting its raster cover.

Given that, both available answers were bad:

- **Bounded window** capped the cost by capping the transcript. At the ceiling a
  scroll-back arrived as `del:60 ins:60`, the reader was returned to the top of the new
  window, and it read as a wall. Verified on device: `off=-36` on six consecutive drags.
- **Unbounded window** removed the wall and brought the full cost back.

Neither asked why re-mounting a row the layout had already measured should cost anything.

## What Telegram does

Verified against [Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS),
`release-6.1.2`:

- **Their own list.** `ListView : UIScrollView` in `submodules/Display`, not
  `UITableView`/`UICollectionView`. They decide exactly when nodes are created, laid out
  and inserted.
- **Layout off the main thread.**
  `ListViewItem.nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params:…, completion: (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void)`
  — the row computes its whole layout on a background queue and hands main a cheap
  `apply`.
- **A small window over the database.** `ChatHistoryListNode.historyMessageCount = 90`,
  `.Initial(count: 60)`. Scrolling issues a **new anchor**
  (`.Navigation(index:anchorIndex:count:)`), so the window slides rather than grows.

Their cap bounds *node* count, which is expensive because their nodes are rich. It is not
a scroll limit the user can feel, because the slide is seamless and layout is already
done by the time main sees it.

**We cannot copy the mechanism.** `UICollectionView.performBatchUpdates` gives no split
between "compute layout" and "apply layout" — the commit is one main-thread block. So we
copy the *property* (main-thread work proportional to what changed) by a different route.

## What we build instead

### 1. `ChatTimelineLayout` — O(changed) commits ✅ landed

`ios/ChatModule/Timeline/ChatTimelineLayout.swift`, replacing
`ChatCollectionFlowLayout: UICollectionViewFlowLayout`.

- **Heights memoized by row identity, not index.** Prepending 100 messages into 1,000
  asks the delegate 100 times, not 1,100. This is the change that makes an unbounded
  transcript affordable.
- **Positions are a prefix sum** over the height table — float addition, microseconds —
  instead of one `UICollectionViewLayoutAttributes` allocation per row.
- **Attributes built for the requested rect only**, found by binary search over the
  sorted origin table. ~20 objects per query rather than one per row.
- **Per-row invalidation.** `invalidateHeight(forIdentity:)` replaces
  `invalidateFlowLayoutDelegateMetrics`, which re-measured everything mounted to correct
  three rows.

Consequence: the window has no ceiling (`VibeWindowPolicy::unbounded`) and the whole
conversation stays mounted, because mounted-row count is no longer what a commit costs.

### 2. Background history drain ✅ landed

`startFullHistoryDrainIfNeeded` walks the engine's history to exhaustion from the moment
a chat opens — one page per 220ms tick, on the engine queue, standing aside while a
finger is down. There is no scroll-triggered page left; reaching the top is not an event
the app reacts to.

### 3. Lazy cell composition ⬜ next

P2: `ChatListCell` allocates `AVPlayerLayer`, `UIVisualEffectView`, `LottieAnimationView`,
link preview, reply preview, waveform, agent action bar, upload progress, selection
circle and forwarded header **eagerly** — 9.5ms per cell, against a 16ms frame budget at
60Hz and 8ms at 120Hz. One cell entering the viewport can drop a frame on its own.

Build each of those on first use for a row that actually needs it. A text bubble should
allocate a label and a background, nothing else.

### 4. Text layout off the main thread ⬜

P3: CoreText measurement is thread-safe. `VibeTimelinePreparedStore` already warms
heights off main; extend it to retain the laid-out `CTFrame` so the cell's
`layoutSubviews` draws a result rather than computing one. This is the closest analogue
we have to Telegram's async node layout.

### 5. Typed rows end to end ⬜

P4: the core holds typed messages, then serializes to `[String: Any]` for the list to
re-parse into `ChatListRow`. Delete the dictionary hop.

### 6. Core owns full row geometry ⬜

Today the core answers *how tall*. Extend `VibeRenderItem` to every sub-frame — bubble,
text, meta, avatar, reply, media — so a cell's layout is assignment, not arithmetic. This
is where Rust earns the most: it is already the only component that sees the whole row
off the main thread.

## Invariants

Any change here must keep all of these:

1. **The list never loses or reorders content.** Order and content come from one core
   window; the engine is a fallback only when the core has not ingested the newest
   message yet.
2. **A delta is proportional to the change, not the store.** Pinned by
   `an_unbounded_window_still_emits_deltas_proportional_to_the_change` (12,000-message
   soak). An unbounded window must never mean an unbounded delta.
3. **Heights are decided once, off the main thread, and never move under a reader.**
   A correction that must happen anyway pays back the offset through the layout.
4. **The RSA private key never crosses the FFI.** Unwrapping stays in the platform's
   Keychain seam and fails closed.
