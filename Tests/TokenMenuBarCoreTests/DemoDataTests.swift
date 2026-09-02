import Foundation
import Testing

@testable import TokenMenuBarCore

@Test(arguments: ProviderID.allCases)
func demoSnapshotsAreDeterministicAndBounded(provider: ProviderID) {
  let snapshot = DemoData.snapshot(provider, now: fixedNow)
  #expect(snapshot == DemoData.snapshot(provider, now: fixedNow))
  #expect(snapshot.provider == provider)
  #expect(!snapshot.windows.isEmpty)
  #expect(snapshot.windows.allSatisfy { (0...100).contains($0.usedPercent) && $0.resetsAt! > fixedNow })
  #expect(snapshot.identity?.planName.isEmpty == false)
  #expect(snapshot.fetchedAt == fixedNow)
  let later = DemoData.snapshot(provider, now: fixedNow.addingTimeInterval(1800))
  #expect(later.windows.map(\.id) == snapshot.windows.map(\.id))
}

@Test func demoWindowsResetAtBoundaries() {
  let boundary = DemoData.boundary(now: fixedNow, duration: 3600, offset: 600)
  #expect(boundary > fixedNow && boundary.timeIntervalSince(fixedNow) <= 3600)
  #expect(Int(boundary.timeIntervalSince1970 - 600) % 3600 == 0)
  let midWindow = DemoData.boundary(now: fixedNow, duration: 3600, offset: 0).addingTimeInterval(-1800)
  let window = DemoData.window(
    id: "w", label: "W", group: .session, duration: 3600, offset: 0, pace: 100, now: midWindow)
  #expect(window.usedPercent == 100)
  let fresh = DemoData.window(
    id: "w", label: "W", group: .session, duration: 3600, offset: 0, pace: 0, now: midWindow)
  #expect(fresh.usedPercent <= 3)
  #expect(DemoData.activity(0) > 0 && DemoData.activity(3) > 0)
}

@Test func demoAnalyticsCoverClaudeAndCodexOnly() {
  let claude = DemoData.analytics(.claude, now: fixedNow, days: 3)!
  #expect(claude.series(for: .costUSD) == ["fable", "haiku", "sonnet"])
  #expect(claude.total(.sessions) > 0)
  #expect(Set(claude.points.map(\.day)).count == 3)
  let codex = DemoData.analytics(.codex, now: fixedNow, days: 2)!
  #expect(codex.series(for: .surfaceUsagePercent) == ["cli", "vscode", "web"])
  #expect(codex.total(.codeReviews) >= 0)
  #expect(DemoData.analytics(.gemini, now: fixedNow, days: 2) == nil)
  #expect(DemoData.analytics(.cursor, now: fixedNow, days: 2) == nil)
}

@Test func demoProviderReturnsSnapshotsAndAnalytics() async {
  let provider = DemoProvider(id: .codex)
  #expect(provider.credentialDescription == "Demo data")
  #expect(provider.credentialState(now: fixedNow) == .valid(expiresAt: nil))
  #expect(provider.pollingPolicy.minimumInterval == 60)
  let plain = await provider.fetch(now: fixedNow, options: FetchOptions())
  #expect(plain.outcome == .success(DemoData.snapshot(.codex, now: fixedNow)))
  #expect(plain.analytics == nil)
  let withAnalytics = await provider.fetch(
    now: fixedNow, options: FetchOptions(includeAnalytics: true, analyticsDays: 4))
  #expect(withAnalytics.analytics?.points.isEmpty == false)
  #expect(
    await DemoProvider(id: .gemini).fetch(now: fixedNow, options: FetchOptions(includeAnalytics: true)).analytics == nil
  )
}

@Test func longTextFixtureExpandsEveryDynamicSurfaceWithoutChangingValues() async {
  let snapshot = DemoData.snapshot(.codex, now: fixedNow, fixture: .longText)
  let standard = DemoData.snapshot(.codex, now: fixedNow)
  let provider = DemoProvider(id: .codex, fixture: .longText)
  let result = await provider.fetch(
    now: fixedNow, options: FetchOptions(includeAnalytics: true, analyticsDays: 2))

  #expect(provider.credentialDescription.hasSuffix("account-profile-with-a-deliberately-long-file-name.json"))
  #expect(snapshot.windows.map(\.usedPercent) == standard.windows.map(\.usedPercent))
  #expect(snapshot.windows.allSatisfy { $0.id.count > 50 && $0.label.count > 50 })
  #expect(snapshot.identity?.email?.count ?? 0 > 50)
  #expect(snapshot.notices.contains { $0.text.count > 100 })
  #expect(result.analytics?.points.allSatisfy { $0.series.count > 50 } == true)
}

@Test(arguments: ProviderID.allCases)
func controlAuditFixtureKeepsUsageAndExposesRecovery(provider: ProviderID) async {
  let result = await DemoProvider(id: provider, fixture: .controlAudit).fetch(
    now: fixedNow, options: FetchOptions())

  #expect(result.outcome == .success(DemoData.snapshot(provider, now: fixedNow)))
  #expect(result.recoveryIssue != nil)
}

@Test func demoSeedPopulatesHistory() async throws {
  let history = try UsageHistoryStore(url: nil)
  try await DemoData.seed(history, providers: [.claude, .gemini], now: fixedNow)
  let stats = try await history.stats()
  #expect(stats.sampleCount > 1000)
  #expect(stats.oldest! <= fixedNow.addingTimeInterval(-Double(DemoData.historyDays - 1) * 86400))
  #expect(try await history.analytics(provider: .claude, from: "2000-01-01", to: "2100-01-01").isEmpty == false)
  #expect(try await history.analytics(provider: .gemini, from: "2000-01-01", to: "2100-01-01").isEmpty)
  let summaries = try await history.summaries()
  #expect(summaries.contains { $0.key == WindowKey(provider: .claude, windowID: "session") })
  #expect(summaries.contains { $0.key == WindowKey(provider: .gemini, windowID: "model:gemini-2.5-pro") })
}

@Test func historySeedIsTransactional() async throws {
  let history = try UsageHistoryStore(url: nil)
  try await history.seed([(DemoData.snapshot(.codex, now: fixedNow), fixedNow)])
  #expect(try await history.stats().sampleCount == DemoData.snapshot(.codex, now: fixedNow).windows.count)
  try await history.breakDatabase()
  await #expect(throws: (any Error).self) {
    try await history.seed([(DemoData.snapshot(.codex, now: fixedNow), fixedNow)])
  }
}
