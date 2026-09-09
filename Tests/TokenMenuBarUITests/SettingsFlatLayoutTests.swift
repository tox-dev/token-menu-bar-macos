import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore

@testable import TokenMenuBarUI

@Test(
  arguments: [548.0, 880],
  [LaunchAtLoginBackend.Status.enabled, .notRegistered, .notFound, .requiresApproval, .unknown]
) @MainActor
func settingsKeepsLoginControlsOnOneRowWithoutADisclosure(width: CGFloat, status: LaunchAtLoginBackend.Status) throws {
  let environment = try makeEnvironment(populate: false)
  environment.launchAtLoginStatus = status
  let hosting = host(SettingsTab(environment: environment, mountsIncrementally: false), width: width, height: 1800)
  let anchors = flatSettingsAnchors(in: hosting)
  let launch = try #require(anchors.first { $0.tooltipContent.title == "Launch at login" })
  let loginItems = try #require(anchors.first { $0.tooltipContent.title == "Open Login Items" })
  let launchFrame = launch.convert(launch.bounds, to: hosting)
  let loginFrame = loginItems.convert(loginItems.bounds, to: hosting)
  #expect(abs(launchFrame.midY - loginFrame.midY) < 3)
  #expect(loginFrame.minX > launchFrame.maxX && loginFrame.maxX <= width)
  #expect(anchors.contains { $0.tooltipContent.title == "Demo data" })
}

@Test @MainActor func settingsKeepsHistoryStorageVisibleWithoutADisclosure() throws {
  let environment = try makeEnvironment(populate: false)
  let hosting = host(SettingsTab(environment: environment, mountsIncrementally: false), width: 880, height: 1800)
  let titles = Set(flatSettingsAnchors(in: hosting).map { $0.tooltipContent.title })
  #expect(titles.contains("History file") && titles.contains("Clear History"))
  #expect(titles.isDisjoint(with: ["Startup details", "Support and diagnostics", "Storage details"]))
  #expect(titles.isDisjoint(with: ["Copy Diagnostics", "Source"]))
}

@Test(
  arguments: [CGFloat(548), CGFloat(880)].flatMap { width in
    PopoverTab.allCases.flatMap { tab in [false, true].map { (width, tab, $0) } }
  }
) @MainActor
func footerKeepsSettingsActionsVisibleWithinItsWidth(width: CGFloat, tab: PopoverTab, updates: Bool) throws {
  let environment = try makeEnvironment(populate: false)
  environment.settings.lastTab = tab
  environment.canCheckForUpdates = updates
  let hosting = host(PopoverFooter(environment: environment), width: width, height: PopoverGeometry.footerHeight)
  let anchors = flatSettingsAnchors(in: hosting).filter { !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.isEmpty }
  let titles = Set(anchors.map { $0.tooltipContent.title })
  var expected: Set<String> = ["Refresh", "Report Issue", "Quit"]
  if tab == .settings { expected.formUnion(["Copy Diagnostics", "Source"]) }
  if updates { expected.insert("Check for Updates") }
  #expect(titles == expected)
  for anchor in anchors {
    let frame = anchor.convert(anchor.bounds, to: hosting)
    #expect(frame.minX >= 0 && frame.maxX <= width)
    #expect(frame.height <= PopoverGeometry.footerHeight)
  }
}

@MainActor private func flatSettingsAnchors(in root: NSView) -> [TooltipTrackingView] {
  root.subviews.flatMap { view in
    (view as? TooltipTrackingView).map { [$0] } ?? flatSettingsAnchors(in: view)
  }
}
