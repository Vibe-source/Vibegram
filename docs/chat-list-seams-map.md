# Chat list seams map

Branch snapshot: `core/timeline-p4`. Read-only survey of where `ChatListView`
gets its **row order** and **row heights** today, plus where messages enter
`ChatEngine` and what building a `ChatListRow` costs.

Every factual claim below is cited as `path:line`. Gaps are marked **unverified**.

---

## 1. Where do rows come from?

### Property

- Display data source: `var rows: [ChatListRow] = []` — `ios/ChatModule/ChatListView.swift:824`.

### Canonical write pipeline

`setRows` / `setAuthoritativeRows` / `clearRows` all funnel into `applyRows`:

| Public API | Line | Authority | Body |
|---|---|---|---|
| `setRows(_:)` | `ChatListView.swift:8610` | `.incremental` | `applyRows(nextRows, authority: .incremental)` |
| `setAuthoritativeRows(_:)` | `ChatListView.swift:8614` | `.fullSnapshot` | `applyRows(nextRows, authority: .fullSnapshot)` |
| `clearRows()` | `ChatListView.swift:8568` | `.fullSnapshot` via empty array | arms `allowsNextExplicitEmptyRows`, then `applyRows([], authority: .fullSnapshot)` |

`applyRows` starts at `ChatListView.swift:8618`. It does **not** assign `rows`
immediately. Order of work:

1. Guards: non-explicit empty keep (`:8631–8640`), defer while scrolling (`:8647–8652`), re-entrancy queue (`:8674–8681`), presentation-seed defer (`:8690–8725`).
2. Merge/filter/parse on main: reply previews + day separators (`:8748–8750`), `parsedRowsReusingCache` (`:8769`), inbox / bridge-fresh / high-water filters (`:8808–8850`).
3. Assigns `sourceRowsPayload` (retained raw baseline) at `:8889`.
4. Diff vs previous `rows`; height-cache eviction for removed keys (`:8957–8962`).
5. Inside the batch/reload path, **`self.rows = parsed`** only via `applyDataSource` (`:9027–9029`). Explicit comment: do **not** set `rows` earlier or UIKit batch counts mismatch (`:9000–9002`).

**Replace vs mutate:** every live assignment to `rows` **replaces** the whole array
(or reassigns a mapped/pruned copy). There is no `rows.append` / `rows[i] =` path
in `ChatListView.swift` (verified by assignment grep).

### Every assignment to `rows` (complete set)

| Line | Function / context | Trigger | Replace / mutate |
|---|---|---|---|
| `:1722`, `:1728` | `setIsGroupOrChannel` | Host flips group flag after cold open | **Replace** via `rows.map` stamping `isGroupOrChannel` |
| `:6563` | warm-tail restore (after presentation-defer check) | Restoring `WarmTranscriptSnapshot` when not deferring presentation | **Replace** with `snapshot.rows` |
| `:8366` | presentation seed mount (`installPresentationSeedIfNeeded` path) | Navigation push seed / engine-or-route seed wins rank | **Replace** with `seedRows` |
| `:9029` | `applyDataSource` inside `applyRows` | Any successful `setRows` / `setAuthoritativeRows` / `clearRows` that reaches finalize | **Replace** with `parsed` |
| `:10917` | `setEventInboxModeEnabled` | Inbox mode turns on while a presentation seed is pending | **Replace** with pruned copy (event rows + orphan day rows removed) |

Indirect re-entry that still ends at `:9029`:

- `finishRowsUpdate` replays `pendingRowsPayload` → `applyRows` (`:14278–14295`).
- `flushRowsDeferredUntilScrollSettlesIfNeeded` → `applyRows` (`:14299–14312`).

### Callers of `setRows` / `setAuthoritativeRows` / `clearRows` (ChatListView)

Internal call sites (all ultimately `applyRows` → `rows = parsed` unless early-return):

