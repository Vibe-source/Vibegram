import CoreGraphics
import UIKit

// MARK: - Failure (identifier / metric only)

/// Typed apply failure for the in-memory reference host.
///
/// Carries message ids and numeric metrics only — never plaintext bodies, media
/// bytes, or UIKit objects. On any failure the committed model is left unchanged.
enum VibeTimelineReferenceHostFailure: Error, Sendable, Equatable {
  case snapshotValidation(VibeRenderSnapshotValidationFailure)
  case transactionValidation(VibeListTransactionValidationFailure)
  case generationMismatch(expectedBase: UInt64, current: UInt64)
  case generationNotMonotonic(previous: UInt64, next: UInt64)
  case unknownIdentity(messageId: String)
  case duplicateIdentity(messageId: String)
  case invalidInsertIndex(index: Int, count: Int)
  case invalidMoveIndex(index: Int, count: Int)
  case orderNotAscending(messageId: String)
  case windowOutOfPolicy(count: Int)
  case emptyModel
}

// MARK: - Prefetch cancel record (bounded, no work)

/// Records a `cancelPrefetch(outside:)` call without performing media/layout work.
struct VibeTimelinePrefetchCancelRecord: Sendable, Equatable {
  /// Range that remains valid for prefetch after the call.
  let keptRange: Range<Int>
  /// Message ids that fell outside `keptRange` at cancel time (bounded to model).
  let cancelledIds: [String]
}

// MARK: - Model fingerprint (deterministic, id/metric only)

/// Compact committed-model fingerprint for deterministic replay comparison.
struct VibeTimelineModelFingerprint: Sendable, Equatable {
  let generation: UInt64
  let itemCount: Int
  let orderedIds: [String]
  /// Per-id height, contentRevision, geometryRevision (parallel to `orderedIds`).
  let heights: [CGFloat]
  let contentRevisions: [UInt64]
  let geometryRevisions: [UInt64]
  let anchorItemId: String
  let anchorPin: VibeViewportPin

  /// Stable string form for equality of same-seed runs (ids + metrics only).
  var token: String {
    var parts: [String] = [
      "g=\(generation)",
      "n=\(itemCount)",
      "a=\(anchorItemId)",
      "p=\(anchorPin.rawValue)",
    ]
    for i in orderedIds.indices {
      parts.append(
        "\(orderedIds[i]):h=\(heights[i]):c=\(contentRevisions[i]):g=\(geometryRevisions[i])"
      )
    }
    return parts.joined(separator: "|")
  }
}

// MARK: - VibeTimelineReferenceHost

/// Bounded, deterministic in-memory `VibeMessageListHost` for contract / replay
/// qualification. Model oracle only — not a live renderer and not wired into chat.
///
/// - Backed by an ordered item array + id→index map.
/// - Validates every snapshot and transaction before mutation; failures are atomic.
/// - After each successful commit, trims to the configured active window (150…300),
///   from the side opposite the preserve anchor.
/// - Tracks ids, items, geometry, anchor, and timing metadata only.
@MainActor
final class VibeTimelineReferenceHost: VibeMessageListHost {
  let view: UIView

  /// Clamped active window capacity (inclusive upper bound for committed count).
  private(set) var activeWindowCount: Int

  private var items: [VibeRenderItem] = []
  /// Message id → index into `items`.
  private var indexById: [String: Int] = [:]

  private(set) var chatId: String = ""
  private(set) var generation: UInt64 = 0
  private(set) var hasCommittedModel: Bool = false
  private(set) var viewportAnchor: VibeViewportAnchor = .pinToBottom
  private(set) var viewportInsets: UIEdgeInsets = .zero
  private(set) var contentHeight: CGFloat = 0
  private(set) var themeEpoch: UInt64 = 0
  private(set) var direction: VibeLayoutDirection = .ltr
  private(set) var preferredContentSizeCategory: String = "UICTContentSizeCategoryL"
  private(set) var lastSnapshot: VibeRenderSnapshot?
  private(set) var lastTransaction: VibeListTransaction?
  private(set) var lastMountReason: VibeMountReason?
  private(set) var lastFailure: VibeTimelineReferenceHostFailure?
  private(set) var lastPreserve: VibeAnchorPreserve = .pinToBottom

