import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func codexAnalyticsWatermarksSurviveRelaunchWithOneDayOverlap() async {
  let defaults = watermarkDefaults()
  let firstTransport = analyticsTransport()
  let first = await codexProvider(
    MemoryCodexStore(validCodex), transport: firstTransport, analyticsWatermarkPersistence: persistence(defaults)
  ).fetch(now: fixedNow, options: FetchOptions(includeAnalytics: true, analyticsDays: 30))
  #expect(first.outcome.snapshot != nil, "\(first.outcome)")
  #expect(first.warnings.isEmpty)
  #expect(first.analytics != nil)
  #expect(startDates(firstTransport) == ["2026-07-31"])
  #expect(allAnalyticsStartDates(firstTransport) == Array(repeating: "2026-07-31", count: 5))

  let secondTransport = analyticsTransport()
  _ = await codexProvider(
    MemoryCodexStore(validCodex), transport: secondTransport, analyticsWatermarkPersistence: persistence(defaults)
  ).fetch(
    now: fixedNow.addingTimeInterval(86400),
    options: FetchOptions(includeAnalytics: true, analyticsDays: 30))
  #expect(startDates(secondTransport) == ["2026-08-28"])
  #expect(allAnalyticsStartDates(secondTransport) == Array(repeating: "2026-08-28", count: 5))
}

@Test func codexAnalyticsRetentionExpansionBackfillsTheUncoveredRange() async {
  let defaults = watermarkDefaults()
  let transport = analyticsTransport()
  let provider = codexProvider(
    MemoryCodexStore(validCodex), transport: transport, analyticsWatermarkPersistence: persistence(defaults))
  _ = await provider.fetch(now: fixedNow, options: FetchOptions(includeAnalytics: true, analyticsDays: 7))
  _ = await provider.fetch(
    now: fixedNow.addingTimeInterval(86400),
    options: FetchOptions(includeAnalytics: true, analyticsDays: 30))
  #expect(
    transport.requests(matching: "daily-token-usage-breakdown").compactMap(\.url?.query).map(analyticsStartDate)
      == ["2026-08-23", "2026-08-01"])
}

@Test func codexCredentialIdentityChangeResetsAccountCaches() async throws {
  let store = MemoryCodexStore(validCodex)
  let transport = analyticsTransport(inlineResetCredits: false)
  let provider = codexProvider(
    store, transport: transport, analyticsWatermarkPersistence: persistence(watermarkDefaults()))
  _ = await provider.fetch(now: fixedNow, options: FetchOptions(includeAnalytics: true, analyticsDays: 7))
  try store.save(CodexAuth(accessToken: "other-token", accountID: "other-account"))
  _ = await provider.fetch(
    now: fixedNow.addingTimeInterval(60),
    options: FetchOptions(includeAnalytics: true, analyticsDays: 7))
  #expect(transport.requests(matching: "rate-limit-reset-credits").count == 2)
  #expect(startDates(transport) == ["2026-08-23"])
}

@Test func codexCredentialIdentityChangeEvictsCachesBeforeANetworkFailure() async throws {
  let store = MemoryCodexStore(validCodex)
  let base = analyticsTransport(inlineResetCredits: false)
  let transport = FailingSecondUsageTransport(base: base)
  let provider = codexProvider(
    store, transport: transport, analyticsWatermarkPersistence: persistence(watermarkDefaults()))
  _ = await provider.fetch(now: fixedNow, options: FetchOptions())
  try store.save(CodexAuth(accessToken: "other-token", accountID: "other-account"))
  _ = await provider.fetch(now: fixedNow.addingTimeInterval(60), options: FetchOptions())
  try store.save(validCodex)
  _ = await provider.fetch(now: fixedNow.addingTimeInterval(120), options: FetchOptions())
  #expect(base.requests(matching: "rate-limit-reset-credits").count == 2)
}

