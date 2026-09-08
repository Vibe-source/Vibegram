import CoreGraphics
import XCTest
@testable import Vibe

// MARK: - Helpers

private enum TimelineTestIDs {
  static let chat = "test-chat"
}

private func makeSettledItem(
  id: String,
  rank: UInt64,
  size: CGSize = CGSize(width: 360, height: 48),
  contentRevision: UInt64 = 1,
  geometryRevision: UInt64 = 1,
  paint: VibePaintSpec = VibePaintSpec(),
  flags: VibeRenderItemFlags = .settled
) -> VibeRenderItem {
  VibeRenderItem(
    identity: VibeTimelineAnchor(messageId: id),
    orderKey: VibeOrderKey(rank: rank),
    contentRevision: contentRevision,
    geometryRevision: geometryRevision,
    size: size,
    paint: paint,
    flags: flags
  )
}

// MARK: - Feature flags

final class VibeTimelineFeatureFlagTests: XCTestCase {
  func testAsyncTimelineDefaultsFalseOnFixedFlags() {
    let fixed = VibeTimelineFixedFeatureFlags(.default)
    XCTAssertFalse(fixed.flags.vibeAsyncTimelineV1Enabled)
    XCTAssertFalse(VibeTimelineFeatureFlags.default.vibeAsyncTimelineV1Enabled)
    for chatClass in VibeTimelineChatClass.allCases {
      XCTAssertFalse(VibeTimelineFeatureFlags.default.isAsyncTimelineEnabled(for: chatClass))
    }
  }

  func testAsyncTimelineDefaultsFalseWhenUserDefaultsKeyMissing() {
    let suiteName = "vibe.timeline.tests.flags.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("UserDefaults suite unavailable")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let provider = VibeTimelineUserDefaultsFeatureFlags(defaults: defaults)
    XCTAssertNil(defaults.object(forKey: VibeTimelineUserDefaultsFeatureFlags.asyncTimelineKey))
    XCTAssertFalse(provider.flags.vibeAsyncTimelineV1Enabled)
    XCTAssertNil(provider.flags.activeWindowOverride)
    // The render allowlist is empty in every configuration — the debug default
    // arms shadow comparison only, through its own separate list.
    XCTAssertEqual(provider.flags.eligibleChatClasses, [])
    #if DEBUG
      XCTAssertTrue(provider.flags.vibeTimelineShadowCompareEnabled)
    #else
      XCTAssertFalse(provider.flags.vibeTimelineShadowCompareEnabled)
      XCTAssertEqual(provider.flags.shadowEligibleChatClasses, [])
    #endif
  }

  func testAsyncTimelineReadsExplicitFalseAndTrue() {
    let suiteName = "vibe.timeline.tests.flags.explicit.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("UserDefaults suite unavailable")
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let provider = VibeTimelineUserDefaultsFeatureFlags(defaults: defaults)
    defaults.set(false, forKey: VibeTimelineUserDefaultsFeatureFlags.asyncTimelineKey)
    XCTAssertFalse(provider.flags.vibeAsyncTimelineV1Enabled)

    defaults.set(true, forKey: VibeTimelineUserDefaultsFeatureFlags.asyncTimelineKey)
    XCTAssertTrue(provider.flags.vibeAsyncTimelineV1Enabled)
    XCTAssertFalse(provider.flags.isAsyncTimelineEnabled(for: .directMessage))

    defaults.set(
      NSNumber(value: VibeTimelineChatClassEligibility.directMessage.rawValue),
      forKey: VibeTimelineUserDefaultsFeatureFlags.eligibleChatClassesKey
    )
    XCTAssertTrue(provider.flags.isAsyncTimelineEnabled(for: .directMessage))
    XCTAssertFalse(provider.flags.isAsyncTimelineEnabled(for: .group))
  }

  func testPerClassEligibilityRequiresUmbrellaAndExactClass() {
    var flags = VibeTimelineFeatureFlags(
      vibeAsyncTimelineV1Enabled: false,
      eligibleChatClasses: [.directMessage, .group]
    )
    XCTAssertFalse(flags.isAsyncTimelineEnabled(for: .directMessage))

    flags.vibeAsyncTimelineV1Enabled = true
    XCTAssertTrue(flags.isAsyncTimelineEnabled(for: .directMessage))
    XCTAssertTrue(flags.isAsyncTimelineEnabled(for: .group))
    XCTAssertFalse(flags.isAsyncTimelineEnabled(for: .channel))
    XCTAssertFalse(flags.isAsyncTimelineEnabled(for: .savedMessages))
    XCTAssertFalse(flags.isAsyncTimelineEnabled(for: .agentDirect))
  }
}

// MARK: - Window policy

final class VibeTimelineWindowPolicyTests: XCTestCase {
  func testDefaultActiveWindowIs200() {
    XCTAssertEqual(VibeTimelineWindowPolicy.defaultActiveWindowCount, 200)
    XCTAssertEqual(VibeTimelineFeatureFlags.default.resolvedActiveWindowCount, 200)
  }

  func testActiveWindowClampsTo150Through300() {
    XCTAssertEqual(VibeTimelineWindowPolicy.clampActiveWindow(0), 150)
    XCTAssertEqual(VibeTimelineWindowPolicy.clampActiveWindow(149), 150)
    XCTAssertEqual(VibeTimelineWindowPolicy.clampActiveWindow(150), 150)
    XCTAssertEqual(VibeTimelineWindowPolicy.clampActiveWindow(200), 200)
    XCTAssertEqual(VibeTimelineWindowPolicy.clampActiveWindow(300), 300)
    XCTAssertEqual(VibeTimelineWindowPolicy.clampActiveWindow(301), 300)
    XCTAssertEqual(VibeTimelineWindowPolicy.clampActiveWindow(10_000), 300)

    XCTAssertTrue(VibeTimelineWindowPolicy.isValidActiveWindow(150))
    XCTAssertTrue(VibeTimelineWindowPolicy.isValidActiveWindow(300))
    XCTAssertFalse(VibeTimelineWindowPolicy.isValidActiveWindow(149))
    XCTAssertFalse(VibeTimelineWindowPolicy.isValidActiveWindow(301))
  }

  func testPreloadBudgetAtMostTwoScreens() {
    XCTAssertEqual(VibeTimelineWindowPolicy.maxPreloadScreens, 2)
    let visible = 12
    let rowsPerScreen = 10
    let maxItems = VibeTimelineReplayHarness.maxInstantiatedItems(
      visibleRows: visible,
      rowsPerScreen: rowsPerScreen
    )
    XCTAssertEqual(maxItems, visible + rowsPerScreen * 2)
    XCTAssertLessThanOrEqual(
      VibeTimelineWindowPolicy.maxPreloadScreens,
      2,
      "preload budget must stay at most two screens"
    )
  }

  func testResolvedActiveWindowUsesOverrideThenClamp() {
    var flags = VibeTimelineFeatureFlags(activeWindowOverride: 999)
    XCTAssertEqual(flags.resolvedActiveWindowCount, 300)
    flags.activeWindowOverride = 100
    XCTAssertEqual(flags.resolvedActiveWindowCount, 150)
  }
}

// MARK: - Settled content-only replacement

final class VibeRenderItemContentOnlyTests: XCTestCase {
  func testSettledContentOnlyAcceptsPaintAndRevisionWithIdenticalGeometry() {
    let current = makeSettledItem(
      id: "a",
      rank: 1,
      size: CGSize(width: 360, height: 52),
      contentRevision: 1,
      geometryRevision: 3,
      paint: VibePaintSpec(backgroundToken: "bubble.a")
    )
    let replacement = makeSettledItem(
      id: "a",
      rank: 1,
      size: CGSize(width: 360, height: 52),
      contentRevision: 2,
      geometryRevision: 3,
      paint: VibePaintSpec(backgroundToken: "bubble.receipt")
    )

    switch VibeRenderItemValidator.validateContentOnlyReplacement(
      current: current,
      replacement: replacement
    ) {
    case .success:
      break
    case .failure(let error):
      XCTFail("expected content-only success, got \(error)")
    }
  }

