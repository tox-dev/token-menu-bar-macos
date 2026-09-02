import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func canonicalAnalyticsTotalUsesOneBreakdownPerDay() {
  let points = [
    AnalyticsPoint(day: "2026-08-01", metric: .turns, series: "total", value: 8),
    AnalyticsPoint(day: "2026-08-01", metric: .turns, series: "model:gpt-5", value: 8),
    AnalyticsPoint(day: "2026-08-02", metric: .turns, series: "surface:cli", value: 5),
    AnalyticsPoint(day: "2026-08-02", metric: .turns, series: "model:gpt-5", value: 5),
  ]

  #expect(ChartPipeline.canonicalTotal(points, metric: .analytics(.turns)) == 13)
}

@Test func lastUsageDatesObservesCancellationBeforeQuery() async throws {
  let store = try UsageHistoryStore(url: nil)
  let (stream, continuation) = AsyncStream<Void>.makeStream()
  let task = Task {
    for await _ in stream.prefix(1) {}
    return try await store.lastUsageDates(
      keys: [WindowKey(provider: .codex, windowID: "weekly")], from: .distantPast, to: .distantFuture)
  }

  task.cancel()
  continuation.finish()

  do {
    _ = try await task.value
    Issue.record("expected cancellation")
  } catch is CancellationError {
    return
  } catch {
    Issue.record("expected CancellationError, got \(error)")
  }
}

@Test func resolvedLabelsRejectAnOverrideThatHidesAnotherDefault() throws {
  let claude = historyCoverageWindow("session", label: "Session")
  let codex = historyCoverageWindow("weekly", label: "Weekly")
  let gemini = historyCoverageWindow("monthly", label: "Monthly")
  let claudeKey = WindowKey(.claude, claude)
  let codexKey = WindowKey(.codex, codex)
  let geminiKey = WindowKey(.gemini, gemini)
  let windows = [claudeKey: claude, codexKey: codex, geminiKey: gemini]
  let defaults = ShortLabelPolicy.derivedLabels(windows: windows)
  let codexDefault = try #require(defaults[codexKey])
  let overrides = [claudeKey: codexDefault]

  #expect(ShortLabelPolicy.resolvedLabels(windows: windows, overrides: overrides) == defaults)
  #expect(
    ShortLabelPolicy.conflictingKey(
      codexDefault, for: geminiKey, windows: windows, overrides: overrides) == claudeKey)
}

@Test func derivedLabelsAdvancePastAnOccupiedSuffix() {
  let windows = ["alpha", "beta", "gamma"].map {
    historyCoverageWindow("additional:spark-\($0)", label: "Spark \($0)")
  }
  let keyed = Dictionary(uniqueKeysWithValues: windows.map { (WindowKey(.codex, $0), $0) })

  #expect(Set(ShortLabelPolicy.derivedLabels(windows: keyed).values) == ["SPK", "SPK2", "SPK3"])
}

@Test func providerPresentationHandlesMissingSnapshotIdentity() {
  let presentation = SettingsProviderPresentation(
    state: ProviderState(serviceHealth: .available), now: Date(timeIntervalSince1970: 1_788_030_000))

  #expect(presentation.identity == nil)
  #expect(presentation.lastSuccess == "No successful refresh")
  #expect(presentation.service == "Service available")
}

private func historyCoverageWindow(_ id: String, label: String) -> QuotaWindow {
  QuotaWindow(id: id, label: label, group: .other, usedPercent: 20, resetsAt: nil)
}
