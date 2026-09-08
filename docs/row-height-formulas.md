# Chat list row height formulas

Read-only inventory of how every transcript row kind gets its **cell height**
today. Purpose: exact inputs for a pure off-main height function that must
reproduce current numbers (no design, no proposed rewrite).

**Pipeline (every non-day message row):**

```
collectionView(_:layout:sizeForItemAt:)          ChatListView.swift:13333
  width = bounds.width - messageHorizontalInset * 2     // 8 * 2
  if row.kind == .day → height 30
  if index OOB → height 56
  extras = groupMeasurementExtras(at:)                   // :1925
  bubbleHeight =
    usesProgressiveTranscriptSizing
      ? presentationSeedMessageHeight(row, extras.measurementWidth)  // :13941
      : estimateMessageHeight(row, extras.measurementWidth)          // :14099
  return CGSize(width, bubbleHeight + extras.extraTop)
```

**Returned height always includes** `extras.extraTop` (group name / run gap /
forwarded header). That top is **outside** bubble-height caches
(`ChatListView.swift:13359`, `groupMeasurementExtras` `:1925–1942`).

**Naming trap:** `estimateMessageHeight` is the **exact** path (measures via
`measureMessageBubbleLayout` after cache miss). `presentationSeedMessageHeight`
is the progressive path; for most ordinary kinds it also measures. Settled agent
turns are the big seed-vs-exact disagreement (see §1 Agent turn + §1.1).

`visualKind` is derived on `ChatListRow` (`ChatListViewModels.swift:639–695`):
`.text | .voice | .video | .videoNote | .media | .document | .sticker`.
`row.kind` is `.day | .message` (`:489–491`).

---

## Section 1 — formulas by row kind

Shared width prelude used by almost every branch of
`measureMessageBubbleLayout` (`ChatListViewCells.swift:4659`):

```
maxBubbleWidth   = floor(rowWidth * bubbleMaxWidthFactor)     // 0.85
maxContentWidth  = max(1, maxBubbleWidth - bubbleHorizontalPadding * 2)  // −24
meta             = bubbleMetaWidths(for: row)                // :2306
```

Final row height reported to the collection view (when using measure metrics):

```
cellHeight = metrics.bubbleHeight + metrics.tallOuterToggleReserve + extras.extraTop
```

`tallOuterToggleReserve` is always set to `0.0` today (`:4783`, `:5165`;
`tallBubbleGlassOuterReserve = 0` in constants). Overlay chip does not grow the cell.

Reaction add-on (many kinds):

```
stripHeight          = rows * reactionChipHeight(24) + (rows - 1) * reactionChipRowGap(4)
reactionHeightOffset = stripHeight
                     + reactionStripTopGap(4)
                     + max(0, reactionStripBottomInset(6) - bottomPadding)
```

The strip is laid out `reactionStripBottomInset` above the plate's bottom edge, so the
plate only grows by the pill plus its gap — one row costs 28 on a text bubble, 34 where
there is no bottom padding (full-bleed media, sticker).

---

### 1. OOB / missing index

| Field | Value |
|---|---|
| **Kind** | `indexPath.item >= rows.count` |
| **Entry** | `ChatListView.swift:13338–13339` |
| **Inputs** | collection width only |
| **Formula** | `height = 56.0` (width = `bounds.width − 16`) |
| **UIView dependency** | none |
| **Notes** | Constant placeholder |

---

### 2. Day separator

| Field | Value |
|---|---|
| **Kind** | `row.kind == .day` |
| **Entry** | `ChatListView.swift:13343–13344` |
| **Inputs** | none (ignores text length) |
| **Formula** | `height = 30.0` |
| **UIView dependency** | none |
| **Notes** | Does not call seed/exact. Day pill drawing uses `dayPill*` constants but height is fixed 30. |

---

### 3. Service / system pill (divider + error notice)

| Field | Value |
|---|---|
| **Kind** | `agentSystemDividerText(for: row) != nil` **or** `agentErrorNoticeText(for: row) != nil` — covers: `agentMsgKind == "summary"` → "Context compacted"; group membership / decision notices (`groupSystemNoticeText`); interrupted turns; `isAgentError` settled humanized error (`ChatListViewCells.swift:2186–2304`) |
| **Entry** | Seed: `presentationSeedMessageHeight` `:13942–13943`. Exact: `estimateMessageHeight` `:14103–14104`. Both skip `measureMessageBubbleLayout`. |
| **Inputs** | `row.serviceMessage?.hasLiveActions` |
| **Formula** | `height = 36.0 + serviceDecisionActionsHeight(row)` where `serviceDecisionActionsHeight` = `0` with no live actions, else `40.0 + ChatServiceDecisionCardView.height(risk:detail:)` (risk chip `20+6`, monospaced detail block `54+6`) → **36**, **76**, **102**, **136** or **162** |
| **UIView dependency** | none |
| **Notes** | Seed and exact **agree**. Not a bubble. |

---

### 4. `agent_actions` control row

| Field | Value |
|---|---|
| **Kind** | `row.kind == .message && row.messageType == "agent_actions"` |
| **Entry** | `measureMessageBubbleLayout` `ChatListViewCells.swift:4664–4685` (both seed/exact reach this if not pill) |
| **Inputs** | `rowWidth` only |
| **Formula** | `bubbleHeight = 36.0` (fixed). `bubbleWidth = max(1, rowWidth − bubbleSideMargin * 2)` |
| **UIView dependency** | none |
| **Notes** | Early return; ignores text/media. Group context excludes these from avatar gutter (`ChatListView.swift:1791`). |

---

### 5. Agent turn (rich bridge / tool feed)

