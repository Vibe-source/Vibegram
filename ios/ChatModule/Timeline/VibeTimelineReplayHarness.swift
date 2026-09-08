import CoreGraphics
import Foundation

// MARK: - Seed constants

enum VibeTimelineReplaySeeds {
  /// Deterministic board seed for 2026-08-02 (date-encoded, not a secret).
  static let board0802: UInt64 = 2_026_08_02
}

// MARK: - Injectable clock / RNG

/// Deterministic virtual clock for replay (seconds).
struct VibeTimelineReplayClock: Sendable, Equatable {
  private(set) var now: TimeInterval

  init(now: TimeInterval = 0) {
    self.now = now
  }

  mutating func advance(by delta: TimeInterval) {
    precondition(delta >= 0)
    now += delta
  }

  mutating func advance(to absolute: TimeInterval) {
    precondition(absolute >= now)
    now = absolute
  }
}

/// Tiny seedable LCG — no system RNG, no global state.
struct VibeTimelineReplayRNG: Sendable {
  private var state: UInt64

  init(seed: UInt64) {
    // Avoid zero state (LCG fixed point).
    self.state = seed == 0 ? 0xC0FFEE : seed
  }

  mutating func nextUInt64() -> UInt64 {
    // Numerical Recipes LCG
    state = state &* 1_664_525 &+ 1_013_904_223
    return state
  }

  mutating func nextUInt32() -> UInt32 {
    UInt32(truncatingIfNeeded: nextUInt64() >> 32)
  }

  mutating func nextBounded(_ upper: Int) -> Int {
    precondition(upper > 0)
    return Int(nextUInt32() % UInt32(upper))
  }

  mutating func nextBool(probabilityPermille: Int = 500) -> Bool {
    nextBounded(1000) < probabilityPermille
  }
}

// MARK: - Compact fixture (lazy 100k)

/// Lazy / compact 100,000-message fixture with 2,000 mixed-media markers.
///
/// Does **not** retain 100k rich payload bodies or instantiate views. Identities and
/// media markers are computed from index + seed on demand.
struct VibeTimelineReplayFixture: Sendable {
  static let defaultMessageCount = 100_000
  static let defaultMediaMarkerCount = 2_000

  let chatId: String
  let messageCount: Int
  let mediaMarkerCount: Int
  let seed: UInt64
  /// Default row height for synthetic items (points).
  let baseRowHeight: CGFloat
  /// Extra height for media-marker rows (reserved frame, not late-loaded growth).
  let mediaReservedExtraHeight: CGFloat

  init(
    chatId: String = "replay-chat",
    messageCount: Int = VibeTimelineReplayFixture.defaultMessageCount,
    mediaMarkerCount: Int = VibeTimelineReplayFixture.defaultMediaMarkerCount,
    seed: UInt64 = VibeTimelineReplaySeeds.board0802,
    baseRowHeight: CGFloat = 48,
    mediaReservedExtraHeight: CGFloat = 180
  ) {
    precondition(messageCount > 0)
    precondition(mediaMarkerCount >= 0 && mediaMarkerCount <= messageCount)
    self.chatId = chatId
    self.messageCount = messageCount
    self.mediaMarkerCount = mediaMarkerCount
    self.seed = seed
    self.baseRowHeight = baseRowHeight
    self.mediaReservedExtraHeight = mediaReservedExtraHeight
  }

  /// Opaque message id for index — O(1), no storage.
  func messageId(at index: Int) -> String {
    precondition(index >= 0 && index < messageCount)
    return "m-\(seed)-\(index)"
  }

  func anchor(at index: Int) -> VibeTimelineAnchor {
    VibeTimelineAnchor(messageId: messageId(at: index), identityGeneration: 1)
  }

