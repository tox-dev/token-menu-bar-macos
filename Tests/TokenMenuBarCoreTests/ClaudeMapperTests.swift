import Foundation
import Testing
import TokenMenuBarCore

@MainActor
private func claudeSnapshot(
  usage: StubTransport.Response, profile: StubTransport.Response = .json("claude_profile"),
  credentials: ClaudeOAuthCredentials = validClaude
) async -> ProviderSnapshot? {
  let transport = StubTransport()
  transport.on(path: "/api/oauth/usage", usage)
  transport.on(path: "/api/oauth/profile", profile)
  let provider = claudeProvider(MemoryClaudeStore(credentials), transport: transport)
  guard case .success(let snapshot) = await provider.fetch(now: fixedNow, options: FetchOptions()).outcome else {
    Issue.record("expected a snapshot")
    return nil
  }
  return snapshot
}

/// A credential that names no plan, so the profile decides the identity rather than the Keychain entry
private let plainClaude = ClaudeOAuthCredentials(
  accessToken: "tok", refreshToken: nil, expiresAt: fixedNow.addingTimeInterval(86400))

/// The usage response carries a vendor-chosen key per window, so the decoder reads string keys and refuses integers.
@Test func claudeWindowKeysAreStringsOnly() async throws {
  let usage = #"{"12": {"utilization": 5}, "five_hour": {"utilization": 12}}"#
  let snapshot = try #require(await claudeSnapshot(usage: .text(usage)))
  #expect(snapshot.windows.map(\.id).sorted() == ["12", "session"])
}

@Test func claudeReportsTheLimitsArrayAsWindows() async throws {
  let snapshot = try #require(await claudeSnapshot(usage: .json("claude_usage")))
  #expect(snapshot.windows.map(\.id) == ["session", "weekly:fable"])
  #expect(snapshot.windows[0].usedPercent == 36)
  #expect(snapshot.windows[0].isActive == false)
  #expect(snapshot.windows[0].duration == 18000)
  #expect(snapshot.windows[1].label == "Fable")
  #expect(snapshot.windows[1].scope == "Fable")
  #expect(snapshot.windows[1].resetsAt == ISODate.parse("2026-09-01T14:59:59.522121+00:00"))
}