@Test func codexAnalyticsWatermarksKeepOnlyFourRecentAccounts() async {
  let defaults = watermarkDefaults()
  var transports: [StubTransport] = []
  for index in 0..<5 {
    let transport = analyticsTransport()
    transports.append(transport)
    let auth = CodexAuth(accessToken: "token-\(index)", accountID: "account-\(index)")
    _ = await codexProvider(
      MemoryCodexStore(auth), transport: transport, analyticsWatermarkPersistence: persistence(defaults)
    ).fetch(
      now: fixedNow.addingTimeInterval(Double(index) * 60),
      options: FetchOptions(includeAnalytics: true, analyticsDays: 30))
  }
  #expect(transports.allSatisfy { startDates($0) == ["2026-07-31"] })

  let evictedTransport = analyticsTransport()
  _ = await codexProvider(
    MemoryCodexStore(CodexAuth(accessToken: "token-0", accountID: "account-0")),
    transport: evictedTransport,
    analyticsWatermarkPersistence: persistence(defaults)
  ).fetch(
    now: fixedNow.addingTimeInterval(360),
    options: FetchOptions(includeAnalytics: true, analyticsDays: 30))
  #expect(startDates(evictedTransport) == ["2026-07-31"])

  let retainedTransport = analyticsTransport()
  _ = await codexProvider(
    MemoryCodexStore(CodexAuth(accessToken: "token-4", accountID: "account-4")),
    transport: retainedTransport,
    analyticsWatermarkPersistence: persistence(defaults)
  ).fetch(
    now: fixedNow.addingTimeInterval(420),
    options: FetchOptions(includeAnalytics: true, analyticsDays: 30))
  #expect(startDates(retainedTransport) == ["2026-08-28"])
}

@Test func codexAnalyticsWatermarksRecoverFromCorruptStorage() async {
  let defaults = watermarkDefaults()
  defaults.set(Data("not json".utf8), forKey: CodexAnalyticsWatermarkStore.storageKey)
  let firstTransport = analyticsTransport()
  _ = await codexProvider(
    MemoryCodexStore(validCodex), transport: firstTransport, analyticsWatermarkPersistence: persistence(defaults)
  ).fetch(now: fixedNow, options: FetchOptions(includeAnalytics: true, analyticsDays: 30))
  #expect(startDates(firstTransport) == ["2026-07-31"])

  let secondTransport = analyticsTransport()
  _ = await codexProvider(
    MemoryCodexStore(validCodex), transport: secondTransport, analyticsWatermarkPersistence: persistence(defaults)
  ).fetch(
    now: fixedNow.addingTimeInterval(86400),
    options: FetchOptions(includeAnalytics: true, analyticsDays: 30))
  #expect(startDates(secondTransport) == ["2026-08-28"])
}

@Test func codexAnalyticsMigratesLegacyWatermarksWithoutPersistingIdentityPlaintext() async throws {
  let defaults = watermarkDefaults()
  let auth = CodexAuth(accessToken: "private-token", accountID: "private-account")
  let legacy = ["accounts": [auth.accountFingerprint: [CodexAPI.Analytics.tokenUsage.rawValue: "2026-08-29"]]]
  defaults.set(try JSONEncoder().encode(legacy), forKey: CodexAnalyticsWatermarkStore.storageKey)
  let transport = analyticsTransport()
  _ = await codexProvider(
    MemoryCodexStore(auth), transport: transport, analyticsWatermarkPersistence: persistence(defaults)
  ).fetch(now: fixedNow, options: FetchOptions(includeAnalytics: true, analyticsDays: 30))
  #expect(startDates(transport) == ["2026-07-31"])
  let stored = String(
    data: defaults.data(forKey: CodexAnalyticsWatermarkStore.storageKey)!, encoding: .utf8)!
  #expect(!stored.contains("private-token"))
  #expect(!stored.contains("private-account"))
}

@Test func codexAnalyticsWatermarksDiscardInvalidAndExpiredCoverage() throws {
  let defaults = watermarkDefaults()
  let account = "account"
  let encodedDate = fixedNow.timeIntervalSinceReferenceDate
  let document: [String: Any] = [
    "version": 1,
    "accounts": [
      account: [
        "lastAccess": encodedDate,
        "coverage": [
          CodexAPI.Analytics.tokenUsage.rawValue: ["start": "2026-01-01", "through": "2026-08-29"],
          CodexAPI.Analytics.workspaceCounts.rawValue: ["start": "bad", "through": "2026-08-29"],
          CodexAPI.Analytics.skills.rawValue: ["start": "2026-08-30", "through": "2026-08-29"],
          CodexAPI.Analytics.plugins.rawValue: ["start": "2026-01-01", "through": "2026-08-01"],
          CodexAPI.Analytics.codeReview.rawValue: ["start": "2026-08-01", "through": "2026-08-30"],
          "unknown": ["start": "2026-08-01", "through": "2026-08-29"],
        ],
      ],
      "empty": ["lastAccess": encodedDate, "coverage": [:]],
    ],
  ]
  defaults.set(try JSONSerialization.data(withJSONObject: document), forKey: CodexAnalyticsWatermarkStore.storageKey)
  let store = CodexAnalyticsWatermarkStore(persistence: persistence(defaults))
  #expect(
    store.load(account: account, now: fixedNow, retentionDays: 7)
      == [.tokenUsage: CodexAnalyticsCoverage(start: "2026-08-23", through: "2026-08-29")])
  #expect(store.load(account: "empty", now: fixedNow, retentionDays: 7).isEmpty)

  var unknownVersion = document
  unknownVersion["version"] = 99
  defaults.set(
    try JSONSerialization.data(withJSONObject: unknownVersion), forKey: CodexAnalyticsWatermarkStore.storageKey)
  #expect(store.load(account: account, now: fixedNow, retentionDays: 7).isEmpty)
}

