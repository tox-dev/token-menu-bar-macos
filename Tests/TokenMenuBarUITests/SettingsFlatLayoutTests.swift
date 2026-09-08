import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@testable import TokenMenuBarUI

@Test @MainActor func firstSettingsSelectionPresentsPreparedModelControls() async throws {
  let environment = try makeEnvironment(populate: false)
  environment.isSandboxed = false
  environment.state.popoverVisible = true
  for provider in ProviderID.allCases {
    environment.state.update(provider) {
      $0.snapshot = DemoData.snapshot(provider, now: fixedNow)
      $0.availability = .current
      $0.credentialState = .valid(expiresAt: nil)
    }
  }
  environment.refreshUsagePresentation(at: fixedNow)
  var measured: Set<PopoverTab> = []
  var presentationView: NSView?
  let root = RootView(
    environment: environment, onMeasure: { measured.insert($0.tab) },
    onTabChange: { _ in presentationView?.setFrameSize(CGSize(width: 880, height: 934)) },
    preferredContentSize: { _ in CGSize(width: 880, height: 934) })
  let hosting = host(root, width: 880, height: 700)
  presentationView = hosting
  defer { presentationView = nil }
  #expect(await waitUntil { measured == Set(PopoverTab.allCases) })
  await mainActorTurn()

  root.select(.settings)
  #expect(environment.settings.lastTab == .settings)
  await mainActorTurn()
  hosting.layoutSubtreeIfNeeded()
  let bitmap = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(ceil(hosting.bounds.width * 2)), pixelsHigh: Int(ceil(hosting.bounds.height * 2)),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0))
  bitmap.size = hosting.bounds.size
  hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

  #expect(
    flatSettingsAnchors(in: hosting).contains {
      $0.tooltipContent.title == "Filter models" && !$0.isHiddenOrHasHiddenAncestor
    })
  let directory = URL(
    fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TOKEN_MENU_BAR_RENDER_ARTIFACTS"]),
    isDirectory: true)
  try RenderedText(contains: ["Launch at login", "Demo data", "Format", "Current session", "All models"]).capture(
    try #require(bitmap.representation(using: .png, properties: [:])),
    at: directory.appendingPathComponent("first-settings-selection.png"))
}

@Test @MainActor func nativeSettingsSelectionPresentsItsFooterBeforeReturning() throws {
  prepareTestApp()
  let root = RootView(environment: try makeEnvironment(), onMeasure: { _ in })
  let view = root.makeNativeView()
  view.frame = CGRect(x: 0, y: 0, width: 880, height: 934)
  view.layoutSubtreeIfNeeded()

  root.select(.settings)

  #expect(flatSettingsAnchors(in: view).contains { $0.tooltipContent.title == "Copy Diagnostics" })
}

@Test @MainActor func nativeRootUsesTheTabSelectedBeforeFirstLayout() throws {
  prepareTestApp()
  let environment = try makeEnvironment()
  let view = RootView(environment: environment, onMeasure: { _ in }).makeNativeView()
  environment.settings.lastTab = .settings

  view.frame = CGRect(x: 0, y: 0, width: 880, height: 934)
  view.layoutSubtreeIfNeeded()

  #expect(
    flatSettingsAnchors(in: view).contains {
      $0.tooltipContent.title == "Filter models" && !$0.isHiddenOrHasHiddenAncestor
    })
}

@Test(arguments: [false, true]) @MainActor
func supportingDetailsHelpOnlyCoversItsLabel(expanded: Bool) throws {
  let state = DisclosureState()
  state.setExpanded(expanded, for: "details")
  let hosting = host(
    SupportingDetails("Details", id: "details", state: state) {
      Text("Supporting information").frame(height: 300)
    }, width: 400, height: 400)
  let anchor = try #require(flatSettingsAnchors(in: hosting).first { $0.tooltipContent.title == "Details" })
  #expect(anchor.bounds.height > 0 && anchor.bounds.height < 50)
}

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

@Test @MainActor func settingsLeavesManualUpdateChecksInTheFooter() throws {
  let environment = try makeEnvironment(populate: false)
  environment.canCheckForUpdates = true
  let hosting = host(SettingsTab(environment: environment, mountsIncrementally: false), width: 880, height: 1800)
  let titles = flatSettingsAnchors(in: hosting).map { $0.tooltipContent.title }
  #expect(titles.contains("Automatic updates"))
  #expect(!titles.contains("Check Now") && !titles.contains("Check for Updates"))
}

@Test(arguments: footerLayoutCases) @MainActor
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

// Swift 6.0 crashes when expanding nested closures inside @Test arguments.
private let footerLayoutCases: [(CGFloat, PopoverTab, Bool)] = [CGFloat(548), CGFloat(880)].flatMap { width in
  PopoverTab.allCases.flatMap { tab in [false, true].map { (width, tab, $0) } }
}