  func testSettledContentOnlyRejectsSizeChange() {
    let current = makeSettledItem(id: "a", rank: 1, size: CGSize(width: 360, height: 48))
    let replacement = makeSettledItem(
      id: "a",
      rank: 1,
      size: CGSize(width: 360, height: 96),
      contentRevision: 2
    )

    switch VibeRenderItemValidator.validateContentOnlyReplacement(
      current: current,
      replacement: replacement
    ) {
    case .success:
      XCTFail("expected size rejection")
    case .failure(.contentOnlyChangedSize(let messageId, let previous, let next)):
      XCTAssertEqual(messageId, "a")
      XCTAssertEqual(previous.height, 48)
      XCTAssertEqual(next.height, 96)
    case .failure(let other):
      XCTFail("unexpected failure \(other)")
    }
  }

  func testSettledContentOnlyRejectsGeometryRevisionChange() {
    let current = makeSettledItem(id: "a", rank: 1, geometryRevision: 2)
    let replacement = makeSettledItem(id: "a", rank: 1, contentRevision: 2, geometryRevision: 3)

    switch VibeRenderItemValidator.validateContentOnlyReplacement(
      current: current,
      replacement: replacement
    ) {
    case .success:
      XCTFail("expected geometry-revision rejection")
    case .failure(.contentOnlyChangedGeometryRevision(let messageId, let previous, let next)):
      XCTAssertEqual(messageId, "a")
      XCTAssertEqual(previous, 2)
      XCTAssertEqual(next, 3)
    case .failure(let other):
      XCTFail("unexpected failure \(other)")
    }
  }

  func testContentOnlyRejectsRevisionReplayAndOrderMutation() {
    let current = makeSettledItem(id: "a", rank: 10, contentRevision: 4)
    let replay = makeSettledItem(id: "a", rank: 10, contentRevision: 4)
    if case .failure(.contentRevisionNotAdvanced) =
      VibeRenderItemValidator.validateContentOnlyReplacement(
        current: current,
        replacement: replay
      )
    {
      // expected
    } else {
      XCTFail("expected content revision replay rejection")
    }

    let reordered = makeSettledItem(id: "a", rank: 11, contentRevision: 5)
    if case .failure(.contentOnlyChangedOrderKey) =
      VibeRenderItemValidator.validateContentOnlyReplacement(
        current: current,
        replacement: reordered
      )
    {
      // expected
    } else {
      XCTFail("expected content-only order mutation rejection")
    }
  }

  func testStructureAndGeometryRejectNonFiniteOrFalseDelta() {
    let nonFinite = makeSettledItem(
      id: "nan",
      rank: 1,
      size: CGSize(width: 360, height: CGFloat.nan)
    )
    if case .failure(.nonFiniteGeometry) = VibeRenderItemValidator.validateStructure(nonFinite) {
      // expected
    } else {
      XCTFail("expected non-finite geometry rejection")
    }

    let current = makeSettledItem(id: "g", rank: 1, size: CGSize(width: 360, height: 48))
    let replacement = makeSettledItem(
      id: "g",
      rank: 1,
      size: CGSize(width: 360, height: 60),
      contentRevision: 2,
      geometryRevision: 2,
      flags: [.settled, .streaming]
    )
    if case .failure(.geometryDeltaMismatch) = VibeRenderItemValidator.validateGeometryUpdate(
      current: current,
      replacement: replacement,
      deltaHeight: 4
    ) {
      // expected
    } else {
      XCTFail("expected declared/actual height-delta rejection")
    }
  }
}

// MARK: - Transaction validator

final class VibeListTransactionValidatorTests: XCTestCase {
  func testRejectsGenerationRegression() {
    let item = makeSettledItem(id: "a", rank: 1)
    let tx = VibeListTransaction(
      baseGeneration: 5,
      nextGeneration: 5,
      ops: [.insert(items: [item], at: 0)]
    )
    switch VibeListTransactionValidator.validate(tx) {
    case .success:
      XCTFail("expected generation rejection")
    case .failure(.generationNotAdvanced(let base, let next)):
      XCTAssertEqual(base, 5)
      XCTAssertEqual(next, 5)
    case .failure(let other):
      XCTFail("unexpected \(other)")
    }

    let regress = VibeListTransaction(
      baseGeneration: 5,
      nextGeneration: 4,
      ops: [.insert(items: [item], at: 0)]
    )
    if case .failure(.generationNotAdvanced) = VibeListTransactionValidator.validate(regress) {
      // ok
    } else {
      XCTFail("expected generation regression rejection")
    }
  }

  func testRejectsEmptyOpsAndDuplicateIdentities() {
    let empty = VibeListTransaction(baseGeneration: 0, nextGeneration: 1, ops: [])
    if case .failure(.emptyOps) = VibeListTransactionValidator.validate(empty) {
      // ok
    } else {
      XCTFail("expected emptyOps")
    }

    let a = makeSettledItem(id: "dup", rank: 1)
    let b = makeSettledItem(id: "dup", rank: 2)
    let dupInsert = VibeListTransaction(
      baseGeneration: 0,
      nextGeneration: 1,
      ops: [.insert(items: [a, b], at: 0)]
    )
    switch VibeListTransactionValidator.validate(dupInsert) {
    case .failure(.duplicateIdentityInTransaction(let id)):
      XCTAssertEqual(id, "dup")
    default:
      XCTFail("expected duplicate identity")
    }

    let crossOp = VibeListTransaction(
      baseGeneration: 0,
      nextGeneration: 1,
      ops: [
        .updateContent(id: "x", item: makeSettledItem(id: "x", rank: 1)),
        .remove(ids: ["x"]),
      ]
    )
    if case .failure(let error) = VibeListTransactionValidator.validate(crossOp) {
      XCTFail("ordered cross-op identity reuse must be legal, got \(error)")
    }
  }

  func testRejectsIllegalContentAndGeometryOpsAgainstMountedItem() {
    let current = makeSettledItem(
      id: "m1",
      rank: 1,
      size: CGSize(width: 360, height: 40),
      geometryRevision: 1
    )
    let sizeChanged = makeSettledItem(
      id: "m1",
      rank: 1,
      size: CGSize(width: 360, height: 80),
      contentRevision: 2,
      geometryRevision: 1
    )
    if case .failure(.contentOnlySizeChanged) = VibeListTransactionValidator.validateContentOp(
      current: current,
      replacement: sizeChanged
    ) {
      // ok
    } else {
      XCTFail("expected content-only size rejection")
    }

    let geoRevChanged = makeSettledItem(
      id: "m1",
      rank: 1,
      size: current.size,
      contentRevision: 2,
      geometryRevision: 2
    )
    if case .failure(.contentOnlyGeometryChanged) = VibeListTransactionValidator.validateContentOp(
      current: current,
      replacement: geoRevChanged
    ) {
      // ok
    } else {
      XCTFail("expected content-only geometry revision rejection")
    }

    let noBump = makeSettledItem(
      id: "m1",
      rank: 1,
      size: CGSize(width: 360, height: 60),
      geometryRevision: 1
    )
    if case .failure(.geometryRevisionNotBumped) = VibeListTransactionValidator.validateGeometryOp(
      current: current,
      replacement: noBump,
      deltaHeight: 20
    ) {
      // ok
    } else {
      XCTFail("expected geometry revision bump requirement")
    }
  }

  func testRejectsUpdateIdentityMismatches() {
    let item = makeSettledItem(id: "real", rank: 1)
    let contentMismatch = VibeListTransaction(
      baseGeneration: 0,
      nextGeneration: 1,
      ops: [.updateContent(id: "other", item: item)]
    )
    if case .failure(.updateContentIdentityMismatch) = VibeListTransactionValidator.validate(contentMismatch) {
      // ok
    } else {
      XCTFail("expected content identity mismatch")
    }

    let geoMismatch = VibeListTransaction(
      baseGeneration: 0,
      nextGeneration: 1,
      ops: [.updateGeometry(id: "other", item: item, deltaHeight: 1)]
    )
    if case .failure(.updateGeometryIdentityMismatch) = VibeListTransactionValidator.validate(geoMismatch) {
      // ok
    } else {
      XCTFail("expected geometry identity mismatch")
    }
  }