@Test func codexAnalyticsWatermarkEvictionIsDeterministicWhenRecencyMatches() {
  let store = CodexAnalyticsWatermarkStore(persistence: persistence(watermarkDefaults()))
  let coverage = [CodexAPI.Analytics.tokenUsage: CodexAnalyticsCoverage(start: "2026-08-01", through: "2026-08-29")]
  for account in ["a", "b", "c", "d", "e"] {
    store.update(account: account, coverage: coverage, now: fixedNow, retentionDays: 30)
  }
  #expect(store.load(account: "a", now: fixedNow, retentionDays: 30).isEmpty)
  #expect(store.load(account: "e", now: fixedNow, retentionDays: 30) == coverage)
}

@Test func codexAnalyticsBoundsServerRowsAndCreditEventsToRetention() async {
  let transport = StubTransport()
  transport.on(
    path: "/wham/usage",
    .text(
      #"{"rate_limit_reset_credits":{"available_count":1,"total_earned_count":1,"#
        + #""immediate_reset_purchase_eligible":true}}"#
    ))
  transport.on(
    path: "daily-token-usage-breakdown",
    .text(
      #"{"data":[{"date":"2026-07-01","product_surface_usage_values":{"cli":1}},"#
        + #"{"date":"2026-08-29","product_surface_usage_values":{"cli":2}},"#
        + #"{"date":"2026-08-30","product_surface_usage_values":{"cli":3}}]}"#
    ))
  for path in [
    "daily-workspace-usage-counts", "daily-skill-usage-metrics", "daily-plugin-usage-metrics",
    "daily-code-review-metrics",
  ] {
    transport.on(path: path, .text(#"{"data":[]}"#))
  }
  transport.on(
    path: "credit-usage-events",
    .text(
      #"{"data":[{"id":"old","date":"2026-07-01","credits_used":1},"#
        + #"{"id":"current","date":"2026-08-29","credits_used":2},"#
        + #"{"id":"future","date":"2026-08-30","credits_used":3}]}"#
    ))
  let result = await codexProvider(MemoryCodexStore(validCodex), transport: transport).fetch(
    now: fixedNow, options: FetchOptions(includeAnalytics: true, analyticsDays: 7))
  #expect(result.analytics?.points.map(\.value) == [2])
  #expect(result.analytics?.creditEvents.map(\.id) == ["current"])
}

@Test func codexAccountFingerprintUsesStableNonSecretIdentity() {
  let accountA = CodexAuth(accessToken: "first", accountID: "account")
  let accountB = CodexAuth(accessToken: "second", accountID: "account")
  #expect(accountA.accountFingerprint == accountB.accountFingerprint)

  let emailA = CodexAuth(accessToken: "first", idToken: makeJWT(.object(["email": .string("USER@example.com")])))
  let emailB = CodexAuth(accessToken: "second", idToken: makeJWT(.object(["email": .string("user@example.com")])))
  #expect(emailA.accountFingerprint == emailB.accountFingerprint)
  #expect(CodexAuth(accessToken: "first").accountFingerprint != CodexAuth(accessToken: "second").accountFingerprint)
  #expect(!accountA.accountFingerprint.contains("account"))
  #expect(accountA.accountFingerprint.count == 64)
}

@Test func providerAnalyticsMergePrunesEveryMetricAndCreditEvent() {
  let cutoff = DayStamp.string(fixedNow.addingTimeInterval(-6 * 86400))
  let old = DayStamp.string(fixedNow.addingTimeInterval(-7 * 86400))
  let today = DayStamp.string(fixedNow)
  let future = DayStamp.string(fixedNow.addingTimeInterval(86400))
  let previous = ProviderAnalytics(
    provider: .codex,
    points: AnalyticsMetric.allCases.flatMap { metric in
      [
        AnalyticsPoint(day: old, metric: metric, series: "series", value: 1),
        AnalyticsPoint(day: cutoff, metric: metric, series: "series", value: 2),
      ]
    },
    creditEvents: [
      CreditEvent(id: "old", date: fixedNow.addingTimeInterval(-7 * 86400), service: "Codex", creditsUsed: 1),
      CreditEvent(id: "cutoff", date: DayStamp.date(cutoff)!, service: "Codex", creditsUsed: 2),
    ],
    fetchedAt: fixedNow.addingTimeInterval(-60),
    accountFingerprint: "account")
  let current = ProviderAnalytics(
    provider: .codex,
    points: AnalyticsMetric.allCases.flatMap { metric in
      [
        AnalyticsPoint(day: cutoff, metric: metric, series: "series", value: 3),
        AnalyticsPoint(day: today, metric: metric, series: "series", value: 4),
        AnalyticsPoint(day: future, metric: metric, series: "series", value: 5),
      ]
    },
    creditEvents: [
      CreditEvent(id: "cutoff", date: DayStamp.date(cutoff)!, service: "Codex", creditsUsed: 3),
      CreditEvent(id: "today", date: fixedNow, service: "Codex", creditsUsed: 4),
      CreditEvent(id: "future", date: fixedNow.addingTimeInterval(86400), service: "Codex", creditsUsed: 5),
    ],
    fetchedAt: fixedNow,
    accountFingerprint: "account")
  let merged = previous.merging(current, retentionDays: 7)
  for metric in AnalyticsMetric.allCases {
    #expect(merged.points.filter { $0.metric == metric }.map(\.value) == [3, 4])
  }
  #expect(merged.creditEvents.map(\.id) == ["cutoff", "today"])
  #expect(merged.creditEvents.map(\.creditsUsed) == [3, 4])
}

@Test func providerAnalyticsMergeDoesNotCrossAccountsOrProviders() {
  let previous = ProviderAnalytics(
    provider: .codex,
    points: [AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .turns, series: "old", value: 1)],
    fetchedAt: fixedNow,
    accountFingerprint: "old")
  let accountChanged = ProviderAnalytics(
    provider: .codex,
    points: [AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .turns, series: "new", value: 2)],
    fetchedAt: fixedNow,
    accountFingerprint: "new")
  #expect(previous.merging(accountChanged, retentionDays: 0).points.map(\.series) == ["new"])

  let providerChanged = ProviderAnalytics(
    provider: .claude,
    points: [AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .turns, series: "claude", value: 3)],
    fetchedAt: fixedNow,
    accountFingerprint: "old")
  #expect(previous.merging(providerChanged, retentionDays: 7).points.map(\.series) == ["claude"])
}

