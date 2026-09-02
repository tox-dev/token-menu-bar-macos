import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func historyRecordsThrottlesAndReloads() async throws {
  let url = temporaryDirectory().appendingPathComponent("history/usage.sqlite")
  let store = try UsageHistoryStore(url: url)
  #expect(store.location == url)
  #expect(try await store.record(snapshot(10), now: fixedNow) == 2)
  #expect(try await store.record(snapshot(11), now: fixedNow.addingTimeInterval(60)) == 0)
  #expect(try await store.record(snapshot(20), now: fixedNow.addingTimeInterval(120)) == 2)
  #expect(try await store.record(snapshot(20, resets: 7200), now: fixedNow.addingTimeInterval(180)) == 1)
  #expect(try await store.record(snapshot(21, resets: 7200), now: fixedNow.addingTimeInterval(600)) == 2)
  let samples = try await store.samples(from: .distantPast, to: .distantFuture)
  #expect(samples.count == 7)
  #expect(samples.first?.usedPercent == 10)
  let reopened = try UsageHistoryStore(url: url)
  #expect(try await reopened.record(snapshot(21, resets: 7200), now: fixedNow.addingTimeInterval(660)) == 0)
  #expect(try await reopened.record(snapshot(30, resets: 7200), now: fixedNow.addingTimeInterval(700)) == 1)
}

private func snapshot(
  _ percent: Double, resets: TimeInterval = 3600, at date: Date = fixedNow, provider: ProviderID = .claude
) -> ProviderSnapshot {
  ProviderSnapshot(
    provider: provider,
    windows: [
      QuotaWindow(
        id: "session", label: "Current session", group: .session, usedPercent: percent,
        resetsAt: date.addingTimeInterval(resets), duration: 18000),
      QuotaWindow(id: "weekly", label: "Weekly", group: .weekly, usedPercent: percent / 2, resetsAt: nil),
    ],
    fetchedAt: date
  )
}

@Test func historyQueriesFilterByKeysAndRange() async throws {
  let store = try UsageHistoryStore(url: nil)
  try await store.record(snapshot(10), now: fixedNow)
  try await store.record(snapshot(40, provider: .codex), now: fixedNow.addingTimeInterval(10))
  let key = WindowKey(provider: .codex, windowID: "session")
  let codex = try await store.samples(keys: [key], from: .distantPast, to: .distantFuture)
  #expect(codex.map(\.key) == [key])
  #expect(codex[0].usedPercent == 40)
  #expect(codex[0].resetsAt == fixedNow.addingTimeInterval(3600))
  #expect(try await store.samples(from: fixedNow.addingTimeInterval(100), to: .distantFuture).isEmpty)
  #expect(try await store.recentSamples(key: key, since: fixedNow.addingTimeInterval(5)).count == 1)
  let summaries = try await store.summaries()
  #expect(summaries.map(\.key.storageKey) == ["claude:session", "claude:weekly", "codex:session", "codex:weekly"])
  #expect(summaries[0].label == "Current session")
  #expect(summaries[0].id == summaries[0].key)
  #expect(summaries[0].lastPercent == 10)
  #expect(try await store.earliestSample() == fixedNow)
  let stats = try await store.stats()
  #expect(
    stats == HistoryStats(sampleCount: 4, analyticsCount: 0, oldest: fixedNow, newest: fixedNow.addingTimeInterval(10)))
  #expect(try await store.lastUsageDates(keys: [], from: .distantPast, to: .distantFuture).isEmpty)
}