  /// Successful apply count (snapshot or transaction).
  private(set) var successfulApplyCount: Int = 0
  /// Failed apply attempts (model unchanged).
  private(set) var failedApplyCount: Int = 0
  /// Virtual / host-local monotonic commit counter (not wall clock).
  private(set) var commitSequence: UInt64 = 0

  private(set) var prefetchCancelRecords: [VibeTimelinePrefetchCancelRecord] = []
  private(set) var didPrepareNavigationPush: Bool = false
  private(set) var didCompletePresentation: Bool = false
  private(set) var preparedBounds: CGRect = .zero
  private(set) var preparedSafeBottom: CGFloat = 0

  init(activeWindowCount: Int = VibeTimelineWindowPolicy.defaultActiveWindowCount) {
    self.view = UIView(frame: .zero)
    self.activeWindowCount = VibeTimelineWindowPolicy.clampActiveWindow(activeWindowCount)
  }

  init(
    view: UIView,
    activeWindowCount: Int = VibeTimelineWindowPolicy.defaultActiveWindowCount
  ) {
    self.view = view
    self.activeWindowCount = VibeTimelineWindowPolicy.clampActiveWindow(activeWindowCount)
  }

  /// Updates the active window capacity (clamped). Does not re-trim existing model
  /// until the next successful commit.
  func setActiveWindowCount(_ proposed: Int) {
    activeWindowCount = VibeTimelineWindowPolicy.clampActiveWindow(proposed)
  }

  // MARK: - VibeMessageListHost

  func apply(snapshot: VibeRenderSnapshot, reason: VibeMountReason) {
    _ = tryApply(snapshot: snapshot, reason: reason)
  }

  func apply(transaction: VibeListTransaction) {
    _ = tryApply(transaction: transaction)
  }

  func setViewportInsets(_ insets: UIEdgeInsets) {
    viewportInsets = insets
  }

  func visibleAnchors() -> [VibeTimelineAnchor] {
    items.map(\.identity)
  }

  func prepareForNavigationPush(bounds: CGRect, safeBottom: CGFloat) {
    view.frame = bounds
    preparedBounds = bounds
    preparedSafeBottom = safeBottom
    didPrepareNavigationPush = true
  }

  func completePresentation() {
    didCompletePresentation = true
  }

  func cancelPrefetch(outside range: Range<Int>) {
    let count = items.count
    var cancelled: [String] = []
    cancelled.reserveCapacity(max(0, count - range.count))
    for (index, item) in items.enumerated() where !range.contains(index) {
      cancelled.append(item.identity.messageId)
    }
    prefetchCancelRecords.append(
      VibeTimelinePrefetchCancelRecord(keptRange: range, cancelledIds: cancelled)
    )
  }

  func debugGeometryMap() -> [String: CGFloat] {
    var map: [String: CGFloat] = [:]
    map.reserveCapacity(items.count)
    for item in items {
      map[item.identity.messageId] = item.size.height
    }
    return map
  }

  // MARK: - Result-returning apply (tests / harness)

