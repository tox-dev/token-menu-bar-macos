import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func claudeUsageDecodesLimitsAndWindows() {
  let response = Fixtures.decode(ClaudeAPI.UsageResponse.self, "claude_usage")
  #expect(response.limits.map(\.kind) == ["session", "weekly_scoped"])
  #expect(Set(response.windows.keys) == ["five_hour", "nimbus_quill"])
  #expect(response.spend?.canToggle == false)
  #expect(response.extraUsage?.disabledReason == "org_level_disabled_until")
}

@Test func claudeDynamicKeysIgnoreIntegers() {
  #expect(ClaudeAPI.UsageResponse.DynamicKey(intValue: 1) == nil)
  #expect(ClaudeAPI.UsageResponse.DynamicKey(stringValue: "x").intValue == nil)
}

@Test func claudeWindowsPreferLimitsArray() {
  let windows = ClaudeMapper.windows(Fixtures.decode(ClaudeAPI.UsageResponse.self, "claude_usage"))
  #expect(windows.map(\.id) == ["session", "weekly:fable"])
  #expect(windows[0].usedPercent == 36)
  #expect(windows[0].isActive == false)
  #expect(windows[0].duration == 18000)
  #expect(windows[1].label == "Fable")
  #expect(windows[1].scope == "Fable")
  #expect(windows[1].resetsAt == ISODate.parse("2026-09-01T14:59:59.522121+00:00"))
}

@Test func claudeWindowsFallBackToFlatKeys() {
  let response = ClaudeAPI.UsageResponse(
    limits: [],
    windows: [
      "five_hour": .init(utilization: 12, resetsAt: "2026-08-29T18:00:00Z"),
      "seven_day_opus": .init(utilization: 40, resetsAt: nil),
      "seven_day_mystery": .init(utilization: 5, resetsAt: nil),
      "tangelo": .init(utilization: 1, resetsAt: nil),
    ],
    spend: nil,
    extraUsage: nil
  )
  let windows = ClaudeMapper.windows(response).sorted { $0.id < $1.id }
  #expect(windows.map(\.id) == ["session", "seven_day_mystery", "tangelo", "weekly:opus"])
  #expect(windows.first { $0.id == "seven_day_mystery" }?.label == "Seven Day Mystery")
  #expect(windows.first { $0.id == "seven_day_mystery" }?.group == .weekly)
  #expect(windows.first { $0.id == "tangelo" }?.group == .other)
  #expect(windows.first { $0.id == "weekly:opus" }?.duration == 604_800)
}

private let limitCases: [(String, String?, String?, String, String)] = [
  ("session", nil, nil, "session", "Current session"),
  ("weekly_all", nil, nil, "weekly", "All models"),
  ("weekly_scoped", "Opus 4", nil, "weekly:opus-4", "Opus 4"),
  ("weekly_scoped", nil, "cowork", "weekly:cowork", "cowork"),
  ("daily_scoped", "Sonnet", nil, "daily_scoped:sonnet", "Daily Scoped Sonnet"),
  ("monthly", nil, nil, "monthly", "Monthly"),
]

@Test(arguments: limitCases)
func claudeLimitKindsMapToWindowIDs(kind: String, model: String?, surface: String?, id: String, label: String) {
  let limit = ClaudeAPI.Limit(
    kind: kind, group: kind == "monthly" ? "monthly" : nil, percent: 10, severity: "warning", resetsAt: nil,
    scope: model == nil && surface == nil
      ? nil : .init(model: model.map { .init(id: nil, displayName: $0) }, surface: surface),
    isActive: nil
  )
  let window = ClaudeMapper.window(limit)
  #expect(window.id == id)
  #expect(window.label == label)
  #expect(window.severity == .warning)
  #expect(window.isActive)
  if kind == "monthly" { #expect(window.group == .monthly) }
}

@Test func claudeSpendUsesSpendBlockAndMonthReset() {
  let response = Fixtures.decode(ClaudeAPI.UsageResponse.self, "claude_usage")
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  let spend = ClaudeMapper.spend(response, now: fixedNow, calendar: calendar)!
  #expect(spend.enabled == false)
  #expect(spend.used?.amountMinor == 0)
  #expect(spend.limit?.currency == "USD")
  #expect(spend.disabledReason == "org_level_disabled_until")
  #expect(spend.autoReload == nil)
  #expect(spend.resetsAt == DayStamp.date("2026-09-01"))
}

@Test func claudeSpendDerivesFromExtraUsageWhenSpendMissing() {
  let response = ClaudeAPI.UsageResponse(
    limits: [], windows: [:], spend: nil,
    extraUsage: .init(
      isEnabled: true, monthlyLimit: 80, usedCredits: 24.45, utilization: nil, currency: "EUR", decimalPlaces: 2,
      disabledReason: nil, spendLimitReached: true)
  )
  let spend = ClaudeMapper.spend(response, now: fixedNow)!
  #expect(spend.enabled)
  #expect(spend.used == Money(amountMinor: 2445, currency: "EUR"))
  #expect(spend.limit == Money(amountMinor: 8000, currency: "EUR"))
  #expect(spend.percent.map { Int($0.rounded()) } == 31)
  #expect(spend.limitReached)
  #expect(spend.disabledReason == nil)
  #expect(spend.autoReload == nil)
}

@Test func claudeSpendIsNilWithoutSpendData() {
  #expect(
    ClaudeMapper.spend(ClaudeAPI.UsageResponse(limits: [], windows: [:], spend: nil, extraUsage: nil), now: fixedNow)
      == nil)
}