@Test func historyQueriesLastUseFromTheFirstPositiveSampleIncreasesAndResets() async throws {
  let store = try UsageHistoryStore(url: nil)
  let start = fixedNow.addingTimeInterval(-500)
  let stamps = (0..<6).map { start.addingTimeInterval(Double($0) * 60) }
  let resets = [600.0, 600, 600, 1200, 1200, 1200]
  let percents = [80.0, 70, 60, 60, 65, 0]
  try await store.seed(
    zip(stamps, zip(percents, resets)).map { stamp, values in
      (snapshot(values.0, resets: values.1, at: stamp), stamp)
    })
  let session = WindowKey(provider: .claude, windowID: "session")

  let dates = try await store.lastUsageDates(keys: [session, session], from: stamps[1], to: stamps[5])
  let samples = try await store.samples(keys: [session], from: stamps[1], to: stamps[5])

  #expect(dates == [session: stamps[4]])
  #expect(dates == SettingsModelPresentation.lastUsageDates(samples))
  #expect(try await store.lastUsageDates(keys: [session], from: stamps[5], to: stamps[5]).isEmpty)
}

@Test func historyLastUseQueryReturnsAtMostOneRowPerRequestedKeyAcrossALargeRange() async throws {
  let store = try UsageHistoryStore(url: nil)
  let keys = (0..<13).map { WindowKey(provider: .codex, windowID: "model-\($0)") }
  let snapshots = (0..<2400).map { step -> (ProviderSnapshot, Date) in
    let stamp = fixedNow.addingTimeInterval(Double(step - 2399) * UsageHistoryStore.sampleInterval)
    return (
      ProviderSnapshot(
        provider: .codex,
        windows: keys.map {
          QuotaWindow(
            id: $0.windowID, label: $0.windowID, group: .other, usedPercent: Double(step % 100), resetsAt: nil)
        },
        fetchedAt: stamp),
      stamp
    )
  }
  try await store.seed(snapshots)
  #expect(try await store.stats().sampleCount == 31_200)

  let dates = try await store.lastUsageDates(
    keys: keys, from: snapshots[0].1, to: snapshots[snapshots.count - 1].1)

  #expect(dates.count == keys.count)
  #expect(Set(dates.keys) == Set(keys))
  #expect(Set(dates.values) == [snapshots[snapshots.count - 1].1])
}

@Test func historyStoresAnalyticsIdempotently() async throws {
  let store = try UsageHistoryStore(url: nil)
  let analytics = ProviderAnalytics(
    provider: .codex,
    points: [
      AnalyticsPoint(day: "2026-08-28", metric: .turns, series: "model:a", value: 3),
      AnalyticsPoint(day: "2026-08-29", metric: .turns, series: "model:a", value: 5),
    ],
    fetchedAt: fixedNow
  )
  #expect(try await store.record(analytics) == 2)
  #expect(
    try await store.record(
      ProviderAnalytics(
        provider: .codex, points: [AnalyticsPoint(day: "2026-08-29", metric: .turns, series: "model:a", value: 9)],
        fetchedAt: fixedNow)) == 1)
  #expect(try await store.analytics(provider: .codex, from: "2026-08-01", to: "2026-08-31").map(\.value) == [3, 9])
  #expect(try await store.analytics(provider: .claude, from: "2026-08-01", to: "2026-08-31").isEmpty)
  #expect(try await store.stats().analyticsCount == 2)
}

@Test func historyAggregatesDuplicateAnalyticsRows() async throws {
  let store = try UsageHistoryStore(url: nil)
  #expect(
    try await store.record(
      ProviderAnalytics(
        provider: .codex,
        points: [
          AnalyticsPoint(day: "2026-08-29", metric: .pluginInvocations, series: "github", value: 7),
          AnalyticsPoint(day: "2026-08-29", metric: .pluginInvocations, series: "github", value: 3),
        ], fetchedAt: fixedNow)) == 1)
  let points = try await store.analytics(provider: .codex, from: "2026-08-29", to: "2026-08-29")
  #expect(points.map(\.value) == [10])
}

