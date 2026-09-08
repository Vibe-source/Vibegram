import CoreGraphics
import Foundation

// MARK: - Window policy

/// Active timeline window and preload budgets for list hosts.
///
/// Invariant: hosts must never retain more than a clamped active window of render
/// items; full history lives in core storage, not in the list model.
enum VibeTimelineWindowPolicy {
  /// Default active window size (messages).
  static let defaultActiveWindowCount: Int = 200
  /// Inclusive bounds for the active window (board qualification: 150…300).
  static let activeWindowRange: ClosedRange<Int> = 150...300
  /// Host may instantiate visible rows plus at most this many preload screens.
  static let maxPreloadScreens: Int = 2

  /// Clamps a proposed window count into `activeWindowRange`.
  static func clampActiveWindow(_ proposed: Int) -> Int {
    min(max(proposed, activeWindowRange.lowerBound), activeWindowRange.upperBound)
  }

  /// Whether `count` is a legal active window size.
  static func isValidActiveWindow(_ count: Int) -> Bool {
    activeWindowRange.contains(count)
  }
}

// MARK: - Stable identity / order

/// Stable scroll identity for one timeline row.
///
/// `messageId` is durable across edits; `identityGeneration` fences stale async
/// completions for that row. Not a UIKit object and never carries plaintext bodies.
struct VibeTimelineAnchor: Hashable, Sendable, Equatable {
  let messageId: String
  /// Per-identity generation fence (distinct from timeline snapshot generation).
  let identityGeneration: UInt64

  init(messageId: String, identityGeneration: UInt64 = 1) {
    self.messageId = messageId
    self.identityGeneration = identityGeneration
  }
}

/// Total order key within a timeline window (oldest → newest).
struct VibeOrderKey: Hashable, Sendable, Equatable, Comparable {
  /// Monotonic rank; lower sorts older.
  let rank: UInt64
  /// Tie-breaker when ranks collide (stable message id hash or insert sequence).
  let tieBreak: UInt64

  init(rank: UInt64, tieBreak: UInt64 = 0) {
    self.rank = rank
    self.tieBreak = tieBreak
  }

  static func < (lhs: VibeOrderKey, rhs: VibeOrderKey) -> Bool {
    if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
    return lhs.tieBreak < rhs.tieBreak
  }
}

// MARK: - Render kind / flags

enum VibeRenderItemKind: String, Sendable, Equatable, CaseIterable {
  case daySeparator
  case message
  case service
  case agentTurn
}

/// Bit flags describing row lifecycle. Settled rows forbid geometry mutation via
/// content-only replacement.
struct VibeRenderItemFlags: OptionSet, Sendable, Hashable {
  let rawValue: UInt32

  init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  static let settled = VibeRenderItemFlags(rawValue: 1 << 0)
  static let streaming = VibeRenderItemFlags(rawValue: 1 << 1)
  static let provisionalMedia = VibeRenderItemFlags(rawValue: 1 << 2)
  static let expandedTall = VibeRenderItemFlags(rawValue: 1 << 3)
  static let selected = VibeRenderItemFlags(rawValue: 1 << 4)

  /// Settled and not actively streaming — geometry must stay fixed under content-only ops.
  var locksGeometry: Bool {
    contains(.settled) && !contains(.streaming)
  }
}

// MARK: - Layout / paint / interaction (value types only)

/// Reserved media box; holds geometry and opaque load keys — never pixel buffers.
struct VibeMediaSlot: Sendable, Equatable {
  let frame: CGRect
  /// Width / height when known; `0` means unknown at settle (still height-locked).
  let aspectRatio: CGFloat
  /// Theme/blurhash token id — not decoded image data.
  let placeholderToken: String?
  /// Opaque media load key for the media pipeline.
  let loadKey: String

  init(
    frame: CGRect,
    aspectRatio: CGFloat = 0,
    placeholderToken: String? = nil,
    loadKey: String
  ) {
    self.frame = frame
    self.aspectRatio = aspectRatio
    self.placeholderToken = placeholderToken
    self.loadKey = loadKey
  }
}

/// Bubble sub-frames in list/row coordinates (points).
struct VibeBubbleLayoutSpec: Sendable, Equatable {
  let textFrame: CGRect
  let mediaBoxFrame: CGRect
  let replyFrame: CGRect
  let metaFrame: CGRect
  let avatarGutter: CGRect

