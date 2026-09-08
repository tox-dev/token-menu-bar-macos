import AppKit
import SwiftUI
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test(arguments: [220.0, 880.0]) @MainActor
func panelRowKeepsOneInteractiveNativeStepper(width: Double) throws {
  let fixture = NativeHosting(
    PanelRow("Retention") {
      Stepper("60 days", value: .constant(60), in: 7...365)
        .richHelp(TooltipContent(title: "Retention", body: "Sets how long samples remain available."))
    }, width: width, height: 120)
  defer { fixture.close() }
  let hosting = fixture.view
  let steppers: [NSStepper] = findViews(in: hosting)
  #expect(steppers.count == 1)
  let stepper = try #require(steppers.first)
  let point = hosting.convert(CGPoint(x: stepper.bounds.midX, y: stepper.bounds.midY), from: stepper)
  let hit = try #require(hosting.hitTest(point))
  #expect(hit === stepper || hit.isDescendant(of: stepper))
}

@Test(arguments: [0.0, 180.0]) @MainActor
func scrollingTabDoesNotInterceptNativeControls(scrollOffset: Double) throws {
  let fixture = NativeHosting(
    ScrollingTab(tab: .settings) {
      VStack {
        Color.clear.frame(height: 200)
        Stepper("Retention", value: .constant(60), in: 1...365)
        Color.clear.frame(height: 900)
      }
    }, width: 880, height: 500)
  defer { fixture.close() }
  let hosting = fixture.view
  let steppers: [NSStepper] = findViews(in: hosting)
  let stepper = try #require(steppers.first)
  let scrollView = try #require(stepper.enclosingScrollView)
  scrollView.contentView.scroll(to: CGPoint(x: 0, y: scrollOffset))
  scrollView.reflectScrolledClipView(scrollView.contentView)
  hosting.layoutSubtreeIfNeeded()
  let point = try #require(hosting.superview).convert(
    CGPoint(x: stepper.bounds.midX, y: stepper.bounds.midY), from: stepper)
  let hit = try #require(hosting.hitTest(point))
  #expect(hit === stepper || hit.isDescendant(of: stepper))
}

@Test @MainActor func longHistoryPathsScrollWithoutTruncation() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let path = root.appendingPathComponent(
    String(repeating: "long-directory/", count: 10) + "history.sqlite")
  let environment = UIEnvironment(
    state: AppState(), settings: makeSettings(), history: try UsageHistoryStore(url: path), log: makeLog(),
    appInfo: testAppInfo)
  environment.disclosures.setExpanded(true, for: "settings.storage")
  let fixture = NativeHosting(
    SettingsTab(environment: environment, mountsIncrementally: false), width: 880, height: 3000)
  defer { fixture.close() }
  let hosting = fixture.view
  fixture.show()
  await waitUntil {
    hosting.layoutSubtreeIfNeeded()
    return scrollViews(hosting).contains { scroll in
      scroll.contentView.bounds.height <= 30
        && (scroll.documentView?.frame.width ?? 0) > scroll.contentView.bounds.width
    }
  }
  #expect(environment.disclosures.expanded.contains("settings.storage"))
  #expect(
    scrollViews(hosting).contains { scroll in
      scroll.contentView.bounds.height <= 30
        && (scroll.documentView?.frame.width ?? 0) > scroll.contentView.bounds.width
    },
    "Host: \(hosting.frame). Scroll frames: \(scrollViews(hosting).map { [$0.bounds, $0.contentView.bounds, $0.documentView?.frame ?? .zero] })"
  )
}

@MainActor
private func findViews<Wanted: NSView>(in root: NSView) -> [Wanted] {
  (root as? Wanted).map { [$0] } ?? root.subviews.flatMap { findViews(in: $0) }
}

@MainActor
private func scrollViews(_ view: NSView) -> [NSScrollView] {
  ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews($0) }
}
