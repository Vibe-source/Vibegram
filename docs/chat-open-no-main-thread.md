# Chat open with no main-thread work, and a list that never shifts

**Status:** P4-A, B, C landed 2026-08-03. D specified, not built.

**Is the core live?** For a real chat, **no** — and that is a scoping fact, not a
switch left off. `VibeCollectionMessageListHost` is referenced from exactly two
places: `VibeCoreListPreview` (the Diagnostics "Core list (UIKit)" screen) and its
tests. `ChatMainView` contains no reference to it at all. Every `[ChatOpen]` line
in a device log comes from `ChatListView`. What *is* live for real chats is the
core's ordering, behind `vibeTimelineCoreOrderAuthorityEnabled`, and the P4-B/C
measurement path, which is Swift. P4-D is what makes the core the render path,
and it is the largest remaining piece — see its section.

Two requirements, stated by the product owner, that everything below serves:

1. **The push must not be settled by the main thread at all.**
2. **The list must never shift. Ever.**

Neither is an optimisation target. They are the acceptance criteria, and the
reason for them is on record: `ChatListView` is 22,586 lines *because* the
problem was attacked by optimisation for months, including by the strongest
model available. Optimisation produced the file. It did not produce a list that
holds still. So the remaining work is structural — the hybrid split Telegram and
Discord use, where the platform's UI toolkit draws and nothing else.

---

## Why the list still shifts today — measured, 2026-08-03

From a device run on the current build:

```
viewport-cover seed     off=4266  contentH=5222  boundsH=956   cover=86%
viewport-cover settled  off=4238  contentH=5222  boundsH=956   cover=89%
```

Content height never changed; the **offset moved 28 pt after mount**. That is the
visible jump on chat open.

```
MAIN-THREAD-SYNC-STALL  104ms at getStatus()
MAIN-THREAD-SYNC-STALL  109ms at getChatRows(_:)
```

```
setRows ins:60  (135 → 195)  177ms  applyMs=169
setRows del:60  (195 → 135)   73ms  applyMs=69
setRows ins:80  (135 → 215)   97ms  applyMs=88
```

Sixty older rows were inserted, **discarded**, then eighty inserted — three
main-thread stalls for a net result one pass could have produced.

The shape of the problem is not that any one of these is slow. It is that chat
open **pulls**: it reads the engine synchronously, parses, decrypts, measures,
mounts, then corrects. Correction after mount is what shifting *is*.

---

## The target: chat open is a hand-off, not a computation

```
        BEFORE push                          AT push                AFTER push
┌────────────────────────────┐        ┌──────────────────┐     ┌──────────────┐
│ core: order, dedup, window │        │ mount frozen     │     │ draw only    │
│ swift: parse, decrypt      │  ───►  │ snapshot         │ ──► │ (cellFor…)   │
│ metrics: measure + freeze  │        │ no measurement   │     │ no measure   │
└────────────────────────────┘        └──────────────────┘     └──────────────┘
     off the push                        main, but O(1)          main, bounded
```

A row that is measured before the push and never re-measured cannot shift. That
is the entire mechanism — there is no second code path to keep in agreement,
which is what the old list's twelve post-hoc height movers each are.

---

## P4-A — the core host draws real cells · **landed**

`VibeCollectionMessageListHost` registered exactly one cell,
`VibeTimelineBubbleCell`, a plain bubble it defines itself. That is why every
flag in front of the core stopped at the Diagnostics preview: the core could
order, window and seal a conversation but **could not draw one**. A real chat
needs agent turns, media, voice waveforms, link previews, replies, reactions —
all of which already exist in `ChatListCell`.

The host now takes a `rowProvider: ((String) -> ChatListRow?)` and dequeues
`ChatListCell` when one is supplied. The division it draws is the migration:

| Owner | Decides |
|---|---|
| **core** | which messages exist, in what order, how tall each is |
| **Swift** | what a message contains (parse, decrypt) and how it is drawn |

`cellForItemAt` does not measure, does not consult a height cache, and never asks
a cell what size it wants. Returning `nil` falls back to the placeholder bubble,
so a missing payload leaves a correctly-sized gap rather than a hole.

---

## P4-B — measurement that can leave the main thread · **landed**

**This corrects a claim made earlier in this project.** Measurement was called
main-thread-bound "and never will be", on the grounds that text measurement is
CoreText and `VibeRowMeasurementCache` is `@MainActor`. That is half right, and
the wrong half is load-bearing:

- **UIView-based sizing cannot leave the main thread.** `UILabel.sizeThatFits`,
  `VibeAgentTurnContentView.measuredHeight`, anything that instantiates or lays
  out a view — main thread, no exceptions.
- **`NSAttributedString.boundingRect(with:options:context:)` can.** It is
  CoreText over an immutable string. No view, no main thread.

### What the audit found — `docs/row-height-formulas.md`, 2026-08-03

A full inventory of every height path settles what is and is not movable, and it
is not a clean sweep:

**Off-main safe today — `boundingRect` and arithmetic only:**
plain text, rich text, media (known aspect), voice, video note, sticker,
document, link/music preview, reply preview, forwarded header, day separator,
`AgentRuntimeSummaryView.measuredHeight` (already a pure formula),
`AgentIntegrationPackView.measuredHeight` (a constant, 72),
`ChatNativeAgentTextRenderer.measuredSize`.

**Not movable — `VibeAgentTurnContentView.measuredHeight`
(`VibeAgentTurnContentView.swift:362–420`):**
it pins a width constraint on a shared template view, calls `configure`,
`layoutIfNeeded`, then `systemLayoutSizeFitting(…, .fittingSizeLevel)`. The body
is a `UIStackView` whose arranged subviews are built in a **loop over progress
items**, each of which is itself Auto Layout sized. There is no arithmetic that
reproduces that without rebuilding the stack — and rebuilding it in order to
predict it is worse than laying it out.

### So the split is by *when*, not only by *where*

Requirement 1 says the push must not be settled by the main thread. It does not
say every measurement must leave the main thread — it says none of them may
happen **during the push**. Two mechanisms, applied where each actually works:

| Rows | Mechanism |
|---|---|
| everything except agent turns | `VibeRowMetrics` — pure, off-main, measured while the transcript is prepared |
| agent turns | measured on main but **off the push** — at prewarm, or when the turn settles — then frozen |

A frozen agent-turn height is as good as an off-main one for this requirement,
because the push reads a number either way. What matters is that the number
exists before `pushViewController` and is never re-derived after.

This is also why P4-C is not optional. Without a prepared timeline there is
nowhere for either measurement to happen except during the push.

### What shipped, and the second correction

The first cut of `VibeRowMetrics` reimplemented the height formulas as pure
arithmetic, on the assumption that `measureMessageBubbleLayout` could not leave
the main thread. **It can.** `ChatListViewCells.swift` contains no `@MainActor`
and no `UIView` sizing on the ordinary path — every height in it is
`boundingRect`, `NSString.size(withAttributes:)`, or arithmetic. The one
exception is the agent-turn branch.

So the parallel implementation was deleted before it could ship. It would have
owed the real path 0.5 pt of agreement, on every kind, forever — and that
agreement burden is the defect being removed, not a step toward removing it.
Heights are already decided in more than one place in this list; adding a
thirteenth was the wrong move.

`VibeRowMetrics` is now a **gate**, not a calculator:

```swift
VibeRowMetrics.requiresMainThread(_ row:) -> Bool          // agent turns
VibeRowMetrics.height(row:rowWidth:state:) -> CGFloat?     // nil = must stay on main
VibeRowMetrics.heights(rows:rowWidth:) -> (byKey:, deferredKeys:)
```

`height` calls `measureMessageBubbleLayout` — the same function the cell calls —
so agreement is **identity**, not tolerance, and there is no drift to test for.
What is tested is the part that is new and can be wrong: the classification, and
that a real row measures to the same number off the main thread
(`testARealRowMeasuresTheSameOffTheMainThread`) under concurrency.

`heights` returns deferred keys rather than dropping main-only rows, because a
row with no prepared height silently falls back to an estimate — and an estimate
that disagrees with the later measurement is precisely the shift.

**One real hazard the audit found and fixed:** `AgentCodeBlockView`'s
`expandedStorageKeys` is a plain `static var Set<String>`, read by
`measureBubbleCodeBlockHeight` and written by a tap on main. Measuring off-main
made that an unsynchronised set across threads, whose symptom is a wrong height
rather than a crash. Both it and `AgentIntegrationPackView`'s equivalent are now
lock-guarded. Everything else measurement touches was already safe:
`ChatMediaNaturalSizeStore` is `NSLock`-guarded and `chatMediaNaturalSizeCache`
is an `NSCache`.