  static let zero = VibeBubbleLayoutSpec(
    textFrame: .zero,
    mediaBoxFrame: .zero,
    replyFrame: .zero,
    metaFrame: .zero,
    avatarGutter: .zero
  )
}

/// Style reference for an attributed run — token ids only, no `NSAttributedString`.
struct VibeAttributedRunRef: Sendable, Equatable {
  let location: Int
  let length: Int
  let styleToken: String
}

/// Paint recipe using theme token ids (no `UIColor` / images).
struct VibePaintSpec: Sendable, Equatable {
  let backgroundToken: String
  let textStyleToken: String
  let attributedRunRefs: [VibeAttributedRunRef]

  init(
    backgroundToken: String = "bubble.default",
    textStyleToken: String = "text.body",
    attributedRunRefs: [VibeAttributedRunRef] = []
  ) {
    self.backgroundToken = backgroundToken
    self.textStyleToken = textStyleToken
    self.attributedRunRefs = attributedRunRefs
  }
}

enum VibeHitActionKind: String, Sendable, Equatable {
  case openMedia
  case reply
  case longPress
  case expandTall
  case link
  case avatar
  case other
}

struct VibeHitTarget: Sendable, Equatable {
  let id: String
  let frame: CGRect
  let action: VibeHitActionKind
}

/// Interaction / a11y metadata without UIView references.
struct VibeInteractionSpec: Sendable, Equatable {
  let hitTargets: [VibeHitTarget]
  let accessibilityLabel: String
  let accessibilityValue: String?
  /// Raw `UIAccessibilityTraits` bits stored as `UInt64` so UIKit is not required here.
  let accessibilityTraitsRaw: UInt64

  init(
    hitTargets: [VibeHitTarget] = [],
    accessibilityLabel: String = "",
    accessibilityValue: String? = nil,
    accessibilityTraitsRaw: UInt64 = 0
  ) {
    self.hitTargets = hitTargets
    self.accessibilityLabel = accessibilityLabel
    self.accessibilityValue = accessibilityValue
    self.accessibilityTraitsRaw = accessibilityTraitsRaw
  }

  static let empty = VibeInteractionSpec()
}

// MARK: - VibeRenderItem

/// Immutable geometry + paint recipe for one list row at a content/geometry revision.
///
/// **Settled invariant:** when `flags.locksGeometry` is true, a content-only replacement
/// must keep `size` and `geometryRevision` unchanged. Late media upgrades pixels inside
/// `mediaSlots` only and must not bump `geometryRevision`.
struct VibeRenderItem: Sendable, Equatable {
  let identity: VibeTimelineAnchor
  let orderKey: VibeOrderKey
  let kind: VibeRenderItemKind
  /// Bumps on edit / stream chunk / receipt-class paint change.
  let contentRevision: UInt64
  /// Bumps only on explicit height-changing ops (stream growth, tall expand).
  let geometryRevision: UInt64
  /// Final row size in list coordinates (points).
  let size: CGSize
  let layout: VibeBubbleLayoutSpec
  let paint: VibePaintSpec
  let mediaSlots: [VibeMediaSlot]
  let interaction: VibeInteractionSpec
  let flags: VibeRenderItemFlags

  init(
    identity: VibeTimelineAnchor,
    orderKey: VibeOrderKey,
    kind: VibeRenderItemKind = .message,
    contentRevision: UInt64 = 1,
    geometryRevision: UInt64 = 1,
    size: CGSize,
    layout: VibeBubbleLayoutSpec = .zero,
    paint: VibePaintSpec = VibePaintSpec(),
    mediaSlots: [VibeMediaSlot] = [],
    interaction: VibeInteractionSpec = .empty,
    flags: VibeRenderItemFlags = .settled
  ) {
    self.identity = identity
    self.orderKey = orderKey
    self.kind = kind
    self.contentRevision = contentRevision
    self.geometryRevision = geometryRevision
    self.size = size
    self.layout = layout
    self.paint = paint
    self.mediaSlots = mediaSlots
    self.interaction = interaction
    self.flags = flags
  }
}

// MARK: - Render item validation

