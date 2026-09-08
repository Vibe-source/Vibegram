import UIKit

/// What the layout needs from the list, and nothing else.
///
/// Three questions: how wide is a row, who is the row at this index, and how tall is it.
/// Identity is what makes a prepend cheap — see ``ChatTimelineLayout``.
protocol ChatTimelineLayoutDelegate: AnyObject {
  /// Width every row is laid out at — and, critically, the width the delegate measured
  /// its heights against.
  ///
  /// The layout does not derive this from `collectionView.bounds`. During a navigation
  /// push the collection view's bounds and the list's bounds disagree for a few frames,
  /// and a row whose height was measured at one width and framed at the other is a
  /// visible width jump followed by clipped or floating text.
  func timelineLayoutItemWidth(_ layout: ChatTimelineLayout) -> CGFloat
  /// Stable identity for the row at `index`. Must be the same string for the same
  /// message however the array around it shifts.
  func timelineLayout(_ layout: ChatTimelineLayout, identityAt index: Int) -> String
  /// Height of the row at `index`, measured against `width`.
  func timelineLayout(_ layout: ChatTimelineLayout, heightForItemAt index: Int, width: CGFloat)
    -> CGFloat

  /// Whether an update should hold the visible content still.
  ///
  /// `false` means the list wants to follow the newest message — a send, or a
  /// reader already parked at the bottom — and the layout must not fight that.
  /// `true` means the reader is somewhere in history and nothing that happens
  /// above them may move what they are looking at.
  ///
  /// Policy lives in the list because only the list knows why rows changed;
  /// mechanism lives in the layout because only the layout knows the geometry
  /// on both sides of the update.
  func timelineLayoutShouldHoldStationaryAnchor(_ layout: ChatTimelineLayout) -> Bool
}

/// A single-column list layout whose cost is proportional to what **changed**, not to
/// how much history exists.
///
/// # The problem this replaces
///
/// `UICollectionViewFlowLayout` recomputes everything on every invalidation. One
/// `setRows` on a 300-row transcript measured 201ms inside `performBatchUpdates`, and
/// that number grows linearly: ~0.65ms per mounted row, so ~600ms at a thousand and
/// seconds at ten thousand. It is paid on every commit, and — because a chat open holds
/// its raster cover until the rows mount — it is also most of the delay between tapping
/// a chat and seeing it.
///
/// That single fact is what made every previous answer a dead end. A bounded window
/// capped the cost by capping the transcript, which the reader felt as a wall. Removing
/// the cap removed the wall and brought the cost back. Neither addressed why mounting a
/// row the layout has already seen should cost anything at all.
///
/// # Why it is O(changed)
///
/// Three properties, and all three are needed:
///
/// 1. **Heights are memoized by row identity, not by index.** Prepending 100 older
///    messages shifts every index by 100; a flow layout re-asks the delegate for all
///    1,100 sizes, this asks for 100. The other thousand are dictionary hits.
/// 2. **Positions are a prefix sum.** One pass of float addition over the height table
///    — microseconds at any transcript size we can hold in memory — rather than a
///    thousand `UICollectionViewLayoutAttributes` allocations.
/// 3. **Attributes are built for the requested rect only.** The offset table is sorted,
///    so the first visible row is a binary search and the rest is a short walk.
///    Roughly twenty objects per query instead of one per row.
///
/// The result is that mounting an entire conversation costs about what mounting one
/// screen of it used to, which is what lets the timeline have no scroll limit without
/// paying for it on every frame.
///
/// # Why every entry point prepares
///
/// A layout that only rebuilds inside `prepare()` is only correct for UIKit, which calls
/// `prepare()` before it reads anything. Everyone else — and this list reads
/// `collectionViewLayout.collectionViewContentSize` directly to decide how much top
/// padding a short transcript needs — gets whatever the last pass happened to leave
/// behind. On a fresh chat that is zero, and the caller concludes the transcript is
/// empty and pads the top by a full screen height. That was the ~950pt of blank
/// wallpaper above the first message, and the jump when it later corrected itself.
///
/// So `ensurePrepared()` guards every read. It is a bool test in the common case.
///
/// # What it deliberately does not do
///
/// It does not measure. Heights come from the delegate, which serves them from the
/// timeline core — already computed off the main thread. Layout here is arithmetic over
/// numbers someone else produced, and keeping it that way is what keeps it fast.
final class ChatTimelineLayout: UICollectionViewLayout {