| Field | Value |
|---|---|
| **Kind** | `bubbleUsesAgentTurnContent(row) == true` (`ChatListViewCells.swift:2153–2175`): agent message, `visualKind == .text`, not native plain prose, not system/error pill; needs progress nodes / runtime / actions / streaming / `agent_progress_tree` / `bridge-` id; group rows only if team-run lead |
| **Entry** | Shell: `measureMessageBubbleLayout` `:4691–4785`. Content height: `VibeAgentTurnContentView.measuredHeight` `:4702–4711` → `VibeAgentTurnContentView.swift:362–420` |
| **Inputs** | `rowWidth`; `AgentTurnBubbleState` (`isProgressExpanded`, `isRuntimeExpanded`, `expandedStepIds`, `streamingStartDate`, `tallExpanded`); full agent payload (text, progress nodes, runtime, actions); `agentTurnContentWidth(...)` hug vs workspace width (`:4584–4656`); reaction emoji; liveness (`isStreamingText` / `agentTurnRowCouldBeLive`); **live computer band** (`ChatEngine.latestAgentComputer(chatId:)`) |
| **Formula (shell, after `previewHeight` from measuredHeight)** | See below |
| **UIView dependency** | **requires a view**: shared offscreen `VibeAgentTurnContentView` template → `configure` → `layoutIfNeeded` → `systemLayoutSizeFitting` (`VibeAgentTurnContentView.swift:371–420`). Nested body is `VibeAgentKitAssistantMessageBodyView` (stack of loader / steps / text blocks / runtime card). |
| **Notes** | Tall collapse only when `previewHeight > 560` **and** `agentTurnBubbleShowsWorkedSummary(row)` (`:4718–4723`). Live turns quantize height via `agentTurnStreamingReservedHeight` (`ChatListViewConstants.swift:51–54`). |

**Shell arithmetic** (`ChatListViewCells.swift:4712–4748`):

```
contentWidth   = agentTurnContentWidth(row, maxContentWidth:
                   max(1, floor(rowWidth * agentTurnMaxWidthFactor)
                          − agentTurnHorizontalPadding * 2))
                 // agentTurnMaxWidthFactor == 0.85; H-pad 14 each side
previewHeight  = VibeAgentTurnContentView.measuredHeight(... availableWidth: contentWidth ...)
bubbleContentHeight = tallCollapsed
  ? min(previewHeight, tallBubbleCollapsedContentHeight)   // 420
  : previewHeight
bodyPlusPadding = bubbleContentHeight
                  + agentTurnVerticalPadding * 2           // 10 + 10 = 20
                  + reactionHeightOffset                   // 0 or 28
needsHeightFloor = compactThinking
  || (live && bubbleContentHeight < 1)
  || (live && !showsWorkedSummary && bubbleContentHeight < 44)
settledBubbleHeight = needsHeightFloor
  ? max(44, bodyPlusPadding)
  : bodyPlusPadding
bubbleHeight = (isLiveStreaming
  ? agentTurnStreamingReservedHeight(settledBubbleHeight)
    // max(48, ceil(measured/48)*48)  because block = 24*2 = 48
  : settledBubbleHeight)
  + agentTurnComputerBandReserve(row)          // 0 or 34, OUTSIDE the quantize
bubbleWidth = max(26, contentWidth + 14*2)
```

**Computer band (agent-computer-v1 §2)** — a one-line plate under the turn body: browser
host + page title, or terminal + command label. Live for the running turn, frozen after.

| Field | Value |
|---|---|
| **Predicate** | `agentTurnComputerBandState(row)` (`ChatListViewCells.swift`) → `AgentTurnComputerBand?`. Live arm: agent-turn row **and** `agentTurnRowCouldBeLive` **and** `ChatEngine.latestAgentComputer(chatId:)` with a non-empty host (browser) or title (shell). Frozen arm: the turn's own last `computer_*` / `browser_*` progress node, dot off. |
| **Constant** | `agentTurnComputerBandTopGap (8) + agentTurnComputerBandHeight (26)` = **34**, via `agentTurnComputerBandReserve(row)` |
| **Applied at** | (1) `measureMessageBubbleLayout` agent-turn arm, added **after** `agentTurnStreamingReservedHeight` so the 48pt block never swallows it. (2) `ChatListView.presentationSeedMessageHeight` settled-agent estimate (`52 + band`, and `min(430, …) + band`) — same helper, so the two paths cannot drift. |
| **UIView dependency** | none. The band is a **sibling of** `VibeAgentTurnContentView` in `ChatListCell`, not a subview of it, so it never enters the offscreen sizing template and stays a pure constant in both paths. |
| **Cache key** | folded into `contentVersionForAgentTurn` so a live↔offline flip invalidates the cached height; the `"agentComputer"` engine change reloads that row via `reloadAgentTurnStateRow`. |
| **Fixed height** | Deliberate — one line, `byTruncatingTail`, never wraps. Wrapping would make it a measure, not a constant. |

Today the band only shows on a **live** turn, so the settled seed estimate's `+ band` term is
0 by construction; it is called there anyway so widening the predicate cannot desync the paths.

**Seed vs exact for this kind — DISAGREE when settled:**

| Path | Settled agent turn | Live agent turn |
|---|---|---|
| `presentationSeedMessageHeight` | **Estimate formula** (no view) when not live (`:14079–14095`) | Measures via `measureMessageBubbleLayout` (`:14068–14077`) |
| `estimateMessageHeight` | Always measures (`:14113–14141`) | Same |

**Settled seed estimate only** (`ChatListView.swift:14079–14095`):

