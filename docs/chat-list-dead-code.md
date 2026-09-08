# Chat list dead code sweep — 2026-08-03

Baseline: ed59159 · passes run: 2

Scope: `ios/ChatModule/ChatListView.swift`, `ios/ChatModule/ChatListViewCells.swift` only.
No behaviour change — unreferenced symbols only. Evidence for every Tier A row is a
whole-`ios/` `rg` on `*.swift` where the sole hit is the declaration.

## Tier A — removed

| Symbol | File:line (before) | Kind | Evidence | Lines removed |
|---|---|---|---|---|
| `formatNativeMusicPlayerTime(_:)` | ChatListView.swift:559 | private func | only hits were decl + body of dead `ChatNativeMusicPlayerBar` | 6 |
| `ChatNativeMusicPlayerBar` | ChatListView.swift:565 | private class | sole hit was the class decl; superseded in-tree by `NativeMusicPlayerBannerView` / `NativeMusicPlayerRootOverlay` (other files) | 219 |
| `lastOverlapProbeAt` | ChatListView.swift:13761 | private var | sole hit was the decl (commented GroupCellOverlap probe never re-wired) | 6 |
| `appendOverlapProbeLine(_:)` | ChatListView.swift:13808 | private static func | sole hit was the decl | 15 |
| `rawRowStableIdentity(_:)` | ChatListView.swift:14437 | private func | sole hit was the decl | 13 |
| `startDotPulseAnimation()` | ChatListView.swift:22442 | private func | sole hit was the decl; `stopDotPulseAnimation` still called from `hideActivityOverlay` | 14 |
| `bubbleBoldRegex` | ChatListViewCells.swift:12 | private let | sole hit was the decl | 1 |
| `chatMediaDiskCacheDir()` | ChatListViewCells.swift:128 | private func | sole hit was the decl; live path uses `VibeMediaVault` directly | 3 |
| `migrateLegacyMediaCacheFolder(named:into:)` | ChatListViewCells.swift:132 | private func | sole hit was the decl (never called after vault migration) | 15 |
| `chatMediaPreviewVideoCacheDir()` | ChatListViewCells.swift:375 | private func | sole hit was the decl; callers use `VibeMediaVault.shared` with `.videoPreview` | 3 |
| `bubbleMetaPendingFont` | ChatListViewCells.swift:1577 | private let | sole hit was the decl | 1 |
| `bubbleStatusCheckStrokeWidth` | ChatListViewCells.swift:1584 | private let | sole hit was the decl | 1 |
| `formatDownloadSizeCaption(downloadedBytes:totalBytes:)` | ChatListViewCells.swift:2008 | private func | sole hit was the decl; sibling `formatDownloadByteCount` still used | 12 |
| `musicMessageCardArtTop` | ChatListViewCells.swift:3070 | private let | only used to build unused `musicMessageCardHeight` | 1 |
| `musicMessageCardArtMaxSide` | ChatListViewCells.swift:3071 | private let | only used to build unused `musicMessageCardHeight` | 1 |
| `musicMessageCardArtBottomGap` | ChatListViewCells.swift:3072 | private let | only used to build unused `musicMessageCardHeight` | 1 |
| `musicMessageCardTextBlockHeight` | ChatListViewCells.swift:3073 | private let | only used to build unused `musicMessageCardHeight` | 1 |
| `musicMessageCardBottomPad` | ChatListViewCells.swift:3074 | private let | only used to build unused `musicMessageCardHeight` | 1 |
| `musicMessageCardHeight` | ChatListViewCells.swift:3075 | private let | sole hit was the decl; live music-URL card uses `bubbleMusicLinkPreviewHeight` / `bubbleMusicLink*` | 3 |
| `bubbleMusicPreviewURL(for:)` | ChatListViewCells.swift:3440 | private func | sole hit was the decl; height/min-width helpers call `bubbleIsMusicPreviewURL` directly | 5 |
| `agentTurnContentWidthConstraint` | ChatListViewCells.swift:9563 | private var | sole hit was the decl; width applied without this stored constraint | 1 |

Total: **21 symbols**, **329 lines** (`git diff --numstat`: 274 + 55).

### Pass notes

- **Pass 1:** removed the 15 zero-ref private symbols found by full private-decl scan, plus the closed `musicMessageCard*` constant graph and `formatNativeMusicPlayerTime` (only referenced from the dead player bar).
- **Pass 2:** re-ran the same private/fileprivate scan over both files after the edit — **0** new zero-ref symbols. Stopped.

### Structural check (no build)

- `ChatListView.swift`: braces `{`/`}` count balanced (3751/3751).
- `ChatListViewCells.swift`: braces `{`/`}` count balanced (2263/2263).
- Diff is pure deletions; no renames, reorder, or call-site rewires.

## Tier B — reachable but superseded (NOT touched)