Measuring off-main also makes something *better*, not just cheaper: the natural-size
probe (`probeLocalMediaSize`, `chatMediaImageHeaderSize`) is file I/O that today
runs on main, which is part of why the square fallback exists at all. Off the push
it is free to run every time, which removes the guess.

**Trap the audit surfaced:** `estimateMessageHeight` is the *exact* path despite
the name, and `presentationSeedMessageHeight` is the progressive one. The two
disagree on settled agent turns, where the seed uses a `boundingRect` + character
formula capped at 430 while the exact path lays out the real view. That
disagreement is a shift by construction and is a strong candidate for the 28 pt.

---

## P4-C — the prepared timeline · **landed**

`getChatRows` blocks the main thread for 109 ms because the chat **pulls** from
the engine at open. The core exists partly to make that structurally impossible:
it has no synchronous read API.

So the route must be handed a snapshot rather than fetch one:

- the engine **pushes** its rows into the core at the persistence choke
  (`persistHistoryRowsToStoreLocked`, `ChatEngine.swift:12255` — the comment
  there already calls it "the single choke for every persist path")
- the core orders, dedups and windows them
- metrics (P4-B) measure and freeze, off the push
- `prepareForNavigationPush` mounts the frozen result

Chat open then costs one array hand-off and a `reloadData` over pre-sized rows.

Also removes the 60-in / 60-out / 80-in churn: pagination becomes a core window
move, not three separate `setRows` passes each re-deciding the whole list.

### What shipped

`VibeTimelinePreparedStore` — heights measured off the push through
`VibeRowMetrics`, which calls `measureMessageBubbleLayout`, the function the
cell itself calls. Agreement is identity, not tolerance.

Two feeds, both at moments the main thread is idle:

| Feed | Covers |
|---|---|
| `persistHistoryRowsToStoreLocked` | a chat whose rows changed on the network |
| `captureReopenSnapshot` (the settle beat) | reopening a chat that changed nothing — far more common |

Three ways a prepared height could be wrong, each closed. Measured at another
width: the width is published from `groupMeasurementExtras`, the one funnel that
derives it, and a change drops every prepared transcript. Measured from a row
that has since changed: the row comes back *with* the height and the caller
compares it with `chatListRowContentEqual`, the same predicate its in-memory
cache uses. Measured before the media aspect was known: the square-fallback flag
now survives the trip through the gate, so `VibeRowMetrics` returns
`Measured { height, mediaAspectWasUnknown }` and a provisional height is promoted
as provisional rather than frozen as exact.

A hit is promoted into `messageHeightCache` exactly as a fresh measurement is, so
`hasExactProgressiveHeight` is already true and the warmup skips the row —
otherwise the warmup re-measures and returns the same number a frame later, a
second pass whose only outcomes are "no change" and "a shift".

### The other half: the mount was inside the animation

Prepared heights kill the *sizing* cost, and the device log says sizing was never
the expensive part:

```
seed-profile sizeCalls=240 sizeMs=10  configure=22 configureMs=20  cell=22 cellMs=112
```

10 ms of measurement against **112 ms of cell configuration**. And it ran here:

```
11.345 viewWillAppear sinceTapMs=49          ← push begins
11.386 seed-mount PUSH-COVERED rows=134
11.582 presentation-seed totalMs=180         ← inside the animation
11.912 viewDidAppear sinceTapMs=615
```

A raster-covered push stashed its seed and mounted it on the *next main turn* —
the commit carrying the slide's first frame. Interactive gestures are tracked on
the main thread, so this is the reported "the push isn't smooth and swiping back
doesn't follow my finger": the finger was queued behind a transcript nobody could
see, under a raster that is a pixel-exact photograph of the same thing.

The mount now waits for `completeTranscriptPresentation()` — for a while this held
only above `coveredEagerSeedMountRowBudget`, so every ordinary chat still mounted
inside the slide; the budget is 0 and the rule is unconditional. It also does *less*
work than before — with the mount deferred, mid-push payloads take the stash lane
and upgrade it monotonically instead of arriving as `retain-frozen` and then
`apply-pending`, so an open mounts once rather than mounting, freezing and
reconciling.

**Ordering trap:** the mount must run before `defersTranscriptUpdatesForPresentation`
flips. `installPresentationSeedIfNeeded` refuses to seed once presentation is no
longer deferred, so a mount ordered after the assignment silently does nothing and
the chat arrives empty behind its own raster.

### Still owed by P4-C

