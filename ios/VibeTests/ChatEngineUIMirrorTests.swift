import Foundation
import XCTest

@testable import Vibe

/// The liveness rule that decides whether a chat shows "Working…".
///
/// This logic moved out of `ChatEngine.agentProgress` when that getter stopped
/// hopping onto the engine queue (a device run measured it blocking the main
/// thread for 64 ms to read one key). The move is only safe if the rule itself
/// is unchanged, and "unchanged" is exactly the kind of claim that needs tests
/// rather than a careful reading — a wrong staleness rule either strands a
/// spinner forever or hides work that is really running.
final class ChatEngineAgentProgressSnapshotTests: XCTestCase {

  private let now: Int64 = 1_000_000

  private func snapshot(
    status: String, agoMs: Int64, label: String = "Working", tool: String? = nil
  ) -> ChatEngineAgentProgressSnapshot {
    ChatEngineAgentProgressSnapshot(
      label: label, tool: tool, status: status, updatedAtMs: now - agoMs)
  }

  // MARK: Terminal statuses win over everything

  func testTerminalStatusIsNeverLiveEvenWhenBrandNew() {
    // The status arrived one millisecond ago and still means "over". Age must
    // not resurrect it — this is the check that stops a finished run from
    // showing as active.
    for status in [
      "done", "completed", "complete", "idle", "failed", "error", "cancelled", "canceled",
      "stopped", "settled", "success",
    ] {
      XCTAssertNil(
        snapshot(status: status, agoMs: 1).activePayload(nowMs: now),
        "\(status) must not be advertised as live work")
    }
  }

  func testTerminalMatchIsCaseAndWhitespaceInsensitive() {
    XCTAssertNil(snapshot(status: "  DONE  ", agoMs: 1).activePayload(nowMs: now))
    XCTAssertNil(snapshot(status: "Completed", agoMs: 1).activePayload(nowMs: now))
  }

  // MARK: Staleness

  func testAnEntryNobodyRefreshedForNinetySecondsExpires() {
    // The property the mirror depends on. Staleness is evaluated at READ time,
    // so an entry that stops being republished dies on its own — which is what
    // makes it safe to publish the mirror only on engine notifications.
    XCTAssertNil(snapshot(status: "running", agoMs: 120_000).activePayload(nowMs: now))
  }

  func testAStatusWithNoActiveHintGoesQuietAfterFifteenSeconds() {
    // Not terminal, not a recognised active word, and no longer fresh.
    XCTAssertNil(snapshot(status: "pondering", agoMs: 30_000).activePayload(nowMs: now))
  }

  func testRecencyAloneKeepsAnUnrecognisedStatusAlive() {
    // Same unrecognised status, but seconds old: a status vocabulary this code
    // has never seen must not blank a run that is demonstrably still ticking.
    XCTAssertNotNil(snapshot(status: "pondering", agoMs: 2_000).activePayload(nowMs: now))
  }

  // MARK: Active hints

  func testAnActiveHintSurvivesPastTheRecencyWindow() {
    // 30s old, so recency has lapsed — the hint is what keeps it live.
    for status in ["running", "streaming", "in_progress", "active", "thinking", "tool", "wait"] {
      XCTAssertNotNil(
        snapshot(status: status, agoMs: 30_000).activePayload(nowMs: now),
        "\(status) should read as live work")
    }
  }

  func testHintsMatchAsSubstrings() {
    XCTAssertNotNil(snapshot(status: "tool_use_pending", agoMs: 30_000).activePayload(nowMs: now))
  }

  func testAnEmptyStatusIsTreatedAsActive() {
    XCTAssertNotNil(snapshot(status: "", agoMs: 30_000).activePayload(nowMs: now))
  }

  // MARK: Payload shape

  func testThePayloadCarriesWhatTheRowRenders() {
    let payload = snapshot(status: "running", agoMs: 1_000, label: "Indexing", tool: "grep")
      .activePayload(nowMs: now)
    XCTAssertEqual(payload?["label"] as? String, "Indexing")
    XCTAssertEqual(payload?["status"] as? String, "running")
    XCTAssertEqual(payload?["tool"] as? String, "grep")
    XCTAssertEqual(payload?["isActive"] as? Bool, true)
    XCTAssertEqual(payload?["updatedAtMs"] as? Int64, now - 1_000)
  }

  func testToolIsOmittedRatherThanNullWhenAbsent() {
    let payload = snapshot(status: "running", agoMs: 1_000).activePayload(nowMs: now)
    XCTAssertNotNil(payload)
    XCTAssertNil(payload?["tool"])
    XCTAssertFalse(payload?.keys.contains("tool") ?? true)
  }
}

/// The mirror itself: what it answers before anyone has published to it.
final class ChatEngineUIMirrorTests: XCTestCase {

