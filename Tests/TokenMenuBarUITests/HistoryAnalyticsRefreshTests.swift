import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test(arguments: PopoverTab.allCases) @MainActor
func historyTabReloadsAnalyticsAfterRefreshCompletes(tab: PopoverTab) async throws {
  let environment = try makeEnvironment(populate: false)
  environment.settings.lastTab = tab
  environment.state.popoverVisible = true
  environment.state.update(.codex) {
    $0.availability = .current
    $0.credentialState = .valid(expiresAt: nil)
  }
  let presenter = environment.historyPresenter
  presenter.setMetric(.analytics(.turns))
  let hosting = host(HistoryTab(environment: environment))
  defer { withExtendedLifetime(hosting) {} }
  await waitUntil { presenter.state.data != nil }
  await presenter.waitForLoad()
  #expect(presenter.state.data?.series.isEmpty == true)

  try await environment.history.record(
    ProviderAnalytics(
      provider: .codex,
      points: [AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .turns, series: "codex", value: 3)],
      fetchedAt: fixedNow))
  environment.state.markHistoryChanged()
  await waitUntil { presenter.state.data?.series.isEmpty == false }

  #expect(presenter.state.data?.series.flatMap(\.points).map(\.value) == [3])
}
