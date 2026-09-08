import Foundation
import UIKit
import XCTest

@testable import Vibe

/// The transcript that is measured **before** the push.
///
/// What is worth testing here is not the heights — those come from
/// `measureMessageBubbleLayout`, the same function the cell calls, so agreement is
/// identity and there is nothing to keep in sync. What is worth testing is every way a
/// prepared height could be handed out when it should not be, because each of those is a
/// wrong height rather than a missing one, and a wrong height is the shift:
///
///   1. measured at one width, read at another
///   2. measured from a row that has since changed
///   3. measured before the media aspect was known
///   4. an agent turn silently getting *some* number instead of being deferred
///
/// (2) is the one that would look fine in every screenshot and be wrong on the device.
final class VibeTimelinePreparedStoreTests: XCTestCase {

  private let store = VibeTimelinePreparedStore.shared
  private let width: CGFloat = 424  // 440pt bounds − messageHorizontalInset * 2

  override func setUp() {
    super.setUp()
    store.resetForTesting()
  }

  override func tearDown() {
    store.resetForTesting()
    super.tearDown()
  }

  // MARK: Fixtures

  private func textRow(
    _ text: String, key: String = UUID().uuidString, isMe: Bool = false
  ) -> ChatListRow {
    ChatListRow(raw: rawTextRow(text, key: key, isMe: isMe))!
  }

  private func rawTextRow(
    _ text: String, key: String = UUID().uuidString, isMe: Bool = false
  ) -> [String: Any] {
    [
      "kind": "message",
      "key": key,
      "message": [
        "id": key,
        "text": text,
        "timestamp": "22:20",
        "isMe": isMe,
        "type": "text",
      ],
    ]
  }

  private func agentTurnRow(key: String = UUID().uuidString) -> ChatListRow {
    ChatListRow(raw: [
      "kind": "message",
      "key": key,
      "message": [
        "id": key,
        "text": "Looked at three files and changed one.",
        "timestamp": "22:20",
        "isMe": false,
        "type": "agent_progress_tree",
        "isAgentMessage": true,
        "agentName": "Claude",
      ],
    ])!
  }

  // MARK: Preparing

  func testAPreparedHeightIsTheRowsOwnMeasurement() {
    store.setMeasurementWidth(width)
    let row = textRow("the quick brown fox jumps over the lazy dog, repeatedly and at length")
    let prepared = store.prepareNow(
      chatId: "c1", rows: [row], width: width, reason: "test")

    let expected = VibeRowMetrics.height(row: row, rowWidth: width)
    XCTAssertNotNil(expected)
    XCTAssertEqual(prepared?.heightsByKey[row.key]?.height, expected)
  }

  func testPreparingWithoutAWidthDoesNothing() {
    // Nothing has published a width yet — the cold-launch case. Measuring against a
    // guess and correcting on mount is the shift, so there is no answer to give.
    let row = textRow("hello")
    store.prepareAsync(chatId: "c1", rows: [row], reason: "test", scope: .fullTranscript)
    XCTAssertNil(store.prepared(chatId: "c1", width: width))
  }

  func testAWidthChangeDropsEveryPreparedTranscript() {
    store.setMeasurementWidth(width)
    let row = textRow("hello")
    store.prepareNow(chatId: "c1", rows: [row], width: width, reason: "test")
    XCTAssertNotNil(store.prepared(chatId: "c1", width: width))

    store.setMeasurementWidth(width - 60)
    XCTAssertNil(
      store.prepared(chatId: "c1", width: width),
      "heights measured at another width are not stale, they are wrong")
  }

  func testAHeightMeasuredAtOneWidthIsNeverHandedOutAtAnother() {
    store.setMeasurementWidth(width)
    let row = textRow("hello")
    store.prepareNow(chatId: "c1", rows: [row], width: width, reason: "test")
    XCTAssertNil(store.preparedRow(chatId: "c1", key: row.key, width: width - 40))
    XCTAssertNotNil(store.preparedRow(chatId: "c1", key: row.key, width: width))
  }

  func testThePreparedRowComesBackSoAStaleHeightCanBeRejected() {
    store.setMeasurementWidth(width)
    let key = "m-edited"
    let original = textRow("before", key: key)
    store.prepareNow(chatId: "c1", rows: [original], width: width, reason: "test")

    // The same key, different content — an edit, a status change, a lost tail. The
    // height is different and the store cannot know that; the caller compares.
    let edited = textRow(
      "after, and considerably longer than it used to be so the bubble wraps onto more "
        + "than one line and the height genuinely differs", key: key)
    guard let hit = store.preparedRow(chatId: "c1", key: key, width: width) else {
      return XCTFail("expected a prepared entry to be returned for comparison")
    }
    XCTAssertFalse(
      chatListRowContentEqual(hit.row, edited),
      "the caller must be able to see that this height was measured from another row")
    XCTAssertNotEqual(
      hit.measured.height, VibeRowMetrics.height(row: edited, rowWidth: width),
      "fixture no longer models a height-changing edit")
  }