  /// Deterministic media markers: evenly strided across the corpus.
  /// For 100_000 / 2_000 → every 50th index.
  func isMediaMarker(at index: Int) -> Bool {
    precondition(index >= 0 && index < messageCount)
    guard mediaMarkerCount > 0 else { return false }
    if mediaMarkerCount == messageCount { return true }
    let stride = max(1, messageCount / mediaMarkerCount)
    // First `mediaMarkerCount` multiples of stride.
    if index % stride != 0 { return false }
    return index / stride < mediaMarkerCount
  }

  func rowHeight(at index: Int) -> CGFloat {
    isMediaMarker(at: index) ? baseRowHeight + mediaReservedExtraHeight : baseRowHeight
  }

  func orderKey(at index: Int) -> VibeOrderKey {
    VibeOrderKey(rank: UInt64(index), tieBreak: seed)
  }

  /// Build a single compact render item (no body text, no buffers).
  func makeItem(at index: Int, contentRevision: UInt64 = 1, geometryRevision: UInt64 = 1, flags: VibeRenderItemFlags = .settled) -> VibeRenderItem {
    let height = rowHeight(at: index)
    let width: CGFloat = 360
    var mediaSlots: [VibeMediaSlot] = []
    if isMediaMarker(at: index) {
      let mediaFrame = CGRect(x: 12, y: 8, width: width - 24, height: mediaReservedExtraHeight)
      mediaSlots = [
        VibeMediaSlot(
          frame: mediaFrame,
          aspectRatio: 1.0,
          placeholderToken: "blur.token.\(index)",
          loadKey: "media-\(seed)-\(index)"
        )
      ]
    }
    return VibeRenderItem(
      identity: anchor(at: index),
      orderKey: orderKey(at: index),
      kind: .message,
      contentRevision: contentRevision,
      geometryRevision: geometryRevision,
      size: CGSize(width: width, height: height),
      layout: VibeBubbleLayoutSpec(
        textFrame: CGRect(x: 12, y: 6, width: width - 24, height: 20),
        mediaBoxFrame: mediaSlots.first?.frame ?? .zero,
        replyFrame: .zero,
        metaFrame: CGRect(x: width - 60, y: height - 16, width: 48, height: 12),
        avatarGutter: .zero
      ),
      paint: VibePaintSpec(backgroundToken: "bubble.replay", textStyleToken: "text.body"),
      mediaSlots: mediaSlots,
      interaction: VibeInteractionSpec(accessibilityLabel: "msg-\(index)"),
      flags: flags
    )
  }

  /// Active window slice without materializing the full corpus.
  func makeWindow(
    startIndex: Int,
    count: Int
  ) -> (window: VibeTimelineWindowV1, items: [VibeRenderItem], contentHeight: CGFloat) {
    // The configured capacity is 150...300, but a legitimate chat/cold page can
    // contain fewer rows. Clamp only the upper bound here; the host owns capacity.
    let clampedCount = min(max(0, count), VibeTimelineWindowPolicy.activeWindowRange.upperBound)
    let start = max(0, min(startIndex, max(0, messageCount - 1)))
    let end = min(messageCount, start + clampedCount)
    let actualCount = max(0, end - start)
    var ids: [String] = []
    var anchors: [VibeTimelineAnchor] = []
    var items: [VibeRenderItem] = []
    ids.reserveCapacity(actualCount)
    anchors.reserveCapacity(actualCount)
    items.reserveCapacity(actualCount)
    var height: CGFloat = 0
    if actualCount > 0 {
      for index in start..<end {
        ids.append(messageId(at: index))
        anchors.append(anchor(at: index))
        let item = makeItem(at: index)
        items.append(item)
        height += item.size.height
      }
    }
    let window = VibeTimelineWindowV1(
      chatId: chatId,
      messageIds: ids,
      anchors: anchors,
      startIndex: start,
      hasOlder: start > 0,
      hasNewer: end < messageCount
    )
    return (window, items, height)
  }

  func makeSnapshot(
    generation: UInt64,
    startIndex: Int,
    count: Int = VibeTimelineWindowPolicy.defaultActiveWindowCount,
    anchor: VibeViewportAnchor = .pinToBottom
  ) -> VibeRenderSnapshot {
    let slice = makeWindow(startIndex: startIndex, count: count)
    return VibeRenderSnapshot(
      chatId: chatId,
      generation: generation,
      window: slice.window,
      items: slice.items,
      anchor: anchor,
      contentHeight: slice.contentHeight
    )
  }
}

