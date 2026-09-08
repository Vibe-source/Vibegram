import CoreGraphics
import UIKit

// MARK: - Layout

/// A layout that is *told* its geometry instead of deriving it.
///
/// Every self-sizing mechanism UIKit offers — `estimatedItemSize`,
/// `preferredLayoutAttributesFitting`, automatic dimension — computes a row's
/// height at the moment the row is about to appear, which means the height of a
/// row can differ from the height the list already assumed for it. That
/// difference *is* the layout shift: the list settles, then a cell measures
/// itself, then everything below it moves.
///
/// Here the sizes arrive already frozen in the `VibeRenderSnapshot`, computed
/// once by `VibeRowMeasurementCache` and never re-derived. This layout does
/// arithmetic on numbers it was handed. It cannot produce a shift because it
/// has nothing to disagree with.
final class VibeTimelineListLayout: UICollectionViewLayout {
  private var frames: [CGRect] = []
  private var totalHeight: CGFloat = 0
  private var width: CGFloat = 0

  /// Row heights, oldest → newest. Replacing these is the only way geometry moves.
  func setRowHeights(_ heights: [CGFloat], width: CGFloat) {
    self.width = width
    frames.removeAll(keepingCapacity: true)
    frames.reserveCapacity(heights.count)
    var y: CGFloat = 0
    for h in heights {
      frames.append(CGRect(x: 0, y: y, width: width, height: h))
      y += h
    }
    totalHeight = y
  }

  override var collectionViewContentSize: CGSize { CGSize(width: width, height: totalHeight) }

  func frameForRow(_ index: Int) -> CGRect? {
    guard index >= 0, index < frames.count else { return nil }
    return frames[index]
  }

  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
    guard !frames.isEmpty else { return nil }
    // Binary search for the first row intersecting `rect`, then walk forward.
    // Scanning all 200 rows per pass would work too, but this keeps the cost
    // proportional to what is on screen, which is what the ≤4 ms budget is for.
    var low = 0
    var high = frames.count - 1
    var first = frames.count
    while low <= high {
      let mid = (low + high) / 2
      if frames[mid].maxY > rect.minY {
        first = mid
        high = mid - 1
      } else {
        low = mid + 1
      }
    }
    var result: [UICollectionViewLayoutAttributes] = []
    var i = first
    while i < frames.count, frames[i].minY < rect.maxY {
      if let attrs = layoutAttributesForItem(at: IndexPath(item: i, section: 0)) {
        result.append(attrs)
      }
      i += 1
    }
    return result
  }

  override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes?
  {
    guard indexPath.item >= 0, indexPath.item < frames.count else { return nil }
    let attrs = UICollectionViewLayoutAttributes(forCellWith: indexPath)
    attrs.frame = frames[indexPath.item]
    return attrs
  }

  override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
    newBounds.width != width
  }
}

// MARK: - Cell

/// Paints one row from a `VibeRenderItem`. Never measures anything.
final class VibeTimelineBubbleCell: UICollectionViewCell {
  static let reuseId = "VibeTimelineBubbleCell"

  private let bubble = UIView()
  private let label = UILabel()
  private let meta = UILabel()
  private let mediaBox = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    bubble.layer.cornerRadius = 15
    bubble.layer.cornerCurve = .continuous
    contentView.addSubview(bubble)

    label.numberOfLines = 0
    bubble.addSubview(label)

    meta.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
    meta.alpha = 0.65
    bubble.addSubview(meta)

    mediaBox.layer.cornerRadius = 10
    mediaBox.layer.cornerCurve = .continuous
    mediaBox.backgroundColor = UIColor.systemGray4
    mediaBox.isHidden = true
    bubble.addSubview(mediaBox)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// `outgoing` drives alignment; everything else comes from the item.
  func configure(with item: VibeRenderItem, text: String, detail: String, width: CGFloat) {
    let outgoing = item.paint.backgroundToken == "bubble.outgoing"
    let inset: CGFloat = 12
    let padH: CGFloat = 11
    let padV: CGFloat = 7

    // The row's own height minus the spacing baked into it by the measurer.
    let bubbleHeight = item.size.height - 4
    let bubbleWidth = item.size.width
    bubble.frame = CGRect(
      x: outgoing ? width - inset - bubbleWidth : inset,
      y: 0,
      width: bubbleWidth,
      height: bubbleHeight
    )
    bubble.backgroundColor =
      outgoing ? UIColor.tintColor : UIColor.secondarySystemFill

    label.textColor = outgoing ? .white : .label
    label.font = .preferredFont(forTextStyle: .body)
    label.text = text
    label.frame = item.layout.textFrame.offsetBy(dx: padH, dy: padV)

    meta.textColor = outgoing ? UIColor.white.withAlphaComponent(0.75) : .secondaryLabel
    meta.text = detail
    meta.frame = CGRect(
      x: padH, y: bubbleHeight - padV - item.layout.metaFrame.height,
      width: bubbleWidth - padH * 2, height: item.layout.metaFrame.height)

    if item.mediaSlots.isEmpty {
      mediaBox.isHidden = true
    } else {
      mediaBox.isHidden = false
      mediaBox.frame = item.layout.mediaBoxFrame.offsetBy(dx: padH, dy: padV)
    }
  }
}