private func watermarkDefaults() -> UserDefaults {
  UserDefaults(suiteName: "codex-retention-\(UUID().uuidString)")!
}

private func persistence(_ defaults: UserDefaults) -> CodexAnalyticsWatermarkPersistence {
  CodexAnalyticsWatermarkPersistence(defaults: defaults)
}

private func analyticsTransport(inlineResetCredits: Bool = true) -> StubTransport {
  let transport = StubTransport()
  transport.on(
    path: "/wham/usage",
    .text(
      inlineResetCredits
        ? #"{"plan_type":"pro","rate_limit_reset_credits":{"available_count":1,"total_earned_count":1,"#
          + #""immediate_reset_purchase_eligible":true}}"#
        : #"{"plan_type":"pro"}"#))
  if !inlineResetCredits {
    transport.on(path: "rate-limit-reset-credits", .json("codex_reset_credits"))
  }
  stubCodexAnalytics(transport)
  return transport
}

private func startDates(_ transport: StubTransport) -> [String] {
  Array(
    Set(
      transport.requests(matching: "daily-token-usage-breakdown").compactMap(\.url?.query).map(
        analyticsStartDate))
  )
  .sorted()
}

private func allAnalyticsStartDates(_ transport: StubTransport) -> [String] {
  CodexAPI.Analytics.allCases.flatMap { endpoint in
    transport.requests(matching: endpoint.rawValue).compactMap(\.url?.query).map(analyticsStartDate)
  }.sorted()
}

private func analyticsStartDate(_ query: String) -> String {
  URLComponents(string: "https://example.test?\(query)")?.queryItems?.first { $0.name == "start_date" }?.value ?? ""
}

private final class FailingSecondUsageTransport: HTTPTransport, @unchecked Sendable {
  private let base: StubTransport
  private let lock = NSLock()
  private var usageRequests = 0

  init(base: StubTransport) {
    self.base = base
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    if request.url?.path.hasSuffix("/wham/usage") == true {
      let requestNumber = lock.withLock {
        usageRequests += 1
        return usageRequests
      }
      if requestNumber == 2 { throw URLError(.notConnectedToInternet) }
    }
    return try await base.data(for: request)
  }
}