The engine hand-off is the *height* hand-off only. `getChatRows` is still a
synchronous read at open, and the core still does not own the window for a real
chat — see P4-D.

---

## P4-D — point the chat surface at the host · **not built**

`ChatConversationController` → `ChatMainView` → **`VibeCollectionMessageListHost`**
instead of `ChatListView`, for 1:1 DM first, behind `vibeAsyncTimelineV1Enabled`
+ `eligibleChatClasses`, both of which already exist and are already default-off.

What stops being on the path, rather than being optimised:

- the twelve post-hoc height movers in `docs/chat-list-seams-map.md`
- `syncOnQueue`-from-main reads during open
- the dual seed/exact sizing paths
- progressive warmup and its corrections

That list is the answer to "will the old functions be removed?" — they are
removed by **replacement**, once the thing replacing them can draw a chat.

### Measured scope, 2026-08-03

- `ChatMainView` calls into `chatListView` at **87 sites**
- `ChatListView` is 23,091 lines and **591 functions**, of which roughly **177
  are list engine** (heights, sizing, seed, raster, scroll/anchor, data source)
  and **414 are chrome and features** (input bar, keyboard, wallpaper, banners,
  agent surface, overlays, send morph, sheets)
- `ChatListView` is therefore not a transcript. It owns the input bar, the
  wallpaper, theme handling, selection mode, reactions, the date pin, search,
  jump-to-bottom, share/sheet presentation, the Telegram send morph, the cell
  removal animation, and the top/bottom edge masks.
- `ChatListView+Interactions.swift` (1,318 lines) holds hold-to-preview morph,
  swipe-to-reply, the context menu and the dismiss tap — all installed on
  `collectionView`, all working off `indexPath → row`.

### The approach that was tried and rejected

A parallel `VibeCoreChatViewController` — host plus `ChatInputBar`, routed to for
gated DMs, old path untouched. It was built, it compiled, it routed, and it was
**deleted the same day**.

It rendered an empty transcript. The cause is the argument against the whole
shape: engine rows are **nested** — the timestamp lives at
`row["message"]["timestampMs"]`, not at the top level — and the re-derived feed
read the top level, got `nil` for every row, and skipped all of them. One small
piece of the row feed, re-derived, wrong within the hour. The header, wallpaper,
theme, sheets, send morph and edge masks are far more intricate than that feed
and are already tuned; re-deriving them would produce twenty of the same bug,
each in code that had already been paid for once.

### The approach being built: replace the engine, keep the file

The product owner's call, and the right one: **`ChatListView` keeps everything
except its list engine.**

```
core → VibeTimelineHost → (VibeMessageListHost) ChatListView
                                                 ├─ collectionView — unchanged
                                                 ├─ chrome, masks, morph, interactions — unchanged
                                                 └─ items + heights — told by the core, never derived
```

`ChatListView` adopts `VibeMessageListHost` (8 methods, every one of them
something it already does). `collectionView` is a `let` referenced **449 times**
and it never moves, so every mask, gesture, overlay and animation bound to it
keeps working *by construction* rather than by re-implementation.

What that deletes, by replacement rather than by editing:

- the twelve post-hoc height movers in `docs/chat-list-seams-map.md`
- `sizeForItemAt` as a decision — the layout reads frozen geometry
- the dual seed/exact sizing paths and the progressive warmup
- `syncOnQueue`-from-main reads during open

What it must not change, and what "hard refactor" means here: the appearance and
every other system stay **exactly** as they are. Header (avatar node, back,
edit/selection), wallpaper, theme, share/sheet rendering, send morph, cell
removal animation, and the top/bottom edge masks are not to be re-derived,
re-tuned, or "improved" in passing. Only the engine changes.

---

## Gates

Inherited from §9.1, plus the two requirements above stated as measurements:

| Gate | Threshold |
|---|---|
| Settled-row geometry changes after mount | **0** |
| Content-offset movement between seed and settled | **0 pt** |
| `MAIN-THREAD-SYNC-STALL` during chat open | **0** |
| Main-thread transaction | p95 ≤ 4 ms, p99 ≤ 8 ms |
| Instantiated cells | visible + ≤ 2 screens |
| Metrics agreement (P4-B vs view-based) | 0 rows differ by > 0.5 pt |

The offset-movement gate is new and is the direct expression of "never shifts".
It is measurable today from `viewport-cover seed` vs `viewport-cover settled`.