// MARK: - Width reporting

/// A collection view that says how wide it is, when it actually knows.
///
/// Row heights depend on width, so *nothing* can be measured before a real
/// width exists. Asking the surrounding view hierarchy for one is unreliable:
/// SwiftUI calls `updateUIView` before layout, UIKit parents may not have
/// resolved constraints yet, and both can answer `0` and then never be asked
/// again. The view being laid out is the only thing that knows the answer at the
/// moment the answer becomes true, so it reports it rather than being polled.
final class VibeTimelineCollectionView: UICollectionView {
  var onWidthChange: ((CGFloat) -> Void)?
  private var reportedWidth: CGFloat = 0

  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.width > 0, bounds.width != reportedWidth else { return }
    reportedWidth = bounds.width
    onWidthChange?(bounds.width)
  }
}

// MARK: - Host

/// `UICollectionView` implementation of ``VibeMessageListHost``.
///
/// # Anchor preservation
///
/// Implements the §5.4 table. The mechanism is deliberately blunt: capture where
/// a chosen row sits relative to the viewport, mutate, then put that row back
/// where it was. `performBatchUpdates` is not used — its animations move the
/// content offset as a side effect, and "no visual jump" is a stronger
/// requirement than "pretty insertion". A trim of the window head is the case
/// that makes this non-negotiable: it removes rows *above* the viewport, and any
/// implementation that does not compensate scrolls the user's content out from
/// under them.
@MainActor
final class VibeCollectionMessageListHost: NSObject, VibeMessageListHost, VibeMessageListBodySink,
  VibeMessageListEngineLifecycle
{
  let view: UIView

  private let collectionView: VibeTimelineCollectionView
  private let listLayout = VibeTimelineListLayout()

  /// Fires when the list learns a new usable width. The owner must re-measure
  /// and re-mount; see ``VibeTimelineCollectionView``.
  var onWidthChange: ((CGFloat) -> Void)? {
    get { collectionView.onWidthChange }
    set { collectionView.onWidthChange = newValue }
  }

  var currentWidth: CGFloat { collectionView.bounds.width }

  private var items: [VibeRenderItem] = []
  /// Display text per row. Kept beside the items because `VibeRenderItem`
  /// carries geometry and paint tokens, not message bodies.
  private var bodies: [String: String] = [:]
  private var details: [String: String] = [:]

  /// Supplies the payload for a message the core has placed.
  ///
  /// **This is the entire seam between the core and UIKit**, and the division it
  /// draws is the point of the whole migration:
  ///
  /// - the core decides *which* messages exist, in what *order*, and how *tall*
  ///   each one is — measured once and frozen (§5.3)
  /// - Swift decides what a message *contains*, because the parse and the
  ///   decrypt already live there and moving them buys nothing
  ///
  /// Without this the host could only draw `VibeTimelineBubbleCell`, a plain
  /// bubble it defines itself — which is why every flag in front of it stopped
  /// at the preview screen. A real conversation needs agent turns, media, voice
  /// waveforms, link previews, replies and reactions, and all of that already
  /// exists in `ChatListCell`. Rebuilding it would be rewriting the app; the
  /// list's problem was never how it *drew* a row, it was everything it did
  /// around drawing one.
  ///
  /// Returning `nil` for a message id falls back to the placeholder bubble
  /// rather than dropping the row, so a payload the adapter has not yet supplied
  /// leaves a gap of the right height instead of a hole in the transcript.
  var rowProvider: ((String) -> ChatListRow?)?

  /// Configuration the chat applies to a real cell after `configure(row:)`.
  /// Kept as a hook rather than parameters so this host never grows a second
  /// copy of `ChatListView`'s per-row decoration rules.
  var rowCellDecorator: ((ChatListCell, ChatListRow) -> Void)?

  private(set) var lastAppliedGeneration: UInt64?
  private(set) var appliedTransactions = 0
  private(set) var rejectedTransactions = 0
  /// Rows whose height changed while settled. Gate §9.1 requires this to be 0.
  private(set) var settledGeometryViolations = 0

  /// Commits after which the anchored row did not end up where it started.
  ///
  /// §5.4's "no visual jump" is a measurable claim, so it gets measured rather
  /// than looked at. After every anchor-preserving commit the anchored row's
  /// screen position is recomputed and compared with where it was before; any
  /// disagreement beyond the geometry tolerance is a jump the user would see.
  private(set) var anchorDriftViolations = 0
  /// Largest observed drift in points, for triage.
  private(set) var worstAnchorDrift: CGFloat = 0

  /// `isFailure` separates "here is what happened" from "here is what went
  /// wrong". Routing both to `VibeLog.error` made 87 successful mounts show up
  /// as 87 errors, which is how a log stops being read.
  var onDiagnostic: ((_ message: String, _ meta: [String: String], _ isFailure: Bool) -> Void)?

  /// How close to the bottom still counts as pinned, in points.
  private let bottomPinSlack: CGFloat = 40

  override init() {
    let layout = listLayout
    collectionView = VibeTimelineCollectionView(frame: .zero, collectionViewLayout: layout)
    view = collectionView
    super.init()

    collectionView.backgroundColor = .clear
    collectionView.alwaysBounceVertical = true
    collectionView.dataSource = self
    collectionView.register(
      VibeTimelineBubbleCell.self, forCellWithReuseIdentifier: VibeTimelineBubbleCell.reuseId)
    // The real chat cell, so this host can draw an actual conversation rather
    // than the placeholder bubble. Registering both is what lets the preview
    // screen and the production list share one host: the preview supplies no
    // `rowProvider` and keeps the bubble; the chat supplies one and gets the
    // cell it has always used.
    collectionView.register(
      ChatListCell.self, forCellWithReuseIdentifier: ChatListCell.reuseIdentifier)
    // Prefetching instantiates cells ahead of the visible range on its own
    // schedule, which fights the explicit "visible + at most two screens" budget
    // in §5.2. The budget is measurable; prefetch heuristics are not.
    collectionView.isPrefetchingEnabled = false
  }

  /// Sets row text. Called by the adapter alongside `apply`.
  func setBodies(_ bodies: [String: String], details: [String: String]) {
    self.bodies = bodies
    self.details = details
  }

  /// Clears every trace of the previous engine, including the generation fence.
  ///
  /// `lastAppliedGeneration` is the important one: leaving it set means the next
  /// engine's transactions are compared against a number from a different
  /// engine's lifetime and rejected wholesale. The violation counter is
  /// deliberately **not** reset — it is a qualification measurement over the
  /// session, and zeroing it on every detach would let a real regression hide
  /// behind a chat switch.
  func detachFromEngine() {
    items.removeAll()
    bodies.removeAll()
    details.removeAll()
    lastAppliedGeneration = nil
    rebuildLayout()
    collectionView.reloadData()
  }

  // MARK: VibeMessageListHost

  func apply(snapshot: VibeRenderSnapshot, reason: VibeMountReason) {
    items = snapshot.items
    lastAppliedGeneration = snapshot.generation
    rebuildLayout()
    collectionView.reloadData()
    collectionView.layoutIfNeeded()
    // A mount is a first paint or a reconcile; §5.1 says it lands populated at
    // the bottom rather than at the top waiting to be scrolled.
    scrollToBottom(animated: false)
    onDiagnostic?(
      "mounted",
      ["reason": reason.rawValue, "rows": String(items.count),
       "gen": String(snapshot.generation), "commits": String(appliedTransactions)],
      false)
  }

  func apply(transaction: VibeListTransaction) {
    // Generation fence. Applying a transaction whose base is not what we hold
    // would interleave two versions of the timeline; the correct recovery is a
    // resync, which the adapter drives via a reset.
    if let current = lastAppliedGeneration, transaction.baseGeneration != current {
      rejectedTransactions += 1
      onDiagnostic?(
        "transaction rejected",
        ["base": String(transaction.baseGeneration), "held": String(current)], true)
      return
    }

    let capture = captureAnchor(preserve: transaction.preserve)
    var next = items

    for op in transaction.ops {
      switch op {
      case .insert(let newItems, let at):
        let index = min(max(at, 0), next.count)
        next.insert(contentsOf: newItems, at: index)
      case .remove(let ids):
        let doomed = Set(ids)
        next.removeAll { doomed.contains($0.identity.messageId) }
      case .updateContent(let id, let item):
        guard let index = next.firstIndex(where: { $0.identity.messageId == id }) else { break }
        if next[index].flags.locksGeometry, next[index].size.height != item.size.height {
          // The contract is that this cannot happen. Counting it is how the
          // §9.1 gate is measured rather than asserted.
          settledGeometryViolations += 1
          onDiagnostic?(
            "settled row changed height on a content op",
            ["id": id, "was": String(describing: next[index].size.height),
             "now": String(describing: item.size.height)], true)
        }
        next[index] = item
      case .updateGeometry(let id, let item, _):
        guard let index = next.firstIndex(where: { $0.identity.messageId == id }) else { break }
        next[index] = item
      case .move(let id, let to):
        guard let from = next.firstIndex(where: { $0.identity.messageId == id }) else { break }
        let moved = next.remove(at: from)
        next.insert(moved, at: min(max(to, 0), next.count))
      }
    }

    items = next
    lastAppliedGeneration = transaction.nextGeneration
    appliedTransactions += 1

    rebuildLayout()
    collectionView.reloadData()
    collectionView.layoutIfNeeded()
    let drift = restoreAnchor(capture)

    if let drift, abs(drift) > VibeTimelineShadowComparator.geometryTolerance {
      anchorDriftViolations += 1
      worstAnchorDrift = max(worstAnchorDrift, abs(drift))
      onDiagnostic?(
        "anchor drifted",
        ["id": capture.itemId ?? "?", "drift": String(format: "%.2f", drift),
         "worst": String(format: "%.2f", worstAnchorDrift)],
        true)
    }
  }

  func setViewportInsets(_ insets: UIEdgeInsets) {
    collectionView.contentInset = insets
    collectionView.verticalScrollIndicatorInsets = insets
  }

  func visibleAnchors() -> [VibeTimelineAnchor] {
    collectionView.indexPathsForVisibleItems
      .sorted { $0.item < $1.item }
      .compactMap { items.indices.contains($0.item) ? items[$0.item].identity : nil }
  }

  func prepareForNavigationPush(bounds: CGRect, safeBottom: CGFloat) {
    view.frame = bounds
    collectionView.contentInset.bottom = safeBottom
    collectionView.layoutIfNeeded()
  }

  func completePresentation() {}

  func cancelPrefetch(outside range: Range<Int>) { _ = range }

  func debugGeometryMap() -> [String: CGFloat] {
    Dictionary(
      uniqueKeysWithValues: items.map { ($0.identity.messageId, $0.size.height) })
  }

  // MARK: Anchor preservation

  private struct AnchorCapture {
    let itemId: String?
    let offsetFromViewportTop: CGFloat
    let pinnedToBottom: Bool
  }

  private var isPinnedToBottom: Bool {
    let maxOffset =
      collectionView.contentSize.height - collectionView.bounds.height
      + collectionView.contentInset.bottom
    return collectionView.contentOffset.y >= maxOffset - bottomPinSlack
  }

  private func captureAnchor(preserve: VibeAnchorPreserve) -> AnchorCapture {
    switch preserve.mode {
    case .pinToBottom:
      // Only *honour* the bottom pin if the user is actually at the bottom.
      // Yanking someone reading history down to the newest message is the
      // behaviour this contract exists to prevent, and "pinToBottom" from the
      // engine means "this is live traffic", not "override the reader".
      if isPinnedToBottom { return AnchorCapture(itemId: nil, offsetFromViewportTop: 0, pinnedToBottom: true) }
      return captureTopmostVisible()
    case .pinToItem(let id, let y):
      return AnchorCapture(itemId: id, offsetFromViewportTop: y, pinnedToBottom: false)
    case .pinToUnread:
      return captureTopmostVisible()
    }
  }

  private func captureTopmostVisible() -> AnchorCapture {
    let visible = collectionView.indexPathsForVisibleItems.sorted { $0.item < $1.item }
    guard let first = visible.first, items.indices.contains(first.item),
      let frame = listLayout.frameForRow(first.item)
    else {
      return AnchorCapture(itemId: nil, offsetFromViewportTop: 0, pinnedToBottom: false)
    }
    return AnchorCapture(
      itemId: items[first.item].identity.messageId,
      offsetFromViewportTop: frame.minY - collectionView.contentOffset.y,
      pinnedToBottom: false
    )
  }

  /// Puts the anchored row back where it was.
  ///
  /// Returns how far it actually ended up from where it started, in points, or
  /// `nil` when no preservation was attempted (a deliberate bottom-follow, a
  /// vanished anchor, or an offset the scroll range cannot represent). `nil` is
  /// not "zero drift" — conflating the two would let every clamped case report
  /// success.
  @discardableResult
  private func restoreAnchor(_ capture: AnchorCapture) -> CGFloat? {
    if capture.pinnedToBottom {
      // Following live traffic is an intentional move, not a jump.
      scrollToBottom(animated: false)
      return nil
    }
    guard let id = capture.itemId,
      let index = items.firstIndex(where: { $0.identity.messageId == id }),
      let frame = listLayout.frameForRow(index)
    else {
      // The anchor row is gone — it was the thing that got removed. Falling back
      // to the bottom is wrong when the user is reading history, so hold the
      // current offset and let the next commit re-anchor.
      return nil
    }
    let target = frame.minY - capture.offsetFromViewportTop
    let minOffset = -collectionView.contentInset.top
    let maxOffset = max(
      minOffset,
      collectionView.contentSize.height - collectionView.bounds.height
        + collectionView.contentInset.bottom)
    let clamped = min(max(target, minOffset), maxOffset)
    collectionView.contentOffset.y = clamped

    // Clamping means the scroll range physically cannot hold the anchor where it
    // was. That is a real visual move, but not a bug in preservation, so it is
    // reported as "not measured" rather than as a violation.
    guard abs(clamped - target) <= VibeTimelineShadowComparator.geometryTolerance else {
      return nil
    }
    return (frame.minY - clamped) - capture.offsetFromViewportTop
  }

  private func scrollToBottom(animated: Bool) {
    let maxOffset =
      collectionView.contentSize.height - collectionView.bounds.height
      + collectionView.contentInset.bottom
    guard maxOffset > -collectionView.contentInset.top else { return }
    collectionView.setContentOffset(CGPoint(x: 0, y: maxOffset), animated: animated)
  }

  private func rebuildLayout() {
    let width = collectionView.bounds.width
    listLayout.setRowHeights(items.map(\.size.height), width: width)
    listLayout.invalidateLayout()
  }
}