@Test func historyReplacesProviderAnalyticsWhenTheAccountChangesAfterRelaunch() async throws {
  let url = temporaryDirectory().appendingPathComponent("usage.sqlite")
  var store: UsageHistoryStore? = try UsageHistoryStore(url: url)
  try await store?.record(
    ProviderAnalytics(
      provider: .codex,
      points: [
        AnalyticsPoint(day: "2026-08-28", metric: .turns, series: "account-a-only", value: 4),
        AnalyticsPoint(day: "2026-08-29", metric: .turns, series: "total", value: 3),
      ],
      fetchedAt: fixedNow,
      accountFingerprint: "account-a"))
  store = nil

  let reopened = try UsageHistoryStore(url: url)
  try await reopened.record(
    ProviderAnalytics(
      provider: .codex,
      points: [AnalyticsPoint(day: "2026-08-29", metric: .turns, series: "total", value: 9)],
      fetchedAt: fixedNow,
      accountFingerprint: "account-b"))

  let points = try await reopened.analytics(provider: .codex, from: "2026-08-01", to: "2026-08-31")
  #expect(points.map(\.day) == ["2026-08-29"])
  #expect(points.map(\.series) == ["total"])
  #expect(points.map(\.value) == [9])
}

@Test func historyPreservesLegacyAnalyticsWhenAttachingTheFirstAccount() async throws {
  let url = temporaryDirectory().appendingPathComponent("usage.sqlite")
  var store: UsageHistoryStore? = try UsageHistoryStore(url: url)
  try await store?.record(
    ProviderAnalytics(
      provider: .codex,
      points: [AnalyticsPoint(day: "2026-08-28", metric: .turns, series: "total", value: 3)],
      fetchedAt: fixedNow))
  store = nil

  let reopened = try UsageHistoryStore(url: url)
  try await reopened.record(
    ProviderAnalytics(
      provider: .codex,
      points: [AnalyticsPoint(day: "2026-08-29", metric: .turns, series: "total", value: 9)],
      fetchedAt: fixedNow,
      accountFingerprint: "account-a"))

  #expect(
    try await reopened.analytics(provider: .codex, from: "2026-08-01", to: "2026-08-31").map(\.value) == [3, 9])
}

@Test func historyCannotReinsertAnalyticsPastRetention() async throws {
  let store = try UsageHistoryStore(url: nil, retentionDays: 60)
  let old = AnalyticsPoint(day: "2026-08-01", metric: .turns, series: "total", value: 1)
  try await store.record(ProviderAnalytics(provider: .codex, points: [old], fetchedAt: fixedNow))
  #expect(try await store.stats().analyticsCount == 1)

  await store.setRetentionDays(7)
  #expect(try await store.record(ProviderAnalytics(provider: .codex, points: [old], fetchedAt: fixedNow)) == 0)
  #expect(try await store.analytics(provider: .codex, from: "2026-01-01", to: "2026-12-31").isEmpty)
}

@Test func historyFiltersAnalyticsByMetricProviderAndDay() async throws {
  let store = try UsageHistoryStore(url: nil)
  try await store.record(
    ProviderAnalytics(
      provider: .claude,
      points: [
        AnalyticsPoint(day: "2026-08-01", metric: .inputTokens, series: "a", value: 1),
        AnalyticsPoint(day: "2026-08-02", metric: .turns, series: "ignored", value: 2),
      ], fetchedAt: fixedNow))
  try await store.record(
    ProviderAnalytics(
      provider: .codex,
      points: [
        AnalyticsPoint(day: "2026-08-02", metric: .inputTokens, series: "b", value: 3),
        AnalyticsPoint(day: "2026-08-03", metric: .inputTokens, series: "late", value: 4),
      ], fetchedAt: fixedNow))

  let rows = try await store.analytics(
    metric: .inputTokens, providers: [.claude, .codex], from: "2026-08-01", to: "2026-08-02")
  #expect(rows.map(\.provider) == [.claude, .codex])
  #expect(rows.map(\.point.value) == [1, 3])
  #expect(
    try await store.earliestAnalytics(metric: .inputTokens, providers: [.claude, .codex]) == DayStamp.date("2026-08-01")
  )
  #expect(try await store.earliestAnalytics(metric: .credits, providers: [.claude, .codex]) == nil)
  #expect(try await store.analytics(metric: .inputTokens, providers: [], from: "a", to: "z").isEmpty)
  #expect(try await store.earliestAnalytics(metric: .inputTokens, providers: []) == nil)
}

