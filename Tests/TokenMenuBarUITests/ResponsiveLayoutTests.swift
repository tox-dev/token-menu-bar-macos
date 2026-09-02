import AppKit
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func usageRowsReflowAt548Points() throws {
  let card = UsagePresenter.card(
    provider: .claude, state: ProviderState(snapshot: sampleSnapshot(.claude), availability: .current), samples: [:],
    now: fixedNow)
  let row = try #require(card.rows.first)
  let wide = fittingSize(WindowRowView(row: row, now: fixedNow), width: 852)
  let narrow = fittingSize(WindowRowView(row: row, now: fixedNow), width: 548)
  #expect(narrow.width <= 548)
  #expect(narrow.height > wide.height)
}

@Test @MainActor func modelRowsReflowAt548PointsAndAccessibilityText() throws {
  let environment = try makeEnvironment()
  let list = WindowSelectionList(environment: environment)
  let row = try #require(list.groups.first?.rows.first)
  let wide = fittingSize(list.modelRow(row), width: 852)
  let narrow = fittingSize(list.modelRow(row), width: 548)
  let accessible = fittingSize(
    list.modelRow(row).environment(\.dynamicTypeSize, .accessibility1), width: 548)
  #expect(narrow.width <= 548)
  #expect(narrow.height > wide.height)
  #expect(accessible.height >= narrow.height)
}

@Test @MainActor func settingsRendersAt548PointsWithAccessibilityText() throws {
  let environment = try makeEnvironment()
  environment.settings.statusFormat = .custom
  let view = SettingsTab(environment: environment).environment(\.dynamicTypeSize, .accessibility1)
  #expect(inkFraction(view, width: 548, height: 1800) > 0)
}

@MainActor private func fittingSize<Content: View>(_ view: Content, width: CGFloat) -> CGSize {
  quietTestApp()
  let hosting = NSHostingView(
    rootView: view.frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
  hosting.layoutSubtreeIfNeeded()
  return hosting.fittingSize
}
