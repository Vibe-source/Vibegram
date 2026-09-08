import CoreGraphics
import UIKit
import XCTest

@testable import Vibe

/// Tests for the P4 render path — the adapter, the measurement cache, and the
/// `UICollectionView` host.
///
/// Every property asserted here was first observed on a physical device, and
/// several of them were observed *failing*. Manual verification found them; only
/// a test keeps them found. The frozen-geometry rule in particular is enforced by
/// the shape of the code today, and this is what notices if that shape changes.
@MainActor
final class VibeTimelineHostTests: XCTestCase {

  // MARK: Fixtures

  private func message(
    id: String,
    tsMs: Int64 = 1_000,
    text: String = "hello",
    isMe: Bool = true,
    contentHash: UInt64 = 1,
    hasMedia: Bool = false,
    hasReply: Bool = false,
    flags: UInt32 = 0
  ) -> VibeFfiMessage {
    VibeFfiMessage(
      messageId: id,
      clientMessageId: nil,
      tsMs: tsMs,
      orderSeq: 0,
      authorUserId: isMe ? "me" : "peer",
      authorIsMe: isMe,
      authorAgentProvider: nil,
      kind: .text,
      text: text,
      caption: nil,
      flags: flags,
      displayStatus: .sent,
      uploadFraction: nil,
      deliveryFailed: false,
      contentHash: contentHash,
      hasMedia: hasMedia,
      hasReply: hasReply,
      hasAgent: false,
      hasService: false,
      isEdited: false,
      // The detail payloads the core grew after this fixture was written. Left nil
      // on purpose: every test in this file is about *geometry* — how a row is
      // measured, frozen and re-measured — and the measure path reads the `has*`
      // booleans above, never these. A fixture that filled them in would be
      // asserting against data the code under test does not consult.
      media: nil,
      reply: nil,
      agent: nil,
      service: nil,
      editedAtMs: nil,
      reactions: [],
      viewCount: nil
    )
  }

  private func makeCache(width: CGFloat = 390) -> VibeRowMeasurementCache {
    let cache = VibeRowMeasurementCache()
    cache.setEnvironment(width: width, contentSizeCategory: .large, themeEpoch: 0)
    return cache
  }

  // MARK: Sizing a real conversation

  private func chatRow(_ id: String, text: String) -> ChatListRow {
    ChatListRow(raw: [
      "kind": "message",
      "key": id,
      "message": [
        "id": id, "text": text, "timestamp": "22:20", "isMe": false, "type": "text",
      ],
    ])!
  }

  func testWithoutAProviderRowsAreSizedByThePlaceholderAndSaySo() {
    // The preview has no parsed rows and legitimately uses the placeholder. What must
    // never happen quietly is a *real* chat doing it, so the count is the alarm.
    let cache = makeCache()
    _ = cache.settledGeometry(for: message(id: "m1", text: "hello"))
    XCTAssertEqual(cache.placeholderMeasurements, 1)
  }

  func testAProvidedRowIsSizedByTheListsOwnMeasurement() {
    // The core drawing `ChatListCell` into a slot sized by the placeholder is the same
    // measured-one-thing-drew-another defect it exists to remove, one layer down.
    let cache = makeCache(width: 390)
    let text = String(repeating: "a body long enough to wrap several times over. ", count: 4)
    let row = chatRow("m1", text: text)
    cache.rowProvider = { id in id == "m1" ? row : nil }

    let measured = cache.settledGeometry(for: message(id: "m1", text: text))

    XCTAssertEqual(cache.placeholderMeasurements, 0)
    XCTAssertEqual(
      measured.size.height,
      VibeRowMetrics.mainThreadHeight(row: row, rowWidth: 390).map { ceil($0) })
  }