enum VibeRenderItemValidationFailure: Error, Sendable, Equatable {
  case emptyMessageId
  case nonPositiveSize(width: CGFloat, height: CGFloat)
  case nonFiniteGeometry(messageId: String)
  case contentOnlyChangedSize(
    messageId: String,
    previous: CGSize,
    next: CGSize
  )
  case contentOnlyChangedGeometryRevision(
    messageId: String,
    previous: UInt64,
    next: UInt64
  )
  case identityMismatch(expected: String, actual: String)
  case identityGenerationMismatch(messageId: String, expected: UInt64, actual: UInt64)
  case contentRevisionNotAdvanced(messageId: String, previous: UInt64, next: UInt64)
  case contentOnlyChangedOrderKey(messageId: String)
  case geometryUpdateWithoutRevisionBump(messageId: String)
  case geometryUpdateSizeUnchanged(messageId: String)
  case geometryUpdateChangedWidth(messageId: String, previous: CGFloat, next: CGFloat)
  case geometryDeltaMismatch(messageId: String, declared: CGFloat, actual: CGFloat)
  case contentRevisionRegressed(messageId: String, previous: UInt64, next: UInt64)
}

enum VibeRenderItemValidator {
  /// Structural checks for a single item (identity + size).
  static func validateStructure(_ item: VibeRenderItem) -> Result<Void, VibeRenderItemValidationFailure> {
    if item.identity.messageId.isEmpty {
      return .failure(.emptyMessageId)
    }
    if !item.size.width.isFinite || !item.size.height.isFinite {
      return .failure(.nonFiniteGeometry(messageId: item.identity.messageId))
    }
    if item.size.width <= 0 || item.size.height <= 0 {
      return .failure(.nonPositiveSize(width: item.size.width, height: item.size.height))
    }
    let frames = [
      item.layout.textFrame,
      item.layout.mediaBoxFrame,
      item.layout.replyFrame,
      item.layout.metaFrame,
      item.layout.avatarGutter,
    ] + item.mediaSlots.map(\.frame) + item.interaction.hitTargets.map(\.frame)
    if frames.contains(where: { !isFinite($0) })
      || item.mediaSlots.contains(where: { !$0.aspectRatio.isFinite || $0.aspectRatio < 0 })
    {
      return .failure(.nonFiniteGeometry(messageId: item.identity.messageId))
    }
    return .success(())
  }

  /// Content-only replacement may change paint/contentRevision/media pixels, never
  /// size or geometryRevision when the current item locks geometry.
  static func validateContentOnlyReplacement(
    current: VibeRenderItem,
    replacement: VibeRenderItem
  ) -> Result<Void, VibeRenderItemValidationFailure> {
    if current.identity.messageId != replacement.identity.messageId {
      return .failure(
        .identityMismatch(
          expected: current.identity.messageId,
          actual: replacement.identity.messageId
        )
      )
    }
    if current.identity.identityGeneration != replacement.identity.identityGeneration {
      return .failure(
        .identityGenerationMismatch(
          messageId: current.identity.messageId,
          expected: current.identity.identityGeneration,
          actual: replacement.identity.identityGeneration
        )
      )
    }
    if let structureFailure = failure(of: validateStructure(replacement)) {
      return .failure(structureFailure)
    }
    if replacement.contentRevision <= current.contentRevision {
      return .failure(
        .contentRevisionNotAdvanced(
          messageId: current.identity.messageId,
          previous: current.contentRevision,
          next: replacement.contentRevision
        )
      )
    }
    if current.orderKey != replacement.orderKey {
      return .failure(.contentOnlyChangedOrderKey(messageId: current.identity.messageId))
    }
    if current.size != replacement.size {
      return .failure(
        .contentOnlyChangedSize(
          messageId: current.identity.messageId,
          previous: current.size,
          next: replacement.size
        )
      )
    }
    if current.geometryRevision != replacement.geometryRevision {
      return .failure(
        .contentOnlyChangedGeometryRevision(
          messageId: current.identity.messageId,
          previous: current.geometryRevision,
          next: replacement.geometryRevision
        )
      )
    }
    return .success(())
  }