| Caller | Line | What triggers it |
|---|---|---|
| `reapplyRowsAfterBridgeSessionScopeChange` | `:3781`, `:3792` | Bridge session scope change; engine read off-main then main |
| `maybeRevealOlderTranscriptRows` (history window) | `:7506` | User scrolled to reveal older windowed rows |
| `setEventInboxModeEnabled` | `:10933` | Inbox mode flip (also may prune `rows` at `:10917`) |
| `refreshAgentTurnRows` | `:12506` | Local agent-turn state after bridge control |
| `hydrateRowsFromNativeHistoryIfReady` | `:13122`, `:13141`, `:13210`, `:13220` | Window/layout hydrate from engine / source payload |
| `applyLocalReactionEmoji` | `:14650` | Optimistic reaction patch |
| `refreshRowsFromEngineDelta` | `:15093` | Engine delta / stream-coalesced refresh (`clearRows` at `:15087` for authoritative empty delete) |
| `syncNativeEngineMessageMutation` | `:15175` | Insert/edit/delete notification path |
| `scheduleStreamCoalescedSetRows` | `:15188`, `:15196` | Agent stream ticks ~50 ms cadence |
| `queueNativeOutgoingMessage` | `:15261`, `:15274` | Optimistic text send (+ status → sent) |
| `queueNativeOutgoingMediaMessage` | `:15366` | Optimistic media send |
| `setNativeOutgoingMessageStatus` | `:15378` | Outgoing status update |
| `removeNativeOutgoingMessage` | `:15392` | Drop optimistic row |
| `cancelOutgoingMessage` | `:15426` | User cancels pending send |
| First-msg reveal fallback | `:15998` | Reveal path could not find row by id |
| `setSearchQuery` | `:16054` | Search filter re-apply |
| `setNativeSendEnabled` | `:16787` | Only when there were native outgoing overlays |
| `startNewBridgeSession` | `:17770` | New bridge session re-filter |
| Bridge media seal stamp | `:18750` | Attach sealed blobs to optimistic media row |
| `clearRows` (bridge history load etc.) | e.g. `:17795` | Authoritative empty / session load |

External hosts:

| Host | Line | Notes |
|---|---|---|
| `ChatMainView.setRows` / `setAuthoritativeRows` / `clearRows` | `ChatMainView.swift:482`, `:493`, `:504` | Forwards to `chatListView` |
| `ChatConversationController` apply path | `AppHomeView.swift:11630–11634` | `source == "native"` or `native-*` → `setAuthoritativeRows`; else `setRows` |
| `ChatAgentView` / streaming text | `ChatAgentView.swift`, `ChatAgentStreamingText.swift` | Separate agent surface (`messagesView.setRows`) — not the main DM list, but same API pattern |

### Ordering today (not “raw payload order”)

Inside `applyRows`, display order is:

1. `mergedRowsPayload(from:)` — engine history + live overlay + optimistic outgoing (`:8749`, def `:14789`).
2. `filterRowsForSearch` (`:8750`, `:16057`).
3. `rowsByInsertingDaySeparators` (`:8750`, static at `:7049`).
4. Parse → inbox split → `bridgeFreshFiltered` → `extractBridgeCommandRows` → `rowsPreservingAgentTurnHighWater`.
5. Optional bridge transcript window `Array(parsed.suffix(agentTranscriptWindow))` (`:8899–8901`).

Engine merge/sort (when rows are *read* from engine) is timestamp-ordered in
`ingestHistoryRowsLocked` (`ChatEngine.swift:9505–9513`) and assembled by
`mergedChatRowsLocked` (`ChatEngine.swift:9215`). The list re-derives presentation
order on every `setRows`.

---

## 2. Where is a row's height decided?

### Entry: collection delegate

`collectionView(_:layout:sizeForItemAt:)` — `ChatListView.swift:13309`.

```
indexPath out of range → width × 56
kind == .day           → width × 30
else:
  extras = groupMeasurementExtras(at:)     // :2131
  bubbleHeight =
    usesProgressiveTranscriptSizing
      ? presentationSeedMessageHeight(row, rowWidth: extras.measurementWidth)  // :13935
      : estimateMessageHeight(row, rowWidth: extras.measurementWidth)          // :14093
  return CGSize(width, bubbleHeight + extras.extraTop)
```