  func testAcceptsValidOrderedTransaction() {
    let insert = makeSettledItem(id: "n1", rank: 10)
    let edit = makeSettledItem(id: "e1", rank: 5, contentRevision: 2)
    let geo = makeSettledItem(
      id: "g1",
      rank: 6,
      size: CGSize(width: 360, height: 70),
      geometryRevision: 2,
      flags: [.settled, .streaming]
    )
    let tx = VibeListTransaction(
      baseGeneration: 3,
      nextGeneration: 4,
      ops: [
        .insert(items: [insert], at: 0),
        .updateContent(id: "e1", item: edit),
        .updateGeometry(id: "g1", item: geo, deltaHeight: 22),
        .remove(ids: ["old"]),
        .move(id: "m1", to: 1),
      ],
      preserve: .pinToBottom,
      animation: .none,
      commitDeadline: .displayLink
    )
    switch VibeListTransactionValidator.validate(tx) {
    case .success:
      break
    case .failure(let error):
      XCTFail("valid transaction rejected: \(error)")
    }
  }

  func testAcceptsMoveThenGeometryUpdateForSameIdentity() {
    let moved = makeSettledItem(
      id: "m1",
      rank: 4,
      size: CGSize(width: 360, height: 72),
      contentRevision: 2,
      geometryRevision: 2,
      flags: [.settled, .streaming]
    )
    let tx = VibeListTransaction(
      baseGeneration: 9,
      nextGeneration: 10,
      ops: [
        .move(id: "m1", to: 0),
        .updateGeometry(id: "m1", item: moved, deltaHeight: 24),
      ]
    )
    if case .failure(let error) = VibeListTransactionValidator.validate(tx) {
      XCTFail("core move+geometry sequence rejected: \(error)")
    }
  }
}

// MARK: - Display-link commit ordering

@MainActor
final class VibeListDisplayLinkCommitterTests: XCTestCase {
  func testImmediateCommitFlushesEveryOlderChainAndKeepsRepeatedIdentityOps() {
    let committer = VibeListDisplayLinkCommitter()
    defer { committer.invalidate() }

    var committed: [VibeListTransaction] = []
    committer.onCommit = { committed.append($0) }

    let moved = makeSettledItem(id: "same", rank: 1)
    let resized = makeSettledItem(
      id: "same",
      rank: 0,
      size: CGSize(width: 360, height: 60),
      contentRevision: 2,
      geometryRevision: 2,
      flags: [.settled, .streaming]
    )
    committer.enqueue(
      VibeListTransaction(
        baseGeneration: 0,
        nextGeneration: 1,
        ops: [.move(id: "same", to: 0)]
      )
    )
    committer.enqueue(
      VibeListTransaction(
        baseGeneration: 1,
        nextGeneration: 2,
        ops: [.updateGeometry(id: "same", item: resized, deltaHeight: 12)]
      )
    )
    // Deliberately discontinuous: this must remain ahead of the later immediate item.
    committer.enqueue(
      VibeListTransaction(
        baseGeneration: 5,
        nextGeneration: 6,
        ops: [.insert(items: [moved], at: 0)]
      )
    )
    committer.enqueue(
      VibeListTransaction(
        baseGeneration: 6,
        nextGeneration: 7,
        ops: [.remove(ids: ["same"])],
        commitDeadline: .immediate
      )
    )

    XCTAssertEqual(committed.map(\.baseGeneration), [0, 5, 6])
    XCTAssertEqual(committed.map(\.nextGeneration), [2, 6, 7])
    XCTAssertEqual(committed[0].ops.count, 2)
    XCTAssertEqual(committer.pendingCount, 0)
  }
}

// MARK: - Snapshot validator

final class VibeRenderSnapshotValidatorTests: XCTestCase {
  private func baseWindow(ids: [String], startIndex: Int = 0) -> VibeTimelineWindowV1 {
    VibeTimelineWindowV1(
      chatId: TimelineTestIDs.chat,
      messageIds: ids,
      anchors: ids.map { VibeTimelineAnchor(messageId: $0) },
      startIndex: startIndex
    )
  }

  func testRejectsDuplicateIds() {
    let items = [
      makeSettledItem(id: "a", rank: 1),
      makeSettledItem(id: "a", rank: 2),
    ]
    // Two items with same id — pad window ids to match count (validator checks count first).
    let snapshot = VibeRenderSnapshot(
      chatId: TimelineTestIDs.chat,
      generation: 1,
      window: baseWindow(ids: ["a", "b"]),
      items: items,
      contentHeight: items.reduce(0) { $0 + $1.size.height }
    )
    switch VibeRenderSnapshotValidator.validate(snapshot) {
    case .failure(.duplicateIdentity(let id)):
      XCTAssertEqual(id, "a")
    default:
      XCTFail("expected duplicate identity")
    }
  }

  func testRejectsWrongOrder() {
    let items = [
      makeSettledItem(id: "b", rank: 2),
      makeSettledItem(id: "a", rank: 1),
    ]
    let snapshot = VibeRenderSnapshot(
      chatId: TimelineTestIDs.chat,
      generation: 1,
      window: baseWindow(ids: ["b", "a"]),
      items: items,
      contentHeight: items.reduce(0) { $0 + $1.size.height }
    )
    if case .failure(.orderNotAscending) = VibeRenderSnapshotValidator.validate(snapshot) {
      // ok
    } else {
      XCTFail("expected orderNotAscending")
    }
  }

  func testRejectsContentHeightMismatchAndWindowMetadata() {
    let items = (0..<150).map { makeSettledItem(id: "id-\($0)", rank: UInt64($0)) }
    let height = items.reduce(CGFloat(0)) { $0 + $1.size.height }
    let badHeight = VibeRenderSnapshot(
      chatId: TimelineTestIDs.chat,
      generation: 1,
      window: baseWindow(ids: items.map(\.identity.messageId)),
      items: items,
      contentHeight: height + 10
    )
    switch VibeRenderSnapshotValidator.validate(badHeight) {
    case .failure(.contentHeightMismatch):
      break
    default:
      XCTFail("expected contentHeightMismatch")
    }

    let chatMismatch = VibeRenderSnapshot(
      chatId: "other",
      generation: 1,
      window: baseWindow(ids: items.map(\.identity.messageId)),
      items: items,
      contentHeight: height
    )
    if case .failure(.chatIdMismatch) = VibeRenderSnapshotValidator.validate(chatMismatch) {
      // ok
    } else {
      XCTFail("expected chatIdMismatch")
    }

    let countMismatch = VibeRenderSnapshot(
      chatId: TimelineTestIDs.chat,
      generation: 1,
      window: baseWindow(ids: ["only-one"]),
      items: items,
      contentHeight: height
    )
    if case .failure(.windowItemCountMismatch) = VibeRenderSnapshotValidator.validate(countMismatch) {
      // ok
    } else {
      XCTFail("expected windowItemCountMismatch")
    }

    // A large window is VALID. This asserted the opposite — anything over 300 was a
    // validation failure — and that is what disabled the core on every real chat once
    // the window went unbounded: the snapshot was rejected, so the host never mounted,
    // so every later transaction was fenced against generation 0.
    //
    // How many rows a host will mount is the host's policy and it enforces its own
    // (see `testAnOversizedSnapshotIsTrimmedByABoundedHost`). Well-formedness is what
    // this validator is for, and a thousand correctly-ordered unique rows are well
    // formed.
    let oversizedItems = (0..<1_001).map { makeSettledItem(id: "o-\($0)", rank: UInt64($0)) }
    let oversized = VibeRenderSnapshot(
      chatId: TimelineTestIDs.chat,
      generation: 1,
      window: baseWindow(ids: oversizedItems.map(\.identity.messageId)),
      items: oversizedItems,
      contentHeight: oversizedItems.reduce(0) { $0 + $1.size.height }
    )
    if case .failure(let failure) = VibeRenderSnapshotValidator.validate(oversized) {
      XCTFail("a 1,001-row snapshot must validate; got \(failure)")
    }
  }

  func testAcceptsValidSnapshotWithinPolicy() {
    let items = (0..<200).map { makeSettledItem(id: "ok-\($0)", rank: UInt64($0)) }
    let height = items.reduce(CGFloat(0)) { $0 + $1.size.height }
    let snapshot = VibeRenderSnapshot(
      chatId: TimelineTestIDs.chat,
      generation: 7,
      window: baseWindow(ids: items.map(\.identity.messageId), startIndex: 100),
      items: items,
      contentHeight: height
    )
    switch VibeRenderSnapshotValidator.validate(snapshot) {
    case .success:
      break
    case .failure(let error):
      XCTFail("valid snapshot rejected: \(error)")
    }
  }