  func testAnAgentTurnIsDeferredRatherThanGivenANumber() {
    store.setMeasurementWidth(width)
    let text = textRow("ordinary")
    let agent = agentTurnRow()
    let prepared = store.prepareNow(
      chatId: "c1", rows: [text, agent], width: width, reason: "test")

    XCTAssertNotNil(prepared?.heightsByKey[text.key])
    XCTAssertNil(
      prepared?.heightsByKey[agent.key],
      "an agent turn needs a live view to measure; a number here would be invented")
    XCTAssertEqual(prepared?.deferredKeys, [agent.key])
    XCTAssertEqual(
      prepared?.orderedKeys, [text.key, agent.key],
      "a deferred row still occupies its place in the transcript")
  }

  func testRawRowsAreParsedIntoTheSameAnswerAsParsedOnes() {
    store.setMeasurementWidth(width)
    let key = "m-parity"
    let raw = rawTextRow("parity between the engine feed and the list feed", key: key)
    let parsed = ChatListRow(raw: raw)!

    let fromRaw = store.prepareNow(chatId: "raw", rawRows: [raw], width: width, reason: "test")
    let fromParsed = store.prepareNow(
      chatId: "parsed", rows: [parsed], width: width, reason: "test")

    XCTAssertNotNil(fromRaw?.heightsByKey[key])
    XCTAssertEqual(fromRaw?.heightsByKey[key], fromParsed?.heightsByKey[key])
  }

  // MARK: Bounds

  func testOnlyTheNewestRowsAreKeptWhenATranscriptIsLongerThanTheWindow() {
    store.setMeasurementWidth(width)
    // 260 > the 200-row cap. A chat opens on its newest rows, so those are the ones
    // whose heights are worth having ready.
    let rows = (0..<260).map { textRow("row \($0)", key: "k\($0)") }
    // Synchronous on purpose: the cap belongs to the measurement, not to the queue hop,
    // and a test that waited on a timer would pass or fail with the simulator's mood.
    store.prepareNow(chatId: "c1", rows: rows, width: width, reason: "test")

    guard let prepared = store.prepared(chatId: "c1", width: width) else {
      return XCTFail("expected the bounded transcript to be prepared")
    }
    XCTAssertEqual(prepared.orderedKeys.count, 200)
    XCTAssertEqual(prepared.orderedKeys.last, "k259")
    XCTAssertNil(store.preparedRow(chatId: "c1", key: "k0", width: width))
    XCTAssertNotNil(store.preparedRow(chatId: "c1", key: "k259", width: width))
  }

  func testTheOldestChatIsEvictedRatherThanGrowingWithoutBound() {
    store.setMeasurementWidth(width)
    // Nine chats against a cap of eight.
    for index in 0..<9 {
      store.prepareNow(
        chatId: "chat\(index)", rows: [textRow("hello", key: "k\(index)")], width: width,
        reason: "test")
    }
    XCTAssertNil(store.prepared(chatId: "chat0", width: width), "the least recent should go")
    XCTAssertNotNil(store.prepared(chatId: "chat8", width: width))
  }

  func testInvalidatingAChatForgetsIt() {
    store.setMeasurementWidth(width)
    let row = textRow("hello")
    store.prepareNow(chatId: "c1", rows: [row], width: width, reason: "test")
    store.invalidate(chatId: "c1")
    XCTAssertNil(store.prepared(chatId: "c1", width: width))
  }

  // MARK: Counters

  func testHitsAndMissesAreCountedByTheCallerNotTheLookup() {
    store.setMeasurementWidth(width)
    let row = textRow("hello")
    store.prepareNow(chatId: "c1", rows: [row], width: width, reason: "test")

    // A lookup alone is not a hit — the caller may still reject it on content, and a
    // rejected lookup that counted as a hit would make the liveness line lie in the
    // one direction nobody would investigate.
    _ = store.preparedRow(chatId: "c1", key: row.key, width: width)
    XCTAssertEqual(store.stats.hits, 0)
    XCTAssertEqual(store.stats.misses, 0)

    store.noteHit(true)
    store.noteHit(false)
    XCTAssertEqual(store.stats.hits, 1)
    XCTAssertEqual(store.stats.misses, 1)
  }

  func testConcurrentPreparesAndReadsStayConsistent() {
    store.setMeasurementWidth(width)
    let rows = (0..<40).map { textRow("row \($0)", key: "k\($0)") }
    let done = expectation(description: "concurrent")
    done.expectedFulfillmentCount = 16

    for worker in 0..<16 {
      DispatchQueue.global().async { [store, width] in
        if worker.isMultiple(of: 2) {
          store.prepareNow(
            chatId: "chat\(worker % 4)", rows: rows, width: width, reason: "test")
        } else {
          _ = store.preparedRow(chatId: "chat\(worker % 4)", key: "k7", width: width)
          _ = store.stats
        }
        done.fulfill()
      }
    }
    wait(for: [done], timeout: 10)

    // The real assertion is that this did not trap or produce a torn read; the height
    // is checked so a silently-empty store cannot pass.
    guard let hit = store.preparedRow(chatId: "chat0", key: "k7", width: width) else {
      return XCTFail("expected chat0 to be prepared after the concurrent run")
    }
    XCTAssertEqual(hit.measured.height, VibeRowMetrics.height(row: rows[7], rowWidth: width))
  }
}