`groupMeasurementExtras` narrows width for the group avatar gutter and adds top
for sender name / run spacing / forwarded header (`:2131–2148`). That top is
**outside** the bubble-height caches.

### Distinct functions that return a height

| Function | Location | Measure vs estimate |
|---|---|---|
| `sizeForItemAt` (day / OOB) | `:13311–13318` | **Estimate** (constants 56 / 30) |
| `presentationSeedMessageHeight` | `:13935` | Mixed: cache/persist lookup; **measures** voice/videoNote/sticker/media/document/plain-text and live agent turns; **estimates** settled agent text (`boundingRect` + char formula, cap 430) |
| `estimateMessageHeight` | `:14093` | Despite the name: for agent turns and ordinary messages this path **measures** via `measureMessageBubbleLayout` (after cache/persist miss). Pills: constant 36 + actions |
| `measureMessageBubbleLayout` | `ChatListViewCells.swift:4712` | **Measure** — real layout math: agent turn via `VibeAgentTurnContentView.measuredHeight` (`:4755`); text via attributed `boundingRect` / rich text; media sizes + caption metrics |
| `serviceDecisionActionsHeight` | `ChatListViewCells.swift:2338` | **Estimate** (action chrome under service pill) |
| `promotePersistedHeightIfAvailable` | `:6198` | Neither: **disk/in-memory promote** of a previously measured height |
| Warmup path | `performNextProgressiveHeightWarmup` `:6854` | Calls seed height then `estimateMessageHeight` to correct (`:6927–6931`) |
| `reloadAgentTurnStateRow` | `:12516` | Forces re-measure via `estimateMessageHeight` after cache drop (`:12538`) |
| `applyHeightCorrections` | `:8063` | Re-measure batch via `estimateMessageHeight` (`:8072`) |

**Naming trap:** `estimateMessageHeight` is the **exact** path when progressive
sizing is off (and for warmup “exact”). `presentationSeedMessageHeight` is the
**cheap / progressive** path that still measures many ordinary kinds so they do
not shift later.

### Caches and what invalidates them

| Cache | Declared | Written | Read | Invalidation |
|---|---|---|---|---|
| `messageHeightCache` | `:1426` | After measure in seed/exact paths (`:13985`, `:14004`, `:14022`, `:14046`, `:14168`); promote from disk (`:6229`, `:6284`) | `presentationSeedMessageHeight` / `estimateMessageHeight` / `hasExactProgressiveHeight` | Key removed when row leaves list (`:8960`); group flag flip clears all (`:1735`); stale-guess / media decode / slot repair / tall toggle / height audit; filter live keys on warm restore (`:6519`, `:10602`) |
| `agentTurnHeightCache` | `:1417` | Live agent measure (`:14068`); exact agent measure (`:14136`); promote (`:6231`, `:6286`) | Same lookup chain for agent turns | Same family of removals (`:8961`, `:1736`, etc.) |
| `persistedHeightsByKey` + on-disk file | promote/load around `:6198`, write `:6319` | After measures (debounced `schedulePersistRowHeights` `:6291`); restore on open | `promotePersistedHeightIfAvailable` | Miss / signature mismatch leaves entry; successful promote removes from `persistedHeightsByKey` (`:6278`); provisional never admitted (`:6355–6360`); media decode / slot repair remove key (`:19582`, `:7953`) |
| `seedTrustedHeightKeys` | used with seed trust | When seed trusts persisted without full sig (`:6233`) | Post-appear height audit | Cleared on media/slot repair (`:19583`, `:7954`) |
| Warm snapshot heights | `rememberWarmTranscript` / restore | On setRows success (`:8924–8929`) | Warm reopen | Filtered to live keys (`:6519–6520`) |
| `rowHeightOriginByKey` | via `noteRowHeight` `:13884` | Every height decision stamps origin for `[HeightShift]` logs | Diagnostics | Cleared with group flag (`:1737`) |