```
text = trim(plainContent ?? text)
if text.isEmpty → 52.0
textWidth = max(120, rowWidth − 54)
measured = NSString.boundingRect(text, width: textWidth, font: system 16).height
characterHeight = ((text.count + 27) / 28) * 22 + 72
progressHeight  = min(4, agentProgressNodes.count) * 28
height = min(430, max(86, max(measured + 64, characterHeight + progressHeight)))
```

This is **not** the same as exact `measuredHeight` + shell. Cap **430** is seed-only.

---

### 6. Native plain agent prose (not agent-turn shell)

| Field | Value |
|---|---|
| **Kind** | `agentTurnRowIsNativePlainProse(row)` → `bubbleUsesAgentTurnContent` returns false (`:2142–2156`). Ordinary text path. |
| **Entry** | Same as plain text (`measureMessageBubbleLayout` text arm `:5009–5166`). Seed measures (`:14047–14054`). |
| **Inputs / formula** | Identical to §8 plain text |
| **UIView dependency** | `boundingRect` only (or rich-text submeasures if block layout qualifies — usually not for plain prose) |
| **Notes** | Deliberately same live/settled path so settle does not re-measure shell 44→34. |

---

### 7. Transparent agent streaming layout

| Field | Value |
|---|---|
| **Kind** | `usesTransparentAgentStreamingLayout(row)` — **always returns `false`** (`ChatListViewCells.swift:2992–2999`) |
| **Entry** | Dead branch at `:4787–4825` |
| **Formula (if ever true)** | `bodyHeight = textHeight + (previewHeight > 0 ? 8 + previewHeight : 0)`; `bubbleHeight = max(36, bodyHeight + bubbleTopPadding + bubbleBottomPadding)` (= body + 5 + 6) |
| **UIView dependency** | `boundingRect` / rich text |
| **Notes** | Unreachable today. Documented so pure reimpl does not revive it by accident. |

---

### 8. Plain text (user / non-agent-turn)

| Field | Value |
|---|---|
| **Kind** | `row.visualKind == .text` after agent-turn / transparent early exits |
| **Entry** | `measureMessageBubbleLayout` `:5009–5166`. Seed: `:14047–14054` (measure). Exact: cache then same measure (`:14099+`). |
| **Inputs** | Display text (`bubbleDisplayText` / markdown attributed via `bubbleDisplayAttributedString`); font = typing? system 13 : `bubbleMessageFont` (system 16) (`:5023–5025`); `rowWidth` → maxContentWidth; meta widths; reply preview; inline attachment; link/music preview height; RTL; tall expand state; reaction |
| **Formula** | See below |
| **UIView dependency** | **boundingRect only** for plain body; rich path may call other pure measures (code/pack/runtime) — no cell UIView. Pack height is constant. |
| **Notes** | Tall: trigger `fullTextHeight > 560`, not typing, no inline attachment (`:5051–5071`). Collapse cap = `floor(420 / lineHeight) * lineHeight` (line-count based), not raw 420. Floor on bubble: **`max(34, …)`** not 36. |

**Text height:**

```
usesRichTextLayout = bubbleUsesBlockLayout(row)   // code/pack/runtime blocks or >1 block
if usesRichTextLayout:
  textHeight = measureBubbleRichText(...).height   // :3471
else:
  textHeight = ceil(attributed.boundingRect(width: textMaxWidth, …).height)
// tallCollapsed → bubbleTextHeight = min(full, collapsedCapHeight)
```

**Body height** (`:5124–5132`):

```
replyPreviewBlockHeight = hasReplyPreview ? (36 + 6) : 0   // height + spacing

if showsInlineAttachment:
  bodyHeight = replyPreviewBlockHeight
             + max(bubbleTextHeight, 0)
             + inlineAttachmentSpacing (8)
             + inlineAttachmentHeight (48)
             + bubbleMetaTopSpacing (1) + bubbleMetaHeight (14)
else if usesBottomMetaLayout:   // rich / preview / RTL / tall-forced
  bodyHeight = replyPreviewBlockHeight
             + max(bubbleTextHeight, 0)
             + (previewHeight > 0 ? bubbleLinkPreviewSpacing(8) + previewHeight : 0)
             + 1 + 14
else:  // inline meta beside short LTR text
  bodyHeight = replyPreviewBlockHeight + max(bubbleTextHeight, bubbleMetaHeight)
```

**Bubble height** (`:5142–5143`):

```
bubbleHeight = max(34, bodyHeight + bubbleTopPadding(5) + bubbleBottomPadding(6) + reactionHeightOffset)
             = max(34, bodyHeight + 11 + reaction)   // reaction = 28 for one chip row
```

**Preview heights** (`bubbleRowPreviewHeight` `:3392–3395`):

| Condition | Height |
|---|---|
| No previewable URL | 0 |
| Music host (SoundCloud/YouTube etc.) | `bubbleMusicLinkPreviewHeight` = 10+236+10+62+10 = **328** (`:3026–3028`) |
| Other link | `bubbleLinkPreviewHeight` = **78** (`:3006`) |

Preview only if `visualKind == .text`, not typing, not inline attachment, not agent message/mention (`bubblePreviewURL` `:3354–3377`).

**Reply preview** only on `visualKind == .text` with `replyToId` (`hasReplyPreview` `:2451–2455`). Media/voice rows do **not** add reply height in the media switch (reply fields forced 0 at `:4999–5000`).

---

### 9. Rich text blocks (subset of text)

When `bubbleUsesBlockLayout` (`:3289–3310`): agent text with code / agentPack / agentRuntime block(s) or multiple blocks; **not** agent-turn path.

`measureBubbleRichText` (`:3471–3523`) sums block heights + `bubbleRichTextBlockSpacing` (10) between blocks:

