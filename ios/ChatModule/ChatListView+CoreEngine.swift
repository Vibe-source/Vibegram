import CoreGraphics
import UIKit

/// P4-D — `ChatListView` as a renderer the timeline core can drive.
///
/// # Why this is an extension and not a new screen
///
/// A parallel `VibeCoreChatViewController` was built on 2026-08-03 and deleted the same
/// day. It compiled and routed and rendered an empty transcript, because engine rows are
/// **nested** — the timestamp is at `row["message"]["timestampMs"]`, not at the top
/// level — so a re-derived feed read `nil` for every row and skipped all of them. One
/// small re-derived piece, wrong within the hour.
///
/// The header, wallpaper, theme handling, share sheets, send morph, cell-removal
/// animation and edge masks are far more intricate than that feed and are all already
/// tuned. Re-deriving them yields twenty of the same bug, each in code that was paid for
/// once already. So the engine gets replaced *where it lives*.
///
/// `collectionView` is a `let` on `ChatListView`, referenced 449 times, and it does not
/// move. Every mask, gesture, overlay and animation bound to it keeps working **by
/// construction** rather than by re-implementation.
///
/// # What this file is allowed to change
///
/// Which rows exist, in what order, and how tall each one is. Nothing else. Appearance
/// and every other system stay exactly as they are — that is a hard constraint from the
/// product owner, and it is the reason this approach was chosen over copying the chrome
/// into a new file.
///
/// # Staging
///
/// This is step one and it is deliberately inert: the core's answer is **recorded**, not
/// rendered. `frozenGeometry` is populated and reported, and `sizeForItemAt` still
/// decides heights the way it does today. That makes the seam verifiable on a device
/// before it is load-bearing — the log can show the core and the list agreeing on every
/// row of a real conversation while the user sees exactly the build they had.
///
/// Step two flips `sizeForItemAt` to read `frozenGeometry` behind the gate, at which
/// point heights are *told* rather than derived and the post-hoc height movers have
/// nothing left to correct.

/// The core's opinion about this list, held beside the view.
///
/// An extension cannot add stored properties, and putting these on `ChatListView` itself
/// would mean editing the one file this migration is trying not to churn. One associated
/// object, one class, released with the view.
final class VibeCoreEngineState {
  var generation: UInt64 = 0
  /// Message ids oldest → newest, exactly as the core ordered them.
  var orderedMessageIds: [String] = []
  /// Frozen row height per message id. Measured once, never re-derived.
  var frozenGeometry: [String: CGFloat] = [:]
  /// Rows whose height changed while settled. §9.1 requires this to be 0.
  var settledGeometryChanges = 0
  /// The core, or `nil` when a gate said no. Built once per chat.
  var driver: VibeCoreListDriver?
  /// Eligibility is resolved once per chat, not once per row batch — a gate that could
  /// change mid-chat would swap the sizing authority under a reader.
  var eligibilityChecked = false
  /// Width the core was last told to measure against.
  var layoutWidth: CGFloat = 0
  /// The core's own rows, in the core's order, in the list's payload shape.
  /// Empty until a window arrives — and empty is what makes the authority gate
  /// refuse, which is the correct answer before the core has anything to say.
  var authoritativeRows: [[String: Any]] = []
}

extension ChatListView: ChatTimelineLayoutDelegate {

  /// The one width a row is ever measured or framed at.
  ///
  /// This is deliberately the list's own bounds and not the collection view's. They are
  /// pinned to each other by constraints and agree in the steady state, but during a
  /// navigation push the collection view is laid out a frame or two behind — and a row
  /// framed at a width its height was not measured against is the bubble-width jitter
  /// the transcript showed on open. `groupMeasurementExtras` derives the measurement
  /// width from exactly this expression; the two must not drift apart.
  func timelineLayoutItemWidth(_ layout: ChatTimelineLayout) -> CGFloat {
    max(0.0, bounds.width - (messageHorizontalInset * 2.0))
  }

