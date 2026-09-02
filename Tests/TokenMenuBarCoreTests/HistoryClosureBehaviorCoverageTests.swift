import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func chartCarriesAFreshSampleIntoAnEmptyViewport() throws {
  let start = historyClosureNow.addingTimeInterval(-600)
  let end = start.addingTimeInterval(60)
  let key = WindowKey(provider: .claude, windowID: "session")
  let data = ChartPipeline.render(
    samples: [
      UsageSample(timestamp: start.addingTimeInterval(-60), key: key, usedPercent: 42, resetsAt: nil)
    ],
    request: HistoryRequest(keys: [key], start: start, end: end, rollup: .minute), labels: [:], now: end)

  let series = try #require(data.series.first)
  #expect(series.points.first?.date == start)
  #expect(series.points.first?.value == 42)
  #expect(data.dataPointCount == 0)
}

@Test @MainActor func historyPresenterReportsStackingOnlyAfterMultipleSeriesLoad() async throws {
  let settings = historyClosureSettings()
  let history = try UsageHistoryStore(url: nil)
  let presenter = HistoryPresenter(
    history: history, settings: settings, clock: .fixed(historyClosureNow),
    initialMetric: .analytics(.inputTokens))

  #expect(!presenter.canStack)
  try await historyClosureRecordStackableAnalytics(in: history)
  presenter.reload()
  await presenter.waitForLoad()

  #expect(presenter.canStack)
}

@Test @MainActor func historyPresenterRedrawsStackableDataAsAStack() async throws {
  let (presenter, settings) = try await historyClosureLoadedStackingPresenter()
  let unstackedMaximum = try #require(presenter.state.data?.yMax)

  presenter.setStacked(true)
  await presenter.waitForLoad()

  #expect(settings.historyStacked)
  #expect(try #require(presenter.state.data?.yMax) > unstackedMaximum)
}

@Test @MainActor func historyPresenterCanIsolateTheFirstAnalyticsSeries() async throws {
  let (presenter, _) = try await historyClosureLoadedStackingPresenter()
  let id = try #require(presenter.state.data?.series.first?.id)

  presenter.isolate(id)
  await presenter.waitForLoad()

  #expect(presenter.state.data?.visibleSeries.map(\.id) == [id])
}

@Test @MainActor func historyPresenterResetRejectsAnInvalidStoredMetric() async throws {
  let settings = historyClosureSettings()
  settings.historyMetricID = "invalid"
  let presenter = HistoryPresenter(
    history: try UsageHistoryStore(url: nil), settings: settings, clock: .fixed(historyClosureNow),
    initialMetric: .analytics(.turns))

  presenter.reset()
  await presenter.waitForLoad()

  #expect(presenter.selectedMetric == .windowUsagePercent)
}

@Test @MainActor func historyPresenterChangesMetricWhileInitiallyPinned() async throws {
  let presenter = HistoryPresenter(
    history: try UsageHistoryStore(url: nil), settings: historyClosureSettings(), clock: .fixed(historyClosureNow))
  presenter.followNow = false

  presenter.setMetric(.analytics(.turns))
  await presenter.waitForLoad()

  #expect(presenter.state.data?.metric == .analytics(.turns))
  #expect(!presenter.followNow)
}

private let historyClosureNow = Date(timeIntervalSince1970: 1_788_030_000)

@MainActor
private func historyClosureSettings() -> Settings {
  Settings(defaults: UserDefaults(suiteName: "history-closure-\(UUID().uuidString)")!)
}

private func historyClosureRecordStackableAnalytics(in history: UsageHistoryStore) async throws {
  try await history.record(
    ProviderAnalytics(
      provider: .codex,
      points: [
        AnalyticsPoint(day: DayStamp.string(historyClosureNow), metric: .inputTokens, series: "model:a", value: 20),
        AnalyticsPoint(day: DayStamp.string(historyClosureNow), metric: .inputTokens, series: "model:b", value: 30),
      ], fetchedAt: historyClosureNow))
}

@MainActor
private func historyClosureLoadedStackingPresenter() async throws -> (HistoryPresenter, Settings) {
  let settings = historyClosureSettings()
  let history = try UsageHistoryStore(url: nil)
  try await historyClosureRecordStackableAnalytics(in: history)
  let presenter = HistoryPresenter(
    history: history, settings: settings, clock: .fixed(historyClosureNow),
    initialMetric: .analytics(.inputTokens))
  presenter.reload()
  await presenter.waitForLoad()
  return (presenter, settings)
}