// MARK: - Replay events (compact)

/// Deterministic scenario events — indices and revisions only, never plaintext bodies.
enum VibeTimelineReplayEvent: Sendable, Equatable {
  case pushOpen(windowStart: Int, windowCount: Int)
  case insert(atEndIndex: Int)
  case edit(index: Int, contentRevision: UInt64)
  case delete(index: Int)
  case receipt(index: Int, contentRevision: UInt64)
  case streamingGeometry(index: Int, deltaHeight: CGFloat, geometryRevision: UInt64)
  case windowShift(newStart: Int, count: Int)
  case lateMediaContentOnly(index: Int, contentRevision: UInt64)
}

enum VibeTimelineReplayScenario: String, Sendable, CaseIterable {
  case pushOpen
  case insertEditDeleteReceipt
  case streamingClassifiedGeometry
  case windowShift
  case lateMediaContentOnly
  case eventStorm20
  case eventStorm50
}

// MARK: - Harness configuration

struct VibeTimelineReplayConfiguration: Sendable {
  var fixture: VibeTimelineReplayFixture
  var activeWindowCount: Int
  var eventsPerSecond: Double
  var stormDurationSeconds: TimeInterval
  var clock: VibeTimelineReplayClock
  var seed: UInt64

  init(
    fixture: VibeTimelineReplayFixture = VibeTimelineReplayFixture(),
    activeWindowCount: Int = VibeTimelineWindowPolicy.defaultActiveWindowCount,
    eventsPerSecond: Double = 20,
    stormDurationSeconds: TimeInterval = 5,
    clock: VibeTimelineReplayClock = VibeTimelineReplayClock(),
    seed: UInt64 = VibeTimelineReplaySeeds.board0802
  ) {
    self.fixture = fixture
    self.activeWindowCount = VibeTimelineWindowPolicy.clampActiveWindow(activeWindowCount)
    self.eventsPerSecond = eventsPerSecond
    self.stormDurationSeconds = stormDurationSeconds
    self.clock = clock
    self.seed = seed
  }
}

// MARK: - Step result

/// One harness step: optional snapshot mount and/or transaction. No views created.
struct VibeTimelineReplayStep: Sendable, Equatable {
  let time: TimeInterval
  let scenario: VibeTimelineReplayScenario
  let event: VibeTimelineReplayEvent
  let snapshot: VibeRenderSnapshot?
  let transaction: VibeListTransaction?
  /// Generation after applying this step.
  let generation: UInt64
}

// MARK: - Harness

/// Deterministic replay driver for qualification scenarios.
///
/// - Generates a lazy 100k fixture with 2k media markers.
/// - Emits push/open, insert/edit/delete/receipt, streaming geometry, window shift,
///   late-media content-only, and event storms at 20 / 50 events/s.
/// - Never instantiates 100k views or retains 100k rich payloads.
/// - Clock and RNG seed are injectable.
///
/// Intended for DEBUG / harness targets; safe to compile in all configs because it
/// allocates only active-window slices.
final class VibeTimelineReplayHarness: @unchecked Sendable {
  private(set) var configuration: VibeTimelineReplayConfiguration
  private var rng: VibeTimelineReplayRNG
  private(set) var generation: UInt64 = 0
  /// Start index of the active window into the fixture corpus.
  private(set) var windowStart: Int = 0
  /// Compact model: only the active window's indices (not full 100k bodies).
  private var windowIndices: [Int] = []
  private var contentRevisions: [Int: UInt64] = [:]
  private var geometryRevisions: [Int: UInt64] = [:]
  private var streamingHeights: [Int: CGFloat] = [:]

  init(configuration: VibeTimelineReplayConfiguration = VibeTimelineReplayConfiguration()) {
    self.configuration = configuration
    self.rng = VibeTimelineReplayRNG(seed: configuration.seed)
  }

