import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

private let utc = TimeZone(identifier: "UTC")!

private func day(_ offset: Int) -> String {
  DayStamp.string(fixedNow.addingTimeInterval(Double(offset) * 86400))
}

private func row(_ provider: ProviderID, _ model: String, day offset: Int, cost: Double) -> HistoryAnalyticsRow {
  HistoryAnalyticsRow(
    provider: provider, point: AnalyticsPoint(day: day(offset), metric: .costUSD, series: model, value: cost))
}

private let rows = [
  row(.claude, "claude-opus-5", day: 0, cost: 3), row(.codex, "gpt-5", day: 0, cost: 1.5),
  row(.claude, "claude-opus-5", day: -1, cost: 2), row(.claude, "claude-haiku-4-5", day: -29, cost: 0.5),
  row(.claude, "claude-opus-5", day: -30, cost: 9), row(.codex, "gpt-5", day: 1, cost: 7),
]

@Test func spendSummaryTotalsTodayYesterdayAndTheWindow() {
  let summary = SpendSummaryPresenter.summary(rows: rows, now: fixedNow, timeZone: utc)
  #expect(summary.today == 4.5)
  #expect(summary.yesterday == 2)
  #expect(summary.lastWindow == 7)
  #expect(summary.providers == [.claude, .codex])
  #expect(summary.hasData)
  #expect(summary.topModels.map(\.id) == ["claude:claude-opus-5", "codex:gpt-5", "claude:claude-haiku-4-5"])
  #expect(summary.topModels.map(\.cost) == [5, 1.5, 0.5])
  #expect(summary.tiles.map(\.title) == ["Today (UTC)", "Yesterday (UTC)", "Last 30 days"])
  #expect(summary.tiles.map(\.text) == [Format.currency(4.5), Format.currency(2), Format.currency(7)])
  #expect(summary.attribution == "API-equivalent cost across Claude + Codex · daily UTC")
  #expect(
    summary.breakdown
      == "Top models over the last 30 days:\nClaude · claude-opus-5: \(Format.currency(5))\n"
      + "Codex · gpt-5: \(Format.currency(1.5))\nClaude · claude-haiku-4-5: \(Format.currency(0.5))")
}

@Test func spendSummaryKeepsTheFiveCostliestModels() {
  let many = (0..<7).map { row(.claude, "model-\($0)", day: 0, cost: Double($0)) }
  let summary = SpendSummaryPresenter.summary(rows: many, now: fixedNow, timeZone: utc)
  #expect(summary.topModels.map(\.model) == ["model-6", "model-5", "model-4", "model-3", "model-2"])
  #expect(summary.today == 21)
}

@Test(
  arguments: [
    (0, day(0), 4.5, 2.0, 7.0),
    (12 * 3600, day(0), 4.5, 2.0, 7.0),
    (-12 * 3600, day(0), 4.5, 2.0, 7.0),
  ])
func spendSummaryPreservesUTCDailyTotalsInEveryTimeZone(
  secondsFromGMT: Int, expectedToday: String, today: Double, yesterday: Double, window: Double
) {
  let timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
  #expect(SpendSummaryPresenter.dayStamps(now: fixedNow, timeZone: timeZone).today == expectedToday)
  let summary = SpendSummaryPresenter.summary(rows: rows, now: fixedNow, timeZone: timeZone)
  #expect(summary.today == today)
  #expect(summary.yesterday == yesterday)
  #expect(summary.lastWindow == window)
}

@Test func spendSummaryHasNoDataWithoutCostRows() {
  let summary = SpendSummaryPresenter.summary(rows: [], now: fixedNow, timeZone: utc)
  #expect(summary == .empty)
  #expect(!summary.hasData)
  #expect(summary.tiles.map(\.text) == Array(repeating: Format.currency(0), count: 3))
  #expect(summary.breakdown == "Top models over the last 30 days:")
}

@Test func spendSummaryLoadsCostRowsForTheRequestedProviders() async throws {
  let history = try UsageHistoryStore(url: nil)
  try await history.record(
    ProviderAnalytics(
      provider: .claude,
      points: [
        AnalyticsPoint(day: day(0), metric: .costUSD, series: "claude-opus-5", value: 3),
        AnalyticsPoint(day: day(0), metric: .projectCost, series: "repo", value: 3),
      ], fetchedAt: fixedNow))
  try await history.record(
    ProviderAnalytics(
      provider: .codex, points: [AnalyticsPoint(day: day(-1), metric: .costUSD, series: "gpt-5", value: 1.5)],
      fetchedAt: fixedNow))

  let claudeOnly = try await SpendSummaryPresenter.load(
    history: history, providers: [.claude, .gemini], now: fixedNow, timeZone: utc)
  #expect(claudeOnly.today == 3)
  #expect(claudeOnly.yesterday == 0)
  #expect(claudeOnly.providers == [.claude])

  let everyone = try await SpendSummaryPresenter.load(
    history: history, providers: ProviderID.allCases, now: fixedNow, timeZone: utc)
  #expect(everyone.today == 3)
  #expect(everyone.yesterday == 1.5)
  #expect(everyone.lastWindow == 4.5)
  #expect(everyone.topModels.map(\.id) == ["claude:claude-opus-5", "codex:gpt-5"])
}
