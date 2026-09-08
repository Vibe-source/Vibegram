import XCTest

/// Reproduces the list shift on the device, at the speed a person actually
/// produces it, and photographs the transition rather than describing it.
///
/// # Why this exists
///
/// The shift is real and was visible in screenshots while the device log read
/// clean, so every round of this bug has cost a manual session. Two things about
/// that session turned out to matter, and both are easy to get wrong:
///
/// - **Speed.** The defect shows up when a chat is opened, flung, and closed
///   faster than the previous commit has settled. A script that politely waits
///   between steps reproduces nothing — it measures the settled state, which was
///   never the complaint.
/// - **The moment.** The shift happens *during* the open, between the tap and
///   the transcript being fully mounted. A screenshot taken after it settles
///   shows a correct list and proves nothing.
///
/// So the open is captured as a **burst of frames with no delay between them**,
/// from the tap until the list has settled. Played back in order those frames
/// are the shift, in the same form the bug was reported in.
///
/// # What it asserts
///
/// That each surface opened, and nothing else. The probes in the app
/// (`[ListShift]`, `[TimelineLayout]`, `[CellWidth]`, `[DatePill]`) are what
/// detect the defect and they report to the device log; this test's job is to
/// provoke it reliably and leave the frames behind. Asserting "nothing shifted"
/// here would fail on a log line rather than on the symptom, and would have to
/// be kept in sync with the probes.
final class VibeListShiftUITests: XCTestCase {

  private var driver: VibeDeviceDriver!

  override func setUpWithError() throws {
    continueAfterFailure = true
    driver = VibeDeviceDriver(shotPrefix: "shift")
    // Attach rather than launch when a console is already following the app —
    // relaunching would kill the process whose log is being captured, which is
    // the only record of what the probes saw. See `VibeDeviceDriver.attach()`.
    if ProcessInfo.processInfo.environment["VIBE_ATTACH_RUNNING_APP"] == "1" {
      driver.attach()
    } else {
      driver.launch()
    }
  }

  /// Marks the phases in the device log, so probe output can be attributed to a
  /// step of this script rather than read as one undifferentiated stream.
  private func phase(_ name: String) {
    NSLog("[ShiftTest] ===== %@ =====", name)
  }

  // MARK: The reported sequence

  /// Opened at the bottom, then jumped to the top.
  func testSavedMessagesOpenFrames() throws {
    phase("saved-messages open")
    XCTAssertTrue(
      openWithFrameBurst(named: "Saved Messages", label: "saved-open", frames: 20),
      "Saved Messages did not open — the rest of this test would be measuring nothing")
    _ = driver.screenshot("saved-settled", test: self)
    _ = driver.goBackFromChat()
  }

  /// The main repro, at the speed it was reported at: open, fling hard, close,
  /// reopen, without pausing between any of it.
  func testFastCycleOnTestChat() throws {
    for iteration in 1...6 {
      phase("test cycle \(iteration) — open")
      guard openWithFrameBurst(named: "test", label: "test-\(iteration)-open", frames: 16) else {
        XCTFail("'test' chat did not open on iteration \(iteration)")
        return
      }

      phase("test cycle \(iteration) — fling to top")
      fling(.towardOlder, times: 6, gapMs: 40)
      _ = driver.screenshot("test-\(iteration)-top", test: self)

      phase("test cycle \(iteration) — fling to bottom")
      fling(.towardNewer, times: 6, gapMs: 40)
      _ = driver.screenshot("test-\(iteration)-bottom", test: self)

      // One long uninterrupted throw. A burst of short swipes never builds the
      // momentum that keeps the list moving through several history pages, and
      // that sustained travel is where the frames were being dropped.
      phase("test cycle \(iteration) — long throw")
      fling(.towardOlder, times: 3, gapMs: 0)

      phase("test cycle \(iteration) — close")
      _ = driver.goBackFromChat(timeout: 6)
      // Deliberately far too short to be polite. Reopening before the close has
      // settled is the case the manual repro kept landing on.
      driver.sleepMs(150)
    }
  }

  /// The agent DM, where the cells change frame rather than just position.
  /// Weighted toward opens, not scrolling — that is where it misbehaves.
  func testAgentChatOpenFrames() throws {
    for pass in 1...4 {
      phase("mahiro open \(pass)")
      guard openWithFrameBurst(named: "Mahiro", label: "mahiro-\(pass)-open", frames: 18) else {
        XCTFail("Mahiro did not open on pass \(pass)")
        return
      }
      if pass.isMultiple(of: 2) {
        phase("mahiro scroll \(pass)")
        fling(.towardOlder, times: 3, gapMs: 60)
        fling(.towardNewer, times: 3, gapMs: 60)
        _ = driver.screenshot("mahiro-\(pass)-scrolled", test: self)
      }
      _ = driver.goBackFromChat(timeout: 6)
      driver.sleepMs(150)
    }
  }

  // MARK: Capture

  /// Taps the chat row and photographs every frame from the tap until the
  /// transcript has settled.
  ///
  /// No sleep between shots on purpose: `XCUIScreen.screenshot()` costs tens of
  /// milliseconds, so back-to-back calls sample at roughly the rate the shift
  /// happens at. Inserting a delay to "space them out" would step straight over
  /// the frames worth having.
  private func openWithFrameBurst(named title: String, label: String, frames: Int) -> Bool {
    driver.goToChats()
    driver.sleepMs(400)
    // Photograph the list *before* the tap too. Half of the reported evidence is
    // about where the transcript lands relative to where the reader came from,
    // and that is unanswerable without the frame before.
    _ = driver.screenshot("\(label)-f00-home", test: self)

    guard let row = chatRow(named: title) else {
      NSLog("[ShiftTest] could not find a row for %@", title)
      return false
    }
    row.tap()
    for index in 1...frames {
      _ = driver.screenshot(String(format: "%@-f%02d", label, index), test: self)
    }
    return true
  }

  /// The row for a chat, without the driver's built-in settle delays — this has
  /// to tap and start photographing in the same breath.
  private func chatRow(named title: String) -> XCUIElement? {
    let cell = driver.app.cells.containing(.staticText, identifier: title).element
    if cell.waitForExistence(timeout: 6), cell.isHittable { return cell }
    let text = driver.app.staticTexts[title]
    if text.waitForExistence(timeout: 6) { return text.isHittable ? text : cell }
    return nil
  }

  // MARK: Gestures

  private enum FlingDirection {
    /// Up the transcript, into history.
    case towardOlder
    /// Back down toward the newest message.
    case towardNewer
  }

  /// Throws the transcript hard, the way a thumb does.
  ///
  /// Addresses the collection view rather than the app: `app.swipeUp()` can land
  /// on the composer or the navigation bar, and a gesture that misses the
  /// transcript measures nothing. `.fast` velocity matters — a slow drag never
  /// enters the momentum phase, and momentum is where the frames were dropped.
  private func fling(_ direction: FlingDirection, times: Int, gapMs: UInt32) {
    let list = driver.app.collectionViews.firstMatch
    guard list.exists else {
      NSLog("[ShiftTest] no collection view to scroll")
      return
    }
    for _ in 0..<times {
      switch direction {
      case .towardOlder: list.swipeDown(velocity: .fast)
      case .towardNewer: list.swipeUp(velocity: .fast)
      }
      if gapMs > 0 { driver.sleepMs(gapMs) }
    }
  }
}