Cache hit conditions (exact path): same `rowWidth`, same `AgentTurnBubbleState`,
`chatListRowContentEqual`, and for agent turns matching `contentVersion`
(`:14110–14114`, `:14145–14149`). Progressive path also rejects
`cachedHeightIsStaleGuess` for ordinary messages (`:13956–13960`).

### Every place a height for an already-visible row can change after the fact

This is the shift surface. Each entry can move content under/above the viewport.

1. **Progressive height warmup** — `scheduleProgressiveHeightWarmup` / `performNextProgressiveHeightWarmup` (`:6820`, `:6854`). Compares seed height vs exact; on delta invalidates layout and re-anchors (`:6932–6965`). Logs `[HeightShift] warmup`.

2. **`cachedHeightIsStaleGuess`** (`:13917`) — provisional media height still cached after natural aspect becomes known in memory. Forces miss → re-measure on next size query.

3. **`promotePersistedHeightIfAvailable` seed trust + later audit** — seed may trust width-only (`:6223–6235`); post-appear audit re-validates signatures and may drop + remeasure + `reloadItems` (`:7830–7897`).

4. **Media natural-size correction** — `handleResolvedMediaSize` (`:19558`) drops caches and calls `repairProvisionalMediaHeights` → `applyHeightCorrections` (`:19590`, `:8031`, `:8063`).

5. **Slot mismatch repair** — `repairMismatchedSlot` (`:7940`) when cell bubble height ≠ slot; coalesced async batch + agent-estimate screen sweep (`:7987–7990`).

6. **`applyHeightCorrections` / `repairProvisionalMediaHeights`** — batch remeasure with optional `contentOffsetAdjustment` for rows above viewport (`:8063–8126`).

7. **Tall / expand local state** — `reloadAgentTurnStateRow` (`:12516`): drops height cache for expand state, remeasures, batch reconfigure (`:12533–12558`).

8. **Streaming agent growth inside `setRows`** — for height-changing reloads, caches busted per reloaded key (`:9798–9800`), remeasured; in-place stream uses `reconfigureItems` + invalidate so the same cell grows (`:9767–9786`).

9. **Group flag late flip** — `setIsGroupOrChannel` clears both height caches and reconfigures (`:1735–1739`).

10. **Removed-key eviction on setRows** — stream-id → final UUID swaps drop old heights (`:8955–8962`); new key starts cold (may estimate then measure).

11. **Agent-mode only: streaming text layout invalidation** — `handleAgentStreamingTextLayoutInvalidated` (`:19593`); bails unless `agentChatMode` (`:19600`). Normal chat relies on setRows chunks instead.

12. **Warmup / setRows progressive mode gate** — `usesProgressiveTranscriptSizing` toggled by seed mount (`:8380`) and by parse count vs `largeTranscriptThreshold` (`:8910`). Switching progressive on/off changes which of seed vs exact runs first paint.

**Not a height API but visible shift:** day separators and group `extraTop` change
item height without going through message height caches (`:13317`, `:2131–2148`).

---

## 3. Where does a message enter the app?

`ChatEngine` serial queue: `private let queue = DispatchQueue(label: "vibe.chat.engine")`
(`ChatEngine.swift:382`). Virtually all history/live mutations run on that queue
(`syncOnQueue` or `queue.async`). Socket frames hop onto it immediately
(`handleNativeSocketFrame` `:7692`).

### Storage dual-write

| Store | Role |
|---|---|
| `liveMessageRowsByChat` | Optimistic sends, socket messages, streams, mutations (`upsertLiveMessageRowLocked` `:9580`) |
| `historyRowsByChat` | HTTP history / local cache restore / saved messages (`applyChatHistoryResponseLocked` `:13314`, restore paths) |

`getChatRows` merges both on the engine queue (`:5595–5614` → `mergedChatRowsLocked`).

### Entry points (outside → engine history/live rows)