  weak var timelineDelegate: ChatTimelineLayoutDelegate?

  /// Vertical gap between consecutive rows. Same meaning as the flow layout's.
  var minimumLineSpacing: CGFloat = 0 {
    didSet {
      guard minimumLineSpacing != oldValue else { return }
      markNeedsRebuild("line-spacing")
      invalidateLayout()
    }
  }

  /// Content padding. Left/right narrow the row; top/bottom are the transcript's
  /// leading and trailing space, which this list uses for the composer and header
  /// clearance rather than `contentInset`.
  var sectionInset: UIEdgeInsets = .zero {
    didSet {
      guard sectionInset != oldValue else { return }
      markNeedsRebuild("section-inset")
      invalidateLayout()
    }
  }

  // MARK: Tables

  /// Height per row, keyed by identity so an index shift costs nothing.
  private var heightByIdentity: [String: CGFloat] = [:]

  // MARK: Cross-open memo
  //
  // The memo above dies with the layout, and the layout dies with the view — and a
  // fresh `ChatListView` is built on every chat open. So every open started from an
  // empty table and re-asked the delegate about the entire transcript. Device run
  // 2026-08-05, chat 176cdf92eec5: `REBUILD 61ms … rows=1286 memo=0 measured=1286
  // reused=0`, then 65ms, 69ms, 73ms, 77ms — once per open, every open, on the main
  // thread while the reader waits for the chat to appear.
  //
  // Nothing about those measurements was invalid. The same rows, at the same width,
  // measured to the same numbers a second earlier. They were thrown away only because
  // the object holding them went away, which is not a reason.
  //
  // So the table outlives the layout. It is keyed by chat *and* width, because a
  // height is only meaningful against the width it was measured at, and bounded so a
  // long session cannot grow it without limit.
  //
  // Staleness is handled the same way it already is within a session: the correction
  // paths call `invalidateHeight(forIdentity:)`, and that now reaches this store too,
  // so a row whose content changed drops out of both. This is the same trade the app
  // already makes by persisting heights to `VibeChatHeights/heights-<chat>.json` and
  // trusting them on the next launch.
  private static let sharedMemoLock = NSLock()
  private static var sharedMemo: [String: [String: CGFloat]] = [:]
  /// Insertion order, oldest first, for eviction.
  private static var sharedMemoOrder: [String] = []
  /// Chats kept. A handful covers "the conversations someone is moving between",
  /// which is the whole point; beyond that the cost is memory for no benefit.
  private static let sharedMemoChatLimit = 6

  /// Which chat this layout's heights belong to. Set by the list as soon as it knows;
  /// empty means "do not share", which is the safe default for previews and probes.
  var sharedMemoChatId: String = "" {
    didSet {
      guard sharedMemoChatId != oldValue else { return }
      // A different chat's heights are not this chat's heights.
      heightByIdentity.removeAll(keepingCapacity: true)
      markNeedsRebuild("chat-changed")
    }
  }

  private var sharedMemoKey: String? {
    guard !sharedMemoChatId.isEmpty, itemWidth > 1.0 else { return nil }
    return "\(sharedMemoChatId)|\(Int(itemWidth.rounded()))"
  }

  private static func loadSharedMemo(_ key: String) -> [String: CGFloat]? {
    sharedMemoLock.lock()
    defer { sharedMemoLock.unlock() }
    return sharedMemo[key]
  }

  private static func storeSharedMemo(_ key: String, _ table: [String: CGFloat]) {
    sharedMemoLock.lock()
    defer { sharedMemoLock.unlock() }
    if sharedMemo[key] == nil {
      sharedMemoOrder.append(key)
      while sharedMemoOrder.count > sharedMemoChatLimit {
        let evicted = sharedMemoOrder.removeFirst()
        sharedMemo.removeValue(forKey: evicted)
      }
    }
    sharedMemo[key] = table
  }