  func testAProvidedRowAndThePlaceholderDisagree() {
    // If these ever matched, the test above would be proving nothing.
    let text = String(repeating: "wrapping body text with real bubble chrome. ", count: 6)
    let row = chatRow("m1", text: text)
    let withProvider = makeCache(width: 390)
    withProvider.rowProvider = { _ in row }
    let real = withProvider.settledGeometry(for: message(id: "m1", text: text)).size.height

    let placeholder = makeCache(width: 390)
      .settledGeometry(for: message(id: "m1", text: text)).size.height

    XCTAssertNotEqual(real, placeholder)
  }

  func testAMissingRowFallsBackRatherThanDroppingTheMessage() {
    // A provider that answers nil for an id still in the window must leave a
    // correctly-ordered, positively-sized gap. A zero-height item is rejected by the
    // validator, which would drop the row entirely.
    let cache = makeCache()
    cache.rowProvider = { _ in nil }
    let measured = cache.settledGeometry(for: message(id: "ghost", text: "hello"))
    XCTAssertGreaterThan(measured.size.height, 0)
    XCTAssertEqual(cache.placeholderMeasurements, 1)
  }

  func testProvidedRowsStillFreezeAfterTheFirstMeasurement() {
    // The freeze is the whole mechanism, and it must not be an artefact of the
    // placeholder being cheap.
    let cache = makeCache()
    let row = chatRow("m1", text: "some body text")
    cache.rowProvider = { _ in row }
    let m = message(id: "m1", text: "some body text")

    let first = cache.settledGeometry(for: m)
    for _ in 0..<20 { _ = cache.settledGeometry(for: m) }

    XCTAssertEqual(cache.measurements, 1)
    XCTAssertEqual(cache.reuses, 20)
    XCTAssertEqual(cache.settledGeometry(for: m).size, first.size)
  }

  // MARK: Frozen geometry

  func testASettledRowIsMeasuredExactlyOnce() {
    let cache = makeCache()
    let m = message(id: "m1", text: "a body long enough to wrap onto more than one line, easily")

    let first = cache.settledGeometry(for: m)
    for _ in 0..<50 { _ = cache.settledGeometry(for: m) }

    XCTAssertEqual(cache.measurements, 1)
    XCTAssertEqual(cache.reuses, 50)
    XCTAssertEqual(cache.settledGeometry(for: m).size, first.size)
  }

  func testAContentOnlyUpdateReusesTheFrozenSize() {
    // The month-long bug in one assertion: a receipt, a delivery status, an
    // upload tick — none of them may move a bubble that is already on screen.
    let cache = makeCache()
    let factory = VibeRenderItemFactory(cache: cache)
    let settled = factory.settledItem(message(id: "m1", text: "original body text here"))

    // Same id, different content hash and a *much* longer body. If the content
    // path measured at all, this would be taller.
    let updated = factory.contentUpdatedItem(
      message(
        id: "m1",
        text: String(repeating: "considerably more text than before. ", count: 20),
        contentHash: 99))

    XCTAssertEqual(updated.size, settled.size, "a content-only op re-measured the row")
    XCTAssertEqual(updated.geometryRevision, settled.geometryRevision)
    XCTAssertNotEqual(updated.contentRevision, settled.contentRevision)
    XCTAssertEqual(cache.measurements, 1)
  }

  func testAGeometryUpdateIsAllowedToChangeHeightAndBumpsTheRevision() {
    let cache = makeCache()
    let factory = VibeRenderItemFactory(cache: cache)
    let settled = factory.settledItem(message(id: "m1", text: "short"))

    let (grown, delta) = factory.geometryUpdatedItem(
      message(id: "m1", text: String(repeating: "much longer body. ", count: 30)))

    XCTAssertGreaterThan(grown.size.height, settled.size.height)
    XCTAssertGreaterThan(delta, 0)
    XCTAssertEqual(grown.geometryRevision, settled.geometryRevision + 1)
  }

  func testAWidthChangeInvalidatesEveryMeasurement() {
    let cache = makeCache(width: 390)
    let m = message(id: "m1", text: String(repeating: "wrapping body ", count: 10))
    let narrow = cache.settledGeometry(for: m)

    XCTAssertTrue(cache.setEnvironment(width: 600, contentSizeCategory: .large, themeEpoch: 0))
    let wide = cache.settledGeometry(for: m)

    XCTAssertLessThan(wide.size.height, narrow.size.height, "wider should wrap less")
    XCTAssertEqual(cache.invalidations, 2, "construction plus the width change")
  }