  func testRejectsWindowIdentityAndAnchorMismatch() {
    let items = [
      makeSettledItem(id: "a", rank: 1),
      makeSettledItem(id: "b", rank: 2),
    ]
    let wrongId = VibeRenderSnapshot(
      chatId: TimelineTestIDs.chat,
      generation: 1,
      window: baseWindow(ids: ["a", "wrong"]),
      items: items,
      contentHeight: 96
    )
    if case .failure(.windowIdentityMismatch(index: 1, windowId: "wrong", itemId: "b")) =
      VibeRenderSnapshotValidator.validate(wrongId)
    {
      // expected
    } else {
      XCTFail("expected exact window/item identity rejection")
    }

    let wrongAnchor = VibeRenderSnapshot(
      chatId: TimelineTestIDs.chat,
      generation: 1,
      window: VibeTimelineWindowV1(
        chatId: TimelineTestIDs.chat,
        messageIds: ["a", "b"],
        anchors: [
          VibeTimelineAnchor(messageId: "a"),
          VibeTimelineAnchor(messageId: "wrong"),
        ]
      ),
      items: items,
      contentHeight: 96
    )
    if case .failure(.windowAnchorMismatch(index: 1, anchorId: "wrong", itemId: "b")) =
      VibeRenderSnapshotValidator.validate(wrongAnchor)
    {
      // expected
    } else {
      XCTFail("expected exact anchor/item identity rejection")
    }
  }
}

// MARK: - Shadow comparator

final class VibeTimelineShadowComparatorTests: XCTestCase {
  private func snapshot(
    generation: UInt64,
    items: [VibeRenderItem],
    anchor: VibeViewportAnchor = .pinToBottom,
    contentHeight: CGFloat? = nil
  ) -> VibeRenderSnapshot {
    let height = contentHeight ?? items.reduce(0) { $0 + $1.size.height }
    return VibeRenderSnapshot(
      chatId: TimelineTestIDs.chat,
      generation: generation,
      window: VibeTimelineWindowV1(
        chatId: TimelineTestIDs.chat,
        messageIds: items.map(\.identity.messageId)
      ),
      items: items,
      anchor: anchor,
      contentHeight: height
    )
  }

  func testMatchWithinHalfPointTolerance() {
    let leftItems = [
      makeSettledItem(id: "a", rank: 1, size: CGSize(width: 360, height: 48.0)),
      makeSettledItem(id: "b", rank: 2, size: CGSize(width: 360, height: 50.0)),
    ]
    // Per-row deltas at the 0.5pt boundary (comparator uses `>` so 0.5 matches).
    // Keep summed contentHeight identical so only per-item geometry is under test.
    let rightItems = [
      makeSettledItem(id: "a", rank: 1, size: CGSize(width: 360, height: 48.4)),
      makeSettledItem(id: "b", rank: 2, size: CGSize(width: 360, height: 50.5)),
    ]
    let sharedHeight: CGFloat = 98.0
    let left = snapshot(generation: 2, items: leftItems, contentHeight: sharedHeight)
    let right = snapshot(generation: 2, items: rightItems, contentHeight: sharedHeight)
    let report = VibeTimelineShadowComparator.compare(left: left, right: right)
    XCTAssertTrue(report.isMatch, "diffs: \(report.diffs)")
  }

  func testDetectsOrderGenerationGeometryAndAnchorWithIdsOnly() {
    let leftItems = [
      makeSettledItem(id: "a", rank: 1, size: CGSize(width: 360, height: 40)),
      makeSettledItem(id: "b", rank: 2, size: CGSize(width: 360, height: 40)),
    ]
    let rightItems = [
      makeSettledItem(id: "b", rank: 1, size: CGSize(width: 360, height: 40)),
      makeSettledItem(id: "a", rank: 2, size: CGSize(width: 360, height: 60)),
    ]
    let left = snapshot(
      generation: 1,
      items: leftItems,
      anchor: VibeViewportAnchor(itemId: "a", offsetFromTop: 0, pin: .item)
    )
    let right = snapshot(
      generation: 9,
      items: rightItems,
      anchor: VibeViewportAnchor(itemId: "b", offsetFromTop: 12, pin: .bottom)
    )
    let report = VibeTimelineShadowComparator.compare(left: left, right: right)
    XCTAssertFalse(report.isMatch)

    let kinds = Set(report.diffs.map(\.kind))
    XCTAssertTrue(kinds.contains(.generationMismatch))
    XCTAssertTrue(kinds.contains(.orderMismatch))
    XCTAssertTrue(kinds.contains(.geometryMismatch))
    XCTAssertTrue(kinds.contains(.anchorMismatch))

    // Diagnostics must be identifier / metric only — never message bodies.
    for diff in report.diffs {
      if let id = diff.identityId {
        XCTAssertFalse(id.contains(" "), "identity should be id-only: \(id)")
        XCTAssertFalse(id.lowercased().contains("hello"), "no plaintext body in diagnostics")
      }
      if let code = diff.detailCode {
        XCTAssertFalse(code.lowercased().contains("lorem"))
      }
    }
  }

  func testGeometryToleranceRejectsAboveHalfPoint() {
    let left = snapshot(
      generation: 1,
      items: [makeSettledItem(id: "x", rank: 1, size: CGSize(width: 360, height: 10))]
    )
    let right = snapshot(
      generation: 1,
      items: [makeSettledItem(id: "x", rank: 1, size: CGSize(width: 360, height: 10.51))]
    )
    let report = VibeTimelineShadowComparator.compare(left: left, right: right)
    XCTAssertTrue(report.diffs.contains { $0.kind == .geometryMismatch && $0.identityId == "x" })
  }
}

// MARK: - Replay fixture + scenarios

final class VibeTimelineReplayHarnessTests: XCTestCase {
  func testFixtureIsLazyCompactWithDeterministicMediaMarkers() {
    let fixture = VibeTimelineReplayFixture()
    XCTAssertEqual(fixture.messageCount, 100_000)
    XCTAssertEqual(fixture.mediaMarkerCount, 2_000)

    // O(1) ids — sample only; do not materialize 100k items.
    XCTAssertEqual(fixture.messageId(at: 0), "m-\(fixture.seed)-0")
    XCTAssertEqual(fixture.messageId(at: 99_999), "m-\(fixture.seed)-99999")

    var markerCount = 0
    // Count markers without allocating row bodies for non-markers.
    var index = 0
    while index < fixture.messageCount {
      if fixture.isMediaMarker(at: index) {
        markerCount += 1
      }
      index += 1
      // Bound work: full 100k bool checks are fine (no rich allocation).
      if index > fixture.messageCount { break }
    }
    XCTAssertEqual(markerCount, 2_000)

    // Compact window materialization only.
    let slice = fixture.makeWindow(startIndex: 50_000, count: 500)
    XCTAssertLessThanOrEqual(slice.items.count, 300)
    XCTAssertEqual(slice.items.count, VibeTimelineWindowPolicy.clampActiveWindow(500))
    XCTAssertEqual(slice.window.count, slice.items.count)
  }

  func testEveryRequestedActiveWindowRemainsAtMost300() {
    let fixture = VibeTimelineReplayFixture()
    let starts = [0, 1, 50_000, 99_700, 99_900]
    let counts = [1, 150, 200, 300, 301, 1_000, 100_000]
    for start in starts {
      for count in counts {
        let slice = fixture.makeWindow(startIndex: start, count: count)
        XCTAssertLessThanOrEqual(
          slice.items.count,
          VibeTimelineWindowPolicy.activeWindowRange.upperBound,
          "start=\(start) count=\(count)"
        )
        let snapshot = fixture.makeSnapshot(generation: 1, startIndex: start, count: count)
        XCTAssertLessThanOrEqual(snapshot.items.count, 300)
        if !snapshot.items.isEmpty {
          switch VibeRenderSnapshotValidator.validate(snapshot) {
          case .success:
            break
          case .failure(let error):
            XCTFail("snapshot invalid at start=\(start) count=\(count): \(error)")
          }
        }
      }
    }
  }