  /// Drops one row from every stored width of one chat. A correction is about the
  /// row's content, and content does not care which width it was measured at.
  private static func dropSharedMemo(identity: String, chatId: String) {
    guard !chatId.isEmpty else { return }
    sharedMemoLock.lock()
    defer { sharedMemoLock.unlock() }
    for key in sharedMemo.keys where key.hasPrefix("\(chatId)|") {
      sharedMemo[key]?.removeValue(forKey: identity)
    }
  }
  /// Identity per index, for the current data source counts.
  private var identities: [String] = []
  /// `origins[i]` is the y origin of row `i`. Has `count` entries.
  private var origins: [CGFloat] = []
  /// `heights[i]` matches `origins[i]`.
  private var heights: [CGFloat] = []
  private var itemWidth: CGFloat = 0
  private var totalHeight: CGFloat = 0
  private var needsRebuild = true
  /// Re-entrancy guard. `ensurePrepared` calls back into the delegate, and a delegate
  /// that touches the collection view could land here again mid-build on tables that
  /// are half-cleared.
  private var isBuilding = false

  /// Origins captured before the in-flight batch update, so a disappearing row can be
  /// given a frame that still exists.
  private var preUpdateOrigins: [CGFloat] = []
  private var preUpdateHeights: [CGFloat] = []
  private var isUpdating = false

  // MARK: Diagnostics

  private(set) var lastRebuildMeasuredRows = 0
  private(set) var lastRebuildReusedRows = 0

  /// Who dirtied the tables. Kept because the cost of a rebuild is paid by
  /// whoever happens to read the layout next — which is very often not whoever
  /// invalidated it — and "the content size read took 65ms" names the reader
  /// rather than the cause.
  /// Every trigger seen since the last rebuild, not just the first.
  ///
  /// Recording only the first one hid the answer on the first device run: a
  /// spurious `invalidateEverything` marked the tables dirty, and the
  /// `invalidateAllHeights` that actually wiped the memo arrived afterwards and
  /// was never named. All of them are kept now — the interesting case is
  /// precisely when several arrive together.
  private var rebuildTriggers: [String] = ["initial"]
  /// Rebuilds cheaper than this are the design working; logging them would be a
  /// per-frame flood. One frame at 120Hz is 8ms, and a rebuild is supposed to be
  /// arithmetic over numbers someone else produced.
  private static let slowRebuildMs = 6.0
  private static let rebuildLogCap = 120
  private var rebuildsLogged = 0
  private var rebuildCount = 0
  private var rebuildTotalMs = 0.0
  private var rebuildWorstMs = 0.0
  private var rebuildMeasuredTotal = 0

  /// What this layout has cost since the last reset, for a summary line.
  var rebuildTotals: (count: Int, totalMs: Double, worstMs: Double, measured: Int) {
    (rebuildCount, rebuildTotalMs, rebuildWorstMs, rebuildMeasuredTotal)
  }

  /// Marks the tables dirty and records why.
  ///
  /// Every path that sets `needsRebuild` goes through here, so no invalidation
  /// can arrive anonymously — an unattributed rebuild is exactly the case the
  /// device logs could not explain.
  private func markNeedsRebuild(_ trigger: String) {
    if !needsRebuild { rebuildTriggers.removeAll(keepingCapacity: true) }
    if rebuildTriggers.last != trigger { rebuildTriggers.append(trigger) }
    needsRebuild = true
  }

  // MARK: Invalidation

  /// Drops the memoized height for one row. Call when a row's content changed in a way
  /// that changes its size — a late media aspect, an expanded bubble, an edit.
  func invalidateHeight(forIdentity identity: String) {
    // Drop it from the cross-open store unconditionally, even when this layout has
    // no local entry: the caller is saying this row's height is wrong, and a copy
    // surviving in the shared table would hand the stale value to the next open.
    Self.dropSharedMemo(identity: identity, chatId: sharedMemoChatId)
    guard heightByIdentity.removeValue(forKey: identity) != nil else { return }
    markNeedsRebuild("row-height")
  }