  func testAnUnchangedEnvironmentDoesNotInvalidate() {
    let cache = makeCache(width: 390)
    XCTAssertFalse(cache.setEnvironment(width: 390, contentSizeCategory: .large, themeEpoch: 0))
  }

  func testMediaWithoutANaturalSizeReservesAStableBoxRatherThanGuessingSquare() {
    // Guess-square-then-correct is the media list-shift bug. A reservation that
    // is merely wrong never moves; a guess that gets corrected moves everything
    // below it.
    let cache = makeCache(width: 390)
    let m = message(id: "m1", text: "", hasMedia: true)
    let first = cache.settledGeometry(for: m)
    let second = cache.settledGeometry(for: m)
    XCTAssertEqual(first.size, second.size)
    XCTAssertNotEqual(first.layout.mediaBoxFrame.height, first.layout.mediaBoxFrame.width)
  }

  // MARK: Order keys

  func testOrderKeysSortByTimestampThenMessageId() {
    let a = VibeTimelineOrderKeyFactory.key(tsMs: 1_000, messageId: "b")
    let b = VibeTimelineOrderKeyFactory.key(tsMs: 2_000, messageId: "a")
    XCTAssertLessThan(a, b, "timestamp must dominate the id")

    let sameTsEarlier = VibeTimelineOrderKeyFactory.key(tsMs: 1_000, messageId: "aaa")
    let sameTsLater = VibeTimelineOrderKeyFactory.key(tsMs: 1_000, messageId: "aab")
    XCTAssertLessThan(sameTsEarlier, sameTsLater, "same ms must fall back to id ASC")
  }

  func testOrderKeysHandleNegativeTimestampsWithoutWrapping() {
    // `UInt64(bitPattern:)` alone would sort every pre-1970 timestamp above
    // everything else. The sign-bit flip is what stops that.
    let past = VibeTimelineOrderKeyFactory.key(tsMs: -5_000, messageId: "a")
    let epoch = VibeTimelineOrderKeyFactory.key(tsMs: 0, messageId: "a")
    let future = VibeTimelineOrderKeyFactory.key(tsMs: 5_000, messageId: "a")
    XCTAssertLessThan(past, epoch)
    XCTAssertLessThan(epoch, future)
  }

  func testShortMessageIdsAreZeroPaddedSoPrefixesOrderCorrectly() {
    let short = VibeTimelineOrderKeyFactory.key(tsMs: 1_000, messageId: "p1")
    let longer = VibeTimelineOrderKeyFactory.key(tsMs: 1_000, messageId: "p10")
    XCTAssertLessThan(short, longer)
  }

  // MARK: List host — generation fencing

  private func makeHost(width: CGFloat = 390, height: CGFloat = 600)
    -> VibeCollectionMessageListHost
  {
    let host = VibeCollectionMessageListHost()
    host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
    host.view.layoutIfNeeded()
    return host
  }

  private func snapshot(generation: UInt64, items: [VibeRenderItem]) -> VibeRenderSnapshot {
    VibeRenderSnapshot(
      chatId: "c1",
      generation: generation,
      window: VibeTimelineWindowV1(
        chatId: "c1",
        messageIds: items.map(\.identity.messageId),
        anchors: items.map(\.identity)),
      items: items,
      contentHeight: items.reduce(0) { $0 + $1.size.height }
    )
  }

  private func item(_ id: String, rank: UInt64, height: CGFloat = 50) -> VibeRenderItem {
    VibeRenderItem(
      identity: VibeTimelineAnchor(messageId: id),
      orderKey: VibeOrderKey(rank: rank),
      size: CGSize(width: 300, height: height),
      flags: .settled
    )
  }

