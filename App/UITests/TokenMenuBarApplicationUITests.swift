import XCTest

final class TokenMenuBarApplicationUITests: XCTestCase {
  @MainActor
  func testStatusItemReopensThePopoverAfterEscape() {
    let verification = VerificationApplication(testName: name)
    defer { verification.terminate() }
    verification.launch()

    XCTAssertTrue(verification.statusItem.waitForExistence(timeout: 5))
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    verification.application.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(verification.tabs.waitForNonExistence(timeout: 2))

    verification.openPopover()
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 2))
  }

  @MainActor
  func testEveryTabExposesNamedControls() {
    let verification = VerificationApplication(testName: name)
    defer { verification.terminate() }
    verification.launch()

    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    for tab in ["History", "Settings", "Usage"] {
      verification.selectTab(tab)
      XCTAssertTrue(verification.tabs.waitForExistence(timeout: 2))
      let surface = verification.application.descendants(matching: .any)["popover-surface"]
      XCTAssertTrue(surface.waitForExistence(timeout: 2))
      let content = verification.application.descendants(matching: .any)["tab-content-\(tab)"]
      XCTAssertTrue(content.waitForExistence(timeout: 2))
      XCTAssertFalse(verification.tab(tab).label.isEmpty)
      for identifier in ["footer-refresh", "footer-report-issue", "footer-quit"] {
        let control = verification.application.descendants(matching: .any)[identifier]
        XCTAssertTrue(control.waitForExistence(timeout: 2))
        XCTAssertFalse(control.label.isEmpty)
      }
      switch tab {
      case "Usage":
        XCTAssertTrue(
          verification.application.descendants(matching: .any)["usage-refresh"].waitForExistence(timeout: 2))
      case "History":
        XCTAssertTrue(
          verification.application.descendants(matching: .any)["history-period"].waitForExistence(timeout: 2))
        XCTAssertTrue(
          verification.application.descendants(matching: .any)["history-from"].waitForExistence(timeout: 2))
      default:
        XCTAssertTrue(
          verification.application.descendants(matching: .any)["model-filter"].waitForExistence(timeout: 2))
      }
    }
  }

  @MainActor
  func testTabSwitchReturnsToIdle() throws {
    let verification = VerificationApplication(testName: name)
    defer { verification.terminate() }
    verification.launch()

    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    let before = try verification.cpuTime()
    verification.selectTab("History")
    Thread.sleep(forTimeInterval: 2)
    XCTAssertLessThan(try verification.cpuTime() - before, 0.5)
  }

  @MainActor
  func testCommandFFocusesTheModelFilter() {
    let verification = VerificationApplication(testName: name)
    defer { verification.terminate() }
    verification.launch()

    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    verification.tab("Settings").click()
    verification.application.typeKey("f", modifierFlags: .command)
    let filter = verification.application.textFields["model-filter"]
    XCTAssertTrue(filter.waitForExistence(timeout: 2))
    filter.typeText("codex")
    XCTAssertEqual(filter.value as? String, "codex")
    XCTAssertNotEqual(verification.application.textFields["Search log"].value as? String, "codex")
  }

  @MainActor
  func testEscapeClosesEveryTab() {
    let verification = VerificationApplication(testName: name)
    defer { verification.terminate() }
    verification.launch()

    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    for tab in ["History", "Settings"] {
      verification.tab(tab).click()
      verification.application.typeKey(.escape, modifierFlags: [])
      XCTAssertTrue(verification.tabs.waitForNonExistence(timeout: 2))
      verification.openPopover()
      XCTAssertTrue(verification.tabs.waitForExistence(timeout: 2))
    }
  }

  @MainActor
  func testLaunchStaysWithinBudget() {
    let verification = VerificationApplication(testName: name)
    defer { verification.terminate() }

    let duration = verification.launch()

    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    XCTAssertLessThan(duration, 5)
  }

  @MainActor
  func testResidentMemoryStaysWithinBudget() throws {
    let verification = VerificationApplication(testName: name)
    defer { verification.terminate() }
    verification.launch()

    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    XCTAssertLessThan(try verification.residentMemoryBytes(), 256 * 1024 * 1024)
  }

  @MainActor
  func testIdleCPUStaysWithinBudget() throws {
    let verification = VerificationApplication(testName: name)
    defer { verification.terminate() }
    verification.launch()

    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    Thread.sleep(forTimeInterval: 1)
    let before = try verification.cpuTime()
    Thread.sleep(forTimeInterval: 2)
    let consumed = try verification.cpuTime() - before
    XCTAssertLessThan(consumed, 0.5)
  }
}