  var clock: VibeTimelineReplayClock {
    get { configuration.clock }
    set { configuration.clock = newValue }
  }

  var fixture: VibeTimelineReplayFixture { configuration.fixture }

  // MARK: Scenarios

  /// Produce the full step sequence for a named scenario (lazy generation).
  func steps(for scenario: VibeTimelineReplayScenario) -> [VibeTimelineReplayStep] {
    switch scenario {
    case .pushOpen:
      return [makePushOpenStep()]
    case .insertEditDeleteReceipt:
      return makeInsertEditDeleteReceiptSteps()
    case .streamingClassifiedGeometry:
      return makeStreamingSteps()
    case .windowShift:
      return makeWindowShiftSteps()
    case .lateMediaContentOnly:
      return makeLateMediaSteps()
    case .eventStorm20:
      return makeEventStorm(eventsPerSecond: 20)
    case .eventStorm50:
      return makeEventStorm(eventsPerSecond: 50)
    }
  }

  /// All board-relevant scenarios in a stable order.
  func allScenarioSteps() -> [(VibeTimelineReplayScenario, [VibeTimelineReplayStep])] {
    VibeTimelineReplayScenario.allCases.map { ($0, steps(for: $0)) }
  }

  /// Preload budget helper: visible rows + at most two screens (by row count estimate).
  static func maxInstantiatedItems(visibleRows: Int, rowsPerScreen: Int) -> Int {
    let screens = VibeTimelineWindowPolicy.maxPreloadScreens
    return visibleRows + max(0, rowsPerScreen) * screens
  }

  // MARK: Push / open

  private func makePushOpenStep() -> VibeTimelineReplayStep {
    resetModel()
    let count = configuration.activeWindowCount
    // Pin to bottom of corpus for chat open.
    windowStart = max(0, fixture.messageCount - count)
    windowIndices = Array(windowStart..<(windowStart + min(count, fixture.messageCount - windowStart)))
    generation = 1
    let event = VibeTimelineReplayEvent.pushOpen(windowStart: windowStart, windowCount: windowIndices.count)
    let snapshot = fixture.makeSnapshot(
      generation: generation,
      startIndex: windowStart,
      count: windowIndices.count,
      anchor: .pinToBottom
    )
    return VibeTimelineReplayStep(
      time: configuration.clock.now,
      scenario: .pushOpen,
      event: event,
      snapshot: snapshot,
      transaction: nil,
      generation: generation
    )
  }

  // MARK: Insert / edit / delete / receipt

  private func makeInsertEditDeleteReceiptSteps() -> [VibeTimelineReplayStep] {
    var steps: [VibeTimelineReplayStep] = [makePushOpenStep()]
    // Insert at end
    steps.append(appendInsertStep(scenario: .insertEditDeleteReceipt))
    // Edit a settled row (content only)
    if let index = windowIndices.dropLast().last {
      steps.append(appendEditStep(index: index, scenario: .insertEditDeleteReceipt))
    }
    // Receipt content-only
    if let index = windowIndices.dropLast().last {
      steps.append(appendReceiptStep(index: index, scenario: .insertEditDeleteReceipt))
    }
    // Delete one non-edge row if possible
    if windowIndices.count > 2 {
      let index = windowIndices[windowIndices.count / 2]
      steps.append(appendDeleteStep(index: index, scenario: .insertEditDeleteReceipt))
    }
    return steps
  }

  // MARK: Streaming geometry

  private func makeStreamingSteps() -> [VibeTimelineReplayStep] {
    var steps: [VibeTimelineReplayStep] = [makePushOpenStep()]
    guard let index = windowIndices.last else { return steps }
    // Classify as streaming: bump geometry twice, then settle via content-only.
    for bump in 1...2 {
      steps.append(
        appendStreamingGeometryStep(
          index: index,
          deltaHeight: 24,
          geometryRevision: UInt64(bump + 1),
          scenario: .streamingClassifiedGeometry
        )
      )
    }
    steps.append(appendEditStep(index: index, scenario: .streamingClassifiedGeometry))
    return steps
  }