  private func published(_ mirror: ChatEngineUIMirror) {
    mirror.publish(
      typingByChatId: ["chat-a": ["u2", "u1"]],
      agentProgressByChatId: [
        "chat-a": ChatEngineAgentProgressSnapshot(
          label: "Working", tool: nil, status: "running", updatedAtMs: 500)
      ],
      onlineUserIds: ["U1"],
      lastSeenByUserId: ["U2": 1234]
    )
  }

  // MARK: Before the first publish

  func testEveryReadFallsBackBeforeTheFirstPublish() {
    // The whole point of the outer optional. An unpublished mirror must say
    // "ask the queue", never "nothing is happening" — otherwise a cold launch
    // would report every peer offline and every agent idle.
    let mirror = ChatEngineUIMirror()
    XCTAssertNil(mirror.typingUserIds(chatId: "chat-a"))
    XCTAssertNil(mirror.isUserOnline(userId: "U1"))
    XCTAssertNil(mirror.lastSeenTimestampMs(userId: "U2"))
    XCTAssertNil(mirror.agentProgress(chatId: "chat-a"))
    XCTAssertNil(mirror.hasAgentProgressEntry(chatId: "chat-a"))
    XCTAssertEqual(mirror.counts.fallbackReads, 5)
    XCTAssertEqual(mirror.counts.mirrorReads, 0)
  }

  func testAPublishedMissIsDistinctFromAnUnpublishedMirror() {
    // Inner nil vs outer nil. Published-but-absent means "no agent here" and is
    // a real answer; unpublished means the caller must go to the queue.
    let mirror = ChatEngineUIMirror()
    published(mirror)
    let answer = mirror.agentProgress(chatId: "chat-with-no-agent")
    XCTAssertNotNil(answer, "the mirror has published, so it must answer")
    XCTAssertNil(answer ?? nil, "and its answer is that no agent is running")
  }

  // MARK: After publishing

  func testPublishedStateIsWhatComesBack() {
    let mirror = ChatEngineUIMirror()
    published(mirror)
    XCTAssertEqual(mirror.typingUserIds(chatId: "chat-a"), ["u1", "u2"])
    XCTAssertEqual(mirror.isUserOnline(userId: "U1"), true)
    XCTAssertEqual(mirror.isUserOnline(userId: "U9"), false)
    XCTAssertEqual(mirror.lastSeenTimestampMs(userId: "U2") ?? nil, 1234)
    XCTAssertEqual(mirror.agentProgress(chatId: "chat-a")??.status, "running")
    XCTAssertEqual(mirror.hasAgentProgressEntry(chatId: "chat-a"), true)
  }

  func testTypingIdsComeBackSorted() {
    // The engine's getter sorted them; a set does not, and an unsorted list
    // would reshuffle the header text on every publish.
    let mirror = ChatEngineUIMirror()
    published(mirror)
    XCTAssertEqual(mirror.typingUserIds(chatId: "chat-a"), ["u1", "u2"])
  }

  func testARepublishReplacesRatherThanMerges() {
    // Stale presence that merged forward would leave users online forever.
    let mirror = ChatEngineUIMirror()
    published(mirror)
    mirror.publish(
      typingByChatId: [:], agentProgressByChatId: [:], onlineUserIds: [], lastSeenByUserId: [:])
    XCTAssertEqual(mirror.typingUserIds(chatId: "chat-a"), [])
    XCTAssertEqual(mirror.isUserOnline(userId: "U1"), false)
    XCTAssertEqual(mirror.hasAgentProgressEntry(chatId: "chat-a"), false)
  }

  func testCountersSeparateMirrorReadsFromFallbacks() {
    // These counters are what the exported log reports; if they lie, a run
    // cannot tell "the mirror is working" from "the mirror never published".
    let mirror = ChatEngineUIMirror()
    _ = mirror.isUserOnline(userId: "U1")
    published(mirror)
    _ = mirror.isUserOnline(userId: "U1")
    _ = mirror.isUserOnline(userId: "U1")
    let counts = mirror.counts
    XCTAssertEqual(counts.fallbackReads, 1)
    XCTAssertEqual(counts.mirrorReads, 2)
    XCTAssertEqual(counts.publishes, 1)
  }

  func testConcurrentReadsAndPublishesDoNotTrip() {
    // The mirror is read from the main thread and written from the engine
    // queue, so the lock is load-bearing rather than decorative.
    let mirror = ChatEngineUIMirror()
    published(mirror)
    let done = expectation(description: "concurrent access")
    done.expectedFulfillmentCount = 2
    DispatchQueue.global().async {
      for _ in 0..<500 { self.published(mirror) }
      done.fulfill()
    }
    DispatchQueue.global().async {
      for _ in 0..<500 { _ = mirror.isUserOnline(userId: "U1") }
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    XCTAssertEqual(mirror.isUserOnline(userId: "U1"), true)
  }
}

// MARK: - Pending bridge approvals

/// The 90 ms stall: `outstandingAgentBridgeAskInfo` blocked the main thread while the
/// engine queue loaded history. The scan was never the cost — the wait was.
///
/// A missed approval prompt is a run that waits forever with nothing on screen, so the
/// cold-start distinction matters more here than anywhere else in the mirror: "nothing
/// published yet" must never be answered as "no approval pending".
extension ChatEngineUIMirrorTests {