  func testATransactionAgainstTheWrongGenerationIsRejected() {
    let host = makeHost()
    host.apply(snapshot: snapshot(generation: 10, items: [item("a", rank: 1)]), reason: .debug)

    host.apply(
      transaction: VibeListTransaction(
        baseGeneration: 7, nextGeneration: 11, ops: [.insert(items: [item("b", rank: 2)], at: 1)]))

    XCTAssertEqual(host.rejectedTransactions, 1)
    XCTAssertEqual(host.debugGeometryMap().count, 1, "the stale op must not have landed")
  }

  func testDetachFromEngineClearsTheFenceSoAFreshEngineIsNotRejected() {
    // Observed on device: after Reset, a new core starts at generation 0 while
    // the long-lived host still held 8610, and every transaction from the
    // replacement was fenced off as stale.
    let host = makeHost()
    host.apply(snapshot: snapshot(generation: 8_610, items: [item("a", rank: 1)]), reason: .debug)

    host.detachFromEngine()
    XCTAssertEqual(host.debugGeometryMap().count, 0)

    host.apply(
      transaction: VibeListTransaction(
        baseGeneration: 0, nextGeneration: 1, ops: [.insert(items: [item("z", rank: 1)], at: 0)]))

    XCTAssertEqual(host.rejectedTransactions, 0, "a fresh engine was fenced against a dead one")
    XCTAssertEqual(host.debugGeometryMap().count, 1)
  }

  func testDetachDoesNotResetTheViolationCounters() {
    // These are session-long qualification measurements. Zeroing them on a chat
    // switch would let a real regression hide behind ordinary navigation.
    let host = makeHost()
    host.apply(snapshot: snapshot(generation: 5, items: [item("a", rank: 1)]), reason: .debug)
    host.apply(
      transaction: VibeListTransaction(
        baseGeneration: 99, nextGeneration: 100, ops: [.remove(ids: ["a"])]))
    XCTAssertEqual(host.rejectedTransactions, 1)

    host.detachFromEngine()
    XCTAssertEqual(host.rejectedTransactions, 1)
  }

  // MARK: List host — settled geometry and anchors

  func testAContentOpThatChangesHeightIsCountedAsAViolation() {
    let host = makeHost()
    host.apply(snapshot: snapshot(generation: 1, items: [item("a", rank: 1, height: 50)]),
               reason: .debug)

    // Deliberately malformed: a content op carrying a different height. The
    // adapter cannot produce this, and this is what notices if it starts to.
    host.apply(
      transaction: VibeListTransaction(
        baseGeneration: 1, nextGeneration: 2,
        ops: [.updateContent(id: "a", item: item("a", rank: 1, height: 80))]))

    XCTAssertEqual(host.settledGeometryViolations, 1)
  }

  func testInsertingAboveTheViewportDoesNotMoveWhatTheUserIsLookingAt() {
    // §5.4 "insert above viewport": the content on screen must not shift.
    let host = makeHost(height: 300)
    let initial = (0..<40).map { item("m\($0)", rank: UInt64($0 + 1), height: 50) }
    host.apply(snapshot: snapshot(generation: 1, items: initial), reason: .debug)

    // Park in the middle, well away from the bottom pin.
    let scrollView = host.view as! UIScrollView
    scrollView.contentOffset.y = 800
    host.view.layoutIfNeeded()
    let anchors = host.visibleAnchors()
    XCTAssertFalse(anchors.isEmpty, "nothing visible — the test cannot measure a shift")

    host.apply(
      transaction: VibeListTransaction(
        baseGeneration: 1, nextGeneration: 2,
        ops: [.insert(items: [item("older", rank: 0, height: 120)], at: 0)],
        preserve: .pinToBottom))

    XCTAssertEqual(host.anchorDriftViolations, 0, "the viewport moved on a history insert")
    XCTAssertEqual(
      scrollView.contentOffset.y, 920, accuracy: 0.5,
      "offset must absorb the inserted height exactly")
  }