  // MARK: Window shift

  private func makeWindowShiftSteps() -> [VibeTimelineReplayStep] {
    var steps: [VibeTimelineReplayStep] = [makePushOpenStep()]
    let newStart = max(0, windowStart - configuration.activeWindowCount / 2)
    steps.append(appendWindowShiftStep(newStart: newStart, scenario: .windowShift))
    return steps
  }

  // MARK: Late media content-only

  private func makeLateMediaSteps() -> [VibeTimelineReplayStep] {
    var steps: [VibeTimelineReplayStep] = [makePushOpenStep()]
    // Find a media marker inside the window.
    let mediaIndex = windowIndices.first(where: { fixture.isMediaMarker(at: $0) })
    if let mediaIndex {
      steps.append(
        appendLateMediaContentOnlyStep(index: mediaIndex, scenario: .lateMediaContentOnly)
      )
    }
    return steps
  }

  // MARK: Event storms

  private func makeEventStorm(eventsPerSecond: Double) -> [VibeTimelineReplayStep] {
    var local = configuration
    local.eventsPerSecond = eventsPerSecond
    configuration.eventsPerSecond = eventsPerSecond

    var steps: [VibeTimelineReplayStep] = [makePushOpenStep()]
    let scenario: VibeTimelineReplayScenario = eventsPerSecond >= 50 ? .eventStorm50 : .eventStorm20
    let duration = configuration.stormDurationSeconds
    let totalEvents = max(1, Int((eventsPerSecond * duration).rounded()))
    let dt = duration / TimeInterval(totalEvents)

    for _ in 0..<totalEvents {
      configuration.clock.advance(by: dt)
      let roll = rng.nextBounded(100)
      let step: VibeTimelineReplayStep
      switch roll {
      case 0..<40:
        step = appendInsertStep(scenario: scenario)
      case 40..<55:
        if let index = pickWindowIndex() {
          step = appendEditStep(index: index, scenario: scenario)
        } else {
          step = appendInsertStep(scenario: scenario)
        }
      case 55..<70:
        if let index = pickWindowIndex() {
          step = appendReceiptStep(index: index, scenario: scenario)
        } else {
          step = appendInsertStep(scenario: scenario)
        }
      case 70..<80:
        if let index = pickWindowIndex(), windowIndices.count > 3 {
          step = appendDeleteStep(index: index, scenario: scenario)
        } else {
          step = appendInsertStep(scenario: scenario)
        }
      case 80..<90:
        if let index = pickWindowIndex() {
          let nextGeo = (geometryRevisions[index] ?? 1) + 1
          step = appendStreamingGeometryStep(
            index: index,
            deltaHeight: 12,
            geometryRevision: nextGeo,
            scenario: scenario
          )
        } else {
          step = appendInsertStep(scenario: scenario)
        }
      default:
        let shift = max(0, windowStart - rng.nextBounded(20))
        step = appendWindowShiftStep(newStart: shift, scenario: scenario)
      }
      steps.append(step)
    }
    return steps
  }

  // MARK: Step builders