  func testNamedScenariosAreDeterministicForSameSeedAndClock() {
    let scenarios = VibeTimelineReplayScenario.allCases
    XCTAssertTrue(scenarios.contains(.pushOpen))
    XCTAssertTrue(scenarios.contains(.insertEditDeleteReceipt))
    XCTAssertTrue(scenarios.contains(.streamingClassifiedGeometry))
    XCTAssertTrue(scenarios.contains(.windowShift))
    XCTAssertTrue(scenarios.contains(.lateMediaContentOnly))
    XCTAssertTrue(scenarios.contains(.eventStorm20))
    XCTAssertTrue(scenarios.contains(.eventStorm50))

    for scenario in scenarios {
      let a = VibeTimelineReplayHarness(
        configuration: VibeTimelineReplayConfiguration(
          activeWindowCount: 200,
          eventsPerSecond: scenario == .eventStorm50 ? 50 : 20,
          stormDurationSeconds: 1,
          clock: VibeTimelineReplayClock(now: 0),
          seed: VibeTimelineReplaySeeds.board0802
        )
      )
      let b = VibeTimelineReplayHarness(
        configuration: VibeTimelineReplayConfiguration(
          activeWindowCount: 200,
          eventsPerSecond: scenario == .eventStorm50 ? 50 : 20,
          stormDurationSeconds: 1,
          clock: VibeTimelineReplayClock(now: 0),
          seed: VibeTimelineReplaySeeds.board0802
        )
      )
      let stepsA = a.steps(for: scenario)
      let stepsB = b.steps(for: scenario)
      XCTAssertEqual(stepsA.count, stepsB.count, "scenario \(scenario.rawValue) step count")
      XCTAssertFalse(stepsA.isEmpty, "scenario \(scenario.rawValue) must emit steps")
      XCTAssertEqual(stepsA, stepsB, "scenario \(scenario.rawValue) must be deterministic")

      // Every snapshot/window in the sequence stays within active-window policy.
      for step in stepsA {
        if let snapshot = step.snapshot {
          XCTAssertLessThanOrEqual(snapshot.items.count, 300)
        }
        if let tx = step.transaction {
          switch VibeListTransactionValidator.validate(tx) {
          case .success:
            break
          case .failure(let error):
            XCTFail("scenario \(scenario.rawValue) invalid tx gen=\(step.generation): \(error)")
          }
        }
      }
    }
  }

  func testStormRatesProduceExpectedEventCountsWithoutSleeps() {
    // stormDurationSeconds=1 → 20 and 50 events after pushOpen.
    let harness20 = VibeTimelineReplayHarness(
      configuration: VibeTimelineReplayConfiguration(
        stormDurationSeconds: 1,
        clock: VibeTimelineReplayClock(now: 0),
        seed: VibeTimelineReplaySeeds.board0802
      )
    )
    let steps20 = harness20.steps(for: .eventStorm20)
    // pushOpen + 20 events
    XCTAssertEqual(steps20.count, 21)
    guard case .pushOpen(let start20, let count20) = steps20[0].event else {
      return XCTFail("eventStorm20 must open with pushOpen")
    }
    XCTAssertEqual(count20, steps20[0].snapshot?.items.count)
    XCTAssertEqual(start20, steps20[0].snapshot?.window.startIndex)
    XCTAssertLessThanOrEqual(count20, 300)

    let harness50 = VibeTimelineReplayHarness(
      configuration: VibeTimelineReplayConfiguration(
        stormDurationSeconds: 1,
        clock: VibeTimelineReplayClock(now: 0),
        seed: VibeTimelineReplaySeeds.board0802
      )
    )
    let steps50 = harness50.steps(for: .eventStorm50)
    XCTAssertEqual(steps50.count, 51)
    guard case .pushOpen = steps50[0].event else {
      return XCTFail("eventStorm50 must open with pushOpen")
    }

    // Virtual clock advances; no wall-clock sleeps.
    XCTAssertGreaterThan(steps50.last?.time ?? 0, 0)
    XCTAssertLessThanOrEqual(steps50.last?.time ?? 0, 1.0 + 1e-6)
  }

  func testScenarioCoverageIncludesPushInsertEditDeleteReceiptStreamingShiftLateMedia() {
    let harness = VibeTimelineReplayHarness(
      configuration: VibeTimelineReplayConfiguration(
        stormDurationSeconds: 1,
        clock: VibeTimelineReplayClock(now: 0)
      )
    )

    let push = harness.steps(for: .pushOpen)
    XCTAssertEqual(push.count, 1)
    if case .pushOpen = push[0].event {
      XCTAssertNotNil(push[0].snapshot)
    } else {
      XCTFail("expected pushOpen event")
    }

    let mut = harness.steps(for: .insertEditDeleteReceipt)
    let mutKinds = Set(mut.map { eventKind($0.event) })
    XCTAssertTrue(mutKinds.contains("pushOpen"))
    XCTAssertTrue(mutKinds.contains("insert"))
    XCTAssertTrue(mutKinds.contains("edit"))
    XCTAssertTrue(mutKinds.contains("receipt"))
    XCTAssertTrue(mutKinds.contains("delete"))

    let stream = harness.steps(for: .streamingClassifiedGeometry)
    XCTAssertTrue(stream.contains { if case .streamingGeometry = $0.event { return true }; return false })

    let shift = harness.steps(for: .windowShift)
    XCTAssertTrue(shift.contains { if case .windowShift = $0.event { return true }; return false })

    let late = harness.steps(for: .lateMediaContentOnly)
    // Window at corpus bottom should include media markers (every 50th index).
    XCTAssertTrue(
      late.contains { if case .lateMediaContentOnly = $0.event { return true }; return false },
      "late media step should appear when media marker is in window"
    )
  }

  private func eventKind(_ event: VibeTimelineReplayEvent) -> String {
    switch event {
    case .pushOpen: return "pushOpen"
    case .insert: return "insert"
    case .edit: return "edit"
    case .delete: return "delete"
    case .receipt: return "receipt"
    case .streamingGeometry: return "streamingGeometry"
    case .windowShift: return "windowShift"
    case .lateMediaContentOnly: return "lateMediaContentOnly"
    }
  }
}

// MARK: - No-op host apply (subset)

@MainActor
final class VibeNoOpMessageListHostTests: XCTestCase {
  /// Snapshot apply: generation updates and instantiated geometry equals window size.
  func testSnapshotApplyRespectsGenerationAndWindowSize() {
    let host = VibeNoOpMessageListHost()
    let fixture = VibeTimelineReplayFixture()
    let snapshot = fixture.makeSnapshot(
      generation: 3,
      startIndex: fixture.messageCount - 200,
      count: 200
    )
    XCTAssertEqual(snapshot.items.count, 200)

    host.apply(snapshot: snapshot, reason: .navigationPush)
    XCTAssertEqual(host.lastAppliedGeneration, 3)
    XCTAssertEqual(host.instantiatedItemCount, snapshot.items.count)
    XCTAssertEqual(host.debugGeometryMap().count, snapshot.items.count)
    XCTAssertLessThanOrEqual(host.instantiatedItemCount, 300)
  }

  /// Transactions update generation; geometry map receives insert/remove/geometry ops.
  func testTransactionApplyUpdatesGenerationAndGeometryMap() {
    let host = VibeNoOpMessageListHost()
    let open = VibeTimelineReplayFixture().makeSnapshot(generation: 1, startIndex: 0, count: 150)
    host.apply(snapshot: open, reason: .navigationPush)
    XCTAssertEqual(host.lastAppliedGeneration, 1)

    let insert = makeSettledItem(id: "tail-new", rank: 9_999)
    let tx = VibeListTransaction(
      baseGeneration: 1,
      nextGeneration: 2,
      ops: [.insert(items: [insert], at: 150)]
    )
    host.apply(transaction: tx)
    XCTAssertEqual(host.lastAppliedGeneration, 2)
    XCTAssertEqual(host.debugGeometryMap()["tail-new"], insert.size.height)

    let remove = VibeListTransaction(
      baseGeneration: 2,
      nextGeneration: 3,
      ops: [.remove(ids: ["tail-new"])]
    )
    host.apply(transaction: remove)
    XCTAssertEqual(host.lastAppliedGeneration, 3)
    XCTAssertNil(host.debugGeometryMap()["tail-new"])
  }

