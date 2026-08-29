import Foundation
import Testing

@testable import TokenMenuBarCore

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

@Test func historyQueriesFilterByKeysAndRange() async throws {
  let store = try UsageHistoryStore(url: nil)
  try await store.record(snapshot(10), now: fixedNow)
  try await store.record(snapshot(40, provider: .codex), now: fixedNow.addingTimeInterval(10))
  let key = WindowKey(provider: .codex, windowID: "session")
  let codex = try await store.samples(keys: [key], from: .distantPast, to: .distantFuture)
  #expect(codex.map(\.key) == [key])
  #expect(codex[0].usedPercent == 40)
  #expect(codex[0].resetsAt == fixedNow.addingTimeInterval(3600))
  let none = try await store.samples(from: fixedNow.addingTimeInterval(100), to: .distantFuture)
  #expect(none.isEmpty)
  let recent = try await store.recentSamples(key: key, since: fixedNow.addingTimeInterval(5))
  #expect(recent.count == 1)
  let summaries = try await store.summaries()
  #expect(summaries.map(\.key.storageKey) == ["claude:session", "claude:weekly", "codex:session", "codex:weekly"])
  #expect(summaries[0].label == "Current session")
  #expect(summaries[0].id == summaries[0].key)
  #expect(summaries[0].lastPercent == 10)
  #expect(try await store.earliestSample() == fixedNow)
  let stats = try await store.stats()
  #expect(
    stats == HistoryStats(sampleCount: 4, analyticsCount: 0, oldest: fixedNow, newest: fixedNow.addingTimeInterval(10)))
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
  let points = try await store.analytics(provider: .codex, from: "2026-08-01", to: "2026-08-31")
  #expect(points.map(\.value) == [3, 9])
  #expect(try await store.analytics(provider: .claude, from: "2026-08-01", to: "2026-08-31").isEmpty)
  #expect(try await store.stats().analyticsCount == 2)
}

@Test func historyExportsCSVAndClears() async throws {
  let store = try UsageHistoryStore(url: nil)
  try await store.record(snapshot(12.5), now: fixedNow)
  let csv = try await store.exportCSV()
  let lines = csv.split(separator: "\n")
  #expect(lines[0] == "timestamp,key,label,used_percent,resets_at")
  #expect(lines[1].hasPrefix("2026-08-29T"))
  #expect(lines[1].contains(",claude:session,Current session,12.50,2026-08-29T"))
  #expect(lines[2].hasSuffix(",claude:weekly,Weekly,6.25,"))
  #expect(try await store.clear() == 2)
  #expect(try await store.samples(from: .distantPast, to: .distantFuture).isEmpty)
  #expect(try await store.record(snapshot(1), now: fixedNow) == 2)
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