| Block | Height source |
|---|---|
| `.text` | `ChatNativeAgentTextRenderer.measuredSize` → `boundingRect` (`ChatAgentStreamingText.swift:670–680`) |
| `.code` | `measureBubbleCodeBlockHeight` (`:3425–3468`): `32 (bar) + 10 + body + 10 + 8`; body = ceil monospaced boundingRect of first 12 lines if collapsed |
| `.agentPack` | `AgentIntegrationPackView.measuredHeight` → constant **`collapsedHeight = 72`** (`ChatAgentStreamingText.swift:2157`, `:2183–2188`) — **no UIView** |
| `.agentRuntime` | `AgentRuntimeSummaryView.measuredHeight` (`:853–876`) — **pure arithmetic**, see §2 |

---

### 10. Voice (waveform)

| Field | Value |
|---|---|
| **Kind** | `row.visualKind == .voice` && **not** `usesAudioMetadataVoiceLayout` (`messageType.lowercased() == "voice"` path) (`:1996–1998`, `:4833–4856`) |
| **Entry** | Media switch `:4833–4856` + common media wrap `:4916–5007`. Seed/exact both measure. |
| **Inputs** | `duration` (clamped 1…30 for width curve only); meta total; maxContentWidth |
| **Formula** | `mediaHeight = 60.0`. Full-bleed-ish voice: `bodyHeight = mediaHeight` (caption block 0 for voice `:4961–4967`). Pads: top **2**, bottom **7**. `bubbleHeight = max(66, 60 + 2 + 7 + reaction) = max(66, 69 + reaction)` |
| **UIView dependency** | none (metrics only) |
| **Notes** | Width uses duration log curve; height is constant 60 media + pads. |

---

### 11. Voice / music file (compact audio metadata cell)

| Field | Value |
|---|---|
| **Kind** | `visualKind == .voice && messageType.lowercased() != "voice"` (`usesAudioMetadataVoiceLayout`) — music/mp3/audio file rows |
| **Entry** | `:4834–4849` |
| **Inputs** | title/detail string widths (fonts 15 semibold / 13 regular) for **width only** |
| **Formula** | `mediaHeight = 68.0`. Same voice pad path: `bubbleHeight = max(66, 68 + 2 + 7 + reaction) = max(66, 77 + reaction)` |
| **UIView dependency** | none |
| **Notes** | Not the tall Telegram link music card (that is text+URL preview, §8). |

---

### 12. Video note (circle)

| Field | Value |
|---|---|
| **Kind** | `visualKind == .videoNote` (`isVideoNote` or type inference) |
| **Entry** | `:4857–4859` + media wrap |
| **Inputs** | none for media box size |
| **Formula** | `targetWidth = 200`, `mediaHeight = 200`. Full bleed if no caption (`usesFullBleedMediaLayout` includes videoNote `:2916–2917`). No caption: `bodyHeight = 200`, `bubbleHeight = max(56, 200 + reaction)`. With caption text: edge/non-edge caption path applies (videoNote can have caption via `hasMediaCaptionLayout` `:2078`). |
| **UIView dependency** | none |
| **Notes** | Square 200 fixed when aspect unknown path not used — always 200×200 before caption chrome. |

---

### 13. Document

| Field | Value |
|---|---|
| **Kind** | `visualKind == .document` |
| **Entry** | `:4860–4872` + media wrap (not full-bleed) |
| **Inputs** | file display name width (15 semibold), type label width (13 regular); maxContentWidth |
| **Formula** | `mediaHeight = documentRowHeight = 62 + 9*2 = 80` (`:2353–2356`). Caption block if text non-empty: not full-bleed, not voice → meta or caption under file row. Without caption: `captionBlockHeight = metaTopSpacing + bubbleMetaHeight = 1 + 14 = 15`; `bodyHeight = 80 + 15 = 95`; pads top 5 bottom 6; `bubbleHeight = max(48, 95 + 11 + reaction) = max(48, 106 + reaction)`. |
| **UIView dependency** | none |
| **Notes** | Document page preview image does not change measured height. |

---

### 14. Photo / image / gif / media grid

| Field | Value |
|---|---|
| **Kind** | `visualKind == .media` (and not treated as file document) |
| **Entry** | `:4873–4910` + wrap `:4916–5007` |
| **Inputs** | natural size (`resolvedMediaNaturalSize` `:2772`); grid count (`chatMediaGridImageCount` `:2938`); caption text; reaction; full-bleed vs edge-caption |
| **Formula — media box** | |
| multi-image grid (`count > 1`) | `targetWidth = maxContentWidth`; `mediaHeight = chatMediaGridLayout(...).height` (`:2965–2989`): `cols = count≤4 ? 2 : 3`; `rowHeight = (width − (cols−1)*2) / cols`; `height = rowCount*rowHeight + (rowCount−1)*2`; tiles capped at 6 |
| known aspect | `ratio = clamp(h/w, 0.2…5)`; `targetWidth = clamp(natural.width, 120…maxContentWidth)`; `mediaHeight = max(84, targetWidth * ratio)`; if `mediaHeight > 380` then `mediaHeight = 380`, `targetWidth = 380/ratio` |
| unknown aspect + has mediaUrl | **square provisional**: `targetWidth = max(120, maxContentWidth)`, `mediaHeight = targetWidth`, `mediaAspectWasUnknown = true` |
| **Formula — bubble** | Full bleed (no caption): `bodyHeight = mediaHeight`, `bubbleHeight = max(56, mediaHeight + reaction)`. Edge caption (image/video + caption): pads inset 1.5 top / 4 bottom; caption gap `mediaCaptionTopGap = 6`; `captionBlockHeight = 6 + captionH + 1 + 14`; etc. Non-edge caption (document-like): gap **8** + caption + meta. |
| **UIView dependency** | none for measure (natural size from payload/cache/header; not UIImageView layout) |
| **Notes** | Provisional square is the main post-open shift source when aspect arrives later. |

