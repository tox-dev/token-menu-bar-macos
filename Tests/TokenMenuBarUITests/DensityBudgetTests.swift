import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func usageContentFitsTheDensityBudget() async throws {
  let height = try await measuredHeight(for: .usage)
  #expect(height <= 1_100, "Usage measured \(height) points")
}

@Test @MainActor func historyContentFitsTheDensityBudget() async throws {
  let height = try await measuredHeight(for: .history)
  #expect((700...760).contains(height), "History measured \(height) points")
}

@Test @MainActor func settingsContentFitsTheDensityBudget() async throws {
  let height = try await measuredHeight(for: .settings)
  #expect(height <= 1_650, "Settings measured \(height) points")
}

@MainActor
private func measuredHeight(for tab: PopoverTab) async throws -> CGFloat {
  let environment = try makeEnvironment()
  environment.settings.lastTab = tab
  var measurements: [PopoverMeasurement] = []
  var settingsContentReady = tab != .settings
  let hosting = host(
    RootView(environment: environment, onMeasure: { measurements.append($0) }, onTabChange: { _ in })
      .onPreferenceChange(SettingsContentReadyKey.self) { settingsContentReady = $0 },
    width: PopoverGeometry.stableTabWidth, height: 1_600)
  #expect(hosting.frame.width == PopoverGeometry.stableTabWidth)
  await waitUntil { settingsContentReady }
  hosting.layoutSubtreeIfNeeded()
  await mainActorTurn()
  hosting.layoutSubtreeIfNeeded()
  await waitUntil { measurements.contains { $0.tab == tab } }
  return try #require(measurements.last { $0.tab == tab }?.size.height)
}