  /// Explicit geometry updates must change size and bump geometryRevision.
  static func validateGeometryUpdate(
    current: VibeRenderItem,
    replacement: VibeRenderItem,
    deltaHeight: CGFloat
  ) -> Result<Void, VibeRenderItemValidationFailure> {
    if current.identity.messageId != replacement.identity.messageId {
      return .failure(
        .identityMismatch(
          expected: current.identity.messageId,
          actual: replacement.identity.messageId
        )
      )
    }
    if current.identity.identityGeneration != replacement.identity.identityGeneration {
      return .failure(
        .identityGenerationMismatch(
          messageId: current.identity.messageId,
          expected: current.identity.identityGeneration,
          actual: replacement.identity.identityGeneration
        )
      )
    }
    if let structureFailure = failure(of: validateStructure(replacement)) {
      return .failure(structureFailure)
    }
    if replacement.geometryRevision <= current.geometryRevision {
      return .failure(.geometryUpdateWithoutRevisionBump(messageId: current.identity.messageId))
    }
    if replacement.contentRevision < current.contentRevision {
      return .failure(
        .contentRevisionRegressed(
          messageId: current.identity.messageId,
          previous: current.contentRevision,
          next: replacement.contentRevision
        )
      )
    }
    if replacement.size.width != current.size.width {
      return .failure(
        .geometryUpdateChangedWidth(
          messageId: current.identity.messageId,
          previous: current.size.width,
          next: replacement.size.width
        )
      )
    }
    let actualDelta = replacement.size.height - current.size.height
    if !deltaHeight.isFinite || abs(actualDelta - deltaHeight) > 0.01 {
      return .failure(
        .geometryDeltaMismatch(
          messageId: current.identity.messageId,
          declared: deltaHeight,
          actual: actualDelta
        )
      )
    }
    return .success(())
  }

  private static func isFinite(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite
      && rect.origin.y.isFinite
      && rect.size.width.isFinite
      && rect.size.height.isFinite
  }

  private static func failure<T, E>(
    of result: Result<T, E>
  ) -> E? {
    if case .failure(let error) = result { return error }
    return nil
  }
}

// MARK: - Viewport / window / snapshot

enum VibeViewportPin: String, Sendable, Equatable {
  case bottom
  case item
  case unread
}

/// Where the viewport is pinned for anchor-preserving commits.
struct VibeViewportAnchor: Sendable, Equatable {
  let itemId: String
  let offsetFromTop: CGFloat
  let pin: VibeViewportPin

  init(itemId: String = "", offsetFromTop: CGFloat = 0, pin: VibeViewportPin = .bottom) {
    self.itemId = itemId
    self.offsetFromTop = offsetFromTop
    self.pin = pin
  }

  static let pinToBottom = VibeViewportAnchor(pin: .bottom)
}

enum VibeLayoutDirection: String, Sendable, Equatable {
  case ltr
  case rtl
}

/// Bounded query result mirror (core also freezes `VibeTimelineWindowV1`).
///
/// iOS host uses this as the window description inside a render snapshot. Ids only —
/// no row payloads.
struct VibeTimelineWindowV1: Sendable, Equatable {
  let chatId: String
  /// Message ids oldest → newest within the active window.
  let messageIds: [String]
  let anchors: [VibeTimelineAnchor]
  /// Index of the first id in the full timeline (for paging).
  let startIndex: Int
  let hasOlder: Bool
  let hasNewer: Bool

  init(
    chatId: String,
    messageIds: [String],
    anchors: [VibeTimelineAnchor] = [],
    startIndex: Int = 0,
    hasOlder: Bool = false,
    hasNewer: Bool = false
  ) {
    self.chatId = chatId
    self.messageIds = messageIds
    self.anchors = anchors
    self.startIndex = startIndex
    self.hasOlder = hasOlder
    self.hasNewer = hasNewer
  }

  var count: Int { messageIds.count }
}

/// Atomic viewport state the host can mount without further engine queries.
struct VibeRenderSnapshot: Sendable, Equatable {
  let chatId: String
  /// Engine timeline generation for this snapshot.
  let generation: UInt64
  let window: VibeTimelineWindowV1
  /// Contiguous window items, oldest → newest.
  let items: [VibeRenderItem]
  let anchor: VibeViewportAnchor
  let contentHeight: CGFloat
  let themeEpoch: UInt64
  let direction: VibeLayoutDirection
  let preferredContentSizeCategory: String

  init(
    chatId: String,
    generation: UInt64,
    window: VibeTimelineWindowV1,
    items: [VibeRenderItem],
    anchor: VibeViewportAnchor = .pinToBottom,
    contentHeight: CGFloat = 0,
    themeEpoch: UInt64 = 0,
    direction: VibeLayoutDirection = .ltr,
    preferredContentSizeCategory: String = "UICTContentSizeCategoryL"
  ) {
    self.chatId = chatId
    self.generation = generation
    self.window = window
    self.items = items
    self.anchor = anchor
    self.contentHeight = contentHeight
    self.themeEpoch = themeEpoch
    self.direction = direction
    self.preferredContentSizeCategory = preferredContentSizeCategory
  }
}