@Test func historyExportsCSVAndClears() async throws {
  let store = try UsageHistoryStore(url: nil)
  try await store.record(snapshot(12.5), now: fixedNow)
  try await store.record(
    ProviderAnalytics(
      provider: .codex,
      points: [AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .turns, series: "total", value: 3)],
      fetchedAt: fixedNow))
  let url = temporaryDirectory().appendingPathComponent("history.csv")
  try await store.exportCSV(to: url)
  let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
  #expect(lines[0] == "kind,timestamp,key,label,used_percent,resets_at,provider,day,metric,series,value")
  #expect(lines[1].hasPrefix("sample,2026-08-29T"))
  #expect(lines[1].contains(",claude:session,Current session,12.50,2026-08-29T"))
  #expect(lines[2].contains(",claude:weekly,Weekly,6.25,"))
  #expect(lines[3] == "analytics,,,,,,codex,2026-08-29,turns,total,3.0000")
  #expect(try await store.clear() == 2)
  #expect(try await store.stats().sampleCount == 0)
  #expect(try await store.stats().analyticsCount == 0)
  #expect(try await store.record(snapshot(1), now: fixedNow) == 2)
}

@Test func historyExportStreamsMoreThanOneChunk() async throws {
  let store = try UsageHistoryStore(url: nil)
  // Enough rows to spill past the write buffer, so the export is exercised as the several writes it becomes.
  try await store.seed(
    (0..<4000).map { step in
      let stamp = fixedNow.addingTimeInterval(-Double(step) * 300)
      return (snapshot(Double(step % 100), at: stamp), stamp)
    })
  let url = temporaryDirectory().appendingPathComponent("large.csv")
  try await store.exportCSV(to: url)
  let text = try String(contentsOf: url, encoding: .utf8)
  #expect(text.utf8.count > 256 * 1024)
  let lines = text.split(separator: "\n")
  #expect(lines.count == 8001)
  #expect(lines[0] == "kind,timestamp,key,label,used_percent,resets_at,provider,day,metric,series,value")
  #expect(lines.last!.contains(",claude:"))
}

@Test func historyExportsTheSelectedMetricAndPeriod() async throws {
  let store = try UsageHistoryStore(url: nil)
  try await store.record(snapshot(12.5), now: fixedNow)
  try await store.record(
    ProviderAnalytics(
      provider: .codex,
      points: [AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .turns, series: "m,1", value: 3)],
      fetchedAt: fixedNow))
  let sampleURL = temporaryDirectory().appendingPathComponent("selected-samples.csv")
  let session = WindowKey(provider: .claude, windowID: "session")
  try await store.exportCSV(
    to: sampleURL, metric: .windowUsagePercent, from: fixedNow.addingTimeInterval(-1),
    to: fixedNow.addingTimeInterval(1), keys: [session])
  let sampleLines = try String(contentsOf: sampleURL, encoding: .utf8).split(separator: "\n")
  #expect(sampleLines.count == 2)
  #expect(sampleLines[1].contains("claude:session"))

  let analyticsURL = temporaryDirectory().appendingPathComponent("selected-analytics.csv")
  try await store.exportCSV(
    to: analyticsURL, metric: .analytics(.turns), from: fixedNow.addingTimeInterval(-1),
    to: fixedNow.addingTimeInterval(1))
  let analyticsText = try String(contentsOf: analyticsURL, encoding: .utf8)
  #expect(analyticsText.contains("provider,day,metric,series,value"))
  #expect(analyticsText.contains("codex,\(DayStamp.string(fixedNow)),turns,\"m,1\",3.0000"))
}