  private func ask(
    _ requestId: String, chat: String = "c1", provider: String = "codex"
  ) -> ChatEngineBridgeAskSnapshot {
    ChatEngineBridgeAskSnapshot(
      requestId: requestId, chatId: chat, kind: "ask", provider: provider,
      sessionId: "s-\(requestId)", resumedFromSessionId: "")
  }

  func testBeforeAnyPublishTheCallerIsSentToTheQueue() {
    let mirror = ChatEngineUIMirror()
    XCTAssertNil(
      mirror.pendingBridgeAsk(chatId: "c1", provider: "codex"),
      "a cold mirror must say 'ask the queue', never 'no approval pending'")
  }

  func testAPublishedChatWithNoPromptAnswersEmptyRatherThanUnknown() {
    let mirror = ChatEngineUIMirror()
    mirror.publish(
      typingByChatId: [:], agentProgressByChatId: [:], onlineUserIds: [],
      lastSeenByUserId: [:], pendingAskByChatId: [:])
    let answer = mirror.pendingBridgeAsk(chatId: "c1", provider: "codex")
    XCTAssertNotNil(answer, "published means the caller must not fall back to the queue")
    XCTAssertNil(answer!, "…and this chat genuinely has nothing waiting")
  }

  func testAPendingPromptIsReturnedWithoutTouchingTheEngine() {
    let mirror = ChatEngineUIMirror()
    mirror.publish(
      typingByChatId: [:], agentProgressByChatId: [:], onlineUserIds: [],
      lastSeenByUserId: [:], pendingAskByChatId: ["c1": [ask("r1")]])
    let prompt = mirror.pendingBridgeAsk(chatId: "c1", provider: "codex")
    XCTAssertEqual(prompt??.requestId, "r1")
    XCTAssertEqual(prompt??.payload["reason"] as? String, "agentBridgeAsk")
    XCTAssertEqual(prompt??.payload["sessionId"] as? String, "s-r1")
  }

  func testAPromptForAnotherProviderIsNotReturned() {
    let mirror = ChatEngineUIMirror()
    mirror.publish(
      typingByChatId: [:], agentProgressByChatId: [:], onlineUserIds: [],
      lastSeenByUserId: [:], pendingAskByChatId: ["c1": [ask("r1", provider: "claude")]])
    XCTAssertNil(mirror.pendingBridgeAsk(chatId: "c1", provider: "codex")!)
  }

  func testAPromptWithNoProviderMatchesAnyProvider() {
    // An unattributable prompt still has to be answerable, or the run waits forever.
    let mirror = ChatEngineUIMirror()
    mirror.publish(
      typingByChatId: [:], agentProgressByChatId: [:], onlineUserIds: [],
      lastSeenByUserId: [:], pendingAskByChatId: ["c1": [ask("r1", provider: "")]])
    XCTAssertEqual(
      mirror.pendingBridgeAsk(chatId: "c1", provider: "codex")??.requestId, "r1")
  }

  func testAnEmptyProviderQueryMatchesAnyPrompt() {
    let mirror = ChatEngineUIMirror()
    mirror.publish(
      typingByChatId: [:], agentProgressByChatId: [:], onlineUserIds: [],
      lastSeenByUserId: [:], pendingAskByChatId: ["c1": [ask("r1", provider: "claude")]])
    XCTAssertEqual(mirror.pendingBridgeAsk(chatId: "c1", provider: "")??.requestId, "r1")
  }

  func testAnotherChatsPromptIsNotReturned() {
    let mirror = ChatEngineUIMirror()
    mirror.publish(
      typingByChatId: [:], agentProgressByChatId: [:], onlineUserIds: [],
      lastSeenByUserId: [:], pendingAskByChatId: ["c2": [ask("r1", chat: "c2")]])
    XCTAssertNil(mirror.pendingBridgeAsk(chatId: "c1", provider: "codex")!)
  }

  func testTheSamePromptIsReturnedEveryTime() {
    // The engine sorts by request id before publishing precisely so this holds. A sheet
    // that swaps which request it is answering mid-flight is worse than a late one.
    let mirror = ChatEngineUIMirror()
    mirror.publish(
      typingByChatId: [:], agentProgressByChatId: [:], onlineUserIds: [],
      lastSeenByUserId: [:], pendingAskByChatId: ["c1": [ask("r1"), ask("r2"), ask("r3")]])
    let first = mirror.pendingBridgeAsk(chatId: "c1", provider: "codex")??.requestId
    for _ in 0..<20 {
      XCTAssertEqual(mirror.pendingBridgeAsk(chatId: "c1", provider: "codex")??.requestId, first)
    }
    XCTAssertEqual(first, "r1")
  }
}