| Symbol | File:line | Called by | Superseded by | Why left alone |
|---|---|---|---|---|
| `presentationSeedMessageHeight(_:rowWidth:)` | ChatListView.swift:13738 | `sizeForItemAt` when `usesProgressiveTranscriptSizing`; progressive warmup; seed estimate paths | `estimateMessageHeight` is the “exact” path (seams map §2) | Both are load-bearing under progressive vs exact sizing; deleting either changes layout |
| `estimateMessageHeight(_:rowWidth:)` | ChatListView.swift:13896 | `sizeForItemAt` when progressive off; warmup correction; `applyHeightCorrections`; agent reload; etc. | Progressive seed path when flag on | Same dual-path contract as seams map |
| `setPeerTyping(_:)` | ChatListView.swift:22189 | engine/host path at ~12602 (`setPeerTyping(false)`) | Argument ignored; body forces `next = false` | Still invoked; typing chrome is stubbed but reachable |
| `updateActivityOverlayState()` | ChatListView.swift:22196 | `setPeerTyping` | Always calls `hideActivityOverlay()` | Dead *effect* for show path, but call graph still live |
| `stopDotPulseAnimation()` | ChatListView.swift:22183 | `hideActivityOverlay` completion | Pair was `startDotPulseAnimation` (removed) | Still called; removing it is a behaviour/edit of a live path |
| `activityOverlay` / `activityDots` / setup | ChatListView.swift (~1713+, ~22350+) | layout + hide path | Typing/show path never arms overlay | Infrastructure still constructed and laid out |
| `lastScrollDeltaY` | ChatListView.swift:1407 | written in scroll handler ~13180 | (none — write-only) | Written each scroll; never read — keep for lead (possible unfinished diagnostic) |
| `reactionDebugTargetEmoji` | ChatListView.swift:1292 | written in reaction apply ~14387 | (none — write-only) | Stored for debug that no longer reads it |
| `chatGapDebugOverlayEnabled` | ChatListView.swift:567 | gates gap overlay helpers | permanently `false` | Flag still consulted; not unreferenced |
| `chatListMediaVerboseDebugLogs` (and cell `chatCell*DebugLogs`) | ChatListView.swift:49; ChatListViewCells.swift:7–11 | many `chatListDebugLog` / cell log sites | permanently `false` | Still referenced; dead *output*, not dead symbols |
| `bubbleMusicLink*` height constants | ChatListViewCells.swift:~3020 | music URL card layout + `bubbleRowPreviewHeight` | (live path for SoundCloud/YouTube cards) | Not superseded — this is the remaining music-card height source after deleting `musicMessageCard*` |
| `usesAudioMetadataVoiceLayout` | ChatListViewCells.swift:~2008 area | music `type:` rows, player queue, bubble layout | compact voice-metadata cell vs tall link card | Live fork for agent `type: music` rows |

## Excluded — looked dead, kept anyway

| Symbol | Why it is actually reachable |
|---|---|
| Anything `public` / `open` on `ChatListView` / cells | Cross-module / host surface; brief forbids deletion even if ios-grep is quiet |
| `UICollectionViewDataSource` / `Delegate` / `FlowLayout` / scroll / gesture methods | Protocol requirements; invoked by UIKit |
| `override` lifecycle (`layoutSubviews`, `prepareForReuse`, `init`, `deinit`, …) | Framework entry points |
| `@objc` selectors inside live types (`#selector`, `addTarget`) | String/runtime dispatch |
| Nested members of `ChatNativeMusicPlayerBar` (`handleTogglePlayback`, `handleClose`, …) | Deleted *with* the dead class in Tier A, not left behind |
| `messageId(fromRawRow:)` | Still used by reply/twin/media merge paths after `rawRowStableIdentity` removal |
| `formatDownloadByteCount` / `chatDownloadByteCountFormatter` | Still used by media caption chrome (~14528 area) after caption helper removal |
| `stopDotPulseAnimation` | Called from `hideActivityOverlay` |
| `sweepGroupAgentCellIntegrity` | Live post-batch integrity sweep; only the unused overlap *probe* var/helper went away |
| Low-hit private helpers (1–2 same-file refs) | Callers present; not zero-ref |

## Method

1. Read `docs/chat-list-seams-map.md` and `docs/production-timeline-core-refactor.md` for load-bearing row/height paths.
2. Extract every `private`/`fileprivate` `func`/`var`/`let`/`class`/`struct`/`enum`/`typealias` in the two files (~1500 decls).
3. `rg -n --glob '*.swift' '\bName\b' ios/` per unique name; Tier A only when non-declaration hits == 0.
4. Skip `@objc` / `override` / public / protocol / lifecycle even if grep looked empty.
5. Delete whole decls (including doc comments); cascade closed reference graphs (`musicMessageCard*`, player time helper + bar).
6. Re-scan until a pass finds nothing new (2 passes).
7. No `xcodebuild`, commit, or push — lead verifies.
