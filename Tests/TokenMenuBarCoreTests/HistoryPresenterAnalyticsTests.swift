import Foundation
import Testing
import TokenMenuBarCore

@Test(arguments: HistoryRange.allCases)
@MainActor func historyPresenterLoadsCodexOnlyAnalyticsForEachRange(_ range: HistoryRange) async throws {
  let settings = Settings(defaults: UserDefaults(suiteName: "history-analytics-\(UUID().uuidString)")!)
  settings.historyRange = range
  let history = try UsageHistoryStore(url: nil)
  let presenter = HistoryPresenter(history: history, settings: settings, clock: testClock)
  try await history.record(
    ProviderAnalytics(
      provider: .codex,
      points: [AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .turns, series: "codex", value: 3)],
      fetchedAt: fixedNow))

  presenter.setMetric(.analytics(.turns))
  await presenter.waitForLoad()

  let data = try #require(presenter.state.data)
  #expect(data.metric == .analytics(.turns))
  #expect(data.series.map(\.id.provider) == [.codex])
  #expect(data.series.flatMap(\.points).map(\.value) == [3])
}

@Test @MainActor func historyPresenterLimitsAnalyticsToActiveProviders() async throws {
  let settings = Settings(defaults: UserDefaults(suiteName: "history-active-providers-\(UUID().uuidString)")!)
  let history = try UsageHistoryStore(url: nil)
  let presenter = HistoryPresenter(
    history: history, settings: settings, clock: testClock, initialMetric: .analytics(.inputTokens))
  let day = DayStamp.string(fixedNow)
  try await history.record(
    ProviderAnalytics(
      provider: .claude,
      points: [AnalyticsPoint(day: day, metric: .inputTokens, series: "opus", value: 2)], fetchedAt: fixedNow))
  try await history.record(
    ProviderAnalytics(
      provider: .codex,
      points: [AnalyticsPoint(day: day, metric: .inputTokens, series: "total", value: 3)], fetchedAt: fixedNow))

  presenter.setDataScope(HistoryDataScope(activeProviders: [.codex]))
  await presenter.waitForLoad()

  #expect(presenter.state.data?.series.map(\.id.provider) == [.codex])
}

@Test @MainActor func historyPresenterPagesThroughExactNonoverlappingUTCDays() async throws {
  let settings = Settings(defaults: UserDefaults(suiteName: "history-pages-\(UUID().uuidString)")!)
  settings.historyRange = .week
  let history = try UsageHistoryStore(url: nil)
  let presenter = HistoryPresenter(
    history: history, settings: settings, clock: testClock, initialMetric: .analytics(.inputTokens))
  let points = (0..<14).map { offset in
    AnalyticsPoint(
      day: DayStamp.string(fixedNow.addingTimeInterval(-Double(offset) * 86400)), metric: .inputTokens,
      series: "total", value: Double(offset + 1))
  }
  try await history.record(ProviderAnalytics(provider: .codex, points: points, fetchedAt: fixedNow))

  presenter.reload()
  await presenter.waitForLoad()
  let current = try #require(presenter.state.data?.series.first).points.map { DayStamp.string($0.date) }
  #expect(current.count == 7)
  #expect(Set(current) == Set((0..<7).map { DayStamp.string(fixedNow.addingTimeInterval(-Double($0) * 86400)) }))
  let currentURL = temporaryDirectory().appendingPathComponent("current.csv")
  await presenter.exportCSV(to: currentURL).value
  let currentExport = try exportedDays(from: currentURL)
  #expect(currentExport == Set(current))

  presenter.page(forward: false, now: fixedNow)
  await presenter.waitForLoad()
  let previous = try #require(presenter.state.data?.series.first).points.map { DayStamp.string($0.date) }
  #expect(previous.count == 7)
  #expect(Set(previous).isDisjoint(with: current))
  let previousURL = temporaryDirectory().appendingPathComponent("previous.csv")
  await presenter.exportCSV(to: previousURL).value
  let previousExport = try exportedDays(from: previousURL)
  #expect(previousExport == Set(previous))
  #expect(previousExport.isDisjoint(with: currentExport))
}

private func exportedDays(from url: URL) throws -> Set<String> {
  Set(
    try String(contentsOf: url, encoding: .utf8).split(separator: "\n").dropFirst().compactMap {
      $0.split(separator: ",").dropFirst().first.map(String.init)
    })
}