  /// Row identity, as the layout's height memo keys it.
  ///
  /// `key` and not the index, and that is the whole reason a prepend is cheap: older
  /// messages arriving above shift every index below them, and an index-keyed memo would
  /// treat all of them as new and re-measure the entire transcript. Identity survives
  /// the shift, so the layout re-asks only about rows it has genuinely not seen.
  func timelineLayout(_ layout: ChatTimelineLayout, identityAt index: Int) -> String {
    guard index >= 0, index < rows.count else { return "oob-\(index)" }
    return rows[index].key
  }

  func timelineLayout(_ layout: ChatTimelineLayout, heightForItemAt index: Int, width: CGFloat)
    -> CGFloat
  {
    rowHeight(at: index, width: width)
  }

  /// Drops the layout's memoized height for exactly these rows.
  ///
  /// The correction paths — late media aspect, an expanded bubble, a settled agent turn,
  /// the post-open height audit — each touch a handful of rows. Under a flow layout the
  /// only way to make it re-ask was `invalidateFlowLayoutDelegateMetrics`, which
  /// re-measures every mounted row to fix three of them. Here the cost is the three.
  func invalidateLayoutHeights(at paths: [IndexPath]) {
    guard let layout = collectionView.collectionViewLayout as? ChatTimelineLayout else { return }
    for path in paths where path.item >= 0 && path.item < rows.count {
      layout.invalidateHeight(forIdentity: rows[path.item].key)
    }
  }
}

extension ChatListView: VibeMessageListHost {

  private static var coreStateKey: UInt8 = 0