@Test func historyExportsOnlyTheHeaderWhenNoWindowsAreSelected() async throws {
  let store = try UsageHistoryStore(url: nil)
  try await store.record(snapshot(12.5), now: fixedNow)
  let url = temporaryDirectory().appendingPathComponent("no-selected-samples.csv")

  try await store.exportCSV(
    to: url, metric: .windowUsagePercent, from: fixedNow.addingTimeInterval(-1),
    to: fixedNow.addingTimeInterval(1), keys: [])

  #expect(try String(contentsOf: url, encoding: .utf8) == "timestamp,key,label,used_percent,resets_at\n")
}

@Test func historyQueriesAndExportsRespondToCancellation() async throws {
  let store = try UsageHistoryStore(url: nil)
  try await store.seed(
    (0..<200).map { step in
      let stamp = fixedNow.addingTimeInterval(-Double(step) * 300)
      return (snapshot(Double(step % 100), at: stamp), stamp)
    })

  let samples = Task {
    try await store.samples(from: fixedNow.addingTimeInterval(-200 * 300), to: fixedNow)
  }
  samples.cancel()
  await expectCancellation(samples)

  let fullURL = temporaryDirectory().appendingPathComponent("cancelled-full.csv")
  let fullExport = Task { try await store.exportCSV(to: fullURL) }
  fullExport.cancel()
  await expectCancellation(fullExport)

  let selectedURL = temporaryDirectory().appendingPathComponent("cancelled-selected.csv")
  let selectedExport = Task {
    try await store.exportCSV(
      to: selectedURL, metric: .windowUsagePercent, from: fixedNow.addingTimeInterval(-200 * 300), to: fixedNow)
  }
  selectedExport.cancel()
  await expectCancellation(selectedExport)
}

private func expectCancellation<Value>(_ task: Task<Value, any Error>) async {
  do {
    _ = try await task.value
    Issue.record("expected cancellation")
  } catch is CancellationError {
    return
  } catch {
    Issue.record("expected CancellationError, got \(error)")
  }
}

@Test func historyRollsSamplesUpInTheDatabase() async throws {
  let store = try UsageHistoryStore(url: nil)
  // Four samples inside one hour, one in the next.
  let stamps = [0.0, 600, 1200, 1800, 3900].map { fixedNow.addingTimeInterval($0) }
  try await store.seed(stamps.enumerated().map { index, stamp in (snapshot(Double(index) * 10, at: stamp), stamp) })

  let all = try await store.samples(from: .distantPast, to: .distantFuture)
  #expect(all.count == 10)

  // An hourly rollup keeps the newest sample of each window in each hour, which is what the chart draws.
  let hourly = try await store.samples(from: .distantPast, to: .distantFuture, rollup: 3600)
  #expect(hourly.count == 4)
  #expect(hourly.map(\.timestamp) == [stamps[3], stamps[3], stamps[4], stamps[4]])
  #expect(hourly.filter { $0.key.windowID == "session" }.map(\.usedPercent) == [30, 40])
}

@Test func historyMinuteRollupKeepsTheNewestSampleInEachMinute() async throws {
  let store = try UsageHistoryStore(url: nil)
  let minute = Date(timeIntervalSince1970: (fixedNow.timeIntervalSince1970 / 60).rounded(.down) * 60)
  let stamps = [minute.addingTimeInterval(5), minute.addingTimeInterval(45), minute.addingTimeInterval(65)]
  try await store.seed(stamps.enumerated().map { (snapshot(Double($0) * 10, at: $1), $1) })

  let samples = try await store.samples(
    from: minute, to: minute.addingTimeInterval(120), rollup: Rollup.minute.seconds,
    timeZone: TimeZone(identifier: "UTC")!)

  #expect(samples.count == 4)
  #expect(samples.filter { $0.key.windowID == "session" }.map(\.timestamp) == [stamps[1], stamps[2]])
  #expect(samples.filter { $0.key.windowID == "session" }.map(\.usedPercent) == [10, 20])
}