  /// Replay steps can be applied for generations; window-bound growth is only
  /// guaranteed on snapshot remounts with the current no-op host (see handoff).
  func testReplayStepsApplyWithMonotonicGenerationOnHost() {
    let host = VibeNoOpMessageListHost()
    let harness = VibeTimelineReplayHarness(
      configuration: VibeTimelineReplayConfiguration(
        activeWindowCount: 200,
        stormDurationSeconds: 1,
        clock: VibeTimelineReplayClock(now: 0),
        seed: VibeTimelineReplaySeeds.board0802
      )
    )
    let steps = harness.steps(for: .insertEditDeleteReceipt)
    var lastGen: UInt64 = 0
    for step in steps {
      if let snapshot = step.snapshot {
        host.apply(snapshot: snapshot, reason: step.scenario == .pushOpen ? .navigationPush : .windowShift)
        XCTAssertEqual(host.lastAppliedGeneration, snapshot.generation)
        // Snapshot path replaces geometry entirely → bounded to window.
        XCTAssertEqual(host.instantiatedItemCount, snapshot.items.count)
        XCTAssertLessThanOrEqual(host.instantiatedItemCount, 300)
      }
      if let tx = step.transaction {
        host.apply(transaction: tx)
        XCTAssertEqual(host.lastAppliedGeneration, tx.nextGeneration)
      }
      XCTAssertGreaterThanOrEqual(step.generation, lastGen)
      lastGen = step.generation
    }
    XCTAssertGreaterThan(lastGen, 0)
  }

  /*
   INTENTIONAL GAP (do not edit P0 `VibeMessageListHost.swift` / no-op host):

   `VibeNoOpMessageListHost` records geometry for inserts but never trims to the
   active window. Window-bounded instantiation under pure transaction storms is
   proven by `VibeTimelineReferenceHostTests` instead.
   */
}

// MARK: - Reference host (bounded model oracle)

@MainActor
final class VibeTimelineReferenceHostTests: XCTestCase {

  // MARK: Helpers

  private func makeHarness(
    activeWindowCount: Int = 200,
    stormDurationSeconds: TimeInterval = 1,
    seed: UInt64 = VibeTimelineReplaySeeds.board0802
  ) -> VibeTimelineReplayHarness {
    VibeTimelineReplayHarness(
      configuration: VibeTimelineReplayConfiguration(
        activeWindowCount: activeWindowCount,
        stormDurationSeconds: stormDurationSeconds,
        clock: VibeTimelineReplayClock(now: 0),
        seed: seed
      )
    )
  }

  private func applyStep(
    _ step: VibeTimelineReplayStep,
    to host: VibeTimelineReferenceHost,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    if let snapshot = step.snapshot {
      let reason: VibeMountReason =
        step.scenario == .pushOpen ? .navigationPush : .windowShift
      let result = host.tryApply(snapshot: snapshot, reason: reason)
      if case .failure(let error) = result {
        XCTFail(
          "snapshot apply failed gen=\(step.generation) scenario=\(step.scenario.rawValue): \(error)",
          file: file,
          line: line
        )
      }
    }
    if let tx = step.transaction {
      let result = host.tryApply(transaction: tx)
      if case .failure(let error) = result {
        XCTFail(
          "transaction apply failed gen=\(step.generation) scenario=\(step.scenario.rawValue): \(error)",
          file: file,
          line: line
        )
      }
    }
  }

  /// Post-commit invariants asserted after every successful step.
  private func assertPostStepInvariants(
    host: VibeTimelineReferenceHost,
    previousGeneration: UInt64,
    step: VibeTimelineReplayStep,
    settledGeometryBaseline: inout [String: (height: CGFloat, geometryRevision: UInt64)],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertLessThanOrEqual(
      host.instantiatedItemCount,
      host.activeWindowCount,
      "count must stay within active window after gen=\(step.generation)",
      file: file,
      line: line
    )
    XCTAssertLessThanOrEqual(
      host.instantiatedItemCount,
      VibeTimelineWindowPolicy.activeWindowRange.upperBound,
      file: file,
      line: line
    )
    XCTAssertGreaterThanOrEqual(
      host.generation,
      previousGeneration,
      "generation must be monotonic",
      file: file,
      line: line
    )
    if host.hasCommittedModel {
      XCTAssertEqual(host.lastAppliedGeneration, host.generation, file: file, line: line)
    }

    switch host.assertModelInvariants() {
    case .success:
      break
    case .failure(let error):
      XCTFail("model invariants failed gen=\(step.generation): \(error)", file: file, line: line)
    }

    let ids = host.orderedIds
    XCTAssertEqual(Set(ids).count, ids.count, "ids must be unique", file: file, line: line)
    XCTAssertEqual(host.debugGeometryMap().count, host.instantiatedItemCount, file: file, line: line)
    XCTAssertEqual(host.visibleAnchors().count, host.instantiatedItemCount, file: file, line: line)

    // Settled content-only: geometry must not change for ids that remain settled-locked.
    for item in host.committedItems {
      let id = item.identity.messageId
      if item.flags.locksGeometry {
        if let prior = settledGeometryBaseline[id] {
          XCTAssertEqual(
            item.size.height,
            prior.height,
            accuracy: 0.01,
            "settled height changed for \(id) at gen=\(step.generation)",
            file: file,
            line: line
          )
          XCTAssertEqual(
            item.geometryRevision,
            prior.geometryRevision,
            "settled geometryRevision changed for \(id) at gen=\(step.generation)",
            file: file,
            line: line
          )
        }
        settledGeometryBaseline[id] = (item.size.height, item.geometryRevision)
      } else {
        // Streaming / unlocked: refresh baseline to current geometry.
        settledGeometryBaseline[id] = (item.size.height, item.geometryRevision)
      }
    }
    // Drop baseline entries that left the window.
    let live = Set(ids)
    settledGeometryBaseline = settledGeometryBaseline.filter { live.contains($0.key) }
  }

  private func runScenario(
    _ scenario: VibeTimelineReplayScenario,
    activeWindowCount: Int = 200,
    stormDurationSeconds: TimeInterval = 1,
    seed: UInt64 = VibeTimelineReplaySeeds.board0802
  ) -> (host: VibeTimelineReferenceHost, fingerprint: VibeTimelineModelFingerprint, steps: Int) {
    let host = VibeTimelineReferenceHost(activeWindowCount: activeWindowCount)
    let harness = makeHarness(
      activeWindowCount: activeWindowCount,
      stormDurationSeconds: stormDurationSeconds,
      seed: seed
    )
    let steps = harness.steps(for: scenario)
    var lastGen: UInt64 = 0
    var settledBaseline: [String: (height: CGFloat, geometryRevision: UInt64)] = [:]

    for step in steps {
      applyStep(step, to: host)
      assertPostStepInvariants(
        host: host,
        previousGeneration: lastGen,
        step: step,
        settledGeometryBaseline: &settledBaseline
      )
      lastGen = host.generation
    }

    return (host, host.modelFingerprint(), steps.count)
  }

  // MARK: Snapshot / basic ops

  func testSnapshotApplyMountsBoundedModel() {
    let host = VibeTimelineReferenceHost(activeWindowCount: 200)
    let fixture = VibeTimelineReplayFixture()
    let snapshot = fixture.makeSnapshot(
      generation: 1,
      startIndex: fixture.messageCount - 200,
      count: 200
    )
    let result = host.tryApply(snapshot: snapshot, reason: .navigationPush)
    XCTAssertNil(host.lastFailure)
    if case .failure(let error) = result {
      return XCTFail("unexpected failure \(error)")
    }
    XCTAssertEqual(host.instantiatedItemCount, 200)
    XCTAssertEqual(host.generation, 1)
    XCTAssertEqual(host.orderedIds.count, 200)
    XCTAssertEqual(host.visibleAnchors().first?.messageId, snapshot.items.first?.identity.messageId)
    XCTAssertEqual(host.debugGeometryMap().count, 200)
  }

