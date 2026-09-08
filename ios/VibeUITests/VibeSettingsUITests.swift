import XCTest

final class VibeSettingsUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 15))
    app.tabBars.buttons["Settings"].tap()
  }

  func testSettingsInformationArchitectureAndProductionDestinations() {
    assertRow("Switch or Add Account")
    assertRow("Connection Manager")
    assertRow("Notifications and Sounds")
    assertRow("Privacy")
    assertRow("Devices")
    assertRow("Appearance")

    app.staticTexts["Notifications and Sounds"].tap()
    XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Private Chats"].exists)
    XCTAssertTrue(app.staticTexts["Group Chats"].exists)
    app.navigationBars.buttons.element(boundBy: 0).tap()

    assertRow("Devices")
    app.staticTexts["Devices"].tap()
    XCTAssertTrue(app.navigationBars["Devices"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Revoke Session"].exists, "Revocation must require selecting another session")
  }

  func testAppearanceHasLiveDevicePreview() {
    assertRow("Appearance")
    app.staticTexts["Appearance"].tap()
    // New editor: live draft preview + Background / Accent / Messages tabs.
    XCTAssertTrue(
      app.otherElements.matching(NSPredicate(format: "label BEGINSWITH 'Appearance preview'"))
        .firstMatch.waitForExistence(timeout: 5)
        || app.staticTexts["Background"].waitForExistence(timeout: 5)
    )
    XCTAssertTrue(app.buttons["Set"].waitForExistence(timeout: 5)
      || app.staticTexts["Set"].waitForExistence(timeout: 2))
  }

  private func assertRow(_ label: String) {
    let row = app.staticTexts[label]
    if !row.exists {
      app.swipeUp()
    }
    XCTAssertTrue(row.waitForExistence(timeout: 4), "Missing Settings row: \(label)")
  }
}
