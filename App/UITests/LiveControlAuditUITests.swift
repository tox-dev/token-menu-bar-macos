import AppKit
import CoreGraphics
import Foundation
import TokenMenuBarCore
import XCTest

final class LiveControlAuditUITests: XCTestCase {
  private let controlTimeout = 5.0

  override func tearDownWithError() throws {
    let directory = try outputDirectory()
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    where ["png", "json"].contains(file.pathExtension) {
      let attachment = XCTAttachment(
        data: try Data(contentsOf: file),
        uniformTypeIdentifier: file.pathExtension == "png" ? "public.png" : "public.json")
      attachment.name = file.lastPathComponent
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    try super.tearDownWithError()
  }

  @MainActor
  func testUsageControlsRespond() throws {
    try auditControls(tab: "Usage")
  }

  @MainActor
  func testHistoryDatesAndControlsRespond() throws {
    try auditControls(tab: "History")
  }

  @MainActor
  func testFileChoosersReturnToThePopover() throws {
    let verification = VerificationApplication(
      testName: name, profile: VerificationProfile(fixture: .controlAudit, nativePanels: true), detailedLogging: true)
    addTeardownBlock { @MainActor in await verification.terminate() }
    try verification.launch()
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    verification.tab("History").click()
    let application = verification.application
    let export = application.buttons["history-export"]
    XCTAssertTrue(export.waitForExistence(timeout: 2))
    export.click()
    retainChooserScreenshot(application, named: "History export sheet")
    assertAndCancelNativePanel(application, rootedAt: verification.supportDirectory)
    XCTAssertTrue(verification.tabs.isEnabled)

    verification.tab("Settings").click()
    let surface = application.descendants(matching: .any)["popover-surface"]
    let row = application.descendants(matching: .any)["Claude setup"]
    let grant = row.buttons.matching(NSPredicate(format: "label IN %@", ["Grant", "Grant Again"])).firstMatch
    XCTAssertTrue(reveal(grant, in: surface))
    grant.click()
    retainChooserScreenshot(application, named: "Provider resource sheet")
    assertAndCancelNativePanel(application, rootedAt: verification.supportDirectory)
    XCTAssertTrue(verification.tabs.isEnabled)
    verification.tab("Usage").click()
    XCTAssertTrue(application.descendants(matching: .any)["tab-content-Usage"].waitForExistence(timeout: 2))
  }

  @MainActor
  private func retainChooserScreenshot(_ application: XCUIApplication, named name: String) {
    let cancel = application.buttons["CancelButton"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 2))
    XCTAssertTrue(cancel.isHittable)
    let attachment = XCTAttachment(screenshot: application.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  func testHistoryExportSavesTheSelectedPeriod() throws {
    let verification = VerificationApplication(
      testName: name, profile: VerificationProfile(fixture: .controlAudit, nativePanels: true))
    addTeardownBlock { @MainActor in await verification.terminate() }
    try verification.launch()
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    verification.tab("History").click()
    let application = verification.application
    let period = application.descendants(matching: .any)["history-period"]
    segment("Today", in: period).click()
    let destination = verification.supportDirectory.appendingPathComponent("token-menu-bar-history.csv")
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

    application.buttons["history-export"].click()
    let save = application.sheets["save-panel"].buttons["OKButton"]
    XCTAssertTrue(save.waitForExistence(timeout: 2))
    XCTAssertTrue(save.isHittable)
    save.click()

    XCTAssertTrue(
      waitUntil(timeout: 2) {
        ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0)
          > "timestamp,key,label,used_percent,resets_at\n".utf8.count
      }, "The selected-period export did not write its header and synthetic samples")
    let rows = try String(contentsOf: destination, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(rows.first, "timestamp,key,label,used_percent,resets_at")
    XCTAssertGreaterThan(rows.count, 1, "The selected period exported no synthetic samples")
    XCTAssertTrue(verification.tabs.isEnabled)
    verification.tab("Usage").click()
    XCTAssertTrue(application.descendants(matching: .any)["tab-content-Usage"].waitForExistence(timeout: 2))
  }

  @MainActor
  func testSettingsMenuBarControlsRespond() throws {
    try auditControls(tab: "Settings", section: .menuBar)
  }

  @MainActor func testCustomTemplateSupportsMultilineEditing() throws {
    let verification = VerificationApplication(testName: name, profile: VerificationProfile(fixture: .controlAudit))
    addTeardownBlock { @MainActor in await verification.terminate() }
    try verification.launch()
    verification.selectTab("Settings")
    let application = verification.application
    let surface = application.descendants(matching: .any)["popover-surface"]
    let format = segmentedControl(named: "Format", application: application)
    XCTAssertTrue(reveal(format, in: surface))
    segment("Custom", in: format).click()
    let editor = application.textViews["status-template"]
    _ = try XCTUnwrap(editor.waitForExistence(timeout: 2) ? editor : nil, "Template must name the editable text view")
    XCTAssertTrue(editor.isEnabled)
    XCTAssertEqual(editor.label, "Template")
    XCTAssertTrue(reveal(editor, in: surface))
    replaceText(in: editor, with: "{label}\n{pct}", application: application)
  }

  @MainActor func testSettingsModelSelectionControlsRespond() throws {
    try auditControls(tab: "Settings", section: .menuBar, modelSelectionOnly: true)
  }

  @MainActor func testSettingsAboutControlsRespond() throws {
    try auditControls(tab: "Settings", section: .about)
  }

  @MainActor func testSettingsProviderControlsRespond() throws {
    try auditControls(tab: "Settings", section: .providers)
  }

  @MainActor func testSettingsProviderAccessActionsRespond() throws {
    executionTimeAllowance = 300
    let verification = VerificationApplication(
      testName: name, profile: VerificationProfile(fixture: .controlAudit, nativePanels: true), detailedLogging: true)
    addTeardownBlock { @MainActor in await verification.terminate() }
    try verification.launch()
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    verification.tab("Settings").click()
    let application = verification.application
    let surface = application.descendants(matching: .any)["popover-surface"]
    let records = exerciseProviderAccessActions(
      application, surface: surface, supportDirectory: verification.supportDirectory)
    let output = try outputDirectory()
    try write(records, to: output.appendingPathComponent("control-matrix-provider-access.json"))
    try application.screenshot().pngRepresentation.write(to: output.appendingPathComponent("provider-access.png"))
    XCTAssertTrue(records.allSatisfy { $0.result == "passed" })
    print("CONTROL_AUDIT=\(output.path) controls=\(records.count)")
  }

  @MainActor func testSettingsDataControlsRespond() throws {
    try auditControls(tab: "Settings", section: .data)
  }

  @MainActor func testSettingsNotificationControlsRespond() throws {
    try auditControls(tab: "Settings", section: .notifications)
  }

  @MainActor func testSettingsLogControlsRespond() throws {
    try auditControls(tab: "Settings", section: .log)
  }

  @MainActor
  private func auditControls(
    tab: String, section: SettingsSection? = nil, modelSelectionOnly: Bool = false
  ) throws {
    executionTimeAllowance = 300
    let verification = VerificationApplication(
      testName: name, profile: VerificationProfile(fixture: .controlAudit, nativePanels: true),
      detailedLogging: tab == "History" || section == .menuBar)
    addTeardownBlock { @MainActor in await verification.terminate() }
    try verification.launch()
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    verification.application.activate()

    let output = try outputDirectory()
    var records: [ControlAuditRecord] = []
    defer { try? write(records, to: output.appendingPathComponent("control-matrix-\(tab.lowercased()).json")) }
    do {
      if tab != "Usage" { verification.tab(tab).click() }
      XCTAssertTrue(
        verification.application.descendants(matching: .any)["tab-content-\(tab)"].waitForExistence(timeout: 2))
      if tab == "Settings" {
        XCTAssertTrue(verification.application.textFields["model-filter"].waitForExistence(timeout: 2))
      }
      if tab != "History" && !modelSelectionOnly {
        try expandSupportingDetails(in: verification.application, section: section)
      }
      if tab == "History" {
        records += try exerciseHistoryControls(
          verification.application, supportDirectory: verification.supportDirectory)
      }
      if tab == "Settings" {
        let application = verification.application
        let surface = application.descendants(matching: .any)["popover-surface"]
        switch section! {
        case .about:
          records += exerciseAboutControls(application, surface: surface)
          records += try exerciseResetAndReopen(
            application, statusItem: verification.statusItem,
            processIdentifier: verification.processIdentifier(), reopen: verification.openPopover)
        case .menuBar:
          records +=
            try modelSelectionOnly
            ? exerciseModelSelectionControls(application)
            : exerciseMenuBarControls(application, statusItem: verification.statusItem)
        case .providers:
          records += exerciseProviderControls(application, surface: surface)
        case .data:
          records += exerciseDataControls(
            application, surface: surface, supportDirectory: verification.supportDirectory)
        case .notifications:
          records += exerciseNotificationControls(application, surface: surface)
        case .log:
          records += exerciseLogControls(application, surface: surface, reopen: verification.openPopover)
        }
      }
      if tab == "Usage" { records += exerciseUsageControls(verification.application) }
      try verification.application.screenshot().pngRepresentation.write(
        to: output.appendingPathComponent("controls-\(tab.lowercased()).png"))
    }

    let failures = records.filter { $0.result.hasPrefix("failed") }
    assertRequiredInventory(records, tab: tab, section: section, modelSelectionOnly: modelSelectionOnly)
    XCTAssertTrue(failures.isEmpty, failures.map { "\($0.tab): \($0.label) \($0.result)" }.joined(separator: "\n"))
    XCTAssertTrue(records.contains { $0.tab == tab && $0.interacted })
    print("CONTROL_AUDIT=\(output.path) controls=\(records.count) failures=\(failures.count)")
  }

  @MainActor
  func testLongTextAtWideWidthInLightAppearance() throws {
    try auditLongText(appearance: .light, widthName: "wide", width: nil)
  }

  @MainActor
  func testLongTextAtNarrowWidthInLightAppearance() throws {
    try auditLongText(appearance: .light, widthName: "narrow", width: 752)
  }

  @MainActor
  func testLongTextAtWideWidthInDarkAppearance() throws {
    try auditLongText(appearance: .dark, widthName: "wide", width: nil)
  }

  @MainActor
  func testLongTextAtNarrowWidthInDarkAppearance() throws {
    try auditLongText(appearance: .dark, widthName: "narrow", width: 752)
  }

  @MainActor
  func testLongSettingsTextAtWideWidthInLightAppearance() throws {
    try auditLongText(appearance: .light, widthName: "wide", width: nil, tabs: ["Settings"])
  }

  @MainActor
  func testLongSettingsTextAtNarrowWidthInLightAppearance() throws {
    try auditLongText(appearance: .light, widthName: "narrow", width: 752, tabs: ["Settings"])
  }

  @MainActor
  func testLongSettingsTextAtWideWidthInDarkAppearance() throws {
    try auditLongText(appearance: .dark, widthName: "wide", width: nil, tabs: ["Settings"])
  }

  @MainActor
  func testLongSettingsTextAtNarrowWidthInDarkAppearance() throws {
    try auditLongText(appearance: .dark, widthName: "narrow", width: 752, tabs: ["Settings"])
  }

  @MainActor
  private func auditLongText(
    appearance: VerificationApplication.Appearance, widthName: String, width: Double?,
    tabs: [String] = ["Usage", "History"]
  ) throws {
    executionTimeAllowance = 300
    let output = try outputDirectory()
    let verification = VerificationApplication(
      testName: "\(name)-\(appearance.rawValue)-\(widthName)",
      profile: VerificationProfile(fixture: .longText, visibleFrameWidth: width),
      appearance: appearance, doubleLocalizedStrings: true, detailedLogging: true)
    addTeardownBlock { @MainActor in await verification.terminate() }
    try verification.launch()
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    let surface = verification.application.descendants(matching: .any)["popover-surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 2))
    let window = verification.application.windows["Token Menu Bar"]
    let chromeWidth = window.frame.width - surface.frame.width
    let expectedWidth = min(880, (width ?? Double.greatestFiniteMagnitude) - 24 - chromeWidth)
    XCTAssertEqual(surface.frame.width, expectedWidth, accuracy: 3)

    for tab in tabs {
      verification.tab(tab).click()
      XCTAssertTrue(
        verification.application.descendants(matching: .any)["tab-content-\(tab)"].waitForExistence(timeout: 2))
      if tab == "Settings" {
        XCTAssertTrue(verification.application.textFields["model-filter"].waitForExistence(timeout: 2))
      }
      if tab != "History" { try expandSupportingDetails(in: verification.application) }
      if tab == "Usage" {
        XCTAssertTrue(
          verification.application.descendants(matching: .any).matching(
            NSPredicate(
              format: "label CONTAINS %@", "Verification warning text is intentionally long")
          ).firstMatch.waitForExistence(timeout: 5))
      }
      let exposedText = try captureAndAuditPages(
        tab: tab, surface: surface, application: verification.application, output: output,
        prefix: "\(appearance.rawValue.lowercased())-\(widthName)")
      if tab == "Usage" {
        XCTAssertTrue(exposedText.contains { $0.contains("Verification warning text is intentionally long") })
        XCTAssertTrue(exposedText.contains { $0.contains("usage window with a deliberately long model name") })
      }
      if tab == "Settings" {
        XCTAssertTrue(exposedText.contains { $0.contains("account-profile-with-a-deliberately-long-file-name") })
      }
    }
    print("LONG_TEXT_AUDIT=\(output.path)")
  }

  @MainActor
  func testUsageRichTooltipsStayAdjacent() throws {
    try auditRichTooltips(tab: "Usage")
  }

  @MainActor
  func testHistoryRichTooltipsStayAdjacent() throws {
    try auditRichTooltips(tab: "History")
  }

  @MainActor
  func testSettingsRichTooltipsStayAdjacentAndTabsHaveNone() throws {
    try auditRichTooltips(tab: "Settings")
  }

  @MainActor
  private func auditRichTooltips(tab: String) throws {
    executionTimeAllowance = 90
    let verification = VerificationApplication(testName: name, detailedLogging: true)
    addTeardownBlock { @MainActor in await verification.terminate() }
    try verification.launch()
    XCTAssertTrue(verification.tabs.waitForExistence(timeout: 5))
    let output = try outputDirectory()
    let processIdentifier = try verification.processIdentifier()

    do {
      verification.tab(tab).click()
      XCTAssertTrue(
        verification.application.descendants(matching: .any)["tab-content-\(tab)"].waitForExistence(timeout: 2))
      if tab == "Settings" {
        XCTAssertTrue(verification.application.textFields["model-filter"].waitForExistence(timeout: 2))
      }
      let surface = verification.application.descendants(matching: .any)["popover-surface"]
      XCTAssertGreaterThanOrEqual(
        try tooltipCandidates(in: surface).count, 5, "\(tab) did not expose tooltip controls across the panel")
      for position in ["top", "bottom", "left", "right", "center"] {
        let control = try XCTUnwrap(tooltipCandidates(in: surface).first { $0.0 == position }?.1)
        XCTAssertTrue(
          waitUntil(timeout: controlTimeout) { control.isHittable },
          "Tooltip target \(control.identifier) is not hittable at \(control.frame)")
        print("TOOLTIP_TARGET tab=\(tab) position=\(position) id=\(control.identifier) frame=\(control.frame)")
        let delay: TimeInterval = tab == "History" && !control.identifier.hasPrefix("footer-") ? 1.2 : 0.15
        movePointerOffPanel(in: verification.application)
        Thread.sleep(forTimeInterval: 0.15)
        let baseline = applicationWindows(processIdentifier: processIdentifier)
        let hoverStarted = ProcessInfo.processInfo.systemUptime
        control.hover()
        let hoverReturned = ProcessInfo.processInfo.systemUptime
        if hoverReturned - hoverStarted < delay - 0.05 {
          Thread.sleep(forTimeInterval: max(0, delay - 0.02 - (ProcessInfo.processInfo.systemUptime - hoverStarted)))
          XCTAssertTrue(
            applicationWindows(processIdentifier: processIdentifier).allSatisfy { baseline[$0.key] != nil },
            "Tooltip appeared before its \(Int(delay * 1_000)) ms threshold")
        }
        let tooltip = try waitForTooltip(
          processIdentifier: processIdentifier, excluding: baseline, timeout: delay + 0.6)
        let showLatency = ProcessInfo.processInfo.systemUptime - hoverStarted
        XCTAssertGreaterThanOrEqual(showLatency, delay - 0.02, "Tooltip appeared before its configured delay")
        let delta = distance(between: control.frame, and: tooltip.frame)
        XCTAssertLessThanOrEqual(delta, 20, "Tooltip was not adjacent to \(control.label)")
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(tooltip.frame), "Tooltip left the active screen")
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).hover()
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertNotNil(
          applicationWindows(processIdentifier: processIdentifier)[tooltip.identifier],
          "Tooltip flickered while the pointer stayed inside \(control.label)")
        try verification.application.screenshot().pngRepresentation.write(
          to: output.appendingPathComponent("tooltip-\(tab.lowercased())-\(position).png"))
        print(
          "TOOLTIP tab=\(tab) control=\(control.label) position=\(position) show_ms=\(Int(showLatency * 1_000)) "
            + "delta=\(delta) frame=\(tooltip.frame)")
        movePointerOffPanel(in: verification.application)
        let dismissStarted = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(
          waitUntil(timeout: 0.25) {
            applicationWindows(processIdentifier: processIdentifier)[tooltip.identifier] == nil
          }, "Tooltip did not dismiss by the 250 ms scheduler-safe ceiling")
        print(
          "TOOLTIP_DISMISS tab=\(tab) control=\(control.label) after_driver_ms=\(Int((ProcessInfo.processInfo.systemUptime - dismissStarted) * 1_000))"
        )
      }

      if let scrollView = surface.scrollViews.allElementsBoundByIndex.first(where: { $0.isHittable }),
        let control = try tooltipCandidates(in: surface).first?.1
      {
        let baseline = applicationWindows(processIdentifier: processIdentifier)
        control.hover()
        let tooltip = try waitForTooltip(
          processIdentifier: processIdentifier, excluding: baseline, timeout: tab == "History" ? 1.8 : 0.75)
        scrollView.scroll(byDeltaX: 0, deltaY: -180)
        XCTAssertTrue(
          waitUntil(timeout: 0.15) {
            applicationWindows(processIdentifier: processIdentifier)[tooltip.identifier] == nil
          }, "Scrolling did not dismiss the tooltip immediately")
        movePointerOffPanel(in: verification.application)
        if let scrolledControl = try tooltipCandidates(in: surface).first?.1 {
          let scrolledBaseline = applicationWindows(processIdentifier: processIdentifier)
          scrolledControl.hover()
          let scrolledTooltip = try waitForTooltip(
            processIdentifier: processIdentifier, excluding: scrolledBaseline, timeout: tab == "History" ? 1.8 : 0.75)
          XCTAssertLessThanOrEqual(distance(between: scrolledControl.frame, and: scrolledTooltip.frame), 20)
          XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(scrolledTooltip.frame))
          try verification.application.screenshot().pngRepresentation.write(
            to: output.appendingPathComponent("tooltip-\(tab.lowercased())-after-scroll.png"))
          movePointerOffPanel(in: verification.application)
          XCTAssertTrue(
            waitUntil(timeout: 0.25) {
              applicationWindows(processIdentifier: processIdentifier)[scrolledTooltip.identifier] == nil
            })
        }
      }
    }

    guard tab == "Settings" else { return }
    for tab in ["Usage", "History", "Settings"] {
      movePointerOffPanel(in: verification.application)
      Thread.sleep(forTimeInterval: 0.2)
      let baseline = applicationWindows(processIdentifier: processIdentifier)
      verification.tab(tab).hover()
      Thread.sleep(forTimeInterval: 0.25)
      let newWindows = applicationWindows(processIdentifier: processIdentifier).filter { baseline[$0.key] == nil }
      XCTAssertTrue(newWindows.isEmpty, "Tab \(tab) presented a tooltip")
    }

    verification.tab("Settings").click()
    let surface = verification.application.descendants(matching: .any)["popover-surface"]
    if let control = try tooltipCandidates(in: surface).first?.1 {
      movePointerOffPanel(in: verification.application)
      let tabBaseline = applicationWindows(processIdentifier: processIdentifier)
      control.hover()
      let tabTooltip = try waitForTooltip(
        processIdentifier: processIdentifier, excluding: tabBaseline, timeout: 0.75)
      verification.tab("Usage").click()
      XCTAssertTrue(
        waitUntil(timeout: 0.15) {
          applicationWindows(processIdentifier: processIdentifier)[tabTooltip.identifier] == nil
        }, "Tab switching did not dismiss the tooltip immediately")

      let usageSurface = verification.application.descendants(matching: .any)["popover-surface"]
      let escapeBaseline = applicationWindows(processIdentifier: processIdentifier)
      try tooltipCandidates(in: usageSurface).first?.1.hover()
      let escapeTooltip = try waitForTooltip(
        processIdentifier: processIdentifier, excluding: escapeBaseline, timeout: 0.75)
      verification.application.typeKey(.escape, modifierFlags: [])
      XCTAssertTrue(
        waitUntil(timeout: 0.15) {
          applicationWindows(processIdentifier: processIdentifier)[escapeTooltip.identifier] == nil
        }, "Escape did not dismiss the tooltip immediately")
      XCTAssertTrue(verification.tabs.waitForNonExistence(timeout: 2), "Escape did not close the popup")
      verification.openPopover()
      XCTAssertTrue(verification.tabs.waitForExistence(timeout: 2))
    }
    print("TOOLTIP_AUDIT=\(output.path)")
  }