  func testWindowTrimAboveTheViewportAlsoPreservesTheAnchor() {
    // Head eviction removes rows *above* the viewport. Not compensating scrolls
    // the user's content out from under them.
    let host = makeHost(height: 300)
    let initial = (0..<40).map { item("m\($0)", rank: UInt64($0 + 1), height: 50) }
    host.apply(snapshot: snapshot(generation: 1, items: initial), reason: .debug)

    let scrollView = host.view as! UIScrollView
    scrollView.contentOffset.y = 800
    host.view.layoutIfNeeded()

    host.apply(
      transaction: VibeListTransaction(
        baseGeneration: 1, nextGeneration: 2,
        ops: [.remove(ids: ["m0", "m1", "m2"])],
        preserve: .pinToBottom))

    XCTAssertEqual(host.anchorDriftViolations, 0)
    XCTAssertEqual(scrollView.contentOffset.y, 650, accuracy: 0.5, "3 × 50 pt removed above")
  }

  func testAViewerAtTheBottomFollowsNewTraffic() {
    let host = makeHost(height: 300)
    let initial = (0..<10).map { item("m\($0)", rank: UInt64($0 + 1), height: 50) }
    host.apply(snapshot: snapshot(generation: 1, items: initial), reason: .debug)
    let scrollView = host.view as! UIScrollView
    let bottomBefore = scrollView.contentOffset.y

    host.apply(
      transaction: VibeListTransaction(
        baseGeneration: 1, nextGeneration: 2,
        ops: [.insert(items: [item("new", rank: 99, height: 50)], at: 10)],
        preserve: .pinToBottom))

    XCTAssertEqual(scrollView.contentOffset.y, bottomBefore + 50, accuracy: 0.5)
    XCTAssertEqual(host.anchorDriftViolations, 0, "following live traffic is not a jump")
  }

  /// The debug default is deliberate, and only covers the harmless gate.
  ///
  /// Shadow comparison arms itself in debug so real-conversation divergence data
  /// accumulates without anyone remembering a switch. The async host must not:
  /// it changes what the user sees, and "it was on in debug" is not a rollout.
  func testDebugArmsShadowComparisonButNeverTheAsyncHost() {
    let defaults = UserDefaults(suiteName: "shadow-default-\(UUID().uuidString)")!
    let flags = VibeTimelineUserDefaultsFeatureFlags(defaults: defaults).flags

    XCTAssertFalse(
      flags.vibeAsyncTimelineV1Enabled, "the render-path gate must never default on")

    // The render allowlist stays empty in every configuration. This is the
    // assertion that keeps the two gates independent: an earlier version of this
    // change armed shadow comparison by defaulting the SHARED allowlist to DM,
    // which would have made the async host go live for DMs the instant anyone
    // enabled its flag. Two risks, two lists.
    XCTAssertEqual(
      flags.eligibleChatClasses.rawValue, 0,
      "arming the diagnostic must not widen the render rollout")
    XCTAssertFalse(flags.isAsyncTimelineEnabled(for: .directMessage))

    #if DEBUG
      XCTAssertTrue(flags.vibeTimelineShadowCompareEnabled)
      XCTAssertTrue(flags.shadowEligibleChatClasses.contains(.directMessage))
      // Armed for DMs and nothing else — P4 covers 1:1 only.
      XCTAssertFalse(flags.shadowEligibleChatClasses.contains(.group))
      XCTAssertFalse(flags.shadowEligibleChatClasses.contains(.channel))
    #else
      XCTAssertFalse(flags.vibeTimelineShadowCompareEnabled)
      XCTAssertEqual(flags.shadowEligibleChatClasses.rawValue, 0)
    #endif

    // An explicit write still wins in both directions.
    defaults.set(false, forKey: VibeTimelineUserDefaultsFeatureFlags.shadowCompareKey)
    XCTAssertFalse(
      VibeTimelineUserDefaultsFeatureFlags(defaults: defaults).flags
        .vibeTimelineShadowCompareEnabled,
      "turning it off in Diagnostics must survive the debug default")
  }

}