@Test func historyRollupUsesTheOffsetAtEachSample() async throws {
  let store = try UsageHistoryStore(url: nil)
  let before = ISODate.parse("2026-03-07T06:30:00Z")!
  let after = ISODate.parse("2026-03-07T07:30:00Z")!
  try await store.seed([(snapshot(10, at: before), before), (snapshot(20, at: after), after)])

  let samples = try await store.samples(
    from: before.addingTimeInterval(-1), to: after.addingTimeInterval(1), rollup: Rollup.day.seconds,
    timeZone: TimeZone(identifier: "America/Los_Angeles")!)
  #expect(samples.count == 2)
  #expect(samples.allSatisfy { $0.timestamp == after })
  #expect(samples.filter { $0.key.windowID == "session" }.map(\.usedPercent) == [20])
}

@Test func historyRollupSplitsTheQueryAtADaylightSavingTransition() async throws {
  let store = try UsageHistoryStore(url: nil)
  let before = ISODate.parse("2026-03-08T09:30:00Z")!
  let after = ISODate.parse("2026-03-08T10:30:00Z")!
  try await store.seed([(snapshot(10, at: before), before), (snapshot(20, at: after), after)])

  let samples = try await store.samples(
    from: ISODate.parse("2026-03-08T08:00:00Z")!, to: ISODate.parse("2026-03-08T12:00:00Z")!,
    rollup: Rollup.day.seconds, timeZone: TimeZone(identifier: "America/Los_Angeles")!)

  #expect(samples.count == 2)
  #expect(samples.allSatisfy { $0.timestamp == after })
}

@Test func historyPrunesOldRows() async throws {
  let store = try UsageHistoryStore(url: nil)
  try await store.record(snapshot(10, at: fixedNow), now: fixedNow)
  let later = fixedNow.addingTimeInterval(UsageHistoryStore.retention + 7200)
  try await store.record(snapshot(20, at: later), now: later)
  #expect(try await store.samples(from: .distantPast, to: .distantFuture).map(\.usedPercent) == [20, 10])
  let muchLater = later.addingTimeInterval(7200)
  try await store.record(snapshot(30, at: muchLater), now: muchLater)
  #expect(try await store.samples(from: .distantPast, to: .distantFuture).count == 4)
}

@Test func historyUsesTheConfiguredRetentionPeriod() async throws {
  let store = try UsageHistoryStore(url: nil, retentionDays: 1)
  #expect(await store.retentionDays == 7)
  try await store.record(snapshot(10, at: fixedNow), now: fixedNow)
  let later = fixedNow.addingTimeInterval(8 * 86400)
  try await store.record(snapshot(20, at: later), now: later)
  #expect(try await store.samples(from: .distantPast, to: .distantFuture).count == 2)
  await store.setRetentionDays(999)
  #expect(await store.retentionDays == 365)
}

@Test func historyAppliesShorterRetentionAtomically() async throws {
  let store = try UsageHistoryStore(url: nil, retentionDays: 60)
  let old = fixedNow.addingTimeInterval(-30 * 86400)
  try await store.seed([(snapshot(10, at: old), old)])
  try await store.record(
    ProviderAnalytics(
      provider: .codex,
      points: [AnalyticsPoint(day: DayStamp.string(old), metric: .turns, series: "total", value: 2)],
      fetchedAt: fixedNow))

  let pruned = try await store.setRetentionDays(7, now: fixedNow)

  #expect(pruned == HistoryPruneResult(samples: 2, analytics: 1))
  #expect(try await store.stats().sampleCount == 0)
  #expect(try await store.stats().analyticsCount == 0)
}