---

### 15. Video (file)

| Field | Value |
|---|---|
| **Kind** | `visualKind == .video` |
| **Entry** | Same branch as media (`:4873+`) |
| **Inputs / formula** | Same aspect / 120–maxContentWidth / min height 84 / cap 380 / full-bleed if no caption / edge caption if caption |
| **UIView dependency** | none |
| **Notes** | Grid is media-only (`visualKind == .media`), not video. |

---

### 16. Sticker

| Field | Value |
|---|---|
| **Kind** | `visualKind == .sticker` → `isTransparentStickerMessage` true (`:2904–2906`) |
| **Entry** | Media switch + **transparent sticker** arm `:4950–4953` |
| **Inputs** | natural size if known; else default side 136 |
| **Formula — media box** | With natural: min side 72, max width 152, max height 184 (`:4883–4891`). Default: `stickerDefaultDisplaySide = 136` square (`:4893–4896`). |
| **Formula — bubble** | `bodyHeight = mediaHeight + stickerMetaTopSpacing(1) + bubbleMetaHeight(14)`; `bubbleHeight = bodyHeight + reaction` (**no** top/bottom bubble padding) |
| **UIView dependency** | none |
| **Notes** | Not full-bleed path (transparent sticker excluded from full-bleed `:2910–2911`). |

---

### 17. Reply chrome (on text only)

Not a separate row kind — additive to §8:

```
hasReplyPreview → replyPreviewHeight = 36, block = 36 + 6 = 42
```

Constants: `bubbleReplyPreviewHeight = 36`, `bubbleReplyPreviewSpacing = 6` (`:2341–2342`). Width of preview card affects bubble width only.

---

### 18. Forwarded header (outside bubble)

| Field | Value |
|---|---|
| **Kind** | `row.isForwarded` on any message |
| **Entry** | `groupMeasurementExtras` `ChatListView.swift:1936–1940` |
| **Inputs** | `isForwarded` |
| **Formula** | `extras.extraTop += forwardedHeaderHeight` (**36**) |
| **UIView dependency** | none (constant reserve; view is `ForwardedFromHeaderView` at layout time) |
| **Notes** | Added on **top of** bubble height from seed/exact. Seed/exact formulas do not include it. |

---

### 19. Group sender name + run spacing (outside bubble)

| Field | Value |
|---|---|
| **Kind** | Group (not channel), incoming, attributable message (`groupCellContext` `:1782–1823`) |
| **Entry** | `groupMeasurementExtras` `:1925–1942` |
| **Inputs** | first-of-run name, speaker-run change |
| **Formula** | `extraTop = (showsName ? groupSenderNameHeight(25) : 0) + reservedRunTopSpacing` where `reservedRunTopSpacing = max(context.topSpacing, speakerRunTopSpacing)`; first of run `context.topSpacing = groupRunTopSpacing(6)`; speaker change adds `messageRunSpeakerChangeSpacing(6)` (`:1737–1769`) |
| **Width effect** | `measurementWidth = listWidth − (reservesGutter ? groupAvatarSize+groupAvatarGap : 0)` = listWidth − **35** when gutter (`:1624–1626`, `:1930`) |
| **UIView dependency** | none for height constants |
| **Notes** | Narrower `rowWidth` changes bubble text wrap → can change bubble height independently of `extraTop`. |

---

### 20. Typing / agent_progress_tree (text path)

| Field | Value |
|---|---|
| **Kind** | `messageType == "typing"` or `"agent_progress_tree"` as text (if not agent-turn) |
| **Entry** | Text path; font size 13 for typing (`:5023–5025`); tall collapse **exempt** for typing (`:5052–5053`) |
| **Formula** | Same as text with smaller font; meta widths zero when `agentResponsePlaceholder` (`:2306–2312`) |
| **UIView dependency** | boundingRect only |
| **Notes** | If agent-turn predicates match `agent_progress_tree`, uses §5 instead. |

---

## Section 1.1 — seed vs exact disagreements

| Kind | Seed (`presentationSeedMessageHeight`) | Exact (`estimateMessageHeight`) | Same? |
|---|---|---|---|
| Day | 30 (in `sizeForItemAt`, not seed) | same | yes |
| Pill / system / error | 36 + actions | 36 + actions | yes |
| Voice / videoNote / sticker / video / media / document | `measureMessageBubbleLayout` | same | yes |
| Ordinary text (incl. native plain agent) | `measureMessageBubbleLayout` | same | yes |
| Live agent turn | `measureMessageBubbleLayout` | same | yes |
| **Settled agent turn** | **char / boundingRect estimate, cap 430** (`:14079–14095`) | **`measureMessageBubbleLayout` + Auto Layout** (`:14113+`) | **NO — intentional progressive cheap path** |
| Empty settled agent text on seed | **52** (`:14081`) | measure path (floor/rules of §5) | **likely NO** |

Warmup (`performNextProgressiveHeightWarmup`) compares seed vs exact and corrects deltas — settled agent rows are the main systematic seed miss.

---

## Section 2 — what blocks going off-main

Every height path that currently depends on a `UIView` (or Auto Layout fitting) in the call graph.

### 2.1 `VibeAgentTurnContentView.measuredHeight` — hard case

**Site:** `VibeAgentTurnContentView.swift:362–420`, called from `measureMessageBubbleLayout` `:4702`.

**What it does:**