  /// Drops every memoized height. The equivalent of the flow layout's
  /// `invalidateFlowLayoutDelegateMetrics`, and just as expensive — a full re-measure —
  /// so it belongs on a width change or a theme change, not on a row update.
  func invalidateAllHeights() {
    heightByIdentity.removeAll(keepingCapacity: true)
    markNeedsRebuild("all-heights")
  }

  override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
    if context.invalidateEverything || context.invalidateDataSourceCounts {
      markNeedsRebuild(context.invalidateEverything ? "invalidate-everything" : "datasource-counts")
    }
    // A targeted invalidation names rows whose size the caller believes changed. Honour
    // it by dropping exactly those memoized heights — the whole point of this layout is
    // that fixing three rows costs three rows.
    if let paths = context.invalidatedItemIndexPaths, !paths.isEmpty {
      for path in paths where path.section == 0 && path.item >= 0 && path.item < identities.count {
        heightByIdentity.removeValue(forKey: identities[path.item])
      }
      markNeedsRebuild("targeted-\(paths.count)")
    }
    super.invalidateLayout(with: context)
  }

  override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
    // Scrolling changes the origin, never the geometry. Only a width change does, and
    // that one has to re-measure every row because the delegate's answer depends on it.
    guard let collectionView else { return false }
    return abs(newBounds.width - collectionView.bounds.width) > 0.5
  }

  override func invalidationContext(forBoundsChange newBounds: CGRect)
    -> UICollectionViewLayoutInvalidationContext
  {
    let context = super.invalidationContext(forBoundsChange: newBounds)
    if let collectionView, abs(newBounds.width - collectionView.bounds.width) > 0.5 {
      invalidateAllHeights()
    }
    return context
  }

  // MARK: Build

  override func prepare() {
    super.prepare()
    ensurePrepared()
  }

  /// Brings the tables in line with the data source, if they are not already.
  ///
  /// Three things can put them out of line, and only the first is something UIKit tells
  /// us about:
  ///
  /// - an explicit invalidation (`needsRebuild`);
  /// - a row count that moved without one — which shows as a screen of wallpaper,
  ///   because attributes are only ever built for indices the tables know about;
  /// - a width change, since every memoized height was measured against the old one.
  private func ensurePrepared() {
    guard !isBuilding, let collectionView, let timelineDelegate else { return }

    let width = timelineDelegate.timelineLayoutItemWidth(self)
    // A zero width means the view has not been laid out yet. Measuring against it would
    // fill the memo with heights for a one-column transcript and then throw them away
    // one frame later — a full re-measure of everything, twice, during the chat open.
    // Keeping the previous tables is strictly better: they are stale, but they are the
    // right shape, and the real width arrives with an invalidation behind it.
    guard width > 1.0 else { return }

    let count = collectionView.numberOfItems(inSection: 0)
    if abs(width - itemWidth) > 0.5 { markNeedsRebuild("width-change") }
    if count != identities.count { markNeedsRebuild("count-drift") }
    guard needsRebuild else { return }

    isBuilding = true
    let startedAt = CACurrentMediaTime()
    let triggers = rebuildTriggers.joined(separator: "+")
    // Size of the memo *before* the rebuild consumes it. This is the field that
    // separates the only two explanations for `reused=0`: `memo=0` means someone
    // cleared it, `memo=1386 reused=0` means the identities themselves are new
    // and the memo is being asked questions it can never answer.
    let memoBefore = heightByIdentity.count
    defer {
      isBuilding = false
      reportRebuild(
        startedAt: startedAt, trigger: triggers, rows: count, width: width, memoBefore: memoBefore)
    }

    // Snapshot the geometry the disappearing rows still belong to, before it is
    // overwritten. Doing it here rather than in `prepare(forCollectionViewUpdates:)`
    // makes it independent of which of the two UIKit calls first.
    if !isUpdating {
      preUpdateOrigins = origins
      preUpdateHeights = heights
    }

    // A width change makes every memoized height wrong rather than stale — they were
    // measured against a different line-break budget — so they go, all of them.
    if abs(width - itemWidth) > 0.5 {
      heightByIdentity.removeAll(keepingCapacity: true)
      itemWidth = width
    }

    // Adopt what a previous open of this chat already measured, at this width.
    // This is the whole point of the cross-open store: without it the loop below
    // re-asks the delegate about every row of a transcript that was measured
    // moments ago, which is where a chat open's main-thread cost was going.
    if heightByIdentity.isEmpty, let key = sharedMemoKey,
      let inherited = Self.loadSharedMemo(key), !inherited.isEmpty
    {
      heightByIdentity = inherited
    }

    // Build into locals and publish at the end, so the live tables are never half-built.
    //
    // The loop below calls the delegate, and the delegate is the list. Anything it
    // touches can come back through `layoutAttributesForElements` on the same stack — and
    // that call sees `isBuilding`, so it serves the tables as they are rather than
    // recursing. If the tables were being cleared and refilled in place, "as they are"
    // means EMPTY, and UIKit is told there is nothing to show in the visible rect.
    //
    // That is the reported "mid-scroll the list goes completely blank, just wallpaper,
    // and a few seconds later everything comes back". Nothing was lost; for the duration
    // of one rebuild the layout was answering questions about a table it was in the
    // middle of writing. Locals make the swap atomic: readers see the previous complete
    // geometry until the new complete geometry replaces it.
    var nextIdentities: [String] = []
    var nextOrigins: [CGFloat] = []
    var nextHeights: [CGFloat] = []
    nextIdentities.reserveCapacity(count)
    nextOrigins.reserveCapacity(count)
    nextHeights.reserveCapacity(count)

    var measured = 0
    var reused = 0
    var y = sectionInset.top
    for index in 0..<count {
      let identity = timelineDelegate.timelineLayout(self, identityAt: index)
      let height: CGFloat
      if let cached = heightByIdentity[identity] {
        height = cached
        reused += 1
      } else {
        // One NaN anywhere in this loop poisons every origin after it, and NaN fails
        // every comparison in the binary search below — which is a permanently blank
        // list, not a mis-sized row. Sanitise at the boundary where it enters.
        let raw = timelineDelegate.timelineLayout(self, heightForItemAt: index, width: width)
        height = raw.isFinite ? max(0.0, raw) : 0.0
        heightByIdentity[identity] = height
        measured += 1
      }
      nextIdentities.append(identity)
      nextOrigins.append(y)
      nextHeights.append(height)
      y += height
      if index < count - 1 { y += minimumLineSpacing }
    }

    identities = nextIdentities
    origins = nextOrigins
    heights = nextHeights
    totalHeight = y + sectionInset.bottom
    lastRebuildMeasuredRows = measured
    lastRebuildReusedRows = reused
    needsRebuild = false

    // The memo is keyed by identity and nothing prunes it on delete, so a long session
    // of opening chats would grow it without bound. Rows currently mounted are the only
    // ones worth keeping; anything else is re-measured for free the next time it is
    // seen. Only pays the sweep when it has actually drifted.
    if heightByIdentity.count > count * 4 && heightByIdentity.count > 2_000 {
      let live = Set(identities)
      heightByIdentity = heightByIdentity.filter { live.contains($0.key) }
    }

    // Publish for the next open of this chat. Written after the sweep so the shared
    // copy is the pruned one, and only when there is something worth keeping — an
    // empty table would evict a useful entry to store nothing.
    if let key = sharedMemoKey, !heightByIdentity.isEmpty {
      Self.storeSharedMemo(key, heightByIdentity)
    }
  }

  /// Names a rebuild that cost real time, and says who is paying for it.
  ///
  /// The critical field is `mode`. `UITrackingRunLoopMode` means this ran with
  /// the reader's finger on the glass — a rebuild there is a dropped frame no
  /// matter how well the arithmetic performs, because the delegate has to
  /// re-measure text for every row not in the memo. `measured` is how many rows
  /// that was; a large `measured` on a scroll is the bug, not the timing.
  private func reportRebuild(
    startedAt: CFTimeInterval, trigger: String, rows: Int, width: CGFloat, memoBefore: Int
  ) {
    let ms = (CACurrentMediaTime() - startedAt) * 1000.0
    rebuildCount += 1
    rebuildTotalMs += ms
    rebuildMeasuredTotal += lastRebuildMeasuredRows
    if ms > rebuildWorstMs { rebuildWorstMs = ms }
    // A rebuild that re-measures rows it had already measured is the design
    // failing, not the design working, and it is worth a line at any duration —
    // on a small transcript it is fast and still wrong.
    let memoMissed = memoBefore > 0 && lastRebuildReusedRows == 0 && lastRebuildMeasuredRows > 8
    guard ms >= Self.slowRebuildMs || memoMissed, rebuildsLogged < Self.rebuildLogCap else {
      return
    }
    rebuildsLogged += 1
    let mode = (CFRunLoopCopyCurrentMode(CFRunLoopGetMain())?.rawValue as String?) ?? "?"
    var note = ""
    if mode == "UITrackingRunLoopMode" {
      note = " — UNDER THE FINGER, this is a dropped frame"
    }
    if memoMissed {
      note +=
        " — MEMO MISSED ENTIRELY: \(memoBefore) heights cached, none matched. Row identity is not stable across commits."
    }
    NSLog(
      "[TimelineLayout] REBUILD %.0fms trigger=%@ rows=%d memo=%d measured=%d reused=%d w=%.0f mode=%@%@",
      ms, trigger, rows, memoBefore, lastRebuildMeasuredRows, lastRebuildReusedRows, width, mode,
      note)
    // Persisted too — the automated repro cannot keep a console attached, so
    // `NSLog` alone would make this invisible in exactly the runs that produce
    // the evidence. See the note in `VibeListShiftProbe.report`.
    VibeLog.warning(
      memoMissed ? "layout re-measured every row" : "slow layout rebuild",
      category: "listshift",
      metadata: [
        "ms": String(format: "%.0f", ms), "trigger": trigger, "rows": String(rows),
        "memo": String(memoBefore), "measured": String(lastRebuildMeasuredRows),
        "reused": String(lastRebuildReusedRows), "mode": mode,
      ])
  }

  /// Totals for the chat that is closing, so a session leaves a verdict behind
  /// even when no single rebuild crossed the log threshold.
  func logRebuildSummary(chatId: String, reason: String) {
    guard rebuildCount > 0 else { return }
    NSLog(
      "[TimelineLayout] summary chat=%@ (%@) rebuilds=%d total=%.0fms worst=%.0fms measured=%d rows=%d",
      String(chatId.prefix(12)), reason, rebuildCount, rebuildTotalMs, rebuildWorstMs,
      rebuildMeasuredTotal, identities.count)
    VibeLog.info(
      "layout rebuild totals", category: "listshift",
      metadata: [
        "chat": String(chatId.prefix(12)), "reason": reason, "rebuilds": String(rebuildCount),
        "totalMs": String(format: "%.0f", rebuildTotalMs),
        "worstMs": String(format: "%.0f", rebuildWorstMs),
        "measured": String(rebuildMeasuredTotal), "rows": String(identities.count),
      ])
  }

  // MARK: Stationary anchoring
  //
  // The row the reader is looking at, and how far below the top of the viewport it
  // sat, captured from the geometry BEFORE an update and re-applied after it.
  //
  // This is the whole answer to the class of bug that has outlived every previous
  // fix. Device measurement 2026-08-05: a rows commit grew the content by 1281.5pt
  // with **zero rows added** — heights above the viewport corrected upward — the
  // content offset did not compensate, and the visible transcript was shoved down a
  // screen and a half before a `scrollToBottom` snapped it back. Twelve different
  // sites can change a settled row's height, and chasing them one at a time is
  // endless; holding the anchor makes all twelve invisible instead.
  //
  // Telegram does exactly this and calls it `setupStationaryOffset` /
  // `fixScrollPosition` (`ListView.swift`), applying `previousFrame.minY -
  // currentFrame.minY` to every frame inside the same transaction as the mutation.
  // They hand-rolled a list to get it. UIKit hands it to a layout for free:
  // `targetContentOffset(forProposedContentOffset:)` is documented in
  // `UICollectionViewLayout.h` as "the content offset to be applied during
  // transition or update animations". We simply had never implemented it.
  private var stationaryAnchor: (identity: String, offsetInViewport: CGFloat)?

  /// The offset a **non-animated** update owes the reader, because UIKit never asked.
  ///
  /// `targetContentOffset(forProposedContentOffset:)` is consulted for animated updates
  /// only — the header quoted above says so in as many words ("during transition or update
  /// animations"). The transcript's batch path deliberately runs inside
  /// `UIView.performWithoutAnimation` + `CATransaction.setDisableActions(true)`
  /// (`ChatListView.setRows`, modes 0/1/2), which is every insert that is not a small
  /// append near the bottom. For all of those the anchor above was captured in
  /// `prepare(forCollectionViewUpdates:)` and then discarded by
  /// `finalizeCollectionViewUpdates()` without once being read.
  ///
  /// That is the history-drain shift. Device run 2026-08-05: a reader restored to offset
  /// 22858 of a 1,387-row chat, four pages of ~100 older rows inserted above them, and the
  /// offset still 22858 at the end while `contentH` went 36271 → 50463. The row under the
  /// viewport changed from `d1a9b741` to `bae0ed7f` with nobody scrolling — 14,192 pt of
  /// content appeared above the reader and they were made to pay for all of it.
  ///
  /// Published rather than applied here on purpose: the list owns *when* the transcript may
  /// move (`performInternalScrollAdjustment`), and a layout that set `contentOffset` itself
  /// would read as a user scroll and re-arm auto-follow — one more scroll authority, which
  /// is the thing this seam is trying to have fewer of.
  private var pendingStationaryOffsetY: CGFloat?

  /// Takes the pending adjustment. One reader, once.
  func consumePendingStationaryOffsetY() -> CGFloat? {
    defer { pendingStationaryOffsetY = nil }
    return pendingStationaryOffsetY
  }

  /// Records where the topmost visible row sits, in the pre-update tables.
  ///
  /// Must run before `ensurePrepared` rebuilds them, which is why it is the first
  /// statement of `prepare(forCollectionViewUpdates:)`.
  private func captureStationaryAnchor() {
    stationaryAnchor = nil
    guard let collectionView, let timelineDelegate,
      timelineDelegate.timelineLayoutShouldHoldStationaryAnchor(self),
      !origins.isEmpty, origins.count == identities.count
    else { return }
    let viewportTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    // First row whose bottom edge is still below the top of the viewport. Anchoring
    // on a row already scrolled past would hold a position nobody can see.
    let index = firstIndex(intersecting: viewportTop)
    guard index < origins.count else { return }
    stationaryAnchor = (identities[index], origins[index] - collectionView.contentOffset.y)
  }

  /// Where the anchor row now sits, expressed as the offset that puts it back on screen
  /// exactly where the reader last saw it. Everything above it may have grown or shrunk by
  /// any amount; that delta is absorbed here instead of being paid by the reader.
  private func stationaryTargetOffsetY() -> CGFloat? {
    guard let anchor = stationaryAnchor, let collectionView,
      let index = identities.firstIndex(of: anchor.identity),
      index < origins.count
    else { return nil }
    let desired = origins[index] - anchor.offsetInViewport
    let maxOffset = max(
      -collectionView.adjustedContentInset.top,
      totalHeight - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
    return max(-collectionView.adjustedContentInset.top, min(maxOffset, desired))
  }

  override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint)
    -> CGPoint
  {
    ensurePrepared()
    guard let y = stationaryTargetOffsetY() else { return proposedContentOffset }
    return CGPoint(x: proposedContentOffset.x, y: y)
  }

  override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
    captureStationaryAnchor()
    isUpdating = true
    super.prepare(forCollectionViewUpdates: updateItems)
    ensurePrepared()
  }

  override func finalizeCollectionViewUpdates() {
    isUpdating = false
    // Ask once more, now that the tables are final, and publish the answer if it is not
    // already the offset we are sitting at. On the animated path UIKit applied it through
    // `targetContentOffset` and the two agree, so nothing is published; on the
    // non-animated path nobody asked, and this is the only chance to say so. Same
    // computation either way — there is one anchor rule, not two.
    ensurePrepared()
    if let y = stationaryTargetOffsetY(), let collectionView,
      abs(collectionView.contentOffset.y - y) > 0.5
    {
      pendingStationaryOffsetY = y
    }
    stationaryAnchor = nil
    preUpdateOrigins.removeAll(keepingCapacity: true)
    preUpdateHeights.removeAll(keepingCapacity: true)
    super.finalizeCollectionViewUpdates()
  }

  // MARK: Query

  override var collectionViewContentSize: CGSize {
    ensurePrepared()
    let width = itemWidth > 1.0 ? itemWidth + sectionInset.left + sectionInset.right : 0.0
    return CGSize(width: max(width, collectionView?.bounds.width ?? 0.0), height: totalHeight)
  }

  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]?
  {
    ensurePrepared()
    guard !origins.isEmpty else { return [] }
    var result: [UICollectionViewLayoutAttributes] = []
    var index = firstIndex(intersecting: rect.minY)
    while index < origins.count, origins[index] < rect.maxY {
      // A zero-height row still has an origin; skip building an attribute for it rather
      // than handing UIKit an empty cell to mount.
      if heights[index] > 0, let attributes = attributes(at: index) {
        result.append(attributes)
      }
      index += 1
    }
    return result
  }

  override func layoutAttributesForItem(at indexPath: IndexPath)
    -> UICollectionViewLayoutAttributes?
  {
    ensurePrepared()
    guard indexPath.section == 0, indexPath.item >= 0, indexPath.item < origins.count else {
      return nil
    }
    return attributes(at: indexPath.item)
  }

  /// Cells never fade or transform, in or out.
  ///
  /// Inherited wholesale from the flow-layout subclass this replaces: position is the
  /// only thing that decides whether a bubble is visible. UIKit will otherwise attach an
  /// implicit opacity animation to any cell created during a batch update, which is the
  /// one-frame flash that scroll-back used to show.
  override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath)
    -> UICollectionViewLayoutAttributes?
  {
    guard let attributes = layoutAttributesForItem(at: itemIndexPath) else { return nil }
    attributes.alpha = 1.0
    attributes.transform = .identity
    return attributes
  }

  override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath)
    -> UICollectionViewLayoutAttributes?
  {
    // Old index paths address the pre-update tables. Falling back to the new ones would
    // put a leaving row at some unrelated row's position and animate it across the
    // screen on the way out.
    let item = itemIndexPath.item
    guard itemIndexPath.section == 0, item >= 0, item < preUpdateOrigins.count else {
      return layoutAttributesForItem(at: itemIndexPath).map {
        $0.alpha = 1.0
        $0.transform = .identity
        return $0
      }
    }
    let attributes = UICollectionViewLayoutAttributes(forCellWith: itemIndexPath)
    attributes.frame = CGRect(
      x: sectionInset.left, y: preUpdateOrigins[item],
      width: itemWidth, height: preUpdateHeights[item])
    attributes.alpha = 1.0
    attributes.transform = .identity
    return attributes
  }

  // MARK: Internals

  private func attributes(at index: Int) -> UICollectionViewLayoutAttributes? {
    let attributes = UICollectionViewLayoutAttributes(
      forCellWith: IndexPath(item: index, section: 0))
    attributes.frame = CGRect(
      x: sectionInset.left, y: origins[index], width: itemWidth, height: heights[index])
    attributes.alpha = 1.0
    return attributes
  }

  /// First row whose bottom edge is at or below `y`.
  ///
  /// Binary search rather than a scan: this runs on every scroll tick, and a linear
  /// walk from row zero is how a long transcript turns scrolling itself into O(n).
  private func firstIndex(intersecting y: CGFloat) -> Int {
    var low = 0
    var high = origins.count - 1
    var answer = origins.count
    while low <= high {
      let mid = (low + high) / 2
      if origins[mid] + heights[mid] >= y {
        answer = mid
        high = mid - 1
      } else {
        low = mid + 1
      }
    }
    return min(answer, origins.count)
  }
}