| Path | Function | Line | Payload shape | Thread | Completeness |
|---|---|---|---|---|---|
| **Socket: chat message** | `handleNativeSocketFrame` → `applyNativeIncomingMessageEventLocked` | `:8205–8207`, `:10285` | Phoenix frame on `chat:<id>`, event `"message"`; payload map with `id`/`message_id`, `fromId`, `encryptedContent` / agent `plainContent`, media fields, `metadata` | Socket callback → **`queue.async`** (`:7692`) | **Yes** — upserts live row (`:10472`) |
| **Socket: agent stream** | `applyAgentStreamLocked` | `:7957–7958`, `:6428` | event `"agent-stream"`; `streamId`, `status`, progress nodes, text, `taskId`, team fields | engine **queue** | **Yes** — live synthetic agent row (`:6869+`, upsert via stream path) |
| **Socket: agent bridge history** | `applyAgentBridgeHistoryResultLocked` → `ingestAgentBridgeSessionLocked` | `:7988–7990`, `:6217`, `:3162` | event `agent-bridge-history`; detail mode `session.messages: [[String:Any]]` | engine **queue** | **Yes** — session messages into live/history-style rows (session ingest) |
| **Socket: edits/deletes** | `applyNativeChatMutationEventLocked` | `:10535` | `message-edited` / `message-deleted` (+ optional nested `message` for cold hydrate) | engine **queue** (via frame handler) | **Yes** — live upsert or tombstone |
| **Socket: receipts** | `applyNativeChatEventLocked` | `:10694` | `message-delivered` / `message-read` | engine **queue** | Status only (not new text body) |
| **User-topic mirror** | `ingestMirroredUserTopicMessageLocked` | `:10260` | Same message map as incoming when chat topic not joined | engine **queue** | **Yes** — calls `applyNativeIncomingMessageEventLocked` |
| **Local send** | `sendMessage` | `:3805` | Public API dict: `chatId`, `type`, `text`, media fields, `metadata`, ids | Caller thread enters; optimistic upsert on **`syncOnQueue`** (`:3893`, `:4000`) | **Yes** — primary optimistic write |
| **HTTP chat history** | `applyChatHistoryResponseLocked` | `:13314` | JSON array or `{data\|messages: [...]}` → `buildHistoryRowsLocked` → `ingestHistoryRowsLocked` | Network completion → engine **queue** | **Yes** — writes `historyRowsByChat` (`:13379`) |
| **Saved messages history** | `applySavedMessagesHistoryResponseLocked` | `:13429` | Saved-items JSON → history rows | engine **queue** | **Yes** |
| **LAN bridge** | `ingestLanBridgeEvent` / `Locked` | `:6060`, `:6066` | type `history_result` / `progress` / `result` / status | Public API → **`queue.async`** | History via `applyLanHistoryResultLocked` (`:6208`); progress → `ingestLanProgressLocked` (`:6312`) → `applyAgentStreamLocked` with `streamId = lan-<taskId>` |
| **Local history restore** | `restoreCachedHistoryRowsLocked` (via `getChatRows` / load paths) | called from `:5599`, assignments e.g. `:12140`, `:12771`, `:12918`, `:13079` | SQLite/message store rows | engine **queue** | **Yes** — repaints `historyRowsByChat` without network |
| **Team worker fold** | `mergeSuppressedTeamWorkerStreamLocked` | from stream / `agent-team-worker` (`:7962`) | team worker payload | engine **queue** | Updates lead row metadata; not a separate list cell when suppressed |

**Plain complete set of writes to engine row stores:** any path that ends in
`upsertLiveMessageRowLocked` (`:9580`), `historyRowsByChat[chatId] = …`,
`liveMessageRowsByChat[chatId] = …` (including mutate helpers), or delete/tombstone
helpers (`markLiveMessageDeletedLocked`, `removeMessageIndicesLocked`). The table
above is the **external ingress** set; internal replays (outbound queue, settle,
pin apply) mutate the same stores but are not new network sources.

**List view does not write engine history.** It reads via `getChatRows` /
`getLiveMessageRow` and holds local overlays (`nativeOutgoingRowsById`,
`nativeEngineRowsById`) that merge in `mergedRowsPayload` (`ChatListView.swift:14789`).

---

## 4. What is `ChatListRow` and what does building one cost?