  private func appendInsertStep(scenario: VibeTimelineReplayScenario) -> VibeTimelineReplayStep {
    // The transaction targets the currently mounted model. Capture its count before
    // updating/trimming the harness mirror; after a full-window append the mirror is
    // already back at 200, but the host still needs an insertion at its old end (200),
    // not before the old last row (199).
    let mountedInsertIndex = windowIndices.count
    let newIndex: Int
    if let last = windowIndices.last {
      newIndex = last + 1
    } else {
      newIndex = 0
    }
    // Stay within fixture bounds when possible; wrap synthetic tail above corpus.
    let itemIndex = min(newIndex, fixture.messageCount - 1)
    let item: VibeRenderItem
    if newIndex < fixture.messageCount {
      item = fixture.makeItem(at: newIndex)
    } else {
      // Synthetic tail beyond corpus for storm inserts — compact id only.
      item = VibeRenderItem(
        identity: VibeTimelineAnchor(messageId: "m-\(fixture.seed)-tail-\(newIndex)"),
        orderKey: VibeOrderKey(rank: UInt64(newIndex), tieBreak: fixture.seed),
        size: CGSize(width: 360, height: fixture.baseRowHeight),
        flags: .settled
      )
    }
    _ = itemIndex
    windowIndices.append(newIndex)
    trimWindowIfNeeded(pinToBottom: true)
    let base = generation
    generation += 1
    let tx = VibeListTransaction(
      baseGeneration: base,
      nextGeneration: generation,
      ops: [.insert(items: [item], at: mountedInsertIndex)],
      preserve: .pinToBottom,
      animation: .insertSpring,
      commitDeadline: .displayLink
    )
    return VibeTimelineReplayStep(
      time: configuration.clock.now,
      scenario: scenario,
      event: .insert(atEndIndex: newIndex),
      snapshot: nil,
      transaction: tx,
      generation: generation
    )
  }

  private func appendEditStep(index: Int, scenario: VibeTimelineReplayScenario) -> VibeTimelineReplayStep {
    let nextRev = (contentRevisions[index] ?? 1) + 1
    contentRevisions[index] = nextRev
    let geo = geometryRevisions[index] ?? 1
    let baseItem = makeCurrentItem(index: index, contentRevision: nextRev, geometryRevision: geo)
    let base = generation
    generation += 1
    let tx = VibeListTransaction(
      baseGeneration: base,
      nextGeneration: generation,
      ops: [.updateContent(id: baseItem.identity.messageId, item: baseItem)],
      preserve: .pinToBottom,
      animation: .none,
      commitDeadline: .displayLink
    )
    return VibeTimelineReplayStep(
      time: configuration.clock.now,
      scenario: scenario,
      event: .edit(index: index, contentRevision: nextRev),
      snapshot: nil,
      transaction: tx,
      generation: generation
    )
  }

  private func appendReceiptStep(index: Int, scenario: VibeTimelineReplayScenario) -> VibeTimelineReplayStep {
    let nextRev = (contentRevisions[index] ?? 1) + 1
    contentRevisions[index] = nextRev
    let geo = geometryRevisions[index] ?? 1
    let item = makeCurrentItem(index: index, contentRevision: nextRev, geometryRevision: geo)
    let base = generation
    generation += 1
    let tx = VibeListTransaction(
      baseGeneration: base,
      nextGeneration: generation,
      ops: [.updateContent(id: item.identity.messageId, item: item)],
      preserve: .pinToBottom,
      animation: .none,
      commitDeadline: .displayLink
    )
    return VibeTimelineReplayStep(
      time: configuration.clock.now,
      scenario: scenario,
      event: .receipt(index: index, contentRevision: nextRev),
      snapshot: nil,
      transaction: tx,
      generation: generation
    )
  }

  private func appendDeleteStep(index: Int, scenario: VibeTimelineReplayScenario) -> VibeTimelineReplayStep {
    let id: String
    if index < fixture.messageCount {
      id = fixture.messageId(at: index)
    } else {
      id = "m-\(fixture.seed)-tail-\(index)"
    }
    windowIndices.removeAll { $0 == index }
    contentRevisions[index] = nil
    geometryRevisions[index] = nil
    streamingHeights[index] = nil
    let base = generation
    generation += 1
    let tx = VibeListTransaction(
      baseGeneration: base,
      nextGeneration: generation,
      ops: [.remove(ids: [id])],
      preserve: .pinToBottom,
      animation: .deleteCollapse,
      commitDeadline: .displayLink
    )
    return VibeTimelineReplayStep(
      time: configuration.clock.now,
      scenario: scenario,
      event: .delete(index: index),
      snapshot: nil,
      transaction: tx,
      generation: generation
    )
  }