enum VibeRenderSnapshotValidationFailure: Error, Sendable, Equatable {
  case chatIdMismatch
  case windowItemCountMismatch(window: Int, items: Int)
  case windowOutOfPolicy(count: Int)
  case duplicateIdentity(messageId: String)
  case windowIdentityMismatch(index: Int, windowId: String, itemId: String)
  case windowAnchorCountMismatch(anchors: Int, items: Int)
  case windowAnchorMismatch(index: Int, anchorId: String, itemId: String)
  case invalidStartIndex(Int)
  case invalidContentHeight(CGFloat)
  case orderNotAscending
  case contentHeightMismatch(expected: CGFloat, actual: CGFloat)
  case itemFailure(VibeRenderItemValidationFailure)
}

enum VibeRenderSnapshotValidator {
  /// Height comparison tolerance when checking summed item heights.
  static let heightTolerance: CGFloat = 0.5

  static func validate(_ snapshot: VibeRenderSnapshot) -> Result<Void, VibeRenderSnapshotValidationFailure> {
    if snapshot.window.chatId != snapshot.chatId {
      return .failure(.chatIdMismatch)
    }
    if snapshot.window.messageIds.count != snapshot.items.count {
      return .failure(
        .windowItemCountMismatch(
          window: snapshot.window.messageIds.count,
          items: snapshot.items.count
        )
      )
    }
    if snapshot.window.startIndex < 0 {
      return .failure(.invalidStartIndex(snapshot.window.startIndex))
    }
    if !snapshot.window.anchors.isEmpty,
       snapshot.window.anchors.count != snapshot.items.count
    {
      return .failure(
        .windowAnchorCountMismatch(
          anchors: snapshot.window.anchors.count,
          items: snapshot.items.count
        )
      )
    }
    if !snapshot.contentHeight.isFinite || snapshot.contentHeight < 0 {
      return .failure(.invalidContentHeight(snapshot.contentHeight))
    }
    // No window-size check. How many rows a host is willing to mount is that host's
    // policy, not a property of whether a snapshot is well-formed — and treating it as
    // validity is what silently disabled the core on every real conversation.
    //
    // This used to reject anything over `activeWindowRange.upperBound` (300). The Rust
    // window then went unbounded and this did not follow, so from that moment every
    // snapshot for a chat with more than 300 messages failed here, `apply(snapshot:)`
    // never ran, the host's generation stayed 0, and every subsequent transaction was
    // fenced. Device run 2026-08-04:
    //   adapter FAILURE snapshot rejected failure=windowOutOfPolicy(count: 999)
    //   host TRANSACTION-FENCED base=1 held=0 — resync owed
    // repeating for the life of the chat. The core was doing all of its work and none
    // of it reached the screen, and nothing said so until the adapter's diagnostic was
    // routed to the console.
    //
    // A host that genuinely wants a bounded model still enforces its own bound and
    // trims to it — see `VibeTimelineReferenceHost.trimIfNeeded`. That is the right
    // place for it: the host knows what it can afford, the snapshot does not.

    var seen = Set<String>()
    var previousOrder: VibeOrderKey?
    var summedHeight: CGFloat = 0
    for (index, item) in snapshot.items.enumerated() {
      if let structureFailure = failure(of: VibeRenderItemValidator.validateStructure(item)) {
        return .failure(.itemFailure(structureFailure))
      }
      if !seen.insert(item.identity.messageId).inserted {
        return .failure(.duplicateIdentity(messageId: item.identity.messageId))
      }
      if let previousOrder, !(previousOrder < item.orderKey) {
        return .failure(.orderNotAscending)
      }
      previousOrder = item.orderKey
      summedHeight += item.size.height
      let windowId = snapshot.window.messageIds[index]
      if windowId != item.identity.messageId {
        return .failure(
          .windowIdentityMismatch(
            index: index,
            windowId: windowId,
            itemId: item.identity.messageId
          )
        )
      }
      if !snapshot.window.anchors.isEmpty {
        let anchorId = snapshot.window.anchors[index].messageId
        if anchorId != item.identity.messageId {
          return .failure(
            .windowAnchorMismatch(
              index: index,
              anchorId: anchorId,
              itemId: item.identity.messageId
            )
          )
        }
      }
    }

    if snapshot.contentHeight > 0,
       abs(snapshot.contentHeight - summedHeight) > heightTolerance
    {
      return .failure(
        .contentHeightMismatch(expected: summedHeight, actual: snapshot.contentHeight)
      )
    }
    return .success(())
  }