@Test @MainActor func historyPresenterUsesTheSelectedAnalyticsMetricForNavigation() async throws {
  let settings = Settings(defaults: UserDefaults(suiteName: "history-earliest-\(UUID().uuidString)")!)
  settings.historyRange = .today
  let history = try UsageHistoryStore(url: nil)
  let presenter = HistoryPresenter(
    history: history, settings: settings, clock: testClock, initialMetric: .analytics(.turns))
  try await history.record(
    ProviderAnalytics(
      provider: .codex,
      points: [AnalyticsPoint(day: "2026-08-10", metric: .turns, series: "total", value: 3)],
      fetchedAt: fixedNow))

  presenter.reload()
  await presenter.waitForLoad()
  #expect(presenter.earliest == DayStamp.date("2026-08-10"))
  #expect(presenter.canPageBack)
}

@Test @MainActor func historyPresenterPagesTodayWithoutDuplicatingUTCDays() async throws {
  let settings = Settings(defaults: UserDefaults(suiteName: "history-today-pages-\(UUID().uuidString)")!)
  settings.historyRange = .today
  let history = try UsageHistoryStore(url: nil)
  let presenter = HistoryPresenter(
    history: history, settings: settings, clock: testClock, initialMetric: .analytics(.turns))
  try await history.record(
    ProviderAnalytics(
      provider: .codex,
      points: (0..<3).map { offset in
        AnalyticsPoint(
          day: DayStamp.string(fixedNow.addingTimeInterval(-Double(offset) * 86400)), metric: .turns,
          series: "total", value: Double(offset + 1))
      }, fetchedAt: fixedNow))

  presenter.reload()
  await presenter.waitForLoad()
  let current = try #require(presenter.state.data?.series.first?.points)
  #expect(current.map { DayStamp.string($0.date) } == [DayStamp.string(fixedNow)])

  presenter.page(forward: false, now: fixedNow)
  await presenter.waitForLoad()
  let previous = try #require(presenter.state.data?.series.first?.points)
  #expect(previous.map { DayStamp.string($0.date) } == [DayStamp.string(fixedNow.addingTimeInterval(-86400))])
}

@Test @MainActor func historyPresenterPagesACustomAnalyticsDurationByWholeUTCDays() async throws {
  let settings = Settings(defaults: UserDefaults(suiteName: "history-custom-pages-\(UUID().uuidString)")!)
  settings.historyRange = .custom
  let history = try UsageHistoryStore(url: nil)
  let presenter = HistoryPresenter(
    history: history, settings: settings, clock: testClock, initialMetric: .analytics(.surfaceUsagePercent))
  presenter.customStart = DayStamp.date("2026-08-20")!
  presenter.customEnd = DayStamp.date("2026-08-22")!
  presenter.followNow = false

  presenter.page(forward: false, now: fixedNow)
  await presenter.waitForLoad()

  #expect(presenter.customStart == DayStamp.date("2026-08-17"))
  #expect(presenter.customEnd == DayStamp.date("2026-08-19"))
  #expect(!presenter.followNow)

  presenter.page(forward: true, now: fixedNow)
  await presenter.waitForLoad()

  #expect(presenter.customStart == DayStamp.date("2026-08-20"))
  #expect(presenter.customEnd == DayStamp.date("2026-08-22"))
}

@Test @MainActor func historyPresenterTogglesAndRestoresAnalyticsSeries() async throws {
  let settings = Settings(defaults: UserDefaults(suiteName: "history-analytics-visibility-\(UUID().uuidString)")!)
  let history = try UsageHistoryStore(url: nil)
  let presenter = HistoryPresenter(
    history: history, settings: settings, clock: testClock, initialMetric: .analytics(.surfaceUsagePercent))
  try await history.record(
    ProviderAnalytics(
      provider: .codex,
      points: [
        AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .surfaceUsagePercent, series: "cli", value: 20),
        AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .surfaceUsagePercent, series: "web", value: 40),
      ], fetchedAt: fixedNow))
  presenter.reload()
  await presenter.waitForLoad()
  let id = try #require(presenter.state.data?.series.first?.id)

  presenter.toggleVisibility(id)
  await presenter.waitForLoad()
  #expect(!presenter.isVisible(id))
  presenter.toggleVisibility(id)
  await presenter.waitForLoad()
  #expect(presenter.isVisible(id))
  presenter.isolate(id)
  await presenter.waitForLoad()
  #expect(presenter.state.data?.visibleSeries.map(\.id) == [id])
  presenter.isolate(id)
  await presenter.waitForLoad()
  #expect(presenter.state.data?.visibleSeries.count == 2)
}