  /// Validate + commit a snapshot. On failure returns the error and leaves the model.
  @discardableResult
  func tryApply(
    snapshot: VibeRenderSnapshot,
    reason: VibeMountReason
  ) -> Result<Void, VibeTimelineReferenceHostFailure> {
    lastFailure = nil

    switch VibeRenderSnapshotValidator.validate(snapshot) {
    case .failure(let failure):
      return recordFailure(.snapshotValidation(failure))
    case .success:
      break
    }

    if hasCommittedModel, snapshot.generation < generation {
      return recordFailure(
        .generationNotMonotonic(previous: generation, next: snapshot.generation)
      )
    }

    // Build working model, then optionally trim if over configured capacity.
    // Snapshots already rejected when count > policy upper bound (300).
    var nextItems = snapshot.items
    var nextIndex = Dictionary(
      uniqueKeysWithValues: nextItems.enumerated().map { ($1.identity.messageId, $0) }
    )
    let preserve = preserveMode(from: snapshot.anchor)
    trimIfNeeded(
      items: &nextItems,
      indexById: &nextIndex,
      preserve: preserve,
      maxCount: activeWindowCount
    )

    if nextItems.count > activeWindowCount {
      return recordFailure(.windowOutOfPolicy(count: nextItems.count))
    }
    // Snapshot validator already enforces ascending order keys on the input;
    // re-check after optional trim (contiguous subrange preserves order).
    if let orderFailure = firstOrderFailure(in: nextItems) {
      return recordFailure(orderFailure)
    }

    commitModel(
      items: nextItems,
      indexById: nextIndex,
      chatId: snapshot.chatId,
      generation: snapshot.generation,
      anchor: snapshot.anchor,
      contentHeight: sumHeights(nextItems),
      themeEpoch: snapshot.themeEpoch,
      direction: snapshot.direction,
      preferredContentSizeCategory: snapshot.preferredContentSizeCategory,
      preserve: preserve
    )
    lastSnapshot = snapshot
    lastMountReason = reason
    lastTransaction = nil
    successfulApplyCount += 1
    commitSequence += 1
    return .success(())
  }

  /// Validate + commit a transaction. On failure returns the error and leaves the model.
  @discardableResult
  func tryApply(
    transaction: VibeListTransaction
  ) -> Result<Void, VibeTimelineReferenceHostFailure> {
    lastFailure = nil

    switch VibeListTransactionValidator.validate(transaction) {
    case .failure(let failure):
      return recordFailure(.transactionValidation(failure))
    case .success:
      break
    }

    let currentGen = hasCommittedModel ? generation : 0
    if transaction.baseGeneration != currentGen {
      return recordFailure(
        .generationMismatch(
          expectedBase: transaction.baseGeneration,
          current: currentGen
        )
      )
    }

    // Working copy — never mutate committed state until all ops succeed.
    var workItems = items
    var workIndex = indexById

    for op in transaction.ops {
      if let failure = applyOp(op, items: &workItems, indexById: &workIndex) {
        return recordFailure(failure)
      }
    }

    // A transaction may be positional, but the committed model must still preserve
    // the canonical total order. Accepting an out-of-order insert here would make the
    // oracle bless exactly the kind of visible reorder/jump this boundary is meant to
    // prevent. The producer must provide an index consistent with each item's key.
    if let orderFailure = firstOrderFailure(in: workItems) {
      return recordFailure(orderFailure)
    }

    trimIfNeeded(
      items: &workItems,
      indexById: &workIndex,
      preserve: transaction.preserve,
      maxCount: activeWindowCount
    )

    if workItems.count > activeWindowCount {
      return recordFailure(.windowOutOfPolicy(count: workItems.count))
    }

    let nextAnchor = anchorAfterCommit(
      preserve: transaction.preserve,
      items: workItems,
      previous: viewportAnchor
    )

    commitModel(
      items: workItems,
      indexById: workIndex,
      chatId: chatId,
      generation: transaction.nextGeneration,
      anchor: nextAnchor,
      contentHeight: sumHeights(workItems),
      themeEpoch: themeEpoch,
      direction: direction,
      preferredContentSizeCategory: preferredContentSizeCategory,
      preserve: transaction.preserve
    )
    lastTransaction = transaction
    successfulApplyCount += 1
    commitSequence += 1
    return .success(())
  }

  // MARK: - Inspectable model

  /// Ordered committed identities (oldest → newest).
  var orderedIds: [String] {
    items.map(\.identity.messageId)
  }