@Test func historyCancelledRetentionDoesNotPrune() async throws {
  let store = try UsageHistoryStore(url: nil, retentionDays: 60)
  let old = fixedNow.addingTimeInterval(-30 * 86400)
  try await store.seed([(snapshot(10, at: old), old)])
  try await store.record(
    ProviderAnalytics(
      provider: .codex,
      points: [AnalyticsPoint(day: DayStamp.string(old), metric: .turns, series: "total", value: 2)],
      fetchedAt: fixedNow))
  let retention = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return try await store.setRetentionDays(7, now: fixedNow)
  }

  await expectCancellation(retention)

  #expect(await store.retentionDays == 60)
  #expect(try await store.stats().sampleCount == 2)
  #expect(try await store.stats().analyticsCount == 1)
}

@Test func historySampleRangesCanExcludeTheEndBoundary() async throws {
  let store = try UsageHistoryStore(url: nil)
  try await store.seed([(snapshot(10, at: fixedNow), fixedNow)])

  let excluded = try await store.samples(
    from: fixedNow.addingTimeInterval(-60), to: fixedNow, includesEnd: false)
  let included = try await store.samples(
    from: fixedNow.addingTimeInterval(-60), to: fixedNow, includesEnd: true)

  #expect(excluded.isEmpty)
  #expect(included.count == 2)
}

@Test func historyRejectsUnopenablePath() {
  #expect(throws: (any Error).self) {
    try UsageHistoryStore(url: URL(fileURLWithPath: "/dev/null/impossible/usage.sqlite"))
  }
}

@Test func historyShouldRecordRules() {
  let key = WindowKey(provider: .claude, windowID: "session")
  let base = UsageSample(timestamp: fixedNow, key: key, usedPercent: 10, resetsAt: fixedNow)
  #expect(UsageHistoryStore.shouldRecord(base, after: nil))
  #expect(
    !UsageHistoryStore.shouldRecord(
      UsageSample(timestamp: fixedNow.addingTimeInterval(10), key: key, usedPercent: 12, resetsAt: fixedNow),
      after: base))
  #expect(
    UsageHistoryStore.shouldRecord(
      UsageSample(timestamp: fixedNow.addingTimeInterval(10), key: key, usedPercent: 15, resetsAt: fixedNow),
      after: base))
  #expect(
    UsageHistoryStore.shouldRecord(
      UsageSample(timestamp: fixedNow.addingTimeInterval(10), key: key, usedPercent: 10, resetsAt: nil), after: base))
  #expect(
    UsageHistoryStore.shouldRecord(
      UsageSample(timestamp: fixedNow.addingTimeInterval(400), key: key, usedPercent: 10, resetsAt: fixedNow),
      after: base))
}

@Test func sqliteWrapperReportsErrors() throws {
  #expect(throws: SQLiteError.self) { try SQLiteDatabase(path: "/dev/null/nope.sqlite") }
  let database = try SQLiteDatabase(path: ":memory:")
  #expect(throws: SQLiteError.self) { try database.execute("NOT SQL") }
  try database.execute("CREATE TABLE t (a INTEGER, b REAL, c TEXT, d REAL)")
  try database.execute("INSERT INTO t VALUES (?, ?, ?, ?)", [.integer(1), .real(2.5), .text("x"), .null])
  let rows = try database.query("SELECT a, b, c, d FROM t") {
    ($0.int(0), $0.double(1), $0.text(2), $0.double(3), $0.date(3))
  }
  #expect(rows.count == 1)
  #expect(rows[0].0 == 1)
  #expect(rows[0].1 == 2.5)
  #expect(rows[0].2 == "x")
  #expect(rows[0].3 == nil)
  #expect(rows[0].4 == nil)
  #expect(database.changes == 1)
  #expect(throws: SQLiteError.self) { try database.execute("INSERT INTO missing VALUES (1)") }
  #expect(throws: SQLiteError.self) { try database.execute("INSERT INTO t VALUES (?, ?, ?, ?, ?)", [.integer(1)]) }
  #expect(SQLiteValue(nil as Double?) == .null)
  #expect(SQLiteValue(fixedNow) == .real(fixedNow.timeIntervalSince1970))
}