  private func appendStreamingGeometryStep(
    index: Int,
    deltaHeight: CGFloat,
    geometryRevision: UInt64,
    scenario: VibeTimelineReplayScenario
  ) -> VibeTimelineReplayStep {
    geometryRevisions[index] = geometryRevision
    let currentHeight = streamingHeights[index] ?? fixture.rowHeight(at: min(index, fixture.messageCount - 1))
    let newHeight = currentHeight + deltaHeight
    streamingHeights[index] = newHeight
    let contentRev = contentRevisions[index] ?? 1
    var item = makeCurrentItem(
      index: index,
      contentRevision: contentRev,
      geometryRevision: geometryRevision,
      flags: [.settled, .streaming]
    )
    // Rebuild with explicit height for streaming growth.
    item = VibeRenderItem(
      identity: item.identity,
      orderKey: item.orderKey,
      kind: item.kind,
      contentRevision: item.contentRevision,
      geometryRevision: geometryRevision,
      size: CGSize(width: item.size.width, height: newHeight),
      layout: item.layout,
      paint: item.paint,
      mediaSlots: item.mediaSlots,
      interaction: item.interaction,
      flags: [.settled, .streaming]
    )
    let base = generation
    generation += 1
    let tx = VibeListTransaction(
      baseGeneration: base,
      nextGeneration: generation,
      ops: [.updateGeometry(id: item.identity.messageId, item: item, deltaHeight: deltaHeight)],
      preserve: .pinToBottom,
      animation: .heightMorph,
      commitDeadline: .displayLink
    )
    return VibeTimelineReplayStep(
      time: configuration.clock.now,
      scenario: scenario,
      event: .streamingGeometry(
        index: index,
        deltaHeight: deltaHeight,
        geometryRevision: geometryRevision
      ),
      snapshot: nil,
      transaction: tx,
      generation: generation
    )
  }

  private func appendWindowShiftStep(
    newStart: Int,
    scenario: VibeTimelineReplayScenario
  ) -> VibeTimelineReplayStep {
    let count = configuration.activeWindowCount
    let start = max(0, min(newStart, max(0, fixture.messageCount - count)))
    windowStart = start
    windowIndices = Array(start..<(start + min(count, fixture.messageCount - start)))
    generation += 1
    // Re-querying a window must not forget revisions/geometry already accepted by
    // the model. Rebuild overlapping rows from current state instead of using the
    // fixture's revision-1/base-height defaults (which would create a fake shift).
    let items = windowIndices.map { index in
      makeCurrentItem(
        index: index,
        contentRevision: contentRevisions[index] ?? 1,
        geometryRevision: geometryRevisions[index] ?? 1
      )
    }
    let snapshot = VibeRenderSnapshot(
      chatId: fixture.chatId,
      generation: generation,
      window: VibeTimelineWindowV1(
        chatId: fixture.chatId,
        messageIds: items.map(\.identity.messageId),
        anchors: items.map(\.identity),
        startIndex: windowStart,
        hasOlder: windowStart > 0,
        hasNewer: (windowStart + items.count) < fixture.messageCount
      ),
      items: items,
      anchor: VibeViewportAnchor(
        itemId: items.first?.identity.messageId ?? "",
        offsetFromTop: 0,
        pin: .item
      ),
      contentHeight: items.reduce(0) { $0 + $1.size.height }
    )
    // Window shift as a full snapshot apply (transaction ops optional for later).
    return VibeTimelineReplayStep(
      time: configuration.clock.now,
      scenario: scenario,
      event: .windowShift(newStart: windowStart, count: windowIndices.count),
      snapshot: snapshot,
      transaction: nil,
      generation: generation
    )
  }