  /// Ordered committed items (copy of the model array).
  var committedItems: [VibeRenderItem] {
    items
  }

  var committedItemCount: Int {
    items.count
  }

  func item(forId id: String) -> VibeRenderItem? {
    guard let index = indexById[id] else { return nil }
    return items[index]
  }

  func index(ofId id: String) -> Int? {
    indexById[id]
  }

  /// Deterministic fingerprint of the committed model (ids + metrics only).
  func modelFingerprint() -> VibeTimelineModelFingerprint {
    VibeTimelineModelFingerprint(
      generation: generation,
      itemCount: items.count,
      orderedIds: items.map(\.identity.messageId),
      heights: items.map(\.size.height),
      contentRevisions: items.map(\.contentRevision),
      geometryRevisions: items.map(\.geometryRevision),
      anchorItemId: viewportAnchor.itemId,
      anchorPin: viewportAnchor.pin
    )
  }

  /// Invariant check for tests: unique ids, index integrity, count bound, and canonical
  /// total order. Callers may disable the order assertion only when deliberately
  /// inspecting an already-rejected working fixture.
  func assertModelInvariants(
    requireAscendingOrder: Bool = true
  ) -> Result<Void, VibeTimelineReferenceHostFailure> {
    if items.count > activeWindowCount {
      return .failure(.windowOutOfPolicy(count: items.count))
    }
    if items.count != indexById.count {
      return .failure(
        .duplicateIdentity(messageId: items.first?.identity.messageId ?? "")
      )
    }
    var seen = Set<String>()
    for (index, item) in items.enumerated() {
      let id = item.identity.messageId
      if !seen.insert(id).inserted {
        return .failure(.duplicateIdentity(messageId: id))
      }
      if indexById[id] != index {
        return .failure(.unknownIdentity(messageId: id))
      }
    }
    if requireAscendingOrder, let orderFailure = firstOrderFailure(in: items) {
      return .failure(orderFailure)
    }
    return .success(())
  }

  // MARK: - Op application (working copy)

  private func applyOp(
    _ op: VibeListOp,
    items: inout [VibeRenderItem],
    indexById: inout [String: Int]
  ) -> VibeTimelineReferenceHostFailure? {
    switch op {
    case .insert(let newItems, let at):
      return applyInsert(newItems, at: at, items: &items, indexById: &indexById)
    case .remove(let ids):
      return applyRemove(ids, items: &items, indexById: &indexById)
    case .updateContent(let id, let item):
      return applyUpdateContent(id: id, item: item, items: &items, indexById: &indexById)
    case .updateGeometry(let id, let item, let deltaHeight):
      return applyUpdateGeometry(
        id: id,
        item: item,
        deltaHeight: deltaHeight,
        items: &items,
        indexById: &indexById
      )
    case .move(let id, let to):
      return applyMove(id: id, to: to, items: &items, indexById: &indexById)
    }
  }

  private func applyInsert(
    _ newItems: [VibeRenderItem],
    at index: Int,
    items: inout [VibeRenderItem],
    indexById: inout [String: Int]
  ) -> VibeTimelineReferenceHostFailure? {
    if index < 0 || index > items.count {
      return .invalidInsertIndex(index: index, count: items.count)
    }
    for item in newItems {
      let id = item.identity.messageId
      if indexById[id] != nil {
        return .duplicateIdentity(messageId: id)
      }
      if case .failure(let structure) = VibeRenderItemValidator.validateStructure(item) {
        return .transactionValidation(.itemStructure(structure))
      }
    }
    items.insert(contentsOf: newItems, at: index)
    rebuildIndex(items: items, indexById: &indexById)
    return nil
  }