// MARK: - Data source

extension VibeCollectionMessageListHost: UICollectionViewDataSource {
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int
  {
    items.count
  }

  func collectionView(
    _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
  ) -> UICollectionViewCell {
    guard items.indices.contains(indexPath.item) else {
      return collectionView.dequeueReusableCell(
        withReuseIdentifier: VibeTimelineBubbleCell.reuseId, for: indexPath)
    }
    let item = items[indexPath.item]

    // Real conversation cell when an adapter has supplied the payload.
    //
    // Note what this method does NOT do, because it is the whole point: it does
    // not measure, does not consult a height cache, and does not ask the cell
    // what size it wants. The item's geometry was decided before mount and is
    // frozen; this is drawing and nothing else. Every post-hoc height mover in
    // the old list exists because that separation was never made.
    if let row = rowProvider?(item.identity.messageId) {
      let cell = collectionView.dequeueReusableCell(
        withReuseIdentifier: ChatListCell.reuseIdentifier, for: indexPath)
      if let listCell = cell as? ChatListCell {
        listCell.configure(row: row, hiddenMessageId: nil)
        rowCellDecorator?(listCell, row)
        return listCell
      }
      return cell
    }

    let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: VibeTimelineBubbleCell.reuseId, for: indexPath)
    guard let bubble = cell as? VibeTimelineBubbleCell else { return cell }
    bubble.configure(
      with: item,
      text: bodies[item.identity.messageId] ?? "",
      detail: details[item.identity.messageId] ?? "",
      width: collectionView.bounds.width
    )
    return bubble
  }
}

extension VibeCollectionMessageListHost: VibeMessageListHostMetrics {
  var instantiatedItemCount: Int { collectionView.visibleCells.count }
}
