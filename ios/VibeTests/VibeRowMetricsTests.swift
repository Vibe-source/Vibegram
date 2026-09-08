import Foundation
import UIKit
import XCTest

@testable import Vibe

/// The gate that decides which rows can be measured before the push.
///
/// These tests do not check height formulas. Heights come from
/// `measureMessageBubbleLayout`, the same function the cell calls, so there is nothing to
/// keep in agreement — that was the point of making this a gate rather than a second
/// implementation. What is worth testing is the part that is new and can be wrong:
///
///   1. the classification (which rows may leave the main thread),
///   2. that measuring off the main thread actually produces the same number,
///   3. that many threads measuring at once stay stable.
///
/// (2) and (3) are the load-bearing ones. A measurement path that is *almost* thread-safe
/// fails as a wrong height, not as a crash — a shift nobody can reproduce.
final class VibeRowMetricsTests: XCTestCase {

  // MARK: Row fixtures

  private func textRow(
    _ text: String, key: String = UUID().uuidString, isMe: Bool = false
  ) -> ChatListRow {
    ChatListRow(raw: [
      "kind": "message",
      "key": key,
      "message": [
        "id": key,
        "text": text,
        "timestamp": "22:20",
        "isMe": isMe,
        "type": "text",
      ],
    ])!
  }

  private func mediaRow(width: Double, height: Double, key: String = UUID().uuidString)
    -> ChatListRow
  {
    ChatListRow(raw: [
      "kind": "message",
      "key": key,
      "message": [
        "id": key,
        "text": "",
        "timestamp": "22:20",
        "isMe": false,
        "type": "image",
        "mediaUrl": "https://example.invalid/\(key).jpg",
        "width": width,
        "height": height,
      ],
    ])!
  }

  private func voiceRow(duration: Double = 12, key: String = UUID().uuidString) -> ChatListRow {
    ChatListRow(raw: [
      "kind": "message",
      "key": key,
      "message": [
        "id": key,
        "text": "",
        "timestamp": "22:20",
        "isMe": false,
        "type": "voice",
        "mediaDuration": duration,
      ],
    ])!
  }

  /// An agent turn with a progress feed — the one shape that must stay on main.
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

  private func plainAgentTurnRow(
    _ text: String, isStreaming: Bool, key: String = UUID().uuidString
  ) -> ChatListRow {
    ChatListRow(raw: [
      "kind": "message",
      "key": key,
      "message": [
        "id": key,
        "text": text,
        "timestamp": "22:20",
        "isMe": false,
        "type": "agent_progress_tree",
        "isAgentMessage": true,
        "isStreaming": isStreaming,
        "agentName": "Vibe AI",
      ],
    ])!
  }

  private let rowWidth: CGFloat = 393  // iPhone 16 Pro Max portrait content width

  // MARK: The gate

  func testOrdinaryRowsCanLeaveTheMainThread() {
    XCTAssertFalse(VibeRowMetrics.requiresMainThread(textRow("hello")))
    XCTAssertFalse(VibeRowMetrics.requiresMainThread(mediaRow(width: 1000, height: 500)))
    XCTAssertFalse(VibeRowMetrics.requiresMainThread(voiceRow()))
  }

  func testAnAgentTurnIsHeldOnTheMainThread() {
    let row = agentTurnRow()
    // If this row ever stops classifying as an agent turn the gate silently opens and a
    // `UIStackView` gets laid out on a background thread, so assert the premise too.
    XCTAssertTrue(bubbleUsesAgentTurnContent(row), "fixture no longer models an agent turn")
    XCTAssertTrue(VibeRowMetrics.requiresMainThread(row))
    XCTAssertNil(VibeRowMetrics.height(row: row, rowWidth: rowWidth))
  }