  private func applyRemove(
    _ ids: [String],
    items: inout [VibeRenderItem],
    indexById: inout [String: Int]
  ) -> VibeTimelineReferenceHostFailure? {
    // Resolve indices first so missing ids fail before any mutation.
    var indices: [Int] = []
    indices.reserveCapacity(ids.count)
    for id in ids {
      guard let idx = indexById[id] else {
        return .unknownIdentity(messageId: id)
      }
      indices.append(idx)
    }
    for idx in indices.sorted(by: >) {
      items.remove(at: idx)
    }
    rebuildIndex(items: items, indexById: &indexById)
    return nil
  }

  private func applyUpdateContent(
    id: String,
    item: VibeRenderItem,
    items: inout [VibeRenderItem],
    indexById: inout [String: Int]
  ) -> VibeTimelineReferenceHostFailure? {
    guard let idx = indexById[id] else {
      return .unknownIdentity(messageId: id)
    }
    let current = items[idx]
    switch VibeListTransactionValidator.validateContentOp(current: current, replacement: item) {
    case .failure(let failure):
      return .transactionValidation(failure)
    case .success:
      break
    }
    items[idx] = item
    return nil
  }

  private func applyUpdateGeometry(
    id: String,
    item: VibeRenderItem,
    deltaHeight: CGFloat,
    items: inout [VibeRenderItem],
    indexById: inout [String: Int]
  ) -> VibeTimelineReferenceHostFailure? {
    guard let idx = indexById[id] else {
      return .unknownIdentity(messageId: id)
    }
    let current = items[idx]
    switch VibeListTransactionValidator.validateGeometryOp(
      current: current,
      replacement: item,
      deltaHeight: deltaHeight
    ) {
    case .failure(let failure):
      return .transactionValidation(failure)
    case .success:
      break
    }
    items[idx] = item
    return nil
  }

  private func applyMove(
    id: String,
    to destination: Int,
    items: inout [VibeRenderItem],
    indexById: inout [String: Int]
  ) -> VibeTimelineReferenceHostFailure? {
    guard let from = indexById[id] else {
      return .unknownIdentity(messageId: id)
    }
    // Destination is the final index in the array after removal, matching the core
    // reference applier. Do not subtract one when moving forward.
    let count = items.count
    if destination < 0 || destination >= count {
      return .invalidMoveIndex(index: destination, count: count)
    }
    if from == destination {
      return nil
    }
    let item = items.remove(at: from)
    items.insert(item, at: destination)
    rebuildIndex(items: items, indexById: &indexById)
    return nil
  }

  // MARK: - Window trim

  /// Trims overflow from the side opposite the preserve anchor.
  /// - Bottom pin: drop oldest (front).
  /// - Item / unread pin: keep the anchor and nearest neighbors.
  private func trimIfNeeded(
    items: inout [VibeRenderItem],
    indexById: inout [String: Int],
    preserve: VibeAnchorPreserve,
    maxCount: Int
  ) {
    guard items.count > maxCount else { return }
    let overflow = items.count - maxCount

    switch preserve.mode {
    case .pinToBottom:
      items.removeFirst(overflow)

    case .pinToItem(let id, _):
      trimAroundAnchor(id: id, items: &items, maxCount: maxCount)

    case .pinToUnread:
      // Prefer explicit item id on current viewport anchor; else treat as bottom pin.
      let unreadId = viewportAnchor.itemId
      if !unreadId.isEmpty, indexById[unreadId] != nil || items.contains(where: {
        $0.identity.messageId == unreadId
      }) {
        trimAroundAnchor(id: unreadId, items: &items, maxCount: maxCount)
      } else {
        items.removeFirst(overflow)
      }
    }

    rebuildIndex(items: items, indexById: &indexById)
  }

