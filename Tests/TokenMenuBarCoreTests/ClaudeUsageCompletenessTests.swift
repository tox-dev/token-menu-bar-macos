import Foundation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@Test(arguments: [
  ("false", false), ("true", true), ("null", nil),
  (#"{"enabled":false}"#, false), (#"{"enabled":true}"#, true), ("{}", nil), ("0", nil),
])
func claudePreservesExplicitAutoReloadState(value: String, expected: Bool?) async throws {
  let snapshot = try #require(await usageSnapshot(#"{"spend":{"enabled":false,"auto_reload":\#(value)}}"#))
  #expect(snapshot.spend?.autoReload == expected)
}

@Test func claudeRetainsNewModelBucketsAlongsideStructuredLimits() async throws {
  let snapshot = try #require(
    await usageSnapshot(
      #"""
      {"limits":[{"kind":"session","percent":52}],
       "five_hour":{"utilization":51},"seven_day_fable":{"utilization":4},"seven_day":{"utilization":11}}
      """#))
  #expect(
    Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.id, $0.usedPercent) }) == [
      "session": 52, "weekly": 11, "seven_day_fable": 4,
    ])
}

@Test func claudeDeduplicatesStructuredAndLegacyScopedLimits() async throws {
  let snapshot = try #require(
    await usageSnapshot(
      #"""
      {"limits":[{"kind":"weekly_scoped","percent":4,"scope":{"model":{"display_name":"Fable"}}}],
       "seven_day_fable":{"utilization":3}}
      """#))
  #expect(snapshot.windows.map(\.id) == ["weekly:fable"])
  #expect(snapshot.windows.first?.usedPercent == 4)
}

@Test(arguments: [(2, 2445, 24.45), (3, 2445, 2.445), (0, 24, 24.0)])
func claudeLegacySpendUsesMinorUnits(exponent: Int, minor: Int, expected: Double) async throws {
  let snapshot = try #require(
    await usageSnapshot(
      #"""
      {"extra_usage":{"is_enabled":true,"used_credits":\#(minor),"monthly_limit":10000,"decimal_places":\#(exponent)}}
      """#))
  #expect(snapshot.spend?.used?.amount == Decimal(string: String(expected)))
}

@Test(arguments: [
  "{}", "[]", #"{"error":{"message":"denied"}}"#, #"{"spend":123}"#, #"{"five_hour":{"utilization":false}}"#,
  #"{"limits":[],"spend":123}"#, #"{"limits":[false],"five_hour":null}"#,
  #"{"future_window":{"utilization":false}}"#,
])
func claudeRejectsUnreadableUsageInsteadOfPublishingEmptyData(json: String) async {
  #expect(await usageSnapshot(json) == nil)
}

@Test(arguments: [#"{"limits":[]}"#, #"{"five_hour":null,"extra_usage":null}"#])
func claudeAcceptsRecognizedEmptyUsage(json: String) async {
  #expect(await usageSnapshot(json)?.windows == [])
}

@Test func claudeRetainsReportedCreditReset() async throws {
  let snapshot = try #require(
    await usageSnapshot(#"{"spend":{"enabled":false,"percent":100,"resets_at":"2026-10-01T00:00:00Z"}}"#))
  #expect(snapshot.spend?.resetsAt == ISODate.parse("2026-10-01T00:00:00Z"))
}

@Test func claudeWarnsAboutMalformedFieldsWithoutDiscardingReadableQuotas() async {
  let transport = StubTransport()
  transport.on(path: "/api/oauth/usage", .text(#"{"five_hour":{"utilization":52},"spend":123}"#))
  transport.on(path: "/api/oauth/profile", .json("claude_profile"))
  let result = await claudeProvider(MemoryClaudeStore(validClaude), transport: transport)
    .fetch(now: fixedNow, options: FetchOptions())
  #expect(result.outcome.snapshot?.windows.first?.usedPercent == 52)
  #expect(result.warnings.contains { $0.contains("unreadable fields: spend") })
}

@Test func claudeDoesNotAttachUnrelatedLocalTranscriptsToADiscoveredAccount() async throws {
  let keychain = MemoryKeychain()
  let selectedService = ClaudeOAuthCredentials.keychainService(configDir: "/fixture/other")
  try keychain.client.save(try JSONEncoder().encode(validClaude.document), service: selectedService, account: "fixture")
  let transport = StubTransport()
  transport.on(path: "/api/oauth/usage", .json("claude_usage"))
  transport.on(path: "/api/oauth/profile", .json("claude_profile"))
  let provider = ClaudeProvider(
    credentials: DiscoveredClaudeKeychainStore(account: "fixture", keychain: keychain.client),
    localAccountURL: nil, transcripts: ClaudeTranscriptReader(root: temporaryDirectory()),
    client: APIClient(transport: transport, log: makeLog()), log: makeLog(), allowRefresh: { false },
    configuredLocalService: ClaudeOAuthCredentials.keychainService)
  let result = await provider.fetch(now: fixedNow, options: FetchOptions(includeAnalytics: true))
  #expect(result.analytics == nil)
  #expect(result.warnings.contains { $0.contains("selected Claude configuration") })
}

private func usageSnapshot(_ json: String) async -> ProviderSnapshot? {
  let transport = StubTransport()
  transport.on(path: "/api/oauth/usage", .text(json))
  transport.on(path: "/api/oauth/profile", .json("claude_profile"))
  return await claudeProvider(MemoryClaudeStore(validClaude), transport: transport)
    .fetch(now: fixedNow, options: FetchOptions()).outcome.snapshot
}