@Test func claudeSpendPercentIsZeroWhenLimitIsZero() {
  let response = ClaudeAPI.UsageResponse(
    limits: [], windows: [:], spend: nil,
    extraUsage: .init(
      isEnabled: false, monthlyLimit: 0, usedCredits: 0, utilization: nil, currency: nil, decimalPlaces: nil,
      disabledReason: "x", spendLimitReached: nil)
  )
  let spend = ClaudeMapper.spend(response, now: fixedNow)!
  #expect(spend.percent == 0)
  #expect(spend.used?.currency == "USD")
  #expect(spend.disabledReason == "x")
}

@Test func claudeIdentityFromProfile() {
  let profile = Fixtures.decode(ClaudeAPI.ProfileResponse.self, "claude_profile")
  let identity = ClaudeMapper.identity(profile: profile, credentials: nil, local: nil)
  #expect(identity.planName == "Max 20x")
  #expect(identity.tier == "default_claude_max_20x")
  #expect(identity.email == "user@example.com")
  #expect(identity.organization == "user@example.com's Organization")
}

private let planNameCases: [(String, String?, String)] = [
  ("claude_pro", "default_claude_pro", "Pro"),
  ("claude_team", nil, "Team"),
  ("claude_enterprise", nil, "Enterprise"),
  ("claude_free", nil, "Free"),
  ("claude_max", "default_claude_max_5x", "Max 5x"),
]

@Test(arguments: planNameCases)
func claudeIdentityPlanNames(type: String, tier: String?, expected: String) {
  let profile = ClaudeAPI.ProfileResponse(
    account: nil,
    organization: .init(
      name: nil, organizationType: type, rateLimitTier: tier, hasExtraUsageEnabled: nil, subscriptionStatus: nil)
  )
  #expect(ClaudeMapper.identity(profile: profile, credentials: nil, local: nil).planName == expected)
}

@Test func claudeIdentityFallsBackToCredentialsAndLocalAccount() {
  let credentials = ClaudeOAuthCredentials(
    accessToken: "t", refreshToken: nil, expiresAt: nil, subscriptionType: "max",
    rateLimitTier: "default_claude_max_20x")
  let local = ClaudeLocalAccount(
    email: "local@example.com", organizationName: "Local Org", rateLimitTier: "default_claude_max_5x",
    hasExtraUsageEnabled: true)
  let identity = ClaudeMapper.identity(profile: nil, credentials: credentials, local: local)
  #expect(identity.planName == "Max 20x")
  #expect(identity.email == "local@example.com")
  #expect(identity.organization == "Local Org")
  #expect(ClaudeMapper.identity(profile: nil, credentials: nil, local: local).planName == "Claude 5x")
}

@Test func claudeIdentityUsesAccountFlagsWithoutOrganizationType() {
  let max = ClaudeAPI.ProfileResponse(
    account: .init(email: nil, displayName: nil, hasClaudeMax: true, hasClaudePro: false), organization: nil)
  let pro = ClaudeAPI.ProfileResponse(
    account: .init(email: nil, displayName: nil, hasClaudeMax: false, hasClaudePro: true), organization: nil)
  #expect(ClaudeMapper.identity(profile: max, credentials: nil, local: nil).planName == "Max")
  #expect(ClaudeMapper.identity(profile: pro, credentials: nil, local: nil).planName == "Pro")
  #expect(ClaudeMapper.identity(profile: nil, credentials: nil, local: nil).planName == "Claude")
}

@Test func claudeNoticesReportSpendLimitAndCriticalWindows() {
  let response = ClaudeAPI.UsageResponse(
    limits: [
      .init(
        kind: "session", group: nil, percent: 100, severity: "critical", resetsAt: "2026-08-29T18:00:00Z", scope: nil,
        isActive: true)
    ],
    windows: [:], spend: nil,
    extraUsage: .init(
      isEnabled: true, monthlyLimit: 1, usedCredits: 1, utilization: 100, currency: "USD", decimalPlaces: 2,
      disabledReason: nil, spendLimitReached: true)
  )
  let notices = ClaudeMapper.notices(response)
  #expect(notices.map(\.kind) == [.spendControl, .limitReached])
  #expect(notices[1].text.contains("Current session"))
  #expect(ClaudeMapper.notices(Fixtures.decode(ClaudeAPI.UsageResponse.self, "claude_usage")).isEmpty)
}
