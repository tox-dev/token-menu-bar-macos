import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@testable import TokenMenuBarUI

@Test @MainActor func tabPresentationDiagnosticMeasuresFromTheInputEvent() throws {
  let environment = try makeEnvironment(populate: false)
  environment.log.debugEnabled = true
  environment.beginTabTransition(to: .settings, inputTimestamp: ProcessInfo.processInfo.systemUptime - 0.01)
  environment.completeTabTransition(to: .history)
  #expect(environment.log.text.contains("tab.transition from=Usage to=Settings"))
  #expect(!environment.log.text.contains("tab.presented"))
  environment.completeTabTransition(to: .settings)
  #expect(environment.log.text.contains("tab.presented to=Settings active=Settings durationMs="))
}

@Test(arguments: [320.0, 728.0, 880.0]) @MainActor
func periodSegmentsReserveTheirFullRenderedLabelWidth(width: Double) throws {
  let view = NativeSegmentedControl(
    HistoryPeriod.allCases.map { (value: $0, label: $0.title) }, selection: .constant(.now),
    accessibilityLabel: "Period")
  let hosting = host(view, width: width, height: 50)
  let control = try #require(segmentedControl(in: hosting))
  let font = control.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
  #expect(
    (0..<control.segmentCount).allSatisfy { index in
      control.width(forSegment: index) >= NSAttributedString(
        string: control.label(forSegment: index)!, attributes: [.font: font]
      ).size().width + 20
    })
}

@Test(arguments: [320.0, 880.0]) @MainActor
func measuredContentReplacesTheInitialHeightEstimate(width: Double) async {
  var measurement: PopoverMeasurement?
  let hosting = host(
    ScrollingTab(tab: .settings, measurementHeight: 1) {
      Text(String(repeating: "Complete supporting details must wrap without truncation. ", count: 40))
        .fixedSize(horizontal: false, vertical: true)
    }.onPreferenceChange(PopoverMeasurementKey.self) { value in MainActor.assumeIsolated { measurement = value } },
    width: width, height: 400)
  await mainActorTurn()
  hosting.layoutSubtreeIfNeeded()
  await mainActorTurn()
  #expect((measurement?.size.height ?? 0) > 100)
}

@Test(arguments: [4.0, 16.0, 440.0]) @MainActor
func scrollingTabPaddingRoutesWheelEventsToItsScrollView(x: Double) throws {
  let hosting = host(
    ScrollingTab(tab: .settings) {
      VStack {
        Text("Top")
        Spacer().frame(height: 1200)
        Text("Bottom")
      }.frame(maxWidth: .infinity)
    }, width: 880, height: 500)
  let window = NonpresentingWindow(content: hosting, frame: CGRect(x: 100, y: 100, width: 880, height: 500))
  defer {
    window.contentView = nil
    window.close()
  }
  hosting.layoutSubtreeIfNeeded()
  let hit = try #require(hosting.hitTest(CGPoint(x: x, y: 250)))
  #expect(hit is NSScrollView || hit.enclosingScrollView != nil, "Wheel target: \(type(of: hit))")
  #expect(!window.isVisible)
}

@MainActor
private func segmentedControl(in root: NSView) -> NSSegmentedControl? {
  if let control = root as? NSSegmentedControl { return control }
  return root.subviews.lazy.compactMap { segmentedControl(in: $0) }.first
}