1. Reset shared static template view.
2. Pin width constraint to `availableWidth`.
3. `configure(row:…)` → maps row via `VibeAgentKitMap`, then configures `VibeAgentKitAssistantMessageBodyView`.
4. `layoutIfNeeded()`.
5. `systemLayoutSizeFitting(width: availableWidth, height: 0)` with vertical `.fittingSizeLevel`.
6. `ceil(size.height)`.

**Cannot be replaced by a single text `boundingRect`.** Body is a vertical `UIStackView` (`spacing = 8` default, custom 6 live / 10 settled after loader/steps) composed of optional arranged subviews:

| Subview | When visible | Height contribution (as built today) |
|---|---|---|
| `teamHeaderLabel` | team run identity | single-line label intrinsic — **UNKNOWN exact pt without fitting** (depends on font/string) |
| `VibeAgentKitAgentLoaderView` | live shimmer or settled "Worked · N steps" when `showsLoaderView` / rules in `configure` (`VibeAgentKitMessageCell.swift:691–751`) | `sizeThatFits`: `max(20, labelHeight)` with optional 15pt icon + 6 spacing (`VibeAgentKitLoaderView.swift:539–553`). Label can wrap (shimmer up to 3 lines). Live "Working · M:SS" clock text can change height over time if multi-line. |
| `stepsStack` | expanded work log / live interleaved feed | **loop over progress items** (`updateStepsList` / `updateStreamingStepsList`). Spacing **9 live / 11 settled** when building list (`:240`); layoutMargins top 2 bottom 4 left 2. Per item: |
| → text narration | `itemType == "text"` | Nested vertical stack; each text block height = `max(lineHeight, measuredSize)` with font 16 / lineHeight **24** via `VibeAgentKitTextRenderer` (`:492–509`); code blocks via `VibeAgentKitCodeBlockView.configure` return height (view-based measure). Spacing 10 between blocks inside narration stack. |
| → `VibeAgentKitStepRowView` | tool steps | Header: title label up to **2 lines** + 5+5 vertical padding (`:1603–1604`); chevron 11×11. Expanded detail stack: detail labels / badges — `preferredHeight` on detail uses `sizeThatFits` loops (`VibeAgentKitLoaderView.swift:867–882` area for related detail chrome). **Per-step expanded height is Auto Layout / sizeThatFits, not a fixed constant.** |
| → `VibeAgentKitTeamWorkerRowView` | teamworker items | Fixed-ish: avatar 22 + vertical pad 5+5 → roughly **32** content band (`:1291–1294`) but status can be multi-attribute; **exact height still from Auto Layout**. |
| answer body blocks | settled / plain-prose live (when body not suppressed) | Text: required height constraint from `VibeAgentKitTextRenderer.measuredSize` (boundingRect + lineHeight 24). Code: `VibeAgentKitCodeBlockView.configure` height. Tall-collapsed: single preview capped `min(max(80, 420−72), measured)` (`:869–872`). |
| `AgentRuntimeSummaryView` | finished turn with diff | Pure formula available (see below) — but live path still sets height via configure + constraint on the template view |

**Fixed chrome on top of pure text (approximate, only when those pieces show):**

- Stack spacing 8 (or 6/10 custom after loader/steps).
- Loader ~20+ pt line (not fixed 36; comments mention ~36 as reserve in collapse math only).
- Worked summary string length affects loader height only via wrapping.
- Expanded steps: **N × (variable step row)** + inter-step spacing — **hard case: loop over subviews**.
- Runtime card: see pure formula in 2.3 if `isExpanded` state known.

**Shell outside the view** (already pure arithmetic in §5): ±20 vertical pad, ±28 reaction, tall min/cap 420/560, streaming quantize to 48, floor 44 under some live conditions, ±34 computer band.

**The computer band is deliberately NOT in this template.** It is a `ChatListCell` sibling
laid out by frame, so it adds a constant to the shell instead of another `systemLayoutSizeFitting`
input. Anything added *inside* `VibeAgentTurnContentView` must be configured on the shared
template identically to the live cell, or measured and rendered heights diverge.

### 2.2 `AgentIntegrationPackView.measuredHeight`

**Site:** `ChatAgentStreamingText.swift:2183–2188`.  
Returns constant `collapsedHeight = 72` (`:2157`). **No UIView.** Off-main safe as pure constant.

### 2.3 `AgentRuntimeSummaryView.measuredHeight`

**Site:** `ChatAgentStreamingText.swift:853–876`. **Pure arithmetic** (no view):

```
teamStripExtra = teamProgressStrip non-empty ? 28 : 0
if !isExpanded:
  return 12 + 36 + teamStripExtra + 12
// expanded:
height = 12 + 36 + teamStripExtra + 1 + 9
       + min(files.count, 4) * 32
       + 3
if command display/executable non-empty: +18
if dirtyBefore: +17
if files.count > 4: +20
return height + 12
```

Used from rich-text measure with `isExpanded: false` only (`ChatListViewCells.swift:3510–3513`). Agent-turn path uses the **view's** configure + height constraint instead of this static function when measuring the full turn template.

### 2.4 `measureBubbleCodeBlockHeight` / `ChatNativeAgentTextRenderer.measuredSize`

**boundingRect only** — off-main safe (fonts + strings). Code expand state is a global storage key (`AgentCodeBlockView.isExpanded`) — pure if that state is passed in.

### 2.5 `VibeAgentKitCodeBlockView.configure` (inside agent-turn template only)

**Requires view** when agent-turn measurement builds code blocks inside the offscreen template. Separate from bubble rich-text code path which uses pure `measureBubbleCodeBlockHeight`.

### 2.6 Paths that do **not** need UIView

