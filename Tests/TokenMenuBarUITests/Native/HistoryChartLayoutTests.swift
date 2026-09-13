import AppKit
import SwiftUI
import Testing
import TokenMenuBarNativeGuard
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test(arguments: [3, 30], [700.0, 880.0]) @MainActor
func historyChartUsesTheHeightBesideItsLegend(modelCount: Int, width: Double) async throws {
  _ = nativeAccessibilityApplication
  let environment = try makeEnvironment()
  let snapshot = ProviderSnapshot(
    provider: .claude,
    windows: (0..<modelCount).map {
      QuotaWindow(
        id: "model-\($0)", label: "Synthetic model \($0)", group: .other, usedPercent: Double($0 + 1), resetsAt: nil)
    }, fetchedAt: fixedNow)
  environment.state.update(.claude) { $0.snapshot = snapshot }
  try await environment.history.record(snapshot, now: fixedNow.addingTimeInterval(-60))
  environment.settings.selectedWindows = snapshot.windows.map { WindowKey(.claude, $0) }
  environment.settings.hasCustomSelection = true
  environment.settings.lastTab = .history
  environment.state.popoverVisible = true
  let fixture = NativeHosting(HistoryTab(environment: environment), width: width, height: 2000)
  defer { fixture.close() }
  let hosting = fixture.view
  try #require(hosting.window).orderFrontRegardless()
  await mainActorTurn()
  await environment.historyPresenter.waitForLoad()
  hosting.layoutSubtreeIfNeeded()
  // SwiftUI creates virtual accessibility elements after a client request.
  let accessibility = await Task.detached {
    let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    var windows: CFTypeRef?
    return AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
  }.value
  try #require(accessibility == .success)
  let anchors = tooltipAnchors(in: hosting)
  let chartFrame = try #require(accessibilityFrame(identifier: "history-chart", in: hosting))
  let rows = anchors.filter {
    $0.tooltipContent.body.first?.text.hasPrefix("Shows the value at the selected date.") == true
  }
  #expect(rows.count == modelCount)
  let legend = rows.reduce(CGRect.null) { $0.union(hosting.convert($1.bounds, from: $1)) }
  if width >= 880 {
    #expect(chartFrame.height >= max(PopoverGeometry.historyChartHeight, legend.height))
    #expect(chartFrame.height <= max(PopoverGeometry.historyChartHeight, legend.height + 100))
  } else {
    #expect(chartFrame.height == PopoverGeometry.historyChartHeight)
  }
}

@MainActor private func accessibilityFrame(identifier: String, in root: NSView) -> CGRect? {
  var visited: Set<ObjectIdentifier> = []
  func frame(in element: AnyObject) -> CGRect? {
    guard visited.insert(ObjectIdentifier(element)).inserted else { return nil }
    if element.accessibilityIdentifier?() == identifier { return element.accessibilityFrame?() }
    for child in element.accessibilityChildren?() ?? [] {
      if let found = frame(in: child as AnyObject) { return found }
    }
    return nil
  }
  return frame(in: root)
}

@MainActor private func tooltipAnchors(in root: NSView) -> [TooltipTrackingView] {
  root.subviews.flatMap { view in
    (view as? TooltipTrackingView).map { [$0] } ?? tooltipAnchors(in: view)
  }
}