  /// Lazily attached, so a list that never meets the core pays nothing.
  var coreState: VibeCoreEngineState {
    if let existing = objc_getAssociatedObject(self, &Self.coreStateKey)
      as? VibeCoreEngineState
    {
      return existing
    }
    let created = VibeCoreEngineState()
    objc_setAssociatedObject(
      self, &Self.coreStateKey, created, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return created
  }

  /// Log label for this chat.
  ///
  /// Read off the armed driver rather than `surfaceId`. `surfaceId` turned out not
  /// to be `"<chatId>#list"` — on device it logged `chat=native_chat_` for every
  /// line, which makes a per-chat diagnostic useless precisely when two chats are
  /// involved. The driver holds the id the core was armed with, which is the id
  /// these numbers are actually about.
  private var coreChatLabel: String {
    String((coreState.driver?.loggingChatId ?? "?").prefix(12))
  }

  var view: UIView { self }

  // MARK: Lifecycle

  /// Arms the core for this chat and asks it for the window.
  ///
  /// **This is the entire call site.** One statement inside `applyRows`, taking values
  /// the caller already has in hand, so the 22,920-line file gains a single line rather
  /// than a migration. `chatId`, `isGroupOrChannel` and `ownUserId` are passed in rather
  /// than read off the view because all three live in `private` storage that another file
  /// cannot see — and widening an access modifier to suit a caller is how a boundary
  /// stops being one.
  ///
  /// It does **not** hand rows over. The core is fed raw server frames by `ChatEngine`
  /// at ingest; this list is a reader of what the core concluded. An earlier version
  /// pushed the list's own rows back into the core as stub frames, which made the core an
  /// echo of the very pipeline it is replacing.
  ///
  /// Safe to call on every batch: eligibility resolves once, and an unchanged window
  /// costs one flush.
  func armCoreEngine(chatId: String, isGroupOrChannel: Bool, ownUserId: String) {
    if !coreState.eligibilityChecked {
      coreState.eligibilityChecked = true
      coreState.driver = Self.makeCoreDriverIfEligible(
        chatId: chatId, isGroupOrChannel: isGroupOrChannel, listHost: self)
      coreState.driver?.start(
        ownUserId: ownUserId,
        rowProvider: { [weak self] messageId in
          guard let self else { return nil }
          return self.coreMeasurementRow(forIdentity: messageId)
        },
        agentStateProvider: { [weak self] row in
          guard let self else { return AgentTurnBubbleState() }
          return self.agentTurnBubbleState(for: row)
        },
        // The measurement this list has already done. Only chats the core is armed for
        // reach here — DMs, never groups (see ``makeCoreDriverIfEligible``) — so the
        // width the core measures against and the width these heights were persisted at
        // are the same expression, and the equality test below is exact rather than
        // hopeful. See ``ChatListView/coreKnownHeight(for:width:)``.
        knownHeightProvider: { [weak self] row, width in
          guard let self else { return nil }
          return self.coreKnownHeight(for: row, width: width)
        }
      )
      coreState.driver?.onCoreRows = { [weak self] rows in
        guard let self else { return }
        self.coreState.authoritativeRows = rows
      }
    }
    guard let driver = coreState.driver else { return }
    // The width rows are measured against, from the same expression the sizing path
    // uses. A core measuring against a width the cells never use produces heights that
    // are wrong rather than missing, which is strictly worse than having none.
    let width = max(0, bounds.width - (messageHorizontalInset * 2))
    if width > 0, abs(coreState.layoutWidth - width) > 0.5 {
      coreState.layoutWidth = width
      driver.setLayoutWidth(width)
    }
    // Refresh, not re-anchor. `requestWindow()` resets the core's cursor to "bottom,
    // default length", and this runs on every engine reconcile — so calling it here is
    // what made `pageOlder()` a no-op and left the top of a 998-message chat
    // unreachable. The first call still anchors; see
    // ``VibeCoreListDriver/refreshWindow()``.
    driver.refreshWindow()
  }

  /// Tells the core about a deletion, so its next window stops carrying the row.
  ///
  /// The core drives the list's content now, so a delete the core never heard about is
  /// a cell that comes back — the engine removes it, the next core publish puts it
  /// straight back on screen.
  func coreEngineDidDeleteMessage(id: String, forEveryone: Bool) {
    coreState.driver?.deleteMessage(id: id, forEveryone: forEveryone)
  }

  /// The core's frozen height for a row, or `nil` when it has nothing to say.
  ///
  /// `nil` is the common and safe answer — the caller then measures exactly as it does
  /// today, so a miss costs what this build already costs. Every guard below turns a
  /// *wrong* height into a *missing* one, which is the only trade worth making here: a
  /// missing height is measured, a wrong one is a visible jump.
  ///
  /// Refuses when:
  ///
  /// - no driver is armed (a gate said no, or this is a group)
  /// - the row carries no message id, so there is nothing to look up
  /// - the width the core measured against is not the width being asked about — heights
  ///   from another width are not stale, they are wrong
  /// - the row is an agent turn, which `VibeRowMetrics` cannot measure off the main
  ///   thread; the core's answer for one is a placeholder, and freezing a placeholder is
  ///   how a settled turn collapses mid-read
  func coreFrozenHeight(for row: ChatListRow) -> CGFloat? {
    guard coreState.driver != nil, !coreState.frozenGeometry.isEmpty else { return nil }
    guard bubblePreviewCandidateURL(for: row) == nil else { return nil }
    // `key` first, and that order is not cosmetic. The driver identifies rows with
    // `VibeCoreListDriver.messageId(from:)`, which prefers the payload's **top-level
    // `key`** — so that is what the core stores heights under. Looking up by
    // `messageId` instead asks for a string the core never saw, and every row misses
    // while the seam looks perfectly wired. `messageId` stays as the fallback for rows
    // whose payload carried no top-level key.
    let frozen = coreState.frozenGeometry[row.key]
      ?? row.messageId.flatMap { coreState.frozenGeometry[$0] }
    guard let frozen else { return nil }
    // Never freeze an estimate. When the core measured this row the list may not
    // have held it yet — at first mount it holds only its seed — so the height is
    // a font-and-a-box guess. Device run 2026-08-03: 102 of 118 rows frozen at
    // 55pt against a real 34pt, which is the shift this whole migration exists to
    // remove. Falling through re-measures, which is exactly today's behaviour.
    if let placeholders = coreState.driver?.placeholderMessageIds {
      if let id = row.messageId, placeholders.contains(id) { return nil }
      if placeholders.contains(row.key) { return nil }
    }
    let width = max(0, bounds.width - (messageHorizontalInset * 2))
    guard width > 0, abs(coreState.layoutWidth - width) <= 0.5 else { return nil }
    guard !VibeRowMetrics.requiresMainThread(row) else { return nil }
    guard frozen > 0 else { return nil }
    return frozen
  }

  /// The core's own rows for this chat, or `nil` to keep the engine's.
  ///
  /// This is order **and** content authority in one answer, because splitting them
  /// is not actually possible: a row list carries its own order, and handing back
  /// core content in engine order would render the core's text against the engine's
  /// sequence — a mix neither layer ever produced.
  ///
  /// # Why this no longer counts rows
  ///
  /// It used to refuse whenever the core held fewer messages than the engine, to
  /// guarantee no row could vanish from screen. That test is unsatisfiable against a
  /// bounded window: the core caps at 200 **by design**, the engine's array has no
  /// cap, so one scroll-back made the engine larger forever and the core never drove
  /// the list again. Device run 2026-08-03: `core=200 engine=959`, refused on every
  /// page, while the list grew 122 → 902 rows and `setRows` went 61ms → 420ms. The
  /// gate was not protecting the transcript, it was preventing the fix.
  ///
  /// A window is not a smaller transcript, it is a viewport onto the same store, and
  /// it moves: `page_before` slides it back once it reaches the cap, `page_after`
  /// slides it forward and re-arms tail following. Fewer rows on screen is the
  /// intended outcome — it is what makes `setRows` constant-cost instead of growing
  /// with history.
  ///
  /// What still has to hold is that the newest message is reachable. That is not a
  /// count property, it is the tail-following property, and it is maintained by
  /// pairing every ``VibeCoreListDriver/pageOlder()`` with a
  /// ``VibeCoreListDriver/pageNewer()`` on the way back down.
  func coreAuthoritativeRows(engineRows: [[String: Any]]) -> [[String: Any]]? {
    guard let driver = coreState.driver else { return nil }
    guard VibeTimelineUserDefaultsFeatureFlags().flags.vibeTimelineCoreOrderAuthorityEnabled
    else { return nil }
    let coreRows = coreState.authoritativeRows
    guard !coreRows.isEmpty else { return nil }

    // The one case that must still refuse: the engine has a message the core has not
    // ingested yet AND the core is sitting at the tail. That is a genuinely late core,
    // not a scrolled-back window, and adopting it would drop the newest message off a
    // screen the user is looking at.
    //
    // "Sitting at the tail" is the core's own answer (`has_more_after == false`), not a
    // guess made here. Inferring it from ids and counts is what would break the moment
    // scroll-back started working: a window that has *deliberately* moved off the tail
    // ends on an older message and holds fewer rows than the engine's uncapped array —
    // the exact shape of a late core — so every page would be refused and the
    // transcript handed straight back to the engine mid-scroll.
    guard driver.windowFollowsTail else {
      NSLog(
        "[VibeCore] authority LIVE chat=%@ rows=%d (scrolled back — window off the tail)",
        coreChatLabel, coreRows.count)
      return coreRows
    }
    let engineMessages = engineRows.filter { ($0["kind"] as? String) == "message" }
    let engineNewestId = (engineMessages.last?["message"] as? [String: Any])?["id"] as? String
    let coreIds = Set(
      coreRows.compactMap { ($0["message"] as? [String: Any])?["id"] as? String })
    if let engineNewestId, !coreIds.contains(engineNewestId) {
      NSLog(
        "[VibeCore] authority REFUSED chat=%@ core=%d engine=%d — newest message not in core yet",
        coreChatLabel, coreRows.count, engineMessages.count)
      return nil
    }
    NSLog(
      "[VibeCore] authority LIVE chat=%@ rows=%d engine=%d (core window drives the list)",
      coreChatLabel, coreRows.count, engineMessages.count)
    return coreRows
  }

  /// Tears the core down. Called when the chat changes or the view goes away — a driver
  /// left holding the previous chat's generation high-water mark fences off everything
  /// the next one sends.
  func shutdownCoreEngine() {
    coreState.driver?.shutdown()
    coreState.driver = nil
    coreState.eligibilityChecked = false
    coreState.generation = 0
    coreState.orderedMessageIds.removeAll()
    coreState.frozenGeometry.removeAll()
    coreState.layoutWidth = 0
  }

  /// Builds a driver only when every gate agrees, otherwise `nil`.
  ///
  /// Fails closed on every input. Kept here, next to the thing it governs, so the rule
  /// that P4 is **1:1 DM only** is written once rather than being a condition someone can
  /// widen in passing at a call site.
  ///
  /// Saved Messages is named explicitly because it slipped through a DM-only allowlist
  /// once already: it answers `false` to `isGroupOrChannel`, and its dual-id history is
  /// exactly the kind of ordering quirk that earns its own soak.
  static let builtInAgentChatIds: Set<String> = [
    "vibe_agent", "vibeagent", "vibe-ai", "vibe_ai",
  ]

  static func makeCoreDriverIfEligible(
    chatId: String,
    isGroupOrChannel: Bool,
    listHost: VibeMessageListHost,
    flags: VibeTimelineFeatureFlags = VibeTimelineUserDefaultsFeatureFlags().flags
  ) -> VibeCoreListDriver? {
    guard flags.vibeAsyncTimelineV1Enabled else { return nil }
    guard flags.eligibleChatClasses.contains(.directMessage) else { return nil }
    guard !isGroupOrChannel else { return nil }
    let trimmed = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("saved_messages") else { return nil }
    // The built-in agent DM is never mirrored into the core store, so arming a driver on
    // it only produced `[VibeCore] error unknown chat` on every open.
    guard !Self.builtInAgentChatIds.contains(trimmed.lowercased()) else { return nil }
    NSLog("[VibeCore] driver ARMED chat=%@", String(trimmed.prefix(12)))
    return VibeCoreListDriver(chatId: trimmed, listHost: listHost)
  }

  // MARK: Mount

  /// Adopts the core's window: which rows, in what order, how tall.
  ///
  /// **Geometry is load-bearing in chats of 12 rows or fewer, and nowhere else.**
  /// The only reader of ``coreFrozenHeight(for:)`` is `estimateMessageHeight`, and
  /// `rowHeight(at:width:)` routes to it only when `usesProgressiveTranscriptSizing`
  /// is false — which is `rows.count > largeTranscriptThreshold`, and that threshold
  /// is 12. Every real conversation takes `presentationSeedMessageHeight` instead,
  /// which never asks the core anything.
  ///
  /// So what lands here is measured, frozen, compared and then, in every chat a user
  /// actually has, ignored. Left wired rather than deleted because the comparison
  /// below is the evidence the flip needs — but the flip is blocked, not pending:
  /// device run 2026-08-04 reported `geometry DIFFERS … differed=9 worst core=42.0
  /// list=34.0`, a systematic 8pt, and routing real chats onto that would shift every
  /// row. Resolve the disagreement first, then widen the reader.
  ///
  /// Order and content are still the engine's — `rows`, the collection view and the
  /// scroll position are untouched from here.
  ///
  /// That split is deliberate and is the reversible half. A wrong height is one
  /// row the wrong size; a wrong order is a user's conversation rearranged. The
  /// second does not follow until the first has been silent on real chats.
  func apply(snapshot: VibeRenderSnapshot, reason: VibeMountReason) {
    coreState.generation = snapshot.generation
    coreState.orderedMessageIds = snapshot.items.map(\.identity.messageId)
    var geometry: [String: CGFloat] = [:]
    geometry.reserveCapacity(snapshot.items.count)
    for item in snapshot.items { geometry[item.identity.messageId] = item.size.height }
    coreState.frozenGeometry = geometry
    NSLog(
      "[VibeCore] host MOUNT chat=%@ reason=%@ gen=%llu rows=%d (geometry LIVE, order/content engine)",
      coreChatLabel, reason.rawValue, snapshot.generation,
      snapshot.items.count)
    reportCoreGeometryAgreement(stage: "mount")
  }

  /// Applies an ordered, atomic mutation from the core.
  ///
  /// Every op is folded into the recorded window so the mirror stays exactly what the
  /// core believes. Applying a partial op set and letting the rest drift is how a list
  /// ends up rendering an order nobody chose.
  func apply(transaction: VibeListTransaction) {
    guard transaction.baseGeneration == coreState.generation else {
      NSLog(
        "[VibeCore] host TRANSACTION-FENCED chat=%@ base=%llu held=%llu — resync owed",
        coreChatLabel, transaction.baseGeneration, coreState.generation)
      return
    }
    for op in transaction.ops {
      switch op {
      case .insert(let items, let at):
        let ids = items.map(\.identity.messageId)
        let index = min(max(at, 0), coreState.orderedMessageIds.count)
        coreState.orderedMessageIds.insert(contentsOf: ids, at: index)
        for item in items { coreState.frozenGeometry[item.identity.messageId] = item.size.height }
      case .remove(let ids):
        let dropped = Set(ids)
        coreState.orderedMessageIds.removeAll { dropped.contains($0) }
        for id in ids { coreState.frozenGeometry.removeValue(forKey: id) }
      case .updateContent(let id, let item):
        // Content-only ops must never move geometry. If one does, the freeze is broken
        // and the row is about to change height under a reader — record it loudly
        // rather than quietly adopting the new number.
        if let held = coreState.frozenGeometry[id], abs(held - item.size.height) > 0.5 {
          coreState.settledGeometryChanges += 1
          NSLog(
            "[VibeCore] host SETTLED-GEOMETRY-CHANGED chat=%@ id=%@ %.1f→%.1f",
            coreChatLabel, String(id.suffix(14)), held, item.size.height)
        }
      case .updateGeometry(let id, let item, _):
        coreState.frozenGeometry[id] = item.size.height
      case .move(let id, let to):
        guard let from = coreState.orderedMessageIds.firstIndex(of: id) else { break }
        let moved = coreState.orderedMessageIds.remove(at: from)
        coreState.orderedMessageIds.insert(moved, at: min(max(to, 0), coreState.orderedMessageIds.count))
      }
    }
    coreState.generation = transaction.nextGeneration
    reportCoreGeometryAgreement(stage: "transaction")
  }

  // MARK: Viewport

  /// The keyboard, composer and safe-area clearance the scrollable area must leave.
  ///
  /// Routed into `contentPaddingBottom`/`contentPaddingTop` — the flow layout's SECTION
  /// insets — because that is where this list has always put them. They are part of
  /// `contentSize`, not `contentInset`; a guard that read `adjustedContentInset.bottom`
  /// instead is what let keyboard-up rasters be cached for months.
  func setViewportInsets(_ insets: UIEdgeInsets) {
    setContentPaddingTop(insets.top)
    setContentPaddingBottom(insets.bottom)
  }

  func visibleAnchors() -> [VibeTimelineAnchor] {
    collectionView.indexPathsForVisibleItems
      .sorted { $0.item < $1.item }
      .compactMap { path in
        guard rows.indices.contains(path.item), let id = rows[path.item].messageId else {
          return nil
        }
        return VibeTimelineAnchor(messageId: id)
      }
  }

  // MARK: Navigation

  func prepareForNavigationPush(bounds: CGRect, safeBottom: CGFloat) {
    setNavigationPrestageSafeAreaBottom(safeBottom)
    beginNavigationPushPrestaging()
  }

  func completePresentation() {
    completeTranscriptPresentation()
  }

  /// Not implemented, and deliberately not stubbed as "done".
  ///
  /// This list does not prefetch: `isPrefetchingEnabled` is off on the core host for the
  /// same reason it should stay off here — prefetch instantiates cells on its own
  /// schedule, which fights an explicit "visible plus two screens" budget. A budget is
  /// measurable; a heuristic is not.
  func cancelPrefetch(outside range: Range<Int>) {}

  func debugGeometryMap() -> [String: CGFloat] { coreState.frozenGeometry }

  // MARK: Agreement

  /// Compares the core's height for each row against the one this list actually used.
  ///
  /// This is the whole point of landing the seam inert first. Before `sizeForItemAt`
  /// depends on the core, the log has to show the two agreeing on real conversations —
  /// on real media, real agent turns, real edits. A disagreement here is a row that
  /// *would* have jumped, caught while it still costs nothing.
  ///
  /// Ids and numbers only, and only the disagreements: a line per agreeing row would
  /// bury the one line that matters, which this project has already done to itself
  /// three times.
  private func reportCoreGeometryAgreement(stage: String) {
    guard !coreState.frozenGeometry.isEmpty, !rows.isEmpty else { return }
    var compared = 0
    var differed = 0
    var placeholders = 0
    var worst: (key: String, core: CGFloat, list: CGFloat)?
    let layout = collectionView.collectionViewLayout
    // Rows the core sized from a guess rather than a measurement. `coreFrozenHeight`
    // already refuses these, so counting them as disagreements compared a number that
    // could never reach the screen against one that did — and reported the result as
    // the core being wrong. That is what a device run reads as a flat 8pt on every row,
    // and it made the evidence this seam gates on impossible to ever turn green.
    let placeholderIds = coreState.driver?.placeholderMessageIds ?? []
    // Only the rows on screen, and never the whole transcript.
    //
    // This walked `rows` end to end, asking the layout for attributes per row. That was
    // free while the core was never mounting a real chat — the loop found an empty
    // geometry map and returned. The moment the snapshot validator stopped rejecting
    // large windows it became a 999-iteration main-thread loop, allocating an attributes
    // object per row, run on every mount, entirely to produce one log line. It showed up
    // immediately as `MainHang BLOCKED … mode=UITrackingRunLoopMode` during chat open.
    //
    // A sample answers the same question. The disagreement this exists to catch is
    // systematic — 9 of 9 rows, every row off by the same 8pt — so it is visible in the
    // first screenful, and a comparison that costs a visible hitch to run is one nobody
    // can afford to leave on.
    let visible = collectionView.indexPathsForVisibleItems.map(\.item).sorted()
    let sampleRange = visible.isEmpty ? Array(0..<min(rows.count, 32)) : visible
    for index in sampleRange {
      guard index >= 0, index < rows.count else { continue }
      let row = rows[index]
      guard let id = row.messageId, let core = coreState.frozenGeometry[id] else { continue }
      guard !placeholderIds.contains(id), !placeholderIds.contains(row.key) else {
        placeholders += 1
        continue
      }
      // The height the list actually laid the row out at, not the height it cached.
      // `messageHeightCache` is `private` and invisible here, which turns out to be the
      // better answer: the laid-out attribute is what the reader saw, and a cache that
      // agrees with the core while the layout disagrees with both is exactly the class
      // of bug this comparison exists to catch.
      guard
        let list = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?
          .size.height
      else { continue }
      compared += 1
      let delta = abs(core - list)
      guard delta > 0.5 else { continue }
      differed += 1
      if delta > abs((worst?.core ?? 0) - (worst?.list ?? 0)) {
        worst = (row.key, core, list)
      }
    }
    guard compared > 0 else {
      // Not silence — "the core has nothing measured to compare yet" is a distinct and
      // actionable state from "the core agrees", and printing neither is how the seam
      // looked healthy while sizing every row from a guess.
      if placeholders > 0 {
        NSLog(
          "[VibeCore] geometry UNMEASURED chat=%@ stage=%@ placeholders=%d — core sized every row from a guess",
          coreChatLabel, stage, placeholders)
      }
      return
    }
    if differed == 0 {
      NSLog(
        "[VibeCore] geometry AGREES chat=%@ stage=%@ rows=%d placeholders=%d",
        coreChatLabel, stage, compared, placeholders)
      return
    }
    NSLog(
      "[VibeCore] geometry DIFFERS chat=%@ stage=%@ rows=%d differed=%d placeholders=%d worst=%@ core=%.1f list=%.1f",
      coreChatLabel, stage, compared, differed, placeholders,
      String(worst?.key.suffix(14) ?? "?"), worst?.core ?? 0, worst?.list ?? 0)
  }
}