  private static func failure<T, E>(
    of result: Result<T, E>
  ) -> E? {
    if case .failure(let error) = result { return error }
    return nil
  }
}

// MARK: - Transactions

/// Ordered mutation applied atomically on the display commit.
enum VibeListOp: Sendable, Equatable {
  /// Insert items at a window order index (0 = oldest edge of current window).
  case insert(items: [VibeRenderItem], at: Int)
  case remove(ids: [String])
  /// Same geometryRevision; paint/content only.
  case updateContent(id: String, item: VibeRenderItem)
  /// Streaming / expand only; must bump geometryRevision.
  case updateGeometry(id: String, item: VibeRenderItem, deltaHeight: CGFloat)
  case move(id: String, to: Int)

  var touchedIds: [String] {
    switch self {
    case .insert(let items, _):
      return items.map(\.identity.messageId)
    case .remove(let ids):
      return ids
    case .updateContent(let id, _):
      return [id]
    case .updateGeometry(let id, _, _):
      return [id]
    case .move(let id, _):
      return [id]
    }
  }
}

enum VibeAnchorPreserveMode: Sendable, Equatable {
  case pinToBottom
  case pinToItem(id: String, y: CGFloat)
  case pinToUnread
}

struct VibeAnchorPreserve: Sendable, Equatable {
  let mode: VibeAnchorPreserveMode

  init(mode: VibeAnchorPreserveMode = .pinToBottom) {
    self.mode = mode
  }

  static let pinToBottom = VibeAnchorPreserve(mode: .pinToBottom)
}

enum VibeListAnimation: String, Sendable, Equatable {
  case none
  case insertSpring
  case deleteCollapse
  case heightMorph
}

enum VibeCommitDeadline: String, Sendable, Equatable {
  /// Coalesce to the next display-link frame (default).
  case displayLink
  /// Apply on the calling main-thread turn (still atomic).
  case immediate
}

/// Atomic list mutation with generation fencing.
struct VibeListTransaction: Sendable, Equatable {
  let baseGeneration: UInt64
  let nextGeneration: UInt64
  let ops: [VibeListOp]
  let preserve: VibeAnchorPreserve
  let animation: VibeListAnimation
  let commitDeadline: VibeCommitDeadline

  init(
    baseGeneration: UInt64,
    nextGeneration: UInt64,
    ops: [VibeListOp],
    preserve: VibeAnchorPreserve = .pinToBottom,
    animation: VibeListAnimation = .none,
    commitDeadline: VibeCommitDeadline = .displayLink
  ) {
    self.baseGeneration = baseGeneration
    self.nextGeneration = nextGeneration
    self.ops = ops
    self.preserve = preserve
    self.animation = animation
    self.commitDeadline = commitDeadline
  }
}

enum VibeListTransactionValidationFailure: Error, Sendable, Equatable {
  case generationNotAdvanced(base: UInt64, next: UInt64)
  case emptyOps
  case duplicateIdentityInTransaction(messageId: String)
  case insertIdentityMismatch
  case updateContentIdentityMismatch(opId: String, itemId: String)
  case updateGeometryIdentityMismatch(opId: String, itemId: String)
  case contentOnlyGeometryChanged(messageId: String)
  case contentOnlySizeChanged(messageId: String)
  case geometryRevisionNotBumped(messageId: String)
  case invalidOrderIndex(index: Int)
  case emptyRemoveSet
  case itemStructure(VibeRenderItemValidationFailure)
}