  /// A host that wants a bounded model **trims** to its bound; it does not reject the
  /// conversation.
  ///
  /// This asserted rejection, and the shared snapshot validator enforced it for every
  /// host — including the real one, which is unbounded. The result was that a chat with
  /// more than 300 messages had every snapshot thrown away before it could mount, so the
  /// core ran and rendered nothing. Bounding is a host's own decision and it is made by
  /// trimming, which is what `trimIfNeeded` has always done.
  func testAnOversizedSnapshotIsTrimmedByABoundedHost() {
    let host = VibeTimelineReferenceHost(activeWindowCount: 200)
    let items = (0..<301).map { makeSettledItem(id: "o-\($0)", rank: UInt64($0)) }
    let snapshot = VibeRenderSnapshot(
      chatId: TimelineTestIDs.chat,
      generation: 1,
      window: VibeTimelineWindowV1(
        chatId: TimelineTestIDs.chat,
        messageIds: items.map(\.identity.messageId)
      ),
      items: items,
      contentHeight: items.reduce(0) { $0 + $1.size.height }
    )
    if case .failure(let failure) = host.tryApply(snapshot: snapshot, reason: .debug) {
      return XCTFail("a bounded host must trim, not reject; got \(failure)")
    }
    XCTAssertTrue(host.hasCommittedModel)
    XCTAssertEqual(host.instantiatedItemCount, 200, "trimmed to the host's own bound")
    XCTAssertEqual(host.failedApplyCount, 0)
    XCTAssertEqual(host.successfulApplyCount, 1)
  }

  // MARK: Failure atomicity

  func testFailedTransactionDoesNotMutateModel() {
    let host = VibeTimelineReferenceHost(activeWindowCount: 150)
    let open = VibeTimelineReplayFixture().makeSnapshot(generation: 1, startIndex: 0, count: 150)
    if case .failure(let error) = host.tryApply(snapshot: open, reason: .navigationPush) {
      return XCTFail("unexpected open failure \(error)")
    }

    let fingerprintBefore = host.modelFingerprint()
    let generationBefore = host.generation
    let countBefore = host.instantiatedItemCount
    let idsBefore = host.orderedIds

    // Illegal content-only size change on a settled row.
    let target = open.items[10]
    let badReplacement = VibeRenderItem(
      identity: target.identity,
      orderKey: target.orderKey,
      kind: target.kind,
      contentRevision: target.contentRevision + 1,
      geometryRevision: target.geometryRevision,
      size: CGSize(width: target.size.width, height: target.size.height + 40),
      layout: target.layout,
      paint: target.paint,
      mediaSlots: target.mediaSlots,
      interaction: target.interaction,
      flags: target.flags
    )
    let badTx = VibeListTransaction(
      baseGeneration: 1,
      nextGeneration: 2,
      ops: [.updateContent(id: target.identity.messageId, item: badReplacement)]
    )
    let result = host.tryApply(transaction: badTx)
    switch result {
    case .failure(.transactionValidation(.contentOnlySizeChanged(let id))):
      XCTAssertEqual(id, target.identity.messageId)
    default:
      XCTFail("expected contentOnlySizeChanged, got \(String(describing: result))")
    }

    XCTAssertEqual(host.generation, generationBefore)
    XCTAssertEqual(host.instantiatedItemCount, countBefore)
    XCTAssertEqual(host.orderedIds, idsBefore)
    XCTAssertEqual(host.modelFingerprint(), fingerprintBefore)
    XCTAssertEqual(host.lastAppliedGeneration, generationBefore)
    XCTAssertEqual(host.failedApplyCount, 1)
    XCTAssertEqual(host.successfulApplyCount, 1)

    // Unknown identity mid multi-op transaction must not partially apply the insert.
    let insert = makeSettledItem(id: "partial-insert", rank: 50_000)
    let multiBad = VibeListTransaction(
      baseGeneration: 1,
      nextGeneration: 2,
      ops: [
        .insert(items: [insert], at: countBefore),
        .remove(ids: ["does-not-exist"]),
      ]
    )
    let multiResult = host.tryApply(transaction: multiBad)
    if case .failure(.unknownIdentity(messageId: "does-not-exist")) = multiResult {
      // expected
    } else {
      XCTFail("expected unknown-identity rejection, got \(String(describing: multiResult))")
    }
    XCTAssertNil(host.item(forId: "partial-insert"))
    XCTAssertEqual(host.modelFingerprint(), fingerprintBefore)
    XCTAssertEqual(host.generation, generationBefore)
  }

  func testGenerationMismatchIsAtomic() {
    let host = VibeTimelineReferenceHost(activeWindowCount: 150)
    let open = VibeTimelineReplayFixture().makeSnapshot(generation: 1, startIndex: 0, count: 150)
    _ = host.tryApply(snapshot: open, reason: .navigationPush)
    let before = host.modelFingerprint()

    let insert = makeSettledItem(id: "x", rank: 9_999)
    let stale = VibeListTransaction(
      baseGeneration: 0,
      nextGeneration: 2,
      ops: [.insert(items: [insert], at: 150)]
    )
    let result = host.tryApply(transaction: stale)
    if case .failure(.generationMismatch(expectedBase: 0, current: 1)) = result {
      // expected
    } else {
      XCTFail("expected generation mismatch, got \(String(describing: result))")
    }
    XCTAssertEqual(host.modelFingerprint(), before)
  }

  // MARK: Anchor retention + trim

  func testBottomPinTrimsOldestOnOverflow() {
    let host = VibeTimelineReferenceHost(activeWindowCount: 150)
    let open = VibeTimelineReplayFixture().makeSnapshot(generation: 1, startIndex: 0, count: 150)
    _ = host.tryApply(snapshot: open, reason: .navigationPush)
    let oldest = open.items.first!.identity.messageId
    let newest = open.items.last!.identity.messageId

    let incoming = makeSettledItem(id: "tail-1", rank: 10_000)
    let tx = VibeListTransaction(
      baseGeneration: 1,
      nextGeneration: 2,
      ops: [.insert(items: [incoming], at: 150)],
      preserve: .pinToBottom
    )
    if case .failure(let error) = host.tryApply(transaction: tx) {
      return XCTFail("unexpected bottom-pin insert failure \(error)")
    }
    XCTAssertEqual(host.instantiatedItemCount, 150)
    XCTAssertNil(host.item(forId: oldest), "oldest must be trimmed under bottom pin")
    XCTAssertNotNil(host.item(forId: newest))
    XCTAssertNotNil(host.item(forId: "tail-1"))
    XCTAssertEqual(host.viewportAnchor.pin, .bottom)
  }

  func testItemPinRetainsAnchorAndNearestNeighbors() {
    let host = VibeTimelineReferenceHost(activeWindowCount: 150)
    // Undersized open so inserts can grow before trim engages.
    let open = VibeTimelineReplayFixture().makeSnapshot(generation: 1, startIndex: 0, count: 100)
    _ = host.tryApply(snapshot: open, reason: .navigationPush)
    XCTAssertEqual(host.instantiatedItemCount, 100)

    // Anchor near the middle of the seed window.
    let anchorItem = open.items[50]
    let anchorId = anchorItem.identity.messageId
    let neighborBefore = open.items[49].identity.messageId
    let neighborAfter = open.items[51].identity.messageId

    // Grow past capacity with end inserts while pinning to the mid item.
    var gen: UInt64 = 1
    for i in 0..<60 {
      gen += 1
      let item = makeSettledItem(id: "overflow-\(i)", rank: 20_000 + UInt64(i))
      let tx = VibeListTransaction(
        baseGeneration: gen - 1,
        nextGeneration: gen,
        ops: [.insert(items: [item], at: host.committedItemCount)],
        preserve: VibeAnchorPreserve(mode: .pinToItem(id: anchorId, y: 12))
      )
      let result = host.tryApply(transaction: tx)
      if case .failure(let error) = result {
        return XCTFail("insert \(i) failed: \(error)")
      }
      XCTAssertLessThanOrEqual(host.instantiatedItemCount, 150)
      XCTAssertNotNil(
        host.item(forId: anchorId),
        "anchor must remain after overflow insert \(i)"
      )
    }

    XCTAssertEqual(host.instantiatedItemCount, 150)
    XCTAssertNotNil(host.item(forId: anchorId))
    // Nearest original neighbors should survive a center-preserving trim.
    XCTAssertNotNil(host.item(forId: neighborBefore))
    XCTAssertNotNil(host.item(forId: neighborAfter))
    guard let anchorIndex = host.index(ofId: anchorId) else {
      return XCTFail("anchor index missing")
    }
    XCTAssertGreaterThan(anchorIndex, 0, "anchor should not sit alone at the oldest edge")
    XCTAssertLessThan(
      anchorIndex,
      host.committedItemCount - 1,
      "anchor should not sit alone at the newest edge after mid pin"
    )
    XCTAssertEqual(host.viewportAnchor.itemId, anchorId)
    XCTAssertEqual(host.viewportAnchor.pin, .item)
  }

