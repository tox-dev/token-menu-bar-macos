import Foundation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@Test(arguments: ["2026-09-08T01:00:00Z", "2026-03-08T10:30:00Z", "2026-11-01T09:30:00Z"])
func spendIncludesCurrentUTCDayAcrossLocalBoundaries(timestamp: String) async throws {
  let now = try #require(ISO8601DateFormatter().date(from: timestamp))
  let history = try UsageHistoryStore(url: nil)
  try await history.record(
    ProviderAnalytics(
      provider: .claude,
      points: [AnalyticsPoint(day: DayStamp.string(now), metric: .costUSD, series: "model", value: 3)],
      fetchedAt: now))
  let summary = try await SpendSummaryPresenter.load(
    history: history, providers: [.claude], now: now, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
  #expect(summary.total.today == 3)
  #expect(summary.total.lastWindow == 3)
}

@Test @MainActor func spendRetainsLastKnownTotalsWhenRefreshFails() async throws {
  let history = try UsageHistoryStore(url: nil)
  try await history.record(
    ProviderAnalytics(
      provider: .claude,
      points: [AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .costUSD, series: "model", value: 3)],
      fetchedAt: fixedNow))
  let model = SpendSummaryModel()
  await model.load(history: history, providers: [.claude], now: fixedNow, timeZone: .current)
  try await history.breakDatabase()
  await model.load(history: history, providers: [.claude], now: fixedNow, timeZone: .current)
  #expect(model.summary?.today == 3)
  #expect(model.byProvider[.claude]?.today == 3)
  #expect(model.error == "Cost history could not be updated. Showing last-known totals.")
}

@Test func clearingAnalyticsOnlyHistoryReportsTheDeletion() async throws {
  let history = try UsageHistoryStore(url: nil)
  try await history.record(
    ProviderAnalytics(
      provider: .claude,
      points: [AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .costUSD, series: "model", value: 3)],
      fetchedAt: fixedNow))
  #expect(try await history.clear() == 1)
  let summary = try await SpendSummaryPresenter.load(
    history: history, providers: [.claude], now: fixedNow, timeZone: .current)
  #expect(summary.total == .empty)
  #expect(summary.byProvider.isEmpty)
}
