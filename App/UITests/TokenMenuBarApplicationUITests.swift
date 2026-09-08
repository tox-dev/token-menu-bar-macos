import XCTest

final class TokenMenuBarApplicationUITests: XCTestCase {
  @MainActor
  func testQuitClosesTheVerificationApplication() {
    let verification = VerificationApplication(testName: name)
    addTeardownBlock { @MainActor in verification.terminate() }
    verification.launch()
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))

    verification.application.buttons["footer-quit"].click()

    XCTAssertTrue(verification.application.wait(for: .notRunning, timeout: 2))
  }

  @MainActor
  func testDemoCanTurnOffAndBackOnWithoutLeavingVerification() async throws {
    let verification = VerificationApplication(testName: name, detailedLogging: true)
    addTeardownBlock { @MainActor in verification.terminate() }
    verification.launch()
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    let originalProcess = try verification.processIdentifier()

    verification.application.buttons["disable-demo-data"].click()

    let relaunchedWithoutDemo = try await verification.waitForRelaunch(from: originalProcess)
    XCTAssertTrue(relaunchedWithoutDemo)
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    XCTAssertFalse(verification.application.buttons["disable-demo-data"].exists)
    XCTAssertEqual(
      verification.application.descendants(matching: .any).matching(
        NSPredicate(format: "identifier BEGINSWITH %@", "usage-provider-")
      ).count, 0)
    verification.selectTab("Settings")
    let support = verification.application.descendants(matching: .any)["disclosure-settings.support"]
    XCTAssertTrue(support.waitForExistence(timeout: 2))
    support.disclosureTriangles.firstMatch.click()
    let demo = verification.application.checkBoxes["Demo data"]
    XCTAssertTrue(demo.waitForExistence(timeout: 2))
    XCTAssertEqual(demo.value as? Int, 0)
    let emptyProcess = try verification.processIdentifier()

    demo.click()

    let relaunchedWithDemo = try await verification.waitForRelaunch(from: emptyProcess)
    XCTAssertTrue(relaunchedWithDemo)
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    verification.selectTab("Usage")
    XCTAssertTrue(verification.application.buttons["disable-demo-data"].waitForExistence(timeout: 2))
  }

  @MainActor
  func testStatusItemReopensThePopoverAfterEscape() {
    let verification = VerificationApplication(testName: name, detailedLogging: true)
    addTeardownBlock { @MainActor in verification.terminate() }
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
    let verification = VerificationApplication(testName: name, detailedLogging: true)
    addTeardownBlock { @MainActor in verification.terminate() }
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
        let dates = verification.application.buttons["history-date-range"]
        XCTAssertTrue(dates.waitForExistence(timeout: 2))
        dates.click()
        for identifier in ["history-from", "history-to"] {
          XCTAssertTrue(verification.application.datePickers[identifier].waitForExistence(timeout: 2))
          XCTAssertTrue(verification.application.datePickers[identifier].isEnabled)
        }
      default:
        XCTAssertTrue(
          verification.application.descendants(matching: .any)["model-filter"].waitForExistence(timeout: 2))
      }
    }
  }

  @MainActor
  func testTabSwitchReturnsToIdle() throws {
    let verification = VerificationApplication(testName: name)
    addTeardownBlock { @MainActor in verification.terminate() }
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
    addTeardownBlock { @MainActor in verification.terminate() }
    verification.launch()

    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    verification.tab("Settings").click()
    verification.application.typeKey("f", modifierFlags: .command)
    let filter = verification.application.textFields["model-filter"]
    XCTAssertTrue(filter.waitForExistence(timeout: 2))
    filter.typeText("codex")
    XCTAssertEqual(filter.value as? String, "codex")
    XCTAssertFalse(verification.application.textFields["Search log"].exists)
  }

  @MainActor
  func testEscapeClosesEveryTab() {
    let verification = VerificationApplication(testName: name, detailedLogging: true)
    addTeardownBlock { @MainActor in verification.terminate() }
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
    addTeardownBlock { @MainActor in verification.terminate() }

    let duration = verification.launch()

    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    XCTAssertLessThan(duration, 5)
  }

  @MainActor
  func testPhysicalFootprintStaysWithinBudget() throws {
    let verification = VerificationApplication(testName: name)
    addTeardownBlock { @MainActor in verification.terminate() }
    verification.launch()

    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    print(try verification.processSnapshot())
    XCTAssertLessThan(try verification.physicalFootprintBytes(), 256 * 1024 * 1024)
  }

  @MainActor
  func testIdleCPUStaysWithinBudget() throws {
    let verification = VerificationApplication(testName: name)
    addTeardownBlock { @MainActor in verification.terminate() }
    verification.launch()

    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    Thread.sleep(forTimeInterval: 1)
    let before = try verification.cpuTime()
    Thread.sleep(forTimeInterval: 2)
    let consumed = try verification.cpuTime() - before
    XCTAssertLessThan(consumed, 0.5)
  }
}
