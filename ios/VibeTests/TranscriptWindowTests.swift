import Foundation
import XCTest

@testable import Vibe

/// The rule that decides how much of a transcript is mounted.
///
/// `ChatListView` has always contained a complete bounded-window implementation
/// — scroll-up detection, reveal, prepend, anchor preservation — wired to the
/// scroll handler and permanently inert, because the one function that fed it
/// returned its input unchanged. Arming it means normal DMs, groups and channels
/// stop mounting every message ever sent.
///
/// The tests are mostly refusals. Withholding a row the user needs on screen is
/// far worse than mounting one they did not: the first looks like lost data, the
/// second is only slow. So every case where the window must stand down is
/// pinned here.
final class TranscriptWindowTests: XCTestCase {

  private func keep(
    rows: Int, limit: Int = 200, enabled: Bool = true, revealed: Bool = false,
    searching: Bool = false
  ) -> Int? {
    ChatListView.transcriptWindowKeepCount(
      rowCount: rows, limit: limit, enabled: enabled, revealed: revealed, isSearching: searching)
  }

  // MARK: It windows when it should

  func testALongTranscriptIsCappedAtTheLimit() {
    XCTAssertEqual(keep(rows: 4_000), 200)
  }

  func testOneRowOverTheLimitStillWindows() {
    XCTAssertEqual(keep(rows: 201), 200)
  }

  // MARK: It stands down when it should

  func testAnUnarmedFlagKeepsEverything() {
    XCTAssertNil(keep(rows: 4_000, enabled: false))
  }

  func testATranscriptShorterThanTheLimitIsNeverTouched() {
    XCTAssertNil(keep(rows: 199))
    XCTAssertNil(keep(rows: 0))
  }

  func testExactlyTheLimitIsNotWindowed() {
    // Windowing here would withhold nothing while still arming the reveal path
    // and its scroll indicator — cost with no benefit.
    XCTAssertNil(keep(rows: 200))
  }

  func testOnceRevealedTheTranscriptStaysWhole() {
    // The user scrolled up and asked for all of it. Re-clamping on the next
    // engine delta would pull rows out from under someone mid-read.
    XCTAssertNil(keep(rows: 4_000, revealed: true))
  }

  func testSearchIsNeverWindowed() {
    // A windowed search would quietly fail to match anything older than the
    // newest 200 rows, which reads as data loss rather than as a bounded list.
    XCTAssertNil(keep(rows: 4_000, searching: true))
  }

  func testAMisconfiguredLimitFallsBackToNoWindow() {
    // A zero or negative limit must never blank a transcript.
    XCTAssertNil(keep(rows: 4_000, limit: 0))
    XCTAssertNil(keep(rows: 4_000, limit: -1))
  }

  // MARK: Interaction with the policy clamp

  func testTheDefaultLimitIsThePolicyWindow() {
    let flags = VibeTimelineUserDefaultsFeatureFlags(
      defaults: UserDefaults(suiteName: "window-\(UUID().uuidString)")!
    ).flags
    XCTAssertEqual(flags.resolvedActiveWindowCount, 200)
    XCTAssertEqual(keep(rows: 4_000, limit: flags.resolvedActiveWindowCount), 200)
  }

  func testAnOversizedOverrideIsClampedBeforeItReachesTheWindow() {
    let defaults = UserDefaults(suiteName: "window-\(UUID().uuidString)")!
    defaults.set(5_000, forKey: VibeTimelineUserDefaultsFeatureFlags.activeWindowKey)
    let resolved = VibeTimelineUserDefaultsFeatureFlags(defaults: defaults)
      .flags.resolvedActiveWindowCount
    XCTAssertEqual(resolved, 300, "policy caps the active window at 300")
    XCTAssertEqual(keep(rows: 10_000, limit: resolved), 300)
  }
}

/// The gate, and what it must not drag along with it.
final class TranscriptWindowFlagTests: XCTestCase {

  private func flags(_ configure: (UserDefaults) -> Void = { _ in })
    -> VibeTimelineFeatureFlags
  {
    let defaults = UserDefaults(suiteName: "window-flag-\(UUID().uuidString)")!
    configure(defaults)
    return VibeTimelineUserDefaultsFeatureFlags(defaults: defaults).flags
  }

  /// The transcript mounts whole unless someone asks otherwise — in every
  /// configuration, debug included.
  ///
  /// This asserted the opposite until the debug default was measured on device: the
  /// cap withheld 779 of 979 rows on open, then charged an 879-row batch insert to
  /// give them back. A row limit is a debug-menu tool now, never a default.
  func testTheWindowIsOffUnlessAskedFor() {
    XCTAssertFalse(flags().vibeTranscriptWindowEnabled)
  }

  func testAnExplicitTrueWins() {
    let resolved = flags {
      $0.set(true, forKey: VibeTimelineUserDefaultsFeatureFlags.transcriptWindowKey)
    }
    XCTAssertTrue(resolved.vibeTranscriptWindowEnabled)
  }

  func testAnExplicitFalseWins() {
    let resolved = flags {
      $0.set(false, forKey: VibeTimelineUserDefaultsFeatureFlags.transcriptWindowKey)
    }
    XCTAssertFalse(resolved.vibeTranscriptWindowEnabled)
  }

  func testArmingTheWindowWidensNoOtherGate() {
    // The lesson from the shadow-compare rollout, which first shipped by
    // widening a SHARED allowlist and would have turned on the async render host
    // the moment its own flag flipped. A gate that arms itself must not arm
    // anything else — least of all one that replaces the render path.
    let resolved = flags()
    XCTAssertFalse(resolved.vibeAsyncTimelineV1Enabled)
    XCTAssertFalse(resolved.vibeTimelineCoreOrderAuthorityEnabled)
    XCTAssertEqual(
      resolved.eligibleChatClasses, [],
      "the render allowlist must stay empty regardless of the transcript window")
  }
}