- Day / OOB / pill / agent_actions constants  
- All media / voice / sticker / document geometry  
- Plain text `boundingRect`  
- Link/music preview fixed heights (78 / 328)  
- Meta widths (`size(withAttributes:)`)  
- Group/forwarded `extraTop` constants  
- Settled agent **seed estimate** (already pure — but wrong vs exact)

### 2.7 Secondary: anything that only affects post-hoc correction

Not in the first-paint formula but invalidates pure heights later: natural media size discovery (`handleResolvedMediaSize`), tall expand toggle, agent expand step ids, progress streaming. Pure function must take those as **inputs** (aspect, expand sets, content version).

---

## Section 3 — constants

| Constant | Value | Declaration |
|---|---|---|
| `messageHorizontalInset` | 8 | `ChatListViewConstants.swift:4` |
| `bubbleSideMargin` | 2 | `:8` |
| `bubbleHorizontalPadding` | 12 | `:9` |
| `bubbleTopPadding` | 5 | `:11` |
| `bubbleBottomPadding` | 6 | `:13` |
| `bubbleMetaTopSpacing` | 1 | `:14` |
| `bubbleMetaHeight` | 14 | `:15` |
| `bubbleMinWidth` | 26 | `:16` |
| `bubbleMaxWidthFactor` | 0.85 | `:17` |
| `agentTurnHorizontalPadding` | 14 | `:22` |
| `agentTurnVerticalPadding` | 10 | `:23` |
| `agentTurnMaxWidthFactor` | `= bubbleMaxWidthFactor` (0.85) | `:27` |
| `agentTurnStreamingLineStep` | 24 | `:30` |
| `agentTurnStreamingHeightBlock` | 48 (`24*2`) | `:45` |
| `agentTurnStreamingReservedHeight` | `max(block, ceil(m/block)*block)` | `:51–54` |
| `agentTurnComputerBandHeight` | 26 | `ChatListViewCells.swift` (before `agentTurnContentWidth`) |
| `agentTurnComputerBandTopGap` | 8 | same |
| Computer band reserve | **34** (8 + 26) | `agentTurnComputerBandReserve` |
| `tallBubbleCollapseTriggerHeight` | 560 | `:67` |
| `tallBubbleCollapsedContentHeight` | 420 | `:68` |
| `tallBubbleToggleSpacing` | 6 | `:70` |
| `tallBubbleCollapseFadeHeight` | 56 | `:72` |
| `tallBubbleGlassToggleSize` | 34 | `:74` |
| `tallBubbleChevronHitSize` | 40 | `:76` |
| `tallBubbleGlassOuterReserve` | 0 | `:78` |
| `dayPillHorizontalPadding` | 14 | `:59` (pill **draw**, not day row height) |
| `dayPillVerticalPadding` | 3.5 | `:60` |
| Day row height | **30** | `ChatListView.swift:13344` (literal) |
| OOB row height | **56** | `:13339` (literal) |
| Pill base height | **36** | `:13943`, `:14104` |
| Service decision actions | **40** | `ChatListViewCells.swift:2303` |
| `agent_actions` height | **36** | `:4669` |
| Reaction offset | **28** | `:4713`, `:4946`, `:5134` |
| Agent height floor (live/compact) | **44** | `:4739` |
| Transparent streaming floor | **36** | `:4805` (dead path) |
| Text bubble floor | **34** | `:5142` |
| Full-bleed media floor | **56** | `:4984` |
| Voice bubble floor | **66** | `:4985` |
| Non-voice media floor | **48** | `:4985` |
| Voice mediaHeight | **60** | `:4855` |
| Music-file mediaHeight | **68** | `:4849` |
| Voice top/bottom pad | **2 / 7** | `:4978–4981` |
| Video note size | **200×200** | `:4858–4859` |
| Media min width/height (non-sticker) | **120 / 84** | `:4884–4885` |
| Media height cap | **380** | `:4888` |
| Aspect clamp | **0.2…5.0** | `:4882` |
| `stickerMinDisplaySide` | 72 | `:2344` |
| `stickerDefaultDisplaySide` | 136 | `:2345` |
| `stickerMaxDisplayWidth` | 152 | `:2346` |
| `stickerMaxDisplayHeight` | 184 | `:2347` |
| `stickerMetaTopSpacing` | 1 | `:2348` |
| `documentPreviewSide` | 62 | `:2354` |
| `documentRowVerticalInset` | 9 | `:2353` |
| `documentRowHeight` | 80 | `:2356` |
| `mediaCaptionEdgeInset` | 1.5 | `:2924` |
| `mediaCaptionTopGap` | 6 | `:2925` |
| `mediaCaptionBottomPadding` | 4 | `:2926` |
| Non-edge caption gap | **8** (literal) | `:4959` |
| `chatMediaGridGap` | 2 | `:2936` |
| `chatMediaGridMaxTiles` | 6 | `:2935` |
| `inlineAttachmentHeight` | 48 | `:2339` |
| `inlineAttachmentSpacing` | 8 | `:2340` |
| `bubbleReplyPreviewHeight` | 36 | `:2341` |
| `bubbleReplyPreviewSpacing` | 6 | `:2342` |
| `bubbleReplyPreviewMinWidth` | 184 | `:2343` |
| `bubbleLinkPreviewHeight` | 78 | `:3006` |
| `bubbleLinkPreviewSpacing` | 8 | `:3007` |
| `bubbleLinkPreviewMinWidth` | 220 | `:3008` |
| `bubbleMusicLinkArtTop` | 10 | `:3021` |
| `bubbleMusicLinkArtworkHeight` | 236 | `:3025` |
| `bubbleMusicLinkArtBottomGap` | 10 | `:3022` |
| `bubbleMusicLinkTextBlockHeight` | 62 | `:3023` |
| `bubbleMusicLinkBottomPad` | 10 | `:3024` |
| `bubbleMusicLinkPreviewHeight` | **328** | `:3026–3028` |
| `bubbleMusicLinkPreviewMinWidth` | 480 | `:3029` |
| `bubbleRichTextBlockSpacing` | 10 | `:3032` |
| `bubbleMessageFont` | system 16 | `:1552` |
| `bubbleMetaFont` | system 10 medium | `:1553` |
| `bubbleMetaInlineSpacing` | 4 | `:1555` |
| `bubbleMetaItemGap` | 2 | `:1556` |
| `bubbleRTLTailSideReserve` | 0 | `:1557` |
| `bubbleStatusSlotWidth` | 17 | `:1558` |
| `bubbleStatusSlotHeight` | 14 | `:1559` |
| Code block bar / pads | bar **32**, hPad **12**, vPad **10**, trailing **+8** | `:3437–3468` |
| Code collapse line limit | **12** lines | `:3448` |
| `AgentIntegrationPackView.collapsedHeight` | 72 | `ChatAgentStreamingText.swift:2157` |
| Agent runtime collapsed | `12+36+teamStrip+12` | `:853–858` |
| Agent runtime file row | **32** each (max 4) | `:862` |
| Settled agent seed empty | **52** | `ChatListView.swift:14081` |
| Settled agent seed floor/cap | **86 / 430** | `:14092–14094` |
| Settled agent seed char formula | `((n+27)/28)*22 + 72` | `:14089` |
| Settled agent seed progress | `min(4,nodes)*28` | `:14090` |
| Settled agent seed width | `max(120, rowWidth−54)` | `:14082` |
| Seed measured pad fudge | `measured + 64` | `:14094` |
| `groupAvatarSize` | 29 | `ChatListView.swift:1624` |
| `groupAvatarGap` | 6 | `:1625` |
| `groupIncomingExtraLeading` | 35 | `:1626` |
| `groupSenderNameHeight` | 25 | `:1628` |
| `forwardedHeaderHeight` | 36 | `:1631` |
| `groupRunTopSpacing` | 6 | `:1635` |
| `messageRunTightSpacing` | 2 | `:1737` |
| `messageRunSpeakerChangeSpacing` | 6 | `:1738` |
| Agent body stack spacing | 8 default; custom 6/10 after loader | `VibeAgentKitMessageCell.swift:1089`, `:1023–1024` |
| Steps stack spacing (list build) | 9 streaming / 11 settled | `:240` |
| Steps layoutMargins | top 2, left 2, bottom 4, right 2 | `:243–245` |
| Agent text lineHeight (AgentKit) | 24 | `:622` |
| Loader min height | 20 | `VibeAgentKitLoaderView.swift:552` |
| Loader icon width | 15 | `:540` |
| Team worker avatar | 22 | `VibeAgentKitMessageCell.swift:1293–1294` |
| Tall collapse preview max | `max(80, 420−72)` | `:870` |

