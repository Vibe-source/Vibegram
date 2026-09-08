import Foundation
import XCTest

@testable import Vibe

/// Tests for P3 — message bodies sealed at rest in `ChatMessageStore`.
///
/// These run against the real store, the real SQLite file, and the real Keychain
/// key, because every interesting failure lives in exactly those seams: the
/// column migration, the NULL-nonce legacy signal, and the associated-data bind.
/// A mock would assert that the mock works.
///
/// The assertion that matters most is ``testTheDatabaseFileHoldsNoPlaintext``.
/// Everything else could pass while the store quietly wrote cleartext — a
/// round-trip test cannot tell sealing from a no-op, because a no-op round-trips
/// perfectly.
final class ChatMessageStoreSealTests: XCTestCase {

  private let userId = "seal-tests-user"
  private let chatId = "seal-tests-chat"
  private var store: ChatMessageStore!
  private var container: URL!

  override func setUp() {
    super.setUp()
    // A private directory per test. The production initialiser opens the user's
    // real `messages.db`; running these against it would write fixture rows into
    // someone's actual conversations and scan the whole thing looking for a
    // canary.
    container = FileManager.default.temporaryDirectory
      .appendingPathComponent("seal-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    store = ChatMessageStore(containerDirectory: container)
  }

  override func tearDown() {
    store = nil
    if let container { try? FileManager.default.removeItem(at: container) }
    container = nil
    super.tearDown()
  }

  // MARK: Helpers

  private func body(_ text: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["id": "x", "content": text])
  }

  private func text(of payload: Data) -> String? {
    ((try? JSONSerialization.jsonObject(with: payload)) as? [String: Any])?["content"] as? String
  }