  func testMultilineAgentProseUsesTheFullReadingWidthWhileStreamingAndSettled() {
    let text = """
      1. Understand the customer
      Ask:
      • What are you looking for?
      • Who is it for?
      """
    let maxContentWidth: CGFloat = 320

    for isStreaming in [true, false] {
      let row = plainAgentTurnRow(text, isStreaming: isStreaming)
      XCTAssertTrue(bubbleUsesAgentTurnContent(row), "fixture no longer models an agent turn")
      XCTAssertEqual(
        agentTurnContentWidth(row, maxContentWidth: maxContentWidth),
        maxContentWidth
      )
    }
  }

  func testShortSingleLineAgentProseCanStillHugItsText() {
    let maxContentWidth: CGFloat = 320
    let row = plainAgentTurnRow("No track found", isStreaming: false)

    XCTAssertLessThan(
      agentTurnContentWidth(row, maxContentWidth: maxContentWidth),
      maxContentWidth
    )
  }

  func testAgentTurnWrapperContainsTransientStreamingOverflow() {
    XCTAssertTrue(VibeAgentTurnContentView().clipsToBounds)
  }

  func testABatchReportsDeferredRowsRatherThanDroppingThem() {
    // A row with no height quietly gets an estimate, and an estimate that disagrees with
    // the eventual measurement is exactly the shift being removed. The caller has to know.
    let text = textRow("ordinary", key: "k-text")
    let agent = agentTurnRow(key: "k-agent")
    let result = VibeRowMetrics.heights(rows: [text, agent], rowWidth: rowWidth)

    XCTAssertEqual(result.deferredKeys, ["k-agent"])
    XCTAssertNotNil(result.byKey["k-text"])
    XCTAssertNil(result.byKey["k-agent"])
  }

  // MARK: Identity with the path the cell uses

  func testHeightIsTheCellsOwnMeasurement() {
    // Not a tolerance — the same call. This pins the composition around it: the
    // `tallOuterToggleReserve` term, and that nothing is added or rounded on the way out.
    for row in [textRow("a short one"), textRow(String(repeating: "wrap ", count: 200))] {
      let metrics = measureMessageBubbleLayout(row: row, rowWidth: rowWidth)
      XCTAssertEqual(
        VibeRowMetrics.height(row: row, rowWidth: rowWidth),
        metrics.bubbleHeight + metrics.tallOuterToggleReserve)
    }
  }

  func testAServicePillUsesTheCenteredHeightAndNotABubble() {
    // `/compact` renders as a centered divider. It never reaches the measure path, so it
    // needs its own branch — and getting that wrong sizes it like a bubble.
    let key = "k-compact"
    let row = ChatListRow(raw: [
      "kind": "message",
      "key": key,
      "message": [
        "id": key,
        "text": "Context compacted",
        "timestamp": "22:20",
        "isMe": false,
        "type": "text",
        "isAgentMessage": true,
        "agentMsgKind": "summary",
      ],
    ])!
    XCTAssertNotNil(agentSystemDividerText(for: row), "fixture no longer models a divider")
    XCTAssertEqual(
      VibeRowMetrics.height(row: row, rowWidth: rowWidth),
      VibeRowMetrics.servicePillBaseHeight + serviceDecisionActionsHeight(for: row))
  }

  func testAZeroWidthMeasuresToNothingRatherThanCrashing() {
    XCTAssertNil(VibeRowMetrics.height(row: textRow("hello"), rowWidth: 0))
    XCTAssertNil(VibeRowMetrics.height(row: textRow("hello"), rowWidth: -10))
  }

  // MARK: The property this exists for