---

## Classification helpers (quick index)

| Helper | Role | Site |
|---|---|---|
| `ChatListRow.visualKind` | media kind | `ChatListViewModels.swift:639` |
| `bubbleUsesAgentTurnContent` | agent shell vs text | `ChatListViewCells.swift:2153` |
| `agentTurnRowIsNativePlainProse` | native prose → text path | `:2142` |
| `agentSystemDividerText` / `agentErrorNoticeText` | pill | `:2186`, `:2224` |
| `serviceDecisionActionsHeight` | +40 under pill, plus the approval card | `:2301` |
| `usesAudioMetadataVoiceLayout` | music file vs voice | `:1996` |
| `hasMediaCaptionLayout` | caption under media | `:2076` |
| `usesFullBleedMediaLayout` | no caption chrome | `:2908` |
| `usesEdgeMediaCaptionLayout` | edge caption | `:2928` |
| `hasReplyPreview` | text + replyToId | `:2451` |
| `hasInlineAttachment` | related msgs / agent file | `:2447` |
| `bubbleUsesBlockLayout` | rich blocks | `:3289` |
| `bubbleRowPreviewHeight` | link/music card H | `:3392` |
| `agentTurnContentWidth` | hug vs full | `:4584` |
| `agentTurnComputerBandState` | live or frozen computer for this turn | `ChatListViewCells.swift` |
| `agentTurnComputerBandReserve` | +0 / +34 in both height paths | same |
| `agentTurnRowCouldBeLive` | live flag | `:4389` |
| `groupMeasurementExtras` | width + extraTop | `ChatListView.swift:1925` |

---

## Gaps / UNKNOWN

1. **Exact Auto Layout height of an expanded multi-step agent turn** without running the template: step detail heights use `sizeThatFits` / nested stacks; no closed-form sum of fixed constants. Pure reimpl must either reimplement `VibeAgentKitAssistantMessageBodyView` layout math or continue calling a main-thread fitter for that kind only.
2. **Team header label height** in agent body: single line, font set in `configureTeamHeader` — exact pt not extracted here; usually one line ~intrinsic ~20s.
3. **Whether reply-to on media rows ever shows chrome**: measure path zeros reply for media (`:4999–5000`); if UI still draws a reply strip on media, that is a measure/render mismatch (not verified in this pass).
4. **Seams map line numbers** in `docs/chat-list-seams-map.md` lag the file (e.g. measure was cited `:4712`, now `:4659`). Prefer this doc’s citations.
5. **`usesTransparentAgentStreamingLayout`** is permanently false; formula kept for completeness only.

---

*Generated as research only. Single deliverable file: `docs/row-height-formulas.md`.*