  private var databaseURL: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("VibeChatStore", isDirectory: true)
      .appendingPathComponent("messages.db")
  }

  // MARK: Round trip

  func testASealedMessageReadsBackAsItself() throws {
    try XCTSkipIf(!store.isAvailable, "store unavailable on this host")
    store.upsertMessages(
      userId: userId, chatId: chatId,
      entries: [("m1", 1_000, body("hello sealed world"))])

    let restored = store.recentMessagePayloads(userId: userId, chatId: chatId, limit: 10)
    XCTAssertEqual(restored.count, 1)
    XCTAssertEqual(text(of: restored[0]), "hello sealed world")
  }

  func testTranscriptOrderSurvivesSealing() throws {
    try XCTSkipIf(!store.isAvailable, "store unavailable on this host")
    // Inserted out of order on purpose — sealing must not touch `ts`, which is
    // the column the transcript order is built from.
    store.upsertMessages(
      userId: userId, chatId: chatId,
      entries: [
        ("m3", 3_000, body("third")),
        ("m1", 1_000, body("first")),
        ("m2", 2_000, body("second")),
      ])

    let restored = store.recentMessagePayloads(userId: userId, chatId: chatId, limit: 10)
    XCTAssertEqual(restored.compactMap(text(of:)), ["first", "second", "third"])
  }

  /// The one that can tell sealing apart from a no-op.
  func testTheDatabaseFileHoldsNoPlaintext() throws {
    try XCTSkipIf(!store.isAvailable, "store unavailable on this host")
    try XCTSkipIf(
      VibeCoreBridge.makeSealer() == nil, "no store key — plaintext fallback is expected")

    // Distinctive enough that finding it in the file cannot be a coincidence.
    let secret = "PLAINTEXT-CANARY-\(UUID().uuidString)"
    store.upsertMessages(
      userId: userId, chatId: chatId, entries: [("m1", 1_000, body(secret))])

    // WAL mode: the row may still be in the write-ahead log rather than the main
    // database file, so both are searched. Checking only `messages.db` would let
    // a plaintext write pass unnoticed.
    guard let dbURL = databaseURL else { return XCTFail("no store path") }
    let candidates = [
      dbURL,
      dbURL.deletingLastPathComponent().appendingPathComponent("messages.db-wal"),
    ]
    let needle = Data(secret.utf8)
    for url in candidates {
      guard let bytes = try? Data(contentsOf: url) else { continue }
      XCTAssertNil(
        bytes.range(of: needle),
        "found the message body in cleartext inside \(url.lastPathComponent)")
    }
  }

  // MARK: Binding

  func testASealedRowDoesNotOpenUnderAnotherChat() throws {
    try XCTSkipIf(!store.isAvailable, "store unavailable on this host")
    try XCTSkipIf(VibeCoreBridge.makeSealer() == nil, "no store key")

    store.upsertMessages(
      userId: userId, chatId: chatId, entries: [("m1", 1_000, body("bound to this chat"))])

    // The seal binds (user, chat, message). A read addressed to a different chat
    // must return nothing rather than another conversation's message — this is
    // the property that stops a mis-restored database rendering one chat inside
    // another, and it is worth an explicit test because the query alone would
    // also return nothing, for a completely different reason.
    let elsewhere = store.recentMessagePayloads(
      userId: userId, chatId: "some-other-chat", limit: 10)
    XCTAssertTrue(elsewhere.isEmpty)

    // Same row, addressed correctly, still opens.
    XCTAssertEqual(
      store.recentMessagePayloads(userId: userId, chatId: chatId, limit: 10).count, 1)
  }

  // MARK: Paging

  func testOlderPayloadsOpenOnTheScrollBackPath() throws {
    try XCTSkipIf(!store.isAvailable, "store unavailable on this host")
    store.upsertMessages(
      userId: userId, chatId: chatId,
      entries: (1...5).map { ("m\($0)", Int64($0) * 1_000, body("body \($0)")) })

    // Scroll-back reads through a different SQL statement than the initial
    // restore. Both must open sealed rows, or history is readable at the bottom
    // and blank the moment the user scrolls up.
    let older = store.olderMessagePayloads(
      userId: userId, chatId: chatId, beforeTs: 4_000, beforeMessageId: "m4", limit: 10)
    XCTAssertEqual(older.compactMap(text(of:)), ["body 1", "body 2", "body 3"])
  }

  // MARK: Accounting

  func testTheSummaryReportsWhatActuallyHappened() throws {
    try XCTSkipIf(!store.isAvailable, "store unavailable on this host")
    store.upsertMessages(
      userId: userId, chatId: chatId,
      entries: [("m1", 1_000, body("a")), ("m2", 2_000, body("b"))])
    _ = store.recentMessagePayloads(userId: userId, chatId: chatId, limit: 10)

    XCTAssertEqual(store.openFailures, 0, "a row written by this store failed to reopen")
    if VibeCoreBridge.makeSealer() == nil {
      XCTAssertEqual(store.plaintextWrites, 2)
      XCTAssertEqual(store.sealedWrites, 0)
    } else {
      XCTAssertEqual(store.sealedWrites, 2)
      XCTAssertEqual(store.plaintextWrites, 0)
      XCTAssertEqual(store.sealedReads, 2)
    }
    XCTAssertEqual(store.sealFailures, 0)
  }

  // MARK: Legacy rows

  func testALegacyPlaintextRowIsReadableAndThenGetsSealed() throws {
    try XCTSkipIf(!store.isAvailable, "store unavailable on this host")
    try XCTSkipIf(VibeCoreBridge.makeSealer() == nil, "no store key")

    // Simulate a row written before sealing existed: `seal_nonce` NULL, `payload`
    // cleartext. Every user upgrading into this build has a database full of
    // these, so "unreadable" here means "their history disappears".
    let legacy = body("written before sealing")
    XCTAssertTrue(
      store.debugInsertLegacyPlaintextRow(
        userId: userId, chatId: chatId, messageId: "old1", ts: 500, payload: legacy))

    let first = store.recentMessagePayloads(userId: userId, chatId: chatId, limit: 10)
    XCTAssertEqual(first.compactMap(text(of:)), ["written before sealing"])
    XCTAssertEqual(store.legacyReads, 1)
    XCTAssertEqual(store.resealedRows, 1, "a legacy row should be sealed once it is read")

    // Second read goes down the sealed path and still returns the same body.
    let second = store.recentMessagePayloads(userId: userId, chatId: chatId, limit: 10)
    XCTAssertEqual(second.compactMap(text(of:)), ["written before sealing"])
    XCTAssertEqual(store.legacyReads, 1, "the row should not be legacy a second time")
    XCTAssertEqual(store.sealedReads, 1)
  }
}