  @MainActor
  private func exerciseHistoryControls(
    _ application: XCUIApplication, supportDirectory: URL
  ) throws -> [ControlAuditRecord] {
    var records: [ControlAuditRecord] = []
    let period = application.descendants(matching: .any)["history-period"]
    let rollup = application.descendants(matching: .any)["history-rollup"]
    let metric = application.descendants(matching: .any)["history-metric"]
    let start = application.datePickers["history-from"]
    let end = application.datePickers["history-to"]
    XCTAssertTrue(period.waitForExistence(timeout: 2))
    XCTAssertEqual(segments(in: period).count, 6, "History must expose Now, four fixed periods, and Custom")
    XCTAssertTrue(metric.waitForExistence(timeout: 2))
    try selectMenuItem("Usage %", from: metric, application: application)
    let utc = application.checkBoxes["UTC"]
    XCTAssertTrue(utc.waitForExistence(timeout: 2))
    XCTAssertTrue(utc.isEnabled)
    toggleAndRestore(utc)
    records.append(scenarioRecord(tab: "History", label: "UTC boundaries", element: utc, action: "toggle twice"))
    XCTAssertTrue(rollup.waitForExistence(timeout: 2))
    XCTAssertTrue(rollup.isEnabled, "Window Usage must enable Rollup")
    XCTAssertEqual(segments(in: rollup).count, 3, "Rollup must expose Minute, Hour, and Day")
    for label in ["Minute", "Hour", "Day"] {
      let option = segment(label, in: rollup)
      XCTAssertTrue(option.isHittable)
      option.click()
      XCTAssertTrue(waitUntil(timeout: controlTimeout) { self.isSelected(option) })
    }
    records.append(scenarioRecord(tab: "History", label: "Window Usage rollups", element: rollup))

    try selectMenuItem("Input tokens", from: metric, application: application)
    XCTAssertTrue(rollup.waitForNonExistence(timeout: 2), "Daily analytics must hide the inapplicable rollup")
    XCTAssertFalse(utc.exists, "Daily analytics always use UTC")
    let stacked = application.checkBoxes["history-stacked"]
    XCTAssertTrue(stacked.waitForExistence(timeout: 2))
    XCTAssertTrue(stacked.isEnabled, "An additive metric with parallel series must enable Stacked")
    toggleAndRestore(stacked)
    records.append(scenarioRecord(tab: "History", label: "Additive metric stacking", element: stacked))

    XCTAssertTrue(application.descendants(matching: .any)["history-chart"].waitForExistence(timeout: 2))
    let series = application.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "history-series-")
    ).allElementsBoundByIndex
    XCTAssertGreaterThan(series.count, 1, "Input tokens must expose more than one data series")
    for toggle in series {
      XCTAssertTrue(toggle.isEnabled)
      XCTAssertTrue(toggle.isHittable)
      toggle.click()
      toggle.click()
    }
    let firstSeries = try XCTUnwrap(series.first)
    records.append(
      scenarioRecord(tab: "History", label: "\(series.count) legend series off and on", element: firstSeries))

    try selectMenuItem("Usage %", from: metric, application: application)
    segment("Today", in: period).click()
    let previous = application.buttons["history-previous-period"]
    let next = application.buttons["history-next-period"]
    XCTAssertTrue(previous.waitForExistence(timeout: 2))
    XCTAssertTrue(previous.isEnabled)
    previous.click()
    XCTAssertTrue(waitUntil(timeout: controlTimeout) { next.isEnabled })
    next.click()
    previous.click()
    let now = segment("Now", in: period)
    XCTAssertTrue(now.isHittable)
    now.click()
    XCTAssertTrue(waitUntil(timeout: controlTimeout) { self.isSelected(now) })
    records.append(scenarioRecord(tab: "History", label: "Previous, next, and Now", element: period))

    let custom = segment("Custom", in: period)
    custom.click()
    XCTAssertTrue(start.waitForExistence(timeout: 2))
    XCTAssertTrue(end.waitForExistence(timeout: 2))
    XCTAssertTrue(start.isEnabled)
    XCTAssertTrue(end.isEnabled)
    // Widen the range before moving To so both edits remain within its bounds.
    adjustDate(start, increasing: false)
    adjustDate(end, increasing: false)
    adjustDate(end, increasing: true)
    adjustDate(start, increasing: true)
    segment("Today", in: period).click()
    XCTAssertTrue(start.waitForNonExistence(timeout: 2))
    application.buttons["history-date-range"].click()
    XCTAssertTrue(start.waitForExistence(timeout: 2))
    adjustDate(start, increasing: false)
    XCTAssertTrue(isSelected(custom))
    records.append(scenarioRecord(tab: "History", label: "Custom From and To", element: start))

    let export = application.buttons["history-export"]
    XCTAssertTrue(export.waitForExistence(timeout: 2))
    let exportRecord = scenarioRecord(tab: "History", label: "Export CSV save panel Cancel", element: export)
    export.click()
    assertAndCancelNativePanel(application, rootedAt: supportDirectory)
    records.append(exportRecord)
    return records
  }

  @MainActor
  private func exerciseUsageControls(_ application: XCUIApplication) -> [ControlAuditRecord] {
    let surface = application.descendants(matching: .any)["popover-surface"]
    scrollToTop(surface)
    var records: [ControlAuditRecord] = []
    let refresh = application.buttons["footer-refresh"]
    XCTAssertTrue(refresh.waitForExistence(timeout: 2))
    XCTAssertTrue(refresh.isHittable)
    refresh.click()
    records.append(scenarioRecord(tab: "Usage", label: "Refresh all providers", element: refresh, action: "click"))

    var copiedValues = 0
    for provider in ProviderID.allCases {
      let providerRefresh = application.buttons["Refresh \(provider.displayName)"]
      XCTAssertTrue(reveal(providerRefresh, in: surface), "Missing \(provider.displayName) Usage refresh")
      XCTAssertTrue(waitUntil(timeout: 2) { providerRefresh.isEnabled })
      providerRefresh.click()
      records.append(
        scenarioRecord(
          tab: "Usage", label: "Refresh \(provider.displayName)", element: providerRefresh, action: "click"))

      let card = application.descendants(matching: .any)["usage-provider-\(provider.rawValue)"]
      XCTAssertTrue(card.exists)
      let copyButtons = card.buttons.matching(
        NSPredicate(format: "label BEGINSWITH 'Copy ' AND label != 'Copy Diagnostics'")
      ).allElementsBoundByIndex.filter(\.isHittable)
      for copy in copyButtons {
        let value = String(copy.label.dropFirst("Copy ".count))
        let primary = surface.buttons[value].firstMatch
        if primary.exists && primary.isHittable {
          primary.click()
          records.append(
            scenarioRecord(
              tab: "Usage", label: "\(provider.displayName) identity \(value)", element: primary,
              action: "click"))
        }
        copy.click()
        records.append(
          scenarioRecord(
            tab: "Usage", label: "\(provider.displayName) copy \(value)", element: copy,
            action: "click"))
        copiedValues += 1
      }
    }
    XCTAssertGreaterThanOrEqual(copiedValues, ProviderID.allCases.count)
    XCTAssertFalse(application.links.firstMatch.exists, "Usage must not expose usage-site links")
    XCTAssertFalse(
      application.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Sign in to '")).firstMatch.exists,
      "Sign-in guidance belongs in Providers, not Usage")
    records.append(absenceRecord(tab: "Usage", label: "Usage-site links", action: "assert absent"))
    records.append(absenceRecord(tab: "Usage", label: "Sign-in prompts", action: "assert absent"))
    return records
  }

  @MainActor
  private func exerciseMenuBarControls(
    _ application: XCUIApplication, statusItem: XCUIElement
  ) throws -> [ControlAuditRecord] {
    let surface = application.descendants(matching: .any)["popover-surface"]
    var records: [ControlAuditRecord] = []
    scrollToTop(surface)

    let adaptiveWidth = application.checkBoxes["Fit to space"]
    XCTAssertTrue(reveal(adaptiveWidth, in: surface))
    let wasAdaptive = isSelected(adaptiveWidth)
    set(adaptiveWidth, enabled: false)
    defer {
      if reveal(adaptiveWidth, in: surface) { set(adaptiveWidth, enabled: wasAdaptive) }
    }
    scrollToTop(surface)

    let order = segmentedControl(named: "Order", application: application)
    let stable = segment("Stable", in: order)
    stable.click()
    XCTAssertTrue(waitUntil(timeout: controlTimeout) { self.isSelected(stable) })
    let moveLater = application.buttons.matching(
      NSPredicate(format: "label BEGINSWITH 'Move ' AND label ENDSWITH ' later'")
    ).firstMatch
    XCTAssertTrue(reveal(moveLater, in: surface), "Stable order did not expose a Move Later button")
    moveLater.click()
    let moveEarlier = application.buttons.matching(
      NSPredicate(format: "label BEGINSWITH 'Move ' AND label ENDSWITH ' earlier'")
    ).firstMatch
    XCTAssertTrue(reveal(moveEarlier, in: surface), "Stable order did not expose a Move Earlier button")
    moveEarlier.click()
    records.append(scenarioRecord(tab: "Settings", label: "Stable order move later and earlier", element: order))

    scrollToTop(surface)
    let format = segmentedControl(named: "Format", application: application)
    let frameBeforeStatusEdits = statusItem.frame
    let panelBeforeStatusEdits = surface.frame
    let formatSignature = try contentSignature(statusItem)
    let customFormat = segment("Custom", in: format)
    customFormat.click()
    XCTAssertTrue(waitUntil(timeout: controlTimeout) { self.isSelected(customFormat) })
    XCTAssertTrue(
      try waitUntil(timeout: controlTimeout) { try self.contentSignature(statusItem) != formatSignature })
    assertAnchorsHeld(
      statusItem: statusItem, statusFrame: frameBeforeStatusEdits,
      surface: surface, panelFrame: panelBeforeStatusEdits, action: "Format")
    let template = application.textViews["Template"]
    XCTAssertTrue(template.waitForExistence(timeout: 2))
    XCTAssertTrue(application.staticTexts["{cell}  {pct}  {label}  {provider}  {window}  {reset}  {pctOrReset}"].exists)

    let originalTemplate = template.value as? String ?? ""
    let templateSignature = try contentSignature(statusItem)
    replaceText(in: template, with: "{label}:{pct}", application: application)
    XCTAssertTrue(
      try waitUntil(timeout: controlTimeout) { try self.contentSignature(statusItem) != templateSignature })
    assertAnchorsHeld(
      statusItem: statusItem, statusFrame: frameBeforeStatusEdits,
      surface: surface, panelFrame: panelBeforeStatusEdits, action: "Template")

    let decimals = application.steppers["percent-decimals"]
    XCTAssertTrue(decimals.waitForExistence(timeout: 2))
    let decimalsSignature = try contentSignature(statusItem)
    incrementStepper(decimals)
    XCTAssertTrue(
      try waitUntil(timeout: controlTimeout) { try self.contentSignature(statusItem) != decimalsSignature })
    assertAnchorsHeld(
      statusItem: statusItem, statusFrame: frameBeforeStatusEdits,
      surface: surface, panelFrame: panelBeforeStatusEdits, action: "Decimals")

    let label = application.textFields["Label"].firstMatch
    XCTAssertTrue(reveal(label, in: surface), "The model list did not expose a short-label field")
    let originalLabel = label.value as? String ?? ""
    XCTAssertFalse(originalLabel.isEmpty, "Short labels must be prefilled")
    label.click()
    application.typeKey("a", modifierFlags: .command)
    label.typeText("TOOLONG")
    XCTAssertTrue(
      waitUntil(timeout: controlTimeout) { (label.value as? String) == "TOOLON" },
      "Expected bounded short label TOOLON; editable value: \(String(describing: label.value))")
    let labelSignature = try contentSignature(statusItem)
    replaceText(in: label, with: "VX", application: application)
    application.typeKey(.enter, modifierFlags: [])
    XCTAssertTrue(
      try waitUntil(timeout: controlTimeout) { try self.contentSignature(statusItem) != labelSignature })
    assertAnchorsHeld(
      statusItem: statusItem, statusFrame: frameBeforeStatusEdits,
      surface: surface, panelFrame: panelBeforeStatusEdits, action: "Short label")
    let revert = application.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Revert label for '")).firstMatch
    XCTAssertTrue(revert.waitForExistence(timeout: 2))
    let revertRecord = scenarioRecord(tab: "Settings", label: "Revert short label", element: revert, action: "click")
    revert.click()
    XCTAssertTrue(waitUntil(timeout: controlTimeout) { (label.value as? String) == originalLabel })
    records.append(
      scenarioRecord(tab: "Settings", label: "Prefilled six-character short label", element: label, action: "edit"))
    records.append(revertRecord)

    scrollToTop(surface)
    replaceText(in: template, with: originalTemplate, application: application)
    for label in ["Hide 0%", "Fit to space"] {
      let toggle = application.checkBoxes[label]
      XCTAssertTrue(toggle.exists && toggle.isHittable)
      toggleAndRestore(toggle)
      records.append(scenarioRecord(tab: "Settings", label: label, element: toggle, action: "toggle twice"))
    }
    let preview = application.descendants(matching: .any)["menu-bar-preview"]
    XCTAssertTrue(preview.exists)
    XCTAssertFalse(preview.buttons.allElementsBoundByIndex.isEmpty, "The preview must retain its model-cell buttons")
    records.append(scenarioRecord(tab: "Settings", label: "Live menu bar preview", element: preview, action: "observe"))
    records.append(scenarioRecord(tab: "Settings", label: "Model order", element: order, action: "select Stable"))
    records.append(scenarioRecord(tab: "Settings", label: "Status format", element: format, action: "select Custom"))
    records.append(scenarioRecord(tab: "Settings", label: "Decimals", element: decimals, action: "increment"))
    records.append(scenarioRecord(tab: "Settings", label: "Template and tokens", element: template, action: "edit"))
    records.append(
      scenarioRecord(tab: "Settings", label: "Live status content and fixed anchor", element: template))

    return records
  }

  @MainActor
  private func exerciseModelSelectionControls(_ application: XCUIApplication) throws -> [ControlAuditRecord] {
    let surface = application.descendants(matching: .any)["popover-surface"]
    var records: [ControlAuditRecord] = []
    scrollToTop(surface)
    let modelSelection = application.checkBoxes["model-selection-claude:session"]
    XCTAssertTrue(reveal(modelSelection, in: surface))
    toggleAndRestore(modelSelection)
    records.append(
      scenarioRecord(tab: "Settings", label: "Model selection", element: modelSelection, action: "toggle twice"))

    for provider in ProviderID.allCases {
      let providerSelection = application.checkBoxes["Show all \(provider.displayName) models"]
      try toggleModelGroupAndRestore(provider, toggle: providerSelection, surface: surface, application: application)
      records.append(
        scenarioRecord(
          tab: "Settings", label: "\(provider.displayName) model select-all", element: providerSelection,
          action: "select all, clear, and restore models"))
    }

    scrollToTop(surface)
    let modelFilter = application.textFields["model-filter"]
    XCTAssertTrue(reveal(modelFilter, in: surface))
    replaceText(in: modelFilter, with: "codex", application: application)
    replaceText(in: modelFilter, with: "", application: application)
    records.append(
      scenarioRecord(tab: "Settings", label: "Model filter", element: modelFilter, action: "type and clear"))
    application.typeKey("f", modifierFlags: .command)
    modelFilter.typeText("route")
    XCTAssertEqual(modelFilter.value as? String, "route", "Command-F did not focus Filter models")
    let logSearch = application.textFields["Search log"]
    if logSearch.exists { XCTAssertNotEqual(logSearch.value as? String, "route") }
    replaceText(in: modelFilter, with: "", application: application)
    records.append(
      scenarioRecord(tab: "Settings", label: "Command-F model filter", element: modelFilter, action: "⌘F then type"))

    let hideUnused = application.checkBoxes["Hide unused in range"]
    XCTAssertTrue(hideUnused.exists && hideUnused.isHittable)
    toggleAndRestore(hideUnused)
    records.append(
      scenarioRecord(tab: "Settings", label: "Hide unused models", element: hideUnused, action: "toggle twice"))
    return records
  }

  @MainActor
  private func exerciseResetAndReopen(
    _ application: XCUIApplication, statusItem: XCUIElement, processIdentifier: pid_t, reopen: () -> Void
  ) throws -> [ControlAuditRecord] {
    let surface = application.descendants(matching: .any)["popover-surface"]
    var records: [ControlAuditRecord] = []
    scrollToTop(surface)
    XCTAssertEqual(
      collectButtonLabels(prefix: "Reset", in: surface), ["Reset All Settings"],
      "Settings must expose only the guarded global reset")
    scrollToTop(surface)
    let reset = application.buttons["Reset All Settings"]
    XCTAssertTrue(reveal(reset, in: surface))
    reset.click()
    let alert = application.sheets.containing(.staticText, identifier: "Reset all settings?").firstMatch
    XCTAssertTrue(alert.waitForExistence(timeout: 2))
    XCTAssertTrue(alert.buttons["Cancel"].isHittable)
    alert.buttons["Cancel"].click()
    XCTAssertTrue(alert.waitForNonExistence(timeout: 2))
    records.append(scenarioRecord(tab: "Settings", label: "Reset All Settings Cancel", element: reset))

    application.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(popoverTabs(in: application).waitForNonExistence(timeout: 2))
    let reopenSampler = WindowFrameSampler(processIdentifier: processIdentifier)
    reopenSampler.start()
    reopen()
    XCTAssertTrue(popoverTabs(in: application).waitForExistence(timeout: 2))
    XCTAssertTrue(application.textFields["model-filter"].waitForExistence(timeout: 2))
    let reopenTimeline = reopenSampler.stop()
    XCTAssertFalse(reopenTimeline.isEmpty)
    if let settled = reopenTimeline.last?.frame {
      for sample in reopenTimeline {
        XCTAssertLessThan(abs(sample.frame.minX - settled.minX), 2, "Reopen moved horizontally")
        XCTAssertLessThan(abs(sample.frame.minY - settled.minY), 2, "Reopen moved the top edge")
      }
    }
    try write(reopenTimeline, to: outputDirectory().appendingPathComponent("status-reopen-frames.json"))
    records.append(scenarioRecord(tab: "Settings", label: "Deferred fit after reopen", element: statusItem))
    return records
  }

  @MainActor
  private func exerciseAboutControls(
    _ application: XCUIApplication, surface: XCUIElement
  ) -> [ControlAuditRecord] {
    var records: [ControlAuditRecord] = []
    let version = surface.staticTexts["settings-version"]
    XCTAssertTrue(reveal(version, in: surface), "Missing About version and build")
    records.append(scenarioRecord(tab: "Settings", label: "Version and build", element: version, action: "observe"))
    let channel = surface.staticTexts["Direct"]
    XCTAssertTrue(channel.exists, "Missing About distribution channel")
    records.append(scenarioRecord(tab: "Settings", label: "Distribution channel", element: channel, action: "observe"))
    let launchAtLogin = application.checkBoxes["Launch at login"]
    XCTAssertTrue(reveal(launchAtLogin, in: surface))
    toggleAndRestore(launchAtLogin)
    records.append(
      scenarioRecord(tab: "Settings", label: "Launch at login", element: launchAtLogin, action: "toggle twice"))
    for (label, identifier) in [
      ("Open Login Items", "Open Login Items"), ("Copy Diagnostics", "footer-copy-diagnostics"),
      ("Source", "footer-source"),
    ] {
      let button = application.buttons[identifier].firstMatch
      XCTAssertTrue(reveal(button, in: surface), "Missing About action \(label)")
      button.click()
      records.append(scenarioRecord(tab: "Settings", label: label, element: button, action: "click"))
    }
    let reportIssue = application.buttons["footer-report-issue"]
    XCTAssertTrue(reportIssue.isHittable)
    reportIssue.click()
    records.append(scenarioRecord(tab: "Settings", label: "Report Issue", element: reportIssue, action: "click"))
    XCTAssertFalse(application.checkBoxes["Check for updates automatically"].exists)
    XCTAssertFalse(application.buttons["Check Now"].exists)
    records.append(
      absenceRecord(
        tab: "Settings", label: "Direct update controls", action: "assert absent outside a live Direct updater"))
    return records
  }

  @MainActor
  private func exerciseProviderControls(
    _ application: XCUIApplication, surface: XCUIElement
  ) -> [ControlAuditRecord] {
    let showAll = application.checkBoxes["Show all providers"]
    XCTAssertTrue(reveal(showAll, in: surface))
    set(showAll, enabled: true)
    var records = [scenarioRecord(tab: "Settings", label: "Show all providers", element: showAll)]
    var refreshSteppers = 0
    for provider in ProviderID.allCases {
      let row = application.descendants(matching: .any)["\(provider.displayName) setup"]
      let toggle = row.checkBoxes[provider.displayName]
      XCTAssertTrue(reveal(toggle, in: surface), "Missing \(provider.displayName) provider row")
      XCTAssertTrue(
        row.staticTexts["Demo data"].exists,
        "\(provider.displayName) did not expose its isolated authentication source")
      records.append(
        scenarioRecord(
          tab: "Settings", label: "\(provider.displayName) authentication source", element: row,
          action: "observe"))
      XCTAssertTrue(toggle.exists)
      toggleAndRestore(toggle)
      records.append(
        scenarioRecord(
          tab: "Settings", label: "\(provider.displayName) enabled", element: toggle, action: "toggle twice"))
      let stepper = row.steppers.firstMatch
      XCTAssertTrue(stepper.exists, "Missing \(provider.displayName) refresh interval")
      XCTAssertTrue(reveal(stepper, in: surface))
      incrementStepper(stepper)
      refreshSteppers += 1
      records.append(
        scenarioRecord(
          tab: "Settings", label: "\(provider.displayName) refresh interval", element: stepper,
          action: "increment"))
    }
    XCTAssertEqual(refreshSteppers, ProviderID.allCases.count)
    let tokenRefresh = application.checkBoxes.matching(
      NSPredicate(format: "label BEGINSWITH 'Refresh expired ' AND label ENDSWITH ' tokens on my behalf'")
    ).firstMatch
    XCTAssertTrue(reveal(tokenRefresh, in: surface))
    toggleAndRestore(tokenRefresh)
    records.append(scenarioRecord(tab: "Settings", label: "Provider token refresh", element: tokenRefresh))
    return records
  }

  @MainActor
  private func exerciseProviderAccessActions(
    _ application: XCUIApplication, surface: XCUIElement, supportDirectory: URL
  ) -> [ControlAuditRecord] {
    let showAll = application.checkBoxes["Show all providers"]
    XCTAssertTrue(reveal(showAll, in: surface))
    set(showAll, enabled: true)
    var records: [ControlAuditRecord] = []
    var recoveryActions = 0
    var resourceActions = 0
    for provider in ProviderID.allCases {
      let row = application.descendants(matching: .any)["\(provider.displayName) setup"]
      for action in row.buttons.matching(
        NSPredicate(format: "label IN %@", ["Copy command", "Check again", "Grant access", "Contact administrator"])
      ).allElementsBoundByIndex {
        XCTAssertTrue(reveal(action, in: surface))
        let label = action.label
        action.click()
        if label == "Grant access" {
          assertAndCancelNativePanel(application, rootedAt: supportDirectory)
        }
        recoveryActions += 1
        records.append(
          scenarioRecord(
            tab: "Settings", label: "\(provider.displayName) recovery \(label)", element: action,
            action: label == "Grant access" ? "open panel and Cancel" : "click"))
      }
      for action in row.buttons.matching(NSPredicate(format: "label IN %@", ["Grant", "Grant Again"]))
        .allElementsBoundByIndex
      {
        XCTAssertTrue(reveal(action, in: surface))
        action.click()
        assertAndCancelNativePanel(application, rootedAt: supportDirectory)
        resourceActions += 1
        records.append(
          scenarioRecord(
            tab: "Settings", label: "\(provider.displayName) resource \(action.label)", element: action,
            action: "open panel and Cancel"))
      }
    }
    XCTAssertEqual(recoveryActions, ProviderID.allCases.count, "Each provider must expose its recovery action")
    XCTAssertEqual(
      resourceActions, ProviderID.allCases.flatMap(\.sandboxResources).count,
      "Each required sandbox resource must expose its grant action")
    return records
  }

  @MainActor
  private func exerciseDataControls(
    _ application: XCUIApplication, surface: XCUIElement, supportDirectory: URL
  ) -> [ControlAuditRecord] {
    var records: [ControlAuditRecord] = []
    let retention = application.steppers["history-retention"]
    XCTAssertTrue(reveal(retention, in: surface), "Missing history retention")
    adjustStepperAndRestore(retention, in: surface)
    records.append(
      scenarioRecord(tab: "Settings", label: "History retention", element: retention, action: "increment/decrement"))

    let analytics = application.steppers["analytics-refresh-interval"]
    XCTAssertTrue(reveal(analytics, in: surface), "Missing analytics refresh interval")
    adjustStepperAndRestore(analytics, in: surface)
    records.append(
      scenarioRecord(tab: "Settings", label: "Analytics refresh", element: analytics, action: "increment/decrement"))

    let historyPath = application.descendants(matching: .any)["History file"]
    XCTAssertTrue(historyPath.exists)
    let path = String(describing: historyPath.value)
    XCTAssertTrue(path.contains("token-menu-bar-verify"), "History must stay in the verification directory")
    records.append(scenarioRecord(tab: "Settings", label: "Full history path", element: historyPath, action: "observe"))

    let open = application.buttons["Open"]
    XCTAssertTrue(reveal(open, in: surface))
    open.click()
    records.append(scenarioRecord(tab: "Settings", label: "History Open", element: open, action: "click"))
    let export = application.buttons["Export History…"]
    XCTAssertTrue(reveal(export, in: surface))
    export.click()
    assertAndCancelNativePanel(application, rootedAt: supportDirectory)
    records.append(
      scenarioRecord(tab: "Settings", label: "History Export", element: export, action: "open panel and Cancel"))
    let clear = application.buttons["Clear…"]
    XCTAssertTrue(reveal(clear, in: surface))
    clear.click()
    let destructive = application.buttons["Clear History"]
    XCTAssertTrue(destructive.waitForExistence(timeout: 2), "Clear History must require confirmation")
    application.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(destructive.waitForNonExistence(timeout: 2))
    records.append(
      scenarioRecord(tab: "Settings", label: "Clear History confirmation", element: clear, action: "Cancel"))
    return records
  }

  @MainActor
  private func exerciseNotificationControls(
    _ application: XCUIApplication, surface: XCUIElement
  ) -> [ControlAuditRecord] {
    let enabled = application.checkBoxes["Enable threshold notifications"]
    XCTAssertTrue(reveal(enabled, in: surface))
    set(enabled, enabled: true)
    var records = [
      scenarioRecord(tab: "Settings", label: "Notifications enabled", element: enabled, action: "enable")
    ]
    let labels = ["50%", "75%", "90%", "100%"]
    for label in labels {
      let threshold = application.checkBoxes[label]
      XCTAssertTrue(reveal(threshold, in: surface))
      XCTAssertTrue(threshold.exists && threshold.isEnabled && threshold.isHittable, "Missing notification \(label)")
      toggleAndRestore(threshold)
      records.append(
        scenarioRecord(
          tab: "Settings", label: "Notification threshold \(label)", element: threshold, action: "toggle twice"))
    }
    for label in ["Window resets", "Sign-in needed"] {
      let toggle = application.checkBoxes[label]
      XCTAssertTrue(reveal(toggle, in: surface))
      XCTAssertTrue(toggle.exists && toggle.isEnabled && toggle.isHittable, "Missing \(label)")
      toggleAndRestore(toggle)
      records.append(
        scenarioRecord(tab: "Settings", label: label, element: toggle, action: "toggle twice"))
    }
    set(enabled, enabled: false)
    XCTAssertFalse(application.checkBoxes["Window resets"].exists)
    XCTAssertFalse(application.checkBoxes["Sign-in needed"].exists)
    return records
  }

  @MainActor
  private func exerciseLogControls(
    _ application: XCUIApplication, surface: XCUIElement, reopen: () -> Void
  ) -> [ControlAuditRecord] {
    let detailed = application.checkBoxes["Detailed logging"]
    XCTAssertTrue(reveal(detailed, in: surface))
    set(detailed, enabled: true)
    movePointerOffPanel(in: application)
    Thread.sleep(forTimeInterval: 0.2)
    var records = [
      scenarioRecord(tab: "Settings", label: "Detailed logging", element: detailed, action: "enable")
    ]
    let log = application.textViews["Log"]
    XCTAssertTrue(log.waitForExistence(timeout: 2))
    application.typeKey("r", modifierFlags: .command)
    XCTAssertTrue(
      waitUntil(timeout: 2) { String(describing: log.value).contains("refresh.provider") },
      "Command-R did not trigger a logged provider refresh")
    records.append(scenarioRecord(tab: "Settings", label: "Command-R refresh", element: log, action: "⌘R"))
    records.append(scenarioRecord(tab: "Settings", label: "Log view", element: log, action: "observe"))
    let level = application.descendants(matching: .any)["Log level"]
    XCTAssertTrue(level.exists)
    XCTAssertEqual(segments(in: level).count, 5, "Log level must expose All plus four severities")
    for segment in segments(in: level) {
      XCTAssertTrue(reveal(segment, in: surface))
      XCTAssertTrue(segment.isEnabled)
      segment.click()
      XCTAssertTrue(waitUntil(timeout: controlTimeout) { self.isSelected(segment) })
    }
    records.append(scenarioRecord(tab: "Settings", label: "Log level", element: level, action: "select every level"))
    let search = application.textFields["Search log"]
    XCTAssertTrue(reveal(search, in: surface))
    replaceText(in: search, with: "verification", application: application)
    replaceText(in: search, with: "", application: application)
    records.append(scenarioRecord(tab: "Settings", label: "Log search", element: search, action: "type and clear"))
    for label in ["Copy", "Clear"] {
      let button = application.buttons[label]
      XCTAssertTrue(reveal(button, in: surface))
      button.click()
      records.append(scenarioRecord(tab: "Settings", label: "Log \(label)", element: button, action: "click"))
    }
    let fullLog = application.buttons["Show Full Log"]
    XCTAssertTrue(reveal(fullLog, in: surface))
    let fullLogRecord = scenarioRecord(
      tab: "Settings", label: "Show Full Log", element: fullLog, action: "open and close")
    fullLog.click()
    XCTAssertTrue(surface.waitForNonExistence(timeout: 2))
    XCTAssertTrue(application.windows["Token Menu Bar Log"].waitForExistence(timeout: 2))
    application.typeKey("f", modifierFlags: .command)
    let fullLogSearch = application.textFields.matching(NSPredicate(format: "label == 'Search log'"))
      .allElementsBoundByIndex.first { $0.isHittable }
    guard let fullLogSearch else {
      XCTFail("Full Log did not expose a searchable field")
      return records
    }
    fullLogSearch.typeText("route")
    XCTAssertEqual(fullLogSearch.value as? String, "route", "Full Log Command-F did not focus its search")
    records.append(
      scenarioRecord(
        tab: "Settings", label: "Full log Command-F search", element: fullLogSearch, action: "⌘F then type"))
    application.typeKey("w", modifierFlags: .command)
    records.append(fullLogRecord)
    reopen()
    XCTAssertTrue(surface.waitForExistence(timeout: 2))
    XCTAssertTrue(reveal(detailed, in: surface))
    set(detailed, enabled: false)
    return records
  }

  @MainActor
  private func adjustDate(_ picker: XCUIElement, increasing: Bool) {
    XCTAssertTrue(
      picker.isHittable,
      "Date picker is unreachable: \(picker.debugDescription)")
    picker.click()
    let before = String(describing: picker.value)
    let arrow = picker.descendants(matching: increasing ? .incrementArrow : .decrementArrow).firstMatch
    XCTAssertTrue(
      arrow.exists && arrow.isHittable,
      "Date arrow is unreachable: \(picker.debugDescription)")
    arrow.click()
    XCTAssertTrue(
      waitUntil(timeout: controlTimeout) { String(describing: picker.value) != before },
      "Date value stayed at \(before) after clicking \(increasing ? "increment" : "decrement"): \(picker.debugDescription)"
    )
  }

  @MainActor
  private func segmentedControl(
    named label: String, application: XCUIApplication
  ) -> XCUIElement {
    let control = application.descendants(matching: .any).matching(
      NSPredicate(
        format: "label == %@ AND (elementType == %d OR elementType == %d)", label,
        XCUIElement.ElementType.segmentedControl.rawValue, XCUIElement.ElementType.radioGroup.rawValue)
    ).firstMatch
    XCTAssertTrue(control.exists, "Missing segmented control \(label)")
    return control
  }

  @MainActor
  private func segment(_ label: String, in control: XCUIElement) -> XCUIElement {
    control.elementType == .radioGroup ? control.radioButtons[label] : control.buttons[label]
  }

  @MainActor
  private func segments(in control: XCUIElement) -> [XCUIElement] {
    (control.elementType == .radioGroup ? control.radioButtons : control.buttons).allElementsBoundByIndex
  }

  @MainActor
  private func popoverTabs(in application: XCUIApplication) -> XCUIElement {
    application.descendants(matching: .radioGroup)
      .matching(NSPredicate(format: "label == %@", "Popover tabs")).firstMatch
  }

  @MainActor
  private func selectMenuItem(
    _ label: String, from picker: XCUIElement, application: XCUIApplication
  ) throws {
    let revealed = reveal(picker, in: application.descendants(matching: .any)["popover-surface"])
    if !revealed {
      let attachment = XCTAttachment(string: application.debugDescription)
      attachment.name = "Unreachable picker \(label), frame \(picker.frame)"
      attachment.lifetime = .keepAlways
      add(attachment)
      let surface = application.descendants(matching: .any)["popover-surface"]
      let viewport = surface.scrollViews.firstMatch.frame.intersection(surface.frame)
      if viewport.contains(picker.frame) {
        picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let item = application.menuItems[label]
        let opened = item.waitForExistence(timeout: 2)
        print("PICKER_HIT_DIAGNOSTIC label=\(label) frame=\(picker.frame) coordinateOpenedMenu=\(opened)")
        if opened { item.click() }
      }
    }
    XCTAssertTrue(revealed, "Cannot reach \(label) picker at \(picker.frame)")
    picker.click()
    let item = application.menuItems[label]
    XCTAssertTrue(item.waitForExistence(timeout: 2), "The picker did not expose \(label)")
    item.click()
    XCTAssertTrue(waitUntil(timeout: controlTimeout) { String(describing: picker.value).contains(label) })
  }

  @MainActor
  private func set(_ toggle: XCUIElement, enabled: Bool) {
    if isSelected(toggle) != enabled { toggle.click() }
    XCTAssertTrue(waitUntil(timeout: controlTimeout) { self.isSelected(toggle) == enabled })
  }

  @MainActor
  private func toggleAndRestore(_ toggle: XCUIElement) {
    let before = isSelected(toggle)
    toggle.click()
    XCTAssertTrue(waitUntil(timeout: controlTimeout) { self.isSelected(toggle) != before })
    toggle.click()
    XCTAssertTrue(waitUntil(timeout: controlTimeout) { self.isSelected(toggle) == before })
  }

  @MainActor
  private func toggleModelGroupAndRestore(
    _ provider: ProviderID, toggle: XCUIElement, surface: XCUIElement, application: XCUIApplication
  ) throws {
    let identifiers = DemoData.snapshot(provider, now: Date(), fixture: .controlAudit).windows.map {
      "model-selection-\(provider.rawValue):\($0.id)"
    }
    XCTAssertTrue(reveal(application.checkBoxes[try XCTUnwrap(identifiers.last)], in: surface))
    XCTAssertTrue(reveal(toggle, in: surface), "Missing \(provider.displayName) model select-all")
    let before = try modelSelectionStates(provider, in: surface)
    XCTAssertEqual(Set(before.keys), Set(identifiers), "Missing model checkboxes for \(provider.displayName)")
    let selected = !before.values.allSatisfy { $0 }
    toggle.click()
    XCTAssertTrue(
      waitUntil(timeout: controlTimeout) {
        (try? self.modelSelectionStates(provider, in: surface)) == before.mapValues { _ in selected }
      })
    XCTAssertTrue(reveal(toggle, in: surface), "Cannot reach \(provider.displayName) model select-all after selection")
    toggle.click()
    XCTAssertTrue(
      waitUntil(timeout: controlTimeout) {
        (try? self.modelSelectionStates(provider, in: surface)) == before.mapValues { _ in !selected }
      })
    for identifier in before.keys.sorted() where before[identifier] != !selected {
      let model = application.checkBoxes[identifier]
      XCTAssertTrue(reveal(model, in: surface))
      model.click()
    }
    XCTAssertEqual(try modelSelectionStates(provider, in: surface), before)
  }

  @MainActor
  private func modelSelectionStates(_ provider: ProviderID, in surface: XCUIElement) throws -> [String: Bool] {
    Dictionary(
      uniqueKeysWithValues: snapshots(in: try surface.snapshot())
        .filter { $0.elementType == .checkBox && $0.identifier.hasPrefix("model-selection-\(provider.rawValue)") }
        .map { ($0.identifier, checked($0.value)) })
  }

  @MainActor
  private func incrementStepper(_ stepper: XCUIElement) {
    let before = String(describing: stepper.value)
    let increment = stepper.descendants(matching: .incrementArrow).firstMatch
    XCTAssertTrue(increment.exists, "Stepper did not expose an increment arrow")
    XCTAssertTrue(increment.isHittable)
    increment.click()
    XCTAssertTrue(waitUntil(timeout: controlTimeout) { String(describing: stepper.value) != before })
  }

  @MainActor
  private func adjustStepperAndRestore(
    _ stepper: XCUIElement, in surface: XCUIElement, decrementFirst: Bool = false
  ) {
    let increment = stepper.descendants(matching: .incrementArrow).firstMatch
    let decrement = stepper.descendants(matching: .decrementArrow).firstMatch
    XCTAssertTrue(reveal(decrementFirst ? decrement : increment, in: surface))
    XCTAssertTrue(increment.exists && decrement.exists, "Stepper did not expose increment and decrement arrows")
    let before = String(describing: stepper.value)
    (decrementFirst ? decrement : increment).click()
    XCTAssertTrue(
      waitUntil(timeout: controlTimeout) { String(describing: stepper.value) != before },
      "Stepper \(stepper.identifier) did not change from \(before)")
    XCTAssertTrue(reveal(decrementFirst ? increment : decrement, in: surface))
    (decrementFirst ? increment : decrement).click()
    XCTAssertTrue(
      waitUntil(timeout: controlTimeout) { String(describing: stepper.value) == before },
      "Stepper \(stepper.identifier) did not restore \(before); received \(String(describing: stepper.value))")
  }

  @MainActor
  private func isSelected(_ element: XCUIElement) -> Bool {
    checked(element.value)
  }

  private func checked(_ value: Any?) -> Bool {
    let text = (value as? NSNumber)?.stringValue ?? (value as? String)?.lowercased()
    switch text {
    case "1", "on", "selected", "true": return true
    case "0", "off", "unselected", "false": return false
    default:
      XCTFail("Expected a binary control value, received \(String(describing: value))")
      return false
    }
  }

  @MainActor
  private func replaceText(in field: XCUIElement, with value: String, application: XCUIApplication) {
    field.click()
    application.typeKey("a", modifierFlags: .command)
    if value.isEmpty {
      application.typeKey(.delete, modifierFlags: [])
    } else {
      field.typeText(value)
    }
    XCTAssertTrue(
      waitUntil(timeout: controlTimeout) { (field.value as? String) == value },
      "Expected editable text \(String(reflecting: value)); received \(String(describing: field.value))")
  }

  @MainActor
  private func reveal(_ element: XCUIElement, in surface: XCUIElement) -> Bool {
    let scrollView = surface.scrollViews.firstMatch
    guard scrollView.exists else { return element.exists && element.isHittable }
    if !element.exists { scrollToTop(surface) }
    for _ in 0..<20 {
      if element.exists { break }
      let first = scrollView.staticTexts.firstMatch
      guard first.exists else { return false }
      let label = first.label
      let frame = first.frame
      scroll(scrollView, by: -scrollView.frame.intersection(surface.frame).height * 0.75)
      guard
        waitUntil(
          timeout: controlTimeout,
          condition: { element.exists || first.exists && (first.label != label || first.frame != frame) })
      else { return false }
    }
    guard element.exists else { return false }
    let type = element.elementType
    if type == .stepper {
      return reveal(element.descendants(matching: .incrementArrow).firstMatch, in: surface)
    }
    if type == .radioGroup || type == .segmentedControl {
      guard let segment = segments(in: element).first else { return false }
      return reveal(segment, in: surface)
    }
    if element.identifier.hasPrefix("footer-") {
      return surface.frame.contains(element.frame) && element.isHittable
    }
    for _ in 0..<20 {
      guard element.exists else { return false }
      let viewport = scrollView.frame.intersection(surface.frame).insetBy(dx: 2, dy: 2)
      let before = element.frame
      let center = CGPoint(x: before.midX, y: before.midY)
      if viewport.contains(before) {
        return type == .staticText || waitUntil(timeout: controlTimeout) { element.isHittable }
      }
      guard center.x >= viewport.minX && center.x <= viewport.maxX else { return false }
      guard abs(center.y - viewport.midY) > 20 else { return false }
      let distance = viewport.midY - center.y
      let page = viewport.height * 0.75
      let anchor = scrollView.staticTexts.firstMatch
      let anchorBefore = anchor.frame
      scroll(scrollView, by: min(max(distance, -page), page))
      guard
        waitUntil(
          timeout: controlTimeout,
          condition: { !element.exists || element.frame != before || anchor.frame != anchorBefore })
      else {
        let attachment = XCTAttachment(
          string:
            "target=\(element.identifier) before=\(before) after=\(element.frame) "
            + "anchorBefore=\(anchorBefore) anchorAfter=\(anchor.frame) viewport=\(viewport)")
        attachment.name = "Scroll made no progress"
        attachment.lifetime = .keepAlways
        add(attachment)
        let screenshot = XCTAttachment(screenshot: surface.screenshot())
        screenshot.name = "Unmoved scroll viewport"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        return false
      }
    }
    return false
  }

  @MainActor
  private func scrollToTop(_ surface: XCUIElement) {
    let scrollView = surface.scrollViews.firstMatch
    guard scrollView.exists else { return }
    let firstText = scrollView.staticTexts.firstMatch
    XCTAssertTrue(firstText.exists, "The tab has no accessible first content row")
    guard firstText.exists else { return }
    let viewport = scrollView.frame.intersection(surface.frame)
    scroll(scrollView, by: max(viewport.height, viewport.minY - firstText.frame.minY + viewport.height))
    XCTAssertTrue(
      reveal(firstText, in: surface),
      "Scrolling did not expose the first content row")
  }

  @MainActor
  private func scroll(_ scrollView: XCUIElement, by delta: CGFloat) {
    scrollView.hover()
    scrollView.scroll(byDeltaX: 0, deltaY: delta)
  }

  @MainActor
  private func collectButtonLabels(prefix: String, in surface: XCUIElement) -> Set<String> {
    Set(
      surface.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).allElementsBoundByIndex.map(\.label))
  }

  @MainActor
  private func contentSignature(_ element: XCUIElement) throws -> String {
    let frame = element.frame
    var display: CGDirectDisplayID = 0
    var count: UInt32 = 0
    let onScreen =
      frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
      && !frame.isEmpty && CGGetDisplaysWithRect(frame, 1, &display, &count) == .success
      && count == 1 && CGDisplayBounds(display).contains(frame)
    _ = try XCTUnwrap(onScreen ? true : nil, "Status-item capture requires a visible item; reported frame: \(frame)")
    let value = String(describing: element.value)
    let pixels = element.screenshot().pngRepresentation
    return "\(element.label)|\(value)|\(pixels.count)|\(pixels.hashValue)"
  }

  @MainActor
  private func assertAnchorsHeld(
    statusItem: XCUIElement, statusFrame: CGRect, surface: XCUIElement, panelFrame: CGRect, action: String
  ) {
    XCTAssertFalse(statusItem.label.isEmpty, "\(action) removed the status-item accessibility label")
    XCTAssertLessThan(abs(statusItem.frame.minX - statusFrame.minX), 2, "\(action) moved the status item")
    XCTAssertLessThan(abs(statusItem.frame.width - statusFrame.width), 2, "\(action) resized the open status item")
    XCTAssertLessThan(abs(surface.frame.minX - panelFrame.minX), 2, "\(action) moved the panel horizontally")
    XCTAssertLessThan(abs(surface.frame.minY - panelFrame.minY), 2, "\(action) moved the panel top edge")
  }

  @MainActor
  private func assertAndCancelNativePanel(_ application: XCUIApplication, rootedAt directory: URL) {
    let panel = application.descendants(matching: .any).matching(
      NSPredicate(format: "identifier IN %@", ["save-panel", "open-panel"])
    ).firstMatch
    let presented = panel.waitForExistence(timeout: 2)
    XCTAssertTrue(presented, "The action did not present an on-screen native panel")
    guard presented else { return }
    let location = panel.popUpButtons["where popup"]
    let locationValue = location.value as? String ?? ""
    XCTAssertTrue(
      location.exists && directory.lastPathComponent.hasPrefix(locationValue.replacingOccurrences(of: "...", with: "")),
      "The native panel is not rooted in \(directory.path): \(locationValue)")
    let cancel = panel.buttons["CancelButton"]
    let canCancel = cancel.isHittable
    XCTAssertTrue(canCancel, "The native panel did not expose an on-screen Cancel button")
    guard canCancel else { return }
    cancel.click()
    XCTAssertTrue(cancel.waitForNonExistence(timeout: 2))
    XCTAssertTrue(application.descendants(matching: .any)["popover-surface"].waitForExistence(timeout: 2))
  }

  @MainActor
  private func scenarioRecord(
    tab: String, label: String, element: XCUIElement, action: String = "interact"
  ) -> ControlAuditRecord {
    do {
      let snapshot = try element.snapshot()
      return ControlAuditRecord(
        tab: tab, type: "scenario", identifier: snapshot.identifier, label: label,
        value: String(describing: snapshot.value), enabled: snapshot.isEnabled, hittable: element.isHittable,
        interacted: true, action: action, result: "passed", frame: FrameRecord(snapshot.frame))
    } catch {
      XCTFail("Could not record \(label): \(error)")
      return ControlAuditRecord(
        tab: tab, type: "scenario", identifier: "", label: label, value: "", enabled: false, hittable: false,
        interacted: true, action: action, result: "failed: \(error)", frame: FrameRecord(.zero))
    }
  }

  private func absenceRecord(tab: String, label: String, action: String) -> ControlAuditRecord {
    ControlAuditRecord(
      tab: tab, type: "absence", identifier: label, label: label, value: "absent", enabled: false,
      hittable: false, interacted: false, action: action, result: "passed", frame: FrameRecord(.zero))
  }

  private func assertRequiredInventory(
    _ records: [ControlAuditRecord], tab: String, section: SettingsSection?, modelSelectionOnly: Bool
  ) {
    let recorded = Set(records.map { "\($0.tab)|\($0.label)" })
    var required: Set<String> = [
      "Usage|Refresh all providers", "Usage|Usage-site links", "Usage|Sign-in prompts",
      "History|UTC boundaries", "History|Window Usage rollups", "History|Additive metric stacking",
      "History|Previous, next, and Now", "History|Custom From and To",
      "History|Export CSV save panel Cancel", "Settings|Version and build", "Settings|Distribution channel",
      "Settings|Reset All Settings Cancel", "Settings|Launch at login", "Settings|Open Login Items",
      "Settings|Copy Diagnostics", "Settings|Report Issue", "Settings|Source",
      "Settings|Direct update controls", "Settings|Model order", "Settings|Status format", "Settings|Decimals",
      "Settings|Template and tokens", "Settings|Live menu bar preview", "Settings|Model filter",
      "Settings|Command-F model filter",
      "Settings|Hide unused models", "Settings|Model selection", "Settings|Revert short label",
      "Settings|Stable order move later and earlier", "Settings|Hide 0%", "Settings|Fit to space",
      "Settings|Show all providers", "Settings|Provider token refresh", "Settings|History retention",
      "Settings|Analytics refresh", "Settings|Full history path", "Settings|History Open",
      "Settings|History Export", "Settings|Clear History confirmation", "Settings|Notifications enabled",
      "Settings|Window resets", "Settings|Sign-in needed", "Settings|Detailed logging", "Settings|Log level",
      "Settings|Log search", "Settings|Log Copy", "Settings|Log Clear", "Settings|Show Full Log",
      "Settings|Log view", "Settings|Command-R refresh", "Settings|Full log Command-F search",
    ]
    for threshold in ["50%", "75%", "90%", "100%"] {
      required.insert("Settings|Notification threshold \(threshold)")
    }
    for provider in ProviderID.allCases {
      required.formUnion([
        "Usage|Refresh \(provider.displayName)", "Settings|\(provider.displayName) model select-all",
        "Settings|\(provider.displayName) enabled", "Settings|\(provider.displayName) refresh interval",
        "Settings|\(provider.displayName) authentication source",
      ])
    }
    required = required.filter {
      let label = String($0.dropFirst(9))
      return $0.hasPrefix("\(tab)|") && (section == nil || settingsSection(for: label) == section)
        && (section != .menuBar || isModelSelectionControl(label) == modelSelectionOnly)
    }
    XCTAssertTrue(
      required.isSubset(of: recorded),
      "Control matrix omitted: \(required.subtracting(recorded).sorted().joined(separator: ", "))")
  }

  private func settingsSection(for label: String) -> SettingsSection {
    switch label {
    case "Version and build", "Distribution channel", "Reset All Settings Cancel", "Launch at login",
      "Open Login Items", "Copy Diagnostics", "Report Issue", "Source", "Direct update controls":
      return .about
    case "Show all providers", "Provider token refresh":
      return .providers
    case "History retention", "Analytics refresh", "Full history path", "History Open", "History Export",
      "Clear History confirmation":
      return .data
    case "Notifications enabled", "Window resets", "Sign-in needed":
      return .notifications
    case "Detailed logging", "Log level", "Log search", "Log Copy", "Log Clear", "Show Full Log", "Log view",
      "Command-R refresh", "Full log Command-F search":
      return .log
    default:
      if label.hasPrefix("Notification threshold ") { return .notifications }
      if [" enabled", " refresh interval", " authentication source"].contains(where: label.hasSuffix) {
        return .providers
      }
      return .menuBar
    }
  }

  private func isModelSelectionControl(_ label: String) -> Bool {
    ["Model filter", "Command-F model filter", "Hide unused models", "Model selection"].contains(label)
      || label.hasSuffix(" model select-all")
  }

  @MainActor
  private func assertVisibleStringsAndControls(
    in surface: XCUIElement, application: XCUIApplication, snapshot: any XCUIElementSnapshot,
    auditedControls: inout Set<[String]>
  ) -> Int {
    let visible = visibleSnapshots(in: snapshot, within: snapshot.frame)
    for text in visible where text.elementType == .staticText {
      XCTAssertFalse(text.label.isEmpty && (text.value as? String ?? "").isEmpty, "Visible text has no accessible text")
    }
    let banners = visible.filter {
      $0.label.hasPrefix("Warning: Verification warning text is intentionally long")
    }
    for banner in banners {
      assertRenderedText(
        element(for: banner, in: surface, tree: snapshot), expected: String(banner.label.dropFirst("Warning: ".count)))
    }
    for control in visible where Self.audits(control.elementType, identifier: control.identifier) && control.isEnabled {
      guard
        auditedControls.insert([
          String(control.elementType.rawValue), control.identifier, control.label, control.title,
          String(describing: control.value), String(describing: control.frame),
        ]).inserted
      else { continue }
      if control.elementType == .stepper { continue }
      let element = element(for: control, in: surface, tree: snapshot)
      let hittable = element.isHittable
      if !hittable {
        let attachment = XCTAttachment(string: application.debugDescription)
        attachment.name = "Inaccessible visible control"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      XCTAssertTrue(
        hittable,
        "Visible enabled control is not hittable: \(control.elementType) \(control.identifier) "
          + "\(control.label) \(control.frame)")
    }
    XCTAssertEqual(application.state, .runningForeground)
    return banners.count
  }

  @MainActor
  private func assertRenderedText(_ element: XCUIElement, expected: String) {
    do {
      try RenderedText(suffix: expected, layout: .paragraph).capture(
        element.screenshot().pngRepresentation,
        at: outputDirectory().appendingPathComponent("banner-\(UUID().uuidString).png"))
    } catch {
      XCTFail("Could not capture rendered-text assertion: \(error)")
    }
  }

  @MainActor
  private func expandSupportingDetails(in application: XCUIApplication, section: SettingsSection? = nil) throws {
    let surface = application.descendants(matching: .any)["popover-surface"]
    let snapshot = try surface.snapshot()
    let elements = snapshots(in: snapshot)
    if let section {
      XCTAssertTrue(
        elements.contains { $0.identifier == "settings-section-\(section.rawValue)" },
        "Missing Settings section \(section.rawValue)")
    }
    var expanded: Set<String> = []
    for heading in elements.sorted(by: { $0.frame.minY < $1.frame.minY })
    where heading.identifier.hasPrefix("disclosure-") && !heading.identifier.hasPrefix("disclosure-content-") {
      let identifier = heading.identifier
      guard expanded.insert(identifier).inserted else { continue }
      if let section, !disclosure(identifier, belongsTo: section) { continue }
      let content = application.descendants(matching: .any)[
        "disclosure-content-" + identifier.dropFirst("disclosure-".count)]
      if content.exists { continue }
      let group = surface.descendants(matching: .any).matching(identifier: identifier).firstMatch
      var disclosure: XCUIElement {
        group.elementType == .disclosureTriangle ? group : group.disclosureTriangles.firstMatch
      }
      guard disclosure.exists else {
        XCTFail("Missing native disclosure for \(identifier)")
        continue
      }
      XCTAssertTrue(
        reveal(disclosure, in: surface),
        "Cannot reach \(identifier): control=\(disclosure.frame) scroll=\(surface.scrollViews.firstMatch.frame) "
          + "surface=\(surface.frame)")
      disclosure.click()
      XCTAssertTrue(
        content.waitForExistence(timeout: controlTimeout),
        "\(identifier) did not expand after clicking its heading")
      if section == .menuBar || section == .data {
        let toggle = content.checkBoxes[section == .menuBar ? "Hide 0%" : "Write usage.json"]
        XCTAssertTrue(reveal(toggle, in: surface))
        let selected = isSelected(toggle)
        set(toggle, enabled: !selected)
        XCTAssertTrue(reveal(disclosure, in: surface))
        disclosure.click()
        XCTAssertTrue(content.waitForNonExistence(timeout: controlTimeout))
        XCTAssertFalse(toggle.exists)
        disclosure.click()
        XCTAssertTrue(content.waitForExistence(timeout: controlTimeout))
        XCTAssertEqual(isSelected(toggle), !selected, "Collapsing \(identifier) changed its setting")
        XCTAssertTrue(reveal(toggle, in: surface))
        set(toggle, enabled: selected)
      }
    }
    scrollToTop(surface)
  }

  private func disclosure(_ identifier: String, belongsTo section: SettingsSection) -> Bool {
    switch section {
    case .about:
      false
    case .menuBar:
      identifier == "disclosure-settings.display"
    case .providers:
      identifier.hasPrefix("disclosure-connection.")
    case .data:
      identifier == "disclosure-settings.collection"
    case .notifications:
      false
    case .log:
      identifier == "disclosure-settings.log"
    }
  }

  @MainActor
  private func captureAndAuditPages(
    tab: String, surface: XCUIElement, application: XCUIApplication, output: URL, prefix: String
  ) throws -> [String] {
    let scrollView = surface.scrollViews.firstMatch
    let hasScrollView = scrollView.exists
    let frame = surface.frame
    let viewport = hasScrollView ? scrollView.frame.intersection(frame) : frame
    let gutter = surface.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: viewport.minX - frame.minX + 4, dy: viewport.midY - frame.minY))
    let outside = coordinateOutsidePanel(surface, frame: frame)
    for coordinate in [gutter, outside] {
      let point = coordinate.screenPoint
      XCTAssertTrue(point.x.isFinite && point.y.isFinite, "Pointer target must have finite screen coordinates")
    }
    var exposedText: [String] = []
    var previousPage: Set<String> = []
    var checkedBanners = 0
    var auditedControls: Set<[String]> = []
    var steppers: [String] = []
    for page in 0..<18 {
      outside.hover()
      let snapshot = try surface.snapshot()
      XCTAssertEqual(snapshot.frame, frame, "The viewport changed during paged text capture")
      try application.screenshot().pngRepresentation.write(
        to: output.appendingPathComponent("\(prefix)-\(tab.lowercased())-page-\(page).png"))
      checkedBanners += assertVisibleStringsAndControls(
        in: surface, application: application, snapshot: snapshot, auditedControls: &auditedControls)
      let visible = visibleSnapshots(in: snapshot, within: snapshot.frame)
      for stepper in visible where stepper.elementType == .stepper && stepper.isEnabled {
        XCTAssertFalse(stepper.identifier.isEmpty, "A stepper needs a stable identifier for the interaction audit")
        if !steppers.contains(stepper.identifier) { steppers.append(stepper.identifier) }
      }
      let text = visible.map(\.label).filter { !$0.isEmpty }
      let values = visible.compactMap { $0.value as? String }
      exposedText += text + values
      let fingerprint = Set(text + values)
      print("LONG_TEXT_PAGE tab=\(tab) page=\(page) text=\(text.count) values=\(values.count)")
      let tree = XCTAttachment(
        string: snapshots(in: snapshot).map {
          "type=\($0.elementType.rawValue) id=\($0.identifier) frame=\($0.frame) "
            + "label=\($0.label) value=\(String(describing: $0.value))"
        }.joined(separator: "\n"))
      tree.name = "\(tab) page \(page) accessibility tree"
      tree.lifetime = .keepAlways
      add(tree)
      if !hasScrollView || fingerprint == previousPage
        || tab == "Settings" && visible.contains(where: { $0.elementType == .button && $0.label == "Show Full Log" })
      {
        break
      }
      previousPage = fingerprint
      gutter.hover()
      gutter.scroll(byDeltaX: 0, deltaY: -520)
    }
    if tab == "Usage" {
      if checkedBanners == 0 {
        let attachment = XCTAttachment(string: application.debugDescription)
        attachment.name = "Missing warning banner accessibility tree"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      XCTAssertGreaterThan(checkedBanners, 0, "No complete warning banner reached the OCR audit")
    }
    for identifier in steppers.reversed() {
      adjustStepperAndRestore(
        surface.steppers[identifier], in: surface, decrementFirst: identifier == "pace-workdays")
    }
    return exposedText
  }

  @MainActor
  private func snapshots(in root: any XCUIElementSnapshot) -> [any XCUIElementSnapshot] {
    root.children.flatMap { [$0] + snapshots(in: $0) }
  }

  @MainActor
  private func visibleSnapshots(in root: any XCUIElementSnapshot, within clip: CGRect) -> [any XCUIElementSnapshot] {
    let clip = root.elementType == .scrollView ? clip.intersection(root.frame) : clip
    return root.children.flatMap {
      (!$0.frame.isEmpty && clip.contains($0.frame) ? [$0] : []) + visibleSnapshots(in: $0, within: clip)
    }
  }

  @MainActor
  private func element(
    for snapshot: any XCUIElementSnapshot, in surface: XCUIElement, tree: any XCUIElementSnapshot
  ) -> XCUIElement {
    let peers = snapshots(in: tree).filter {
      $0.elementType == snapshot.elementType && $0.identifier == snapshot.identifier
    }
    let elements = surface.descendants(matching: snapshot.elementType)
    if !snapshot.identifier.isEmpty && peers.count == 1 {
      return elements.matching(identifier: snapshot.identifier).firstMatch
    }
    let matches = elements.matching(
      NSPredicate(
        format: "identifier == %@ AND label == %@ AND title == %@",
        snapshot.identifier, snapshot.label, snapshot.title))
    return matches.element(
      boundBy: peers.filter { $0.label == snapshot.label && $0.title == snapshot.title }
        .firstIndex { $0.frame == snapshot.frame }!)
  }

  @MainActor
  private func tooltipCandidates(in surface: XCUIElement) throws -> [(String, XCUIElement)] {
    let snapshot = try surface.snapshot()
    var controls = visibleSnapshots(in: snapshot, within: snapshot.frame).filter {
      Self.audits($0.elementType, identifier: $0.identifier) && $0.isEnabled
        && !["Usage", "History", "Settings"].contains($0.label)
    }
    guard controls.count >= 5 else { return [] }
    let center = CGPoint(x: snapshot.frame.midX, y: snapshot.frame.midY)
    func take(_ best: ([any XCUIElementSnapshot]) -> (any XCUIElementSnapshot)?) -> XCUIElement {
      let selected = best(controls)!
      let frame = selected.frame
      let type = selected.elementType
      controls.removeAll { $0.frame == frame && $0.elementType == type }
      return element(for: selected, in: surface, tree: snapshot)
    }
    return [
      ("top", take { $0.min { $0.frame.midY < $1.frame.midY } }),
      ("bottom", take { $0.max { $0.frame.midY < $1.frame.midY } }),
      ("left", take { $0.min { $0.frame.midX < $1.frame.midX } }),
      ("right", take { $0.max { $0.frame.midX < $1.frame.midX } }),
      ("center", take { $0.min { distance($0.frame.center, center) < distance($1.frame.center, center) } }),
    ]
  }

  private func waitForTooltip(
    processIdentifier: pid_t, excluding baseline: [CGWindowID: WindowRecord], timeout: TimeInterval
  ) throws -> WindowRecord {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
      if let tooltip = applicationWindows(processIdentifier: processIdentifier).first(where: {
        baseline[$0.key] == nil && $0.value.frame.width <= 420 && $0.value.frame.height <= 240
      })?.value {
        return tooltip
      }
      Thread.sleep(forTimeInterval: 0.016)
    }
    throw ControlAuditError.tooltipMissing
  }

  private func applicationWindows(processIdentifier: pid_t) -> [CGWindowID: WindowRecord] {
    guard
      let values = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[CFString: Any]]
    else { return [:] }
    return Dictionary(
      uniqueKeysWithValues: values.compactMap { value in
        guard
          (value[kCGWindowOwnerPID] as? NSNumber)?.int32Value == processIdentifier,
          let identifier = (value[kCGWindowNumber] as? NSNumber)?.uint32Value,
          let bounds = value[kCGWindowBounds] as? NSDictionary,
          let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return nil }
        return (identifier, WindowRecord(identifier: identifier, frame: frame))
      })
  }

  @MainActor
  private func movePointerOffPanel(in application: XCUIApplication) {
    let surface = application.descendants(matching: .any)["popover-surface"]
    coordinateOutsidePanel(surface, frame: surface.frame).hover()
  }

  @MainActor
  private func coordinateOutsidePanel(_ surface: XCUIElement, frame: CGRect) -> XCUICoordinate {
    let screen = CGDisplayBounds(CGMainDisplayID())
    let x = frame.minX > screen.midX ? screen.minX + 5 : screen.maxX - 5
    return surface.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: x - frame.minX, dy: screen.midY - frame.minY))
  }

  private func distance(between control: CGRect, and tooltip: CGRect) -> CGFloat {
    let horizontal = max(max(control.minX - tooltip.maxX, tooltip.minX - control.maxX), 0)
    let vertical = max(max(control.minY - tooltip.maxY, tooltip.minY - control.maxY), 0)
    return hypot(horizontal, vertical)
  }

  private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    hypot(lhs.x - rhs.x, lhs.y - rhs.y)
  }

  private func waitUntil(timeout: TimeInterval, condition: () throws -> Bool) rethrows -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
      if try condition() { return true }
      Thread.sleep(forTimeInterval: 0.016)
    }
    return try condition()
  }

  private func outputDirectory() throws -> URL {
    let root =
      ProcessInfo.processInfo.environment["TMB_BENCHMARK_OUTPUT_DIR"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      } ?? FileManager.default.temporaryDirectory.appendingPathComponent("token-menu-bar-live-audit", isDirectory: true)
    let directory = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url)
  }

  private static let auditedTypes: Set<XCUIElement.ElementType> = [
    .button, .checkBox, .comboBox, .datePicker, .link, .menuButton, .popUpButton, .radioButton,
    .searchField, .segmentedControl, .slider, .stepper, .switch, .textField,
  ]

  private static func audits(_ type: XCUIElement.ElementType, identifier: String) -> Bool {
    auditedTypes.contains(type) || type == .textView && identifier == "status-template"
  }

  private enum ControlAuditError: Error {
    case tooltipMissing
  }
}

private struct ControlAuditRecord: Codable {
  let tab: String
  let type: String
  let identifier: String
  let label: String
  let value: String
  let enabled: Bool
  let hittable: Bool
  let interacted: Bool
  let action: String
  let result: String
  let frame: FrameRecord
}

private struct FrameRecord: Codable {
  let minX: CGFloat
  let minY: CGFloat
  let width: CGFloat
  let height: CGFloat

  init(_ frame: CGRect) {
    minX = frame.minX
    minY = frame.minY
    width = frame.width
    height = frame.height
  }
}

private struct WindowRecord {
  let identifier: CGWindowID
  let frame: CGRect
}

private extension CGRect {
  var center: CGPoint { CGPoint(x: midX, y: midY) }
}