@Test func claudeFallsBackToTheFlatWindowKeys() async throws {
  let usage = #"""
    {"five_hour": {"utilization": 12, "resets_at": "2026-08-29T18:00:00Z"},
     "seven_day_opus": {"utilization": 40}, "seven_day_mystery": {"utilization": 5}, "tangelo": {"utilization": 1}}
    """#
  let windows = try #require(await claudeSnapshot(usage: .text(usage))).windows
  #expect(windows.map(\.id).sorted() == ["session", "seven_day_mystery", "tangelo", "weekly:opus"])
  #expect(windows.first { $0.id == "seven_day_mystery" }?.label == "Seven Day Mystery")
  #expect(windows.first { $0.id == "seven_day_mystery" }?.group == .weekly)
  #expect(windows.first { $0.id == "tangelo" }?.group == .other)
  #expect(windows.first { $0.id == "weekly:opus" }?.duration == 604_800)
}

@Test(
  arguments: [
    (#"{"kind": "session", "percent": 10, "severity": "warning"}"#, "session", "Current session"),
    (#"{"kind": "weekly_all", "percent": 10, "severity": "warning"}"#, "weekly", "All models"),
    (
      #"""
      {"kind": "weekly_scoped", "percent": 10, "severity": "warning",
       "scope": {"model": {"display_name": "Opus 4"}}}
      """#,
      "weekly:opus-4", "Opus 4"
    ),
    (
      #"{"kind": "weekly_scoped", "percent": 10, "severity": "warning", "scope": {"surface": "cowork"}}"#,
      "weekly:cowork", "cowork"
    ),
    (
      #"""
      {"kind": "daily_scoped", "percent": 10, "severity": "warning",
       "scope": {"model": {"display_name": "Sonnet"}}}
      """#,
      "daily_scoped:sonnet", "Daily Scoped Sonnet"
    ),
    (#"{"kind": "monthly", "group": "monthly", "percent": 10, "severity": "warning"}"#, "monthly", "Monthly"),
  ])
func claudeNamesAWindowAfterItsLimitKind(limit: String, id: String, label: String) async throws {
  let snapshot = try #require(await claudeSnapshot(usage: .text(#"{"limits": [\#(limit)]}"#)))
  #expect(snapshot.windows.map(\.id) == [id])
  #expect(snapshot.windows[0].label == label)
  #expect(snapshot.windows[0].severity == .warning)
  #expect(snapshot.windows[0].isActive)
}

@Test func claudeReportsTheSpendBlockAndItsMonthlyReset() async throws {
  let snapshot = try #require(await claudeSnapshot(usage: .json("claude_usage")))
  #expect(snapshot.spend?.enabled == false)
  #expect(snapshot.spend?.used?.amountMinor == 0)
  #expect(snapshot.spend?.limit?.currency == "USD")
  #expect(snapshot.spend?.disabledReason == "org_level_disabled_until")
  #expect(snapshot.spend?.autoReload == nil)
  #expect(
    snapshot.spend?.resetsAt == Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 1)))
}

@Test func claudeDerivesSpendFromExtraUsageWhenTheBlockIsMissing() async throws {
  let usage = #"""
    {"extra_usage": {"is_enabled": true, "monthly_limit": 80, "used_credits": 24.45, "currency": "EUR",
     "decimal_places": 2, "spend_limit_reached": true}}
    """#
  let snapshot = try #require(await claudeSnapshot(usage: .text(usage)))
  let spend = try #require(snapshot.spend)
  #expect(spend.enabled)
  #expect(spend.used == Money(amountMinor: 2445, currency: "EUR"))
  #expect(spend.limit == Money(amountMinor: 8000, currency: "EUR"))
  #expect(spend.percent.map { Int($0.rounded()) } == 31)
  #expect(spend.limitReached)
  #expect(spend.disabledReason == nil)
}

@Test func claudeReportsNoSpendWithoutSpendData() async throws {
  let snapshot = try #require(await claudeSnapshot(usage: .text("{}")))
  #expect(snapshot.spend == nil)
}

@Test func claudeReportsZeroPercentAgainstAZeroLimit() async throws {
  let usage = #"""
    {"extra_usage": {"is_enabled": false, "monthly_limit": 0, "used_credits": 0, "disabled_reason": "x"}}
    """#
  let snapshot = try #require(await claudeSnapshot(usage: .text(usage)))
  let spend = try #require(snapshot.spend)
  #expect(spend.percent == 0)
  #expect(spend.used?.currency == "USD")
  #expect(spend.disabledReason == "x")
}

@Test func claudeReadsIdentityFromTheProfile() async throws {
  let snapshot = try #require(await claudeSnapshot(usage: .json("claude_usage")))
  let identity = try #require(snapshot.identity)
  #expect(identity.planName == "Max 20x")
  #expect(identity.tier == "default_claude_max_20x")
  #expect(identity.email == "user@example.com")
  #expect(identity.organization == "user@example.com's Organization")
}

@Test(
  arguments: [
    (#"{"organization_type": "claude_pro", "rate_limit_tier": "default_claude_pro"}"#, "Pro"),
    (#"{"organization_type": "claude_team"}"#, "Team"),
    (#"{"organization_type": "claude_enterprise"}"#, "Enterprise"),
    (#"{"organization_type": "claude_free"}"#, "Free"),
    (#"{"organization_type": "claude_max", "rate_limit_tier": "default_claude_max_5x"}"#, "Max 5x"),
  ])
func claudeNamesThePlanFromTheOrganization(organization: String, expected: String) async throws {
  let profile = #"{"organization": \#(organization)}"#
  let snapshot = try #require(
    await claudeSnapshot(usage: .json("claude_usage"), profile: .text(profile), credentials: plainClaude))
  #expect(snapshot.identity?.planName == expected)
}

@Test(
  arguments: [
    (#"{"account": {"has_claude_max": true, "has_claude_pro": false}}"#, "Max"),
    (#"{"account": {"has_claude_max": false, "has_claude_pro": true}}"#, "Pro"),
  ])
func claudeNamesThePlanFromTheAccountFlags(profile: String, expected: String) async throws {
  let snapshot = try #require(
    await claudeSnapshot(usage: .json("claude_usage"), profile: .text(profile), credentials: plainClaude))
  #expect(snapshot.identity?.planName == expected)
}

@Test func claudeNoticesReportSpendLimitAndExhaustedWindows() async throws {
  let usage = #"""
    {"limits": [{"kind": "session", "percent": 100, "severity": "critical",
     "resets_at": "2026-08-29T18:00:00Z", "is_active": true}],
     "extra_usage": {"is_enabled": true, "monthly_limit": 1, "used_credits": 1, "utilization": 100,
     "currency": "USD", "decimal_places": 2, "spend_limit_reached": true}}
    """#
  let notices = try #require(await claudeSnapshot(usage: .text(usage))).notices
  #expect(notices.map(\.kind) == [.spendControl, .limitReached])
  #expect(notices[1].text.contains("Current session"))
  let clean = try #require(await claudeSnapshot(usage: .json("claude_usage")))
  #expect(clean.notices.isEmpty)
}