  func testARealRowMeasuresTheSameOffTheMainThread() {
    // The whole point. This is the claim that lets a transcript be measured before it is
    // pushed instead of during — and it is a claim about the real measure path, not about
    // a formula written to imitate it.
    let rows = [
      textRow("short"),
      textRow(String(repeating: "the quick brown fox ", count: 60)),
      mediaRow(width: 1600, height: 900),
      voiceRow(duration: 27),
    ]
    let onMain = rows.map { VibeRowMetrics.height(row: $0, rowWidth: rowWidth) }

    let done = expectation(description: "measured off main")
    var offMain: [CGFloat?] = []
    DispatchQueue.global(qos: .userInitiated).async {
      XCTAssertFalse(Thread.isMainThread)
      offMain = rows.map { VibeRowMetrics.height(row: $0, rowWidth: self.rowWidth) }
      done.fulfill()
    }
    wait(for: [done], timeout: 10)

    XCTAssertEqual(offMain.count, onMain.count)
    for (index, expected) in onMain.enumerated() {
      XCTAssertNotNil(expected, "row \(index) should measure")
      XCTAssertEqual(
        offMain[index], expected,
        "row \(index) measured differently off the main thread")
    }
  }

  func testConcurrentMeasurementIsStable() {
    // A prepared transcript measures many rows at once. This is where a thread-hostile
    // cache or an unguarded static shows up — as a wrong number, not as a crash.
    let rows = (0..<12).map { textRow(String(repeating: "message body ", count: $0 + 1)) }
    let expected = rows.map { VibeRowMetrics.height(row: $0, rowWidth: rowWidth) }

    let done = expectation(description: "concurrent")
    done.expectedFulfillmentCount = 8
    for _ in 0..<8 {
      DispatchQueue.global().async {
        for _ in 0..<25 {
          for (index, row) in rows.enumerated() {
            XCTAssertEqual(
              VibeRowMetrics.height(row: row, rowWidth: self.rowWidth), expected[index])
          }
        }
        done.fulfill()
      }
    }
    wait(for: [done], timeout: 60)
  }

  func testCodeBlockExpansionStateSurvivesConcurrentReads() {
    // `measureBubbleCodeBlockHeight` reads `AgentCodeBlockView.isExpanded` while a tap on
    // main can be writing it. That set is lock-guarded for exactly this reason; without
    // the lock this is an unsynchronised `Set<String>` across threads.
    let code = String(repeating: "let x = 1\n", count: 40)
    let done = expectation(description: "expansion reads")
    done.expectedFulfillmentCount = 8
    for _ in 0..<8 {
      DispatchQueue.global().async {
        for _ in 0..<200 {
          _ = AgentCodeBlockView.isExpanded(code: code, language: "swift")
        }
        done.fulfill()
      }
    }
    wait(for: [done], timeout: 30)
  }

  // MARK: Primitives

  func testTextWidthFollowsTheBubbleFactorAndPadding() {
    // 440 * 0.85 = 374, floor 374, minus 24 padding = 350.
    XCTAssertEqual(VibeRowMetrics.textMaxWidth(rowWidth: 440), 350)
    XCTAssertGreaterThan(VibeRowMetrics.textMaxWidth(rowWidth: 1), 0)
  }

  func testTextHeightIsRoundedUpAndWrapsNarrower() {
    let text = NSAttributedString(
      string: String(repeating: "wrap me please ", count: 20),
      attributes: [.font: UIFont.systemFont(ofSize: 16)])
    let wide = VibeRowMetrics.textHeight(text, width: 400)
    let narrow = VibeRowMetrics.textHeight(text, width: 120)
    XCTAssertGreaterThan(narrow, wide)
    XCTAssertEqual(wide, wide.rounded(.up))
  }

  func testEmptyAndZeroWidthTextMeasureToNothing() {
    let empty = NSAttributedString(string: "")
    let hello = NSAttributedString(string: "hello")
    XCTAssertEqual(VibeRowMetrics.textHeight(empty, width: 300), 0)
    XCTAssertEqual(VibeRowMetrics.textHeight(hello, width: 0), 0)
    XCTAssertEqual(VibeRowMetrics.textHeight(hello, width: -10), 0)
  }

  func testDaySeparatorIsAConstant() {
    XCTAssertEqual(VibeRowMetrics.daySeparatorHeight(), 30)
  }
}
