import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func providerAnalyticsMergeReplacesOnlyCoveredMetricDays() {
  let previous = ProviderAnalytics(
    provider: .codex,
    points: correctionSeed,
    fetchedAt: fixedNow,
    accountFingerprint: "account")
  let correction = ProviderAnalytics(
    provider: .codex,
    points: [AnalyticsPoint(day: "2026-08-29", metric: .surfaceUsagePercent, series: "cli", value: 9)],
    fetchedAt: fixedNow,
    accountFingerprint: "account",
    coveredScopes: [tokenUsageScope])

  #expect(Set(previous.merging(correction, retentionDays: 7).points) == Set(correctedPoints))
}

@Test func historyRecordReplacesOnlyCoveredMetricDays() async throws {
  let store = try UsageHistoryStore(url: nil)
  try await store.record(
    ProviderAnalytics(
      provider: .codex, points: correctionSeed, fetchedAt: fixedNow, accountFingerprint: "account"))

  try await store.record(
    ProviderAnalytics(
      provider: .codex,
      points: [AnalyticsPoint(day: "2026-08-29", metric: .surfaceUsagePercent, series: "cli", value: 9)],
      fetchedAt: fixedNow,
      accountFingerprint: "account",
      coveredScopes: [tokenUsageScope]))

  let stored = try await store.analytics(provider: .codex, from: "2026-08-28", to: "2026-08-29")
  #expect(Set(stored) == Set(correctedPoints))
}

@Test func historyRecordRollsBackScopeDeletionWhenInsertionFails() async throws {
  let store = try UsageHistoryStore(url: nil)
  let previous = AnalyticsPoint(day: "2026-08-29", metric: .surfaceUsagePercent, series: "web", value: 5)
  try await store.record(ProviderAnalytics(provider: .codex, points: [previous], fetchedAt: fixedNow))
  try await store.rejectAnalyticsInsertions()

  await #expect(throws: SQLiteError.self) {
    try await store.record(
      ProviderAnalytics(
        provider: .codex,
        points: [AnalyticsPoint(day: "2026-08-29", metric: .surfaceUsagePercent, series: "cli", value: 9)],
        fetchedAt: fixedNow,
        coveredScopes: [tokenUsageScope]))
  }

  #expect(try await store.analytics(provider: .codex, from: "2026-08-29", to: "2026-08-29") == [previous])
}

@Test func codexProviderReportsCoverageOnlyForSuccessfulEndpoints() async throws {
  let transport = StubTransport()
  transport.on(
    path: "/wham/usage",
    .text(
      #"{"rate_limit_reset_credits":{"available_count":1,"total_earned_count":1,"#
        + #""immediate_reset_purchase_eligible":true}}"#))
  for endpoint in [
    CodexAPI.Analytics.tokenUsage, .workspaceCounts, .plugins, .codeReview,
  ] {
    transport.on(path: endpoint.rawValue, .text(#"{"data":[]}"#))
  }
  transport.on(path: CodexAPI.Analytics.skills.rawValue, error: URLError(.notConnectedToInternet))
  transport.on(path: "credit-usage-events", .text(#"{"data":[]}"#))

  let result = await codexProvider(MemoryCodexStore(validCodex), transport: transport).fetch(
    now: fixedNow, options: FetchOptions(includeAnalytics: true, analyticsDays: 7))
  let analytics = try #require(result.analytics)
  let expected: Set<AnalyticsCoverageScope> = [
    AnalyticsCoverageScope(
      metrics: [.surfaceUsagePercent, .modelCredits], startDay: "2026-08-23", endDay: "2026-08-29"),
    AnalyticsCoverageScope(
      metrics: [.inputTokens, .cachedInputTokens, .outputTokens, .turns, .threads, .credits],
      startDay: "2026-08-23", endDay: "2026-08-29"),
    AnalyticsCoverageScope(metrics: [.pluginInvocations], startDay: "2026-08-23", endDay: "2026-08-29"),
    AnalyticsCoverageScope(metrics: [.codeReviews], startDay: "2026-08-23", endDay: "2026-08-29"),
  ]

  #expect(analytics.points.isEmpty)
  #expect(Set(analytics.coveredScopes) == expected)
  #expect(result.warnings.count == 1)
  #expect(result.warnings[0].hasPrefix("Skills analytics unavailable"))
}

@Test func codexAnalyticsEndpointsDeclareProducedMetrics() {
  #expect(CodexAPI.Analytics.tokenUsage.metrics == [.surfaceUsagePercent, .modelCredits])
  #expect(
    CodexAPI.Analytics.workspaceCounts.metrics
      == [.inputTokens, .cachedInputTokens, .outputTokens, .turns, .threads, .credits])
  #expect(CodexAPI.Analytics.skills.metrics == [.skillInvocations])
  #expect(CodexAPI.Analytics.plugins.metrics == [.pluginInvocations])
  #expect(CodexAPI.Analytics.codeReview.metrics == [.codeReviews])
}

@Test func providerAnalyticsCoverageRoundTripsAndLegacyPayloadsDecode() throws {
  let analytics = ProviderAnalytics(
    provider: .codex,
    points: [AnalyticsPoint(day: "2026-08-29", metric: .surfaceUsagePercent, series: "cli", value: 9)],
    fetchedAt: fixedNow,
    accountFingerprint: "account",
    coveredScopes: [tokenUsageScope])
  let encoded = try JSONEncoder().encode(analytics)
  #expect(try JSONDecoder().decode(ProviderAnalytics.self, from: encoded) == analytics)

  var document = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
  document.removeValue(forKey: "accountFingerprint")
  document.removeValue(forKey: "coveredScopes")
  let legacy = try JSONDecoder().decode(
    ProviderAnalytics.self, from: JSONSerialization.data(withJSONObject: document))
  #expect(legacy.accountFingerprint == nil)
  #expect(legacy.coveredScopes.isEmpty)
}

private let tokenUsageScope = AnalyticsCoverageScope(
  metrics: [.surfaceUsagePercent, .modelCredits], startDay: "2026-08-28", endDay: "2026-08-29")

private let correctionSeed = [
  AnalyticsPoint(day: "2026-08-28", metric: .surfaceUsagePercent, series: "web", value: 3),
  AnalyticsPoint(day: "2026-08-29", metric: .surfaceUsagePercent, series: "cli", value: 4),
  AnalyticsPoint(day: "2026-08-29", metric: .surfaceUsagePercent, series: "web", value: 5),
  AnalyticsPoint(day: "2026-08-29", metric: .modelCredits, series: "removed-model", value: 7),
  AnalyticsPoint(day: "2026-08-29", metric: .skillInvocations, series: "failed-endpoint", value: 6),
]

private let correctedPoints = [
  AnalyticsPoint(day: "2026-08-29", metric: .surfaceUsagePercent, series: "cli", value: 9),
  AnalyticsPoint(day: "2026-08-29", metric: .skillInvocations, series: "failed-endpoint", value: 6),
]

extension UsageHistoryStore {
  fileprivate func rejectAnalyticsInsertions() throws {
    try database.execute(
      """
      CREATE TRIGGER reject_analytics_insert BEFORE INSERT ON analytics
      BEGIN
        SELECT RAISE(ABORT, 'rejected');
      END
      """)
  }
}