### Type

`struct ChatListRow` — `ios/ChatModule/ChatListViewModels.swift:71`.

Primary failable initialiser: `init?(raw: [String: Any])` — `:705`.

(Other inits at `:2175` / `:2212` belong to a **different** transition type later in
the same file, not `ChatListRow`.)

### `init?(raw:)` behaviour

1. Requires top-level `kind` (`:706–708`).
2. **`kind == "day"`** — cheap constant fill, early return (`:713–789`).
3. **`kind == "message"`** — requires nested `message: [String: Any]` (`:792–794`); otherwise `nil`.
4. Field extraction is dictionary key probing (camelCase + snake_case aliases) for
   text, media, forward chrome, stickers, agent flags, event-inbox flags, service
   messages (`:797–1196`).
5. **JSON / structure parsing (per row, when present):**
   - `parseAgentProgressNodes(metadata?["progressNodes"])` (`:1066`) → walks node
     arrays (`:1702`).
   - `AgentCard.parse` (`:1103–1105`).
   - `parseAgentRuntimeSummary` on plaintext runtime **or** decrypted runtime (`:1131–1133`).
   - `ChatServiceMessage.parse` (`:1193–1195`).
   - Waveform / string arrays / reply preview maps.
6. **Decryption (per row, when ciphertext present):**
   - `AgentRuntimeCrypto.decrypt(metadata/message agentRuntimeEnc)` (`:1122–1123`).
   - Comment at `:594–596`: `agentActionEnc` / `agentActionsEnc` stay **opaque**
     here; decrypted at **render** time with the phone-held key — not in this init.
7. **No full-message E2E hybrid decrypt in `ChatListRow.init`.** Wire decryption for
   peer ciphertext happens earlier in `ChatEngine.applyNativeIncomingMessageEventLocked`
   (`ChatEngine.swift:10326–10340`) when building engine row maps. By list time,
   `message["text"]` / `plainContent` are usually plaintext (or empty / failed).
8. **No `NSAttributedString` work in the init.** Attributed layout is deferred to
   measure/render (`measureMessageBubbleLayout` → `bubbleDisplayAttributedString`,
   `ChatListViewCells.swift:4849+`).

### Cost: per-row vs amortised

| Work | When | Amortisation |
|---|---|---|
| Dict probing + type inference (`visualKind` is computed property `:639`) | Every successful init | None |
| Progress node parse | Every agent row with nodes | None per setRows miss |
| `AgentRuntimeCrypto.decrypt` | Rows with `agentRuntimeEnc` | None; comment notes init runs every setRows (`:1109–1111`) |
| Day row init | Day separators | Trivial |
| **Parse reuse** | `parsedRowsReusingCache` (`ChatListView.swift:6435`) | If raw `NSDictionary` equal for same key, **skips** re-init (`:6445–6449`) |
| Height caches | After first measure | Amortises layout cost across layout passes |
| Persisted heights | Disk restore | Amortises measure across launches |
| Engine-side decrypt | Once at ingest | Amortised vs list re-parse |

Streaming agent ticks still re-enter `setRows` → merge → parse (coalesced ~50 ms,
`:15179–15200`); reuse cache only helps when the raw dict is bitwise equal.

---

## Seams for the core

Smallest set of functions that must change (or be bypassed) for **row ordering**
and **row height** to come from a Rust timeline core. Ranked by **blast radius**
(how many other paths break if this is wrong).

### Rank 1 — highest blast radius

1. **`ChatListView.applyRows` (`:8618`) / `setRows` / `setAuthoritativeRows`**  
   Sole pipeline that commits display `rows` order after filters. Core ordering
   must either feed here as pre-ordered authoritative payloads, or replace the
   merge/filter/day-separator stages (`mergedRowsPayload`, `rowsByInsertingDaySeparators`,
   bridge windowing). Dual paths here = double truth.