  private func appendLateMediaContentOnlyStep(
    index: Int,
    scenario: VibeTimelineReplayScenario
  ) -> VibeTimelineReplayStep {
    // Late media: same size + geometryRevision, contentRevision bumps, media slot
    // placeholder may upgrade token — pixels only, no height change.
    let nextRev = (contentRevisions[index] ?? 1) + 1
    contentRevisions[index] = nextRev
    let geo = geometryRevisions[index] ?? 1
    var item = makeCurrentItem(index: index, contentRevision: nextRev, geometryRevision: geo)
    if var slot = item.mediaSlots.first {
      slot = VibeMediaSlot(
        frame: slot.frame,
        aspectRatio: slot.aspectRatio,
        placeholderToken: "decoded.token.\(index)",
        loadKey: slot.loadKey
      )
      item = VibeRenderItem(
        identity: item.identity,
        orderKey: item.orderKey,
        kind: item.kind,
        contentRevision: nextRev,
        geometryRevision: geo,
        size: item.size,
        layout: item.layout,
        paint: item.paint,
        mediaSlots: [slot],
        interaction: item.interaction,
        flags: .settled
      )
    }
    // Validate settled content-only invariant against previous revision.
    let previous = makeCurrentItem(
      index: index,
      contentRevision: max(1, nextRev - 1),
      geometryRevision: geo
    )
    _ = VibeRenderItemValidator.validateContentOnlyReplacement(
      current: previous,
      replacement: item
    )
    let base = generation
    generation += 1
    let tx = VibeListTransaction(
      baseGeneration: base,
      nextGeneration: generation,
      ops: [.updateContent(id: item.identity.messageId, item: item)],
      preserve: .pinToBottom,
      animation: .none,
      commitDeadline: .displayLink
    )
    return VibeTimelineReplayStep(
      time: configuration.clock.now,
      scenario: scenario,
      event: .lateMediaContentOnly(index: index, contentRevision: nextRev),
      snapshot: nil,
      transaction: tx,
      generation: generation
    )
  }

  // MARK: Helpers

  private func resetModel() {
    generation = 0
    windowStart = 0
    windowIndices = []
    contentRevisions.removeAll(keepingCapacity: true)
    geometryRevisions.removeAll(keepingCapacity: true)
    streamingHeights.removeAll(keepingCapacity: true)
    rng = VibeTimelineReplayRNG(seed: configuration.seed)
  }

  private func trimWindowIfNeeded(pinToBottom: Bool) {
    let maxCount = configuration.activeWindowCount
    guard windowIndices.count > maxCount else { return }
    let overflow = windowIndices.count - maxCount
    if pinToBottom {
      windowIndices.removeFirst(overflow)
      windowStart = windowIndices.first ?? windowStart
    } else {
      windowIndices.removeLast(overflow)
    }
  }

  private func pickWindowIndex() -> Int? {
    guard !windowIndices.isEmpty else { return nil }
    let offset = rng.nextBounded(windowIndices.count)
    return windowIndices[offset]
  }

  private func makeCurrentItem(
    index: Int,
    contentRevision: UInt64,
    geometryRevision: UInt64,
    flags: VibeRenderItemFlags = .settled
  ) -> VibeRenderItem {
    if index < fixture.messageCount {
      var item = fixture.makeItem(
        at: index,
        contentRevision: contentRevision,
        geometryRevision: geometryRevision,
        flags: flags
      )
      if let h = streamingHeights[index] {
        item = VibeRenderItem(
          identity: item.identity,
          orderKey: item.orderKey,
          kind: item.kind,
          contentRevision: contentRevision,
          geometryRevision: geometryRevision,
          size: CGSize(width: item.size.width, height: h),
          layout: item.layout,
          paint: item.paint,
          mediaSlots: item.mediaSlots,
          interaction: item.interaction,
          flags: flags
        )
      }
      return item
    }
    return VibeRenderItem(
      identity: VibeTimelineAnchor(messageId: "m-\(fixture.seed)-tail-\(index)"),
      orderKey: VibeOrderKey(rank: UInt64(index), tieBreak: fixture.seed),
      contentRevision: contentRevision,
      geometryRevision: geometryRevision,
      size: CGSize(
        width: 360,
        height: streamingHeights[index] ?? fixture.baseRowHeight
      ),
      flags: flags
    )
  }
}