  // MARK: Settled geometry under content-only

  func testSettledContentOnlyKeepsGeometryOnHost() {
    let host = VibeTimelineReferenceHost(activeWindowCount: 150)
    let open = VibeTimelineReplayFixture().makeSnapshot(generation: 1, startIndex: 0, count: 150)
    _ = host.tryApply(snapshot: open, reason: .navigationPush)
    let target = open.items[5]
    let heightBefore = target.size.height
    let geoBefore = target.geometryRevision

    let painted = VibeRenderItem(
      identity: target.identity,
      orderKey: target.orderKey,
      kind: target.kind,
      contentRevision: target.contentRevision + 1,
      geometryRevision: target.geometryRevision,
      size: target.size,
      layout: target.layout,
      paint: VibePaintSpec(backgroundToken: "bubble.receipt"),
      mediaSlots: target.mediaSlots,
      interaction: target.interaction,
      flags: .settled
    )
    let tx = VibeListTransaction(
      baseGeneration: 1,
      nextGeneration: 2,
      ops: [.updateContent(id: target.identity.messageId, item: painted)]
    )
    if case .failure(let error) = host.tryApply(transaction: tx) {
      return XCTFail("unexpected content update failure \(error)")
    }
    let after = host.item(forId: target.identity.messageId)
    XCTAssertEqual(after?.size.height, heightBefore)
    XCTAssertEqual(after?.geometryRevision, geoBefore)
    XCTAssertEqual(after?.contentRevision, target.contentRevision + 1)
    XCTAssertEqual(host.debugGeometryMap()[target.identity.messageId], heightBefore)
  }

  func testMoveThenGeometryUpdateUsesFinalDestinationAndStaysAtomic() {
    let host = VibeTimelineReferenceHost(activeWindowCount: 150)
    let initial = [
      makeSettledItem(id: "a", rank: 10),
      makeSettledItem(id: "b", rank: 20),
      makeSettledItem(id: "c", rank: 30),
    ]
    let snapshot = VibeRenderSnapshot(
      chatId: TimelineTestIDs.chat,
      generation: 1,
      window: VibeTimelineWindowV1(
        chatId: TimelineTestIDs.chat,
        messageIds: initial.map(\.identity.messageId),
        anchors: initial.map(\.identity)
      ),
      items: initial,
      contentHeight: initial.reduce(0) { $0 + $1.size.height }
    )
    if case .failure(let error) = host.tryApply(snapshot: snapshot, reason: .debug) {
      return XCTFail("unexpected snapshot failure \(error)")
    }

    let moved = makeSettledItem(
      id: "c",
      rank: 5,
      size: CGSize(width: 360, height: 58),
      contentRevision: 2,
      geometryRevision: 2,
      flags: [.settled, .streaming]
    )
    let tx = VibeListTransaction(
      baseGeneration: 1,
      nextGeneration: 2,
      ops: [
        .move(id: "c", to: 0),
        .updateGeometry(id: "c", item: moved, deltaHeight: 10),
      ],
      preserve: VibeAnchorPreserve(mode: .pinToItem(id: "b", y: 8))
    )
    if case .failure(let error) = host.tryApply(transaction: tx) {
      return XCTFail("move+geometry transaction failed \(error)")
    }
    XCTAssertEqual(host.orderedIds, ["c", "a", "b"])
    XCTAssertEqual(host.item(forId: "c")?.size.height, 58)
    if case .failure(let error) = host.assertModelInvariants() {
      XCTFail("post-move invariant failure \(error)")
    }
  }

  // MARK: Prefetch cancel records only

  func testCancelPrefetchRecordsIdsWithoutSideEffects() {
    let host = VibeTimelineReferenceHost(activeWindowCount: 150)
    let open = VibeTimelineReplayFixture().makeSnapshot(generation: 1, startIndex: 0, count: 150)
    _ = host.tryApply(snapshot: open, reason: .navigationPush)
    let before = host.modelFingerprint()

    host.cancelPrefetch(outside: 10..<20)
    XCTAssertEqual(host.prefetchCancelRecords.count, 1)
    let record = host.prefetchCancelRecords[0]
    XCTAssertEqual(record.keptRange, 10..<20)
    XCTAssertEqual(record.cancelledIds.count, 150 - 10)
    XCTAssertFalse(record.cancelledIds.contains(open.items[15].identity.messageId))
    XCTAssertTrue(record.cancelledIds.contains(open.items[0].identity.messageId))
    XCTAssertEqual(host.modelFingerprint(), before, "cancelPrefetch must not mutate model")
  }

  // MARK: All scenarios + storms

  func testAllScenariosApplyWithPerStepInvariants() {
    for scenario in VibeTimelineReplayScenario.allCases {
      let run = runScenario(scenario, stormDurationSeconds: 1)
      XCTAssertGreaterThan(run.steps, 0, scenario.rawValue)
      XCTAssertLessThanOrEqual(run.host.instantiatedItemCount, run.host.activeWindowCount)
      XCTAssertGreaterThan(run.host.generation, 0)
      XCTAssertNil(run.host.lastFailure, scenario.rawValue)
    }
  }

  func testEventStorm20And50StayWithinActiveWindow() {
    for scenario in [VibeTimelineReplayScenario.eventStorm20, .eventStorm50] {
      let run = runScenario(scenario, activeWindowCount: 200, stormDurationSeconds: 1)
      let expectedSteps = scenario == .eventStorm20 ? 21 : 51
      XCTAssertEqual(run.steps, expectedSteps, scenario.rawValue)
      XCTAssertLessThanOrEqual(run.host.instantiatedItemCount, 200)
      XCTAssertEqual(run.host.successfulApplyCount, run.steps)
      XCTAssertEqual(run.host.failedApplyCount, 0)
    }
  }

  func testSameSeedProducesDeterministicFingerprint() {
    let scenarios: [VibeTimelineReplayScenario] = [
      .insertEditDeleteReceipt,
      .eventStorm20,
      .eventStorm50,
      .streamingClassifiedGeometry,
      .lateMediaContentOnly,
    ]
    for scenario in scenarios {
      let a = runScenario(scenario, seed: VibeTimelineReplaySeeds.board0802)
      let b = runScenario(scenario, seed: VibeTimelineReplaySeeds.board0802)
      XCTAssertEqual(
        a.fingerprint.token,
        b.fingerprint.token,
        "fingerprint mismatch for \(scenario.rawValue)"
      )
      XCTAssertEqual(a.fingerprint.orderedIds, b.fingerprint.orderedIds)
      XCTAssertEqual(a.fingerprint.generation, b.fingerprint.generation)
      XCTAssertEqual(a.fingerprint.heights, b.fingerprint.heights)
    }
  }

  func testDifferentSeedChangesStormFingerprint() {
    let a = runScenario(.eventStorm20, seed: VibeTimelineReplaySeeds.board0802)
    let b = runScenario(.eventStorm20, seed: VibeTimelineReplaySeeds.board0802 &+ 1)
    XCTAssertNotEqual(
      a.fingerprint.token,
      b.fingerprint.token,
      "distinct seeds should diverge under RNG-driven storms"
    )
  }

  func testMetricsReflectBoundedCommittedModel() {
    let host = VibeTimelineReferenceHost(activeWindowCount: 200)
    let harness = makeHarness(activeWindowCount: 200, stormDurationSeconds: 1)
    let steps = harness.steps(for: .eventStorm20)
    for step in steps {
      applyStep(step, to: host)
    }
    XCTAssertEqual(host.lastAppliedGeneration, host.generation)
    XCTAssertEqual(host.instantiatedItemCount, host.committedItemCount)
    XCTAssertEqual(host.instantiatedItemCount, host.orderedIds.count)
    XCTAssertLessThanOrEqual(host.instantiatedItemCount, 200)
    XCTAssertEqual(host.visibleAnchors().map(\.messageId), host.orderedIds)
    let geo = host.debugGeometryMap()
    for id in host.orderedIds {
      XCTAssertNotNil(geo[id])
    }
  }
}