enum VibeListTransactionValidator {
  /// Validates generation fence, identity uniqueness, and content-vs-geometry op rules.
  ///
  /// Content-only ops must not change size or geometryRevision relative to the item
  /// payload's own declared revisions (payload is self-describing; host also checks
  /// against current model when applying).
  static func validate(
    _ transaction: VibeListTransaction
  ) -> Result<Void, VibeListTransactionValidationFailure> {
    if transaction.nextGeneration <= transaction.baseGeneration {
      return .failure(
        .generationNotAdvanced(
          base: transaction.baseGeneration,
          next: transaction.nextGeneration
        )
      )
    }
    if transaction.ops.isEmpty {
      return .failure(.emptyOps)
    }

    for op in transaction.ops {
      switch op {
      case .insert(let items, let at):
        if at < 0 {
          return .failure(.invalidOrderIndex(index: at))
        }
        if items.isEmpty {
          return .failure(.emptyOps)
        }
        var insertedIds = Set<String>()
        for item in items {
          if let structureFailure = failure(of: VibeRenderItemValidator.validateStructure(item)) {
            return .failure(.itemStructure(structureFailure))
          }
          if !insertedIds.insert(item.identity.messageId).inserted {
            return .failure(.duplicateIdentityInTransaction(messageId: item.identity.messageId))
          }
        }

      case .remove(let ids):
        if ids.isEmpty {
          return .failure(.emptyRemoveSet)
        }
        var removedIds = Set<String>()
        for id in ids {
          if id.isEmpty {
            return .failure(.duplicateIdentityInTransaction(messageId: id))
          }
          if !removedIds.insert(id).inserted {
            return .failure(.duplicateIdentityInTransaction(messageId: id))
          }
        }

      case .updateContent(let id, let item):
        if id != item.identity.messageId {
          return .failure(.updateContentIdentityMismatch(opId: id, itemId: item.identity.messageId))
        }
        if let structureFailure = failure(of: VibeRenderItemValidator.validateStructure(item)) {
          return .failure(.itemStructure(structureFailure))
        }
        // Content-only: item must not present itself as a geometry change.
        // Geometry revision and size are authoritative; host compares to base model.
        if item.flags.locksGeometry == false && item.flags.contains(.streaming) {
          // Streaming content updates are allowed without geometry bump only when
          // size is unchanged; geometry growth must use updateGeometry.
        }
      case .updateGeometry(let id, let item, _):
        if id != item.identity.messageId {
          return .failure(
            .updateGeometryIdentityMismatch(opId: id, itemId: item.identity.messageId)
          )
        }
        if let structureFailure = failure(of: VibeRenderItemValidator.validateStructure(item)) {
          return .failure(.itemStructure(structureFailure))
        }
        if item.geometryRevision == 0 {
          return .failure(.geometryRevisionNotBumped(messageId: id))
        }
      case .move(let id, let to):
        if to < 0 {
          return .failure(.invalidOrderIndex(index: to))
        }
        if id.isEmpty {
          return .failure(.duplicateIdentityInTransaction(messageId: id))
        }
      }
    }
    return .success(())
  }

  /// Validates an `updateContent` op against the currently mounted item (settled lock).
  static func validateContentOp(
    current: VibeRenderItem,
    replacement: VibeRenderItem
  ) -> Result<Void, VibeListTransactionValidationFailure> {
    switch VibeRenderItemValidator.validateContentOnlyReplacement(
      current: current,
      replacement: replacement
    ) {
    case .success:
      return .success(())
    case .failure(.contentOnlyChangedSize(_, _, _)):
      return .failure(.contentOnlySizeChanged(messageId: current.identity.messageId))
    case .failure(.contentOnlyChangedGeometryRevision(_, _, _)):
      return .failure(.contentOnlyGeometryChanged(messageId: current.identity.messageId))
    case .failure(let other):
      return .failure(.itemStructure(other))
    }
  }

  /// Validates an `updateGeometry` op against the currently mounted item.
  static func validateGeometryOp(
    current: VibeRenderItem,
    replacement: VibeRenderItem,
    deltaHeight: CGFloat
  ) -> Result<Void, VibeListTransactionValidationFailure> {
    switch VibeRenderItemValidator.validateGeometryUpdate(
      current: current,
      replacement: replacement,
      deltaHeight: deltaHeight
    ) {
    case .success:
      return .success(())
    case .failure(.geometryUpdateWithoutRevisionBump(let id)):
      return .failure(.geometryRevisionNotBumped(messageId: id))
    case .failure(let other):
      return .failure(.itemStructure(other))
    }
  }

  private static func failure<T, E>(
    of result: Result<T, E>
  ) -> E? {
    if case .failure(let error) = result { return error }
    return nil
  }
}

// MARK: - Mount reason (host apply)

enum VibeMountReason: String, Sendable, Equatable {
  case navigationPush
  case reopen
  case engineReconcile
  case themeOrTrait
  case windowShift
  case debug
}