  private func trimAroundAnchor(
    id: String,
    items: inout [VibeRenderItem],
    maxCount: Int
  ) {
    guard items.count > maxCount else { return }
    guard let anchorIndex = items.firstIndex(where: { $0.identity.messageId == id }) else {
      // Anchor missing: fall back to bottom-pin (trim oldest).
      let overflow = items.count - maxCount
      items.removeFirst(overflow)
      return
    }

    // Keep a contiguous window of `maxCount` centered on the anchor when possible.
    let half = maxCount / 2
    var start = anchorIndex - half
    var end = start + maxCount
    if start < 0 {
      start = 0
      end = maxCount
    }
    if end > items.count {
      end = items.count
      start = max(0, end - maxCount)
    }
    items = Array(items[start..<end])
  }

  // MARK: - Helpers

  private func commitModel(
    items nextItems: [VibeRenderItem],
    indexById nextIndex: [String: Int],
    chatId: String,
    generation: UInt64,
    anchor: VibeViewportAnchor,
    contentHeight: CGFloat,
    themeEpoch: UInt64,
    direction: VibeLayoutDirection,
    preferredContentSizeCategory: String,
    preserve: VibeAnchorPreserve
  ) {
    self.items = nextItems
    self.indexById = nextIndex
    self.chatId = chatId
    self.generation = generation
    self.hasCommittedModel = true
    self.viewportAnchor = anchor
    self.contentHeight = contentHeight
    self.themeEpoch = themeEpoch
    self.direction = direction
    self.preferredContentSizeCategory = preferredContentSizeCategory
    self.lastPreserve = preserve
    self.lastFailure = nil
  }

  private func recordFailure(
    _ failure: VibeTimelineReferenceHostFailure
  ) -> Result<Void, VibeTimelineReferenceHostFailure> {
    lastFailure = failure
    failedApplyCount += 1
    return .failure(failure)
  }

  private func rebuildIndex(
    items: [VibeRenderItem],
    indexById: inout [String: Int]
  ) {
    indexById.removeAll(keepingCapacity: true)
    for (index, item) in items.enumerated() {
      indexById[item.identity.messageId] = index
    }
  }

  private func firstOrderFailure(
    in items: [VibeRenderItem]
  ) -> VibeTimelineReferenceHostFailure? {
    guard items.count > 1 else { return nil }
    for i in 1..<items.count {
      if !(items[i - 1].orderKey < items[i].orderKey) {
        return .orderNotAscending(messageId: items[i].identity.messageId)
      }
    }
    return nil
  }

  private func sumHeights(_ items: [VibeRenderItem]) -> CGFloat {
    items.reduce(0) { $0 + $1.size.height }
  }

  private func preserveMode(from anchor: VibeViewportAnchor) -> VibeAnchorPreserve {
    switch anchor.pin {
    case .bottom:
      return .pinToBottom
    case .item:
      return VibeAnchorPreserve(mode: .pinToItem(id: anchor.itemId, y: anchor.offsetFromTop))
    case .unread:
      return VibeAnchorPreserve(mode: .pinToUnread)
    }
  }

  private func anchorAfterCommit(
    preserve: VibeAnchorPreserve,
    items: [VibeRenderItem],
    previous: VibeViewportAnchor
  ) -> VibeViewportAnchor {
    switch preserve.mode {
    case .pinToBottom:
      let lastId = items.last?.identity.messageId ?? ""
      return VibeViewportAnchor(itemId: lastId, offsetFromTop: 0, pin: .bottom)
    case .pinToItem(let id, let y):
      return VibeViewportAnchor(itemId: id, offsetFromTop: y, pin: .item)
    case .pinToUnread:
      if !previous.itemId.isEmpty {
        return VibeViewportAnchor(itemId: previous.itemId, offsetFromTop: previous.offsetFromTop, pin: .unread)
      }
      let lastId = items.last?.identity.messageId ?? ""
      return VibeViewportAnchor(itemId: lastId, offsetFromTop: 0, pin: .unread)
    }
  }
}

// MARK: - Metrics

extension VibeTimelineReferenceHost: VibeMessageListHostMetrics {
  var lastAppliedGeneration: UInt64? {
    hasCommittedModel ? generation : nil
  }

  var instantiatedItemCount: Int {
    items.count
  }
}