2. **`collectionView(_:layout:sizeForItemAt:)` (`:13309`) +
   `presentationSeedMessageHeight` / `estimateMessageHeight`**  
   All item heights for layout. Core heights must be the single source for
   `sizeForItemAt` (including day rows / group extras policy). Leaving progressive
   seed estimates alive beside core heights reintroduces visible shifts.

3. **`measureMessageBubbleLayout` (`ChatListViewCells.swift:4712`)**  
   Still needed for *render* layout and send-morph projection (`:14679`), but must
   not independently redefine list slot height if core owns slots. Mismatch →
   `repairMismatchedSlot` churn.

### Rank 2 — high (post-hoc height movers)

4. **`performNextProgressiveHeightWarmup` (`:6854`) +
   `usesProgressiveTranscriptSizing`**  
   If core heights are exact, warmup should no-op or only verify; if both measure,
   list still shifts.

5. **`applyHeightCorrections` / `repairProvisionalMediaHeights` /
   `handleResolvedMediaSize` / `repairMismatchedSlot`**  
   All assume UIKit may have been wrong. With core authority, either core is
   updated when media aspect resolves, or these stay as temporary compatibility
   shims with a single invalidation path back into core.

6. **Height caches + persist (`messageHeightCache`, `agentTurnHeightCache`,
   `promotePersistedHeightIfAvailable`, `persistRowHeightsNow`)**  
   Either become a thin cache in front of core or are deleted; two durable stores
   will disagree on reopen.

### Rank 3 — ordering / payload edges

7. **`mergedRowsPayload` (`:14789`) + native overlays
   (`nativeOutgoingRowsById`, `nativeEngineRowsById`)**  
   Optimistic and engine overlay merge can reorder relative to core if not
   represented in the same model.

8. **`ChatEngine.mergedChatRowsLocked` / `getChatRows` (`:9215`, `:5595`) +
   ingest writers (`applyNativeIncomingMessageEventLocked`, `sendMessage`
   optimistic upsert, `applyAgentStreamLocked`, history ingest)**  
   Core must observe the same complete write set (section 3) or the list will
   re-merge Swift-side and drift.

9. **Presentation seed mount (`rows = seedRows` at `:8366`) and warm restore
   (`:6563`)**  
   Bypass normal setRows; must seed from core (or be disabled) or first paint
   order/height diverge from post-appear reconcile.

### Rank 4 — smaller but still dual-path risks

10. **`reloadAgentTurnStateRow` (`:12516`)** — local expand height without setRows.  
11. **`setIsGroupOrChannel` row rewrite + cache clear (`:1722–1736`)** — geometry.  
12. **`setEventInboxModeEnabled` prune (`:10917`) / `setSearchQuery` (`:16054`)** —
    filtered views of the same underlying order.  
13. **`ChatListRow.init?(raw:)` (`ChatListViewModels.swift:705`)** — still needed for
    cell configure unless core ships fully typed rows; decrypt/parse cost remains
    on the Swift side until moved.

### Minimal “swap surface” summary

| Concern | Must own | Today’s owners |
|---|---|---|
| Order | Core | `applyRows` filters + `mergedRowsPayload` + engine merge sort |
| Height | Core (per key/width/state) | `sizeForItemAt` → seed/exact → `measureMessageBubbleLayout` + 6 post-hoc correctors |
| Ingress | Engine (or core ingest) write set in §3 | `liveMessageRowsByChat` / `historyRowsByChat` |

**Shadow probe already observes raw setRows payloads** at `applyRows` (`:8654–8663`,
`VibeTimelineShadowProbe`) — comparison only; it does not yet drive order or height.

---

## Notes / open gaps

- Exact line ranges inside `mergedRowsPayload` merge rules: surveyed at definition
  `:14789`; full branch matrix **not** expanded here (large function).  
- Complete list of every `historyRowsByChat[chatId] =` internal assign beyond the
  ingress table: many restore/replay helpers; all sit on the engine queue.  
- Whether JS/RN still pushes rows on any production path beyond
  `ChatConversationController`’s `source` string: hosts call `setRows` vs
  `setAuthoritativeRows` from `AppHomeView.swift:11630`; further JS bridge
  mapping **unverified** in this pass.
