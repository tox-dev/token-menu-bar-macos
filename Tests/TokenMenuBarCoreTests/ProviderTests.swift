import Foundation
import Testing

@testable import TokenMenuBarCore

final class MemoryClaudeStore: ClaudeCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: ClaudeOAuthCredentials?
  var loadError: (any Error)?
  var saveError: (any Error)?
  private(set) var saved: [ClaudeOAuthCredentials] = []

  init(_ credentials: ClaudeOAuthCredentials?) {
    stored = credentials
  }

  var description: String { "memory" }

  func load() throws -> ClaudeOAuthCredentials? {
    if let loadError { throw loadError }
    return lock.withLock { stored }
  }

  func save(_ credentials: ClaudeOAuthCredentials) throws {
    if let saveError { throw saveError }
    lock.withLock {
      stored = credentials
      saved.append(credentials)
    }
  }
}

final class MemoryCodexStore: CodexAuthStore, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: CodexAuth?
  var loadError: (any Error)?
  var saveError: (any Error)?
  private(set) var saved: [CodexAuth] = []

  init(_ auth: CodexAuth?) {
    stored = auth
  }

  var description: String { "memory" }

  func load() throws -> CodexAuth? {
    if let loadError { throw loadError }
    return lock.withLock { stored }
  }

  func save(_ auth: CodexAuth) throws {
    if let saveError { throw saveError }
    lock.withLock {
      stored = auth
      saved.append(auth)
    }
  }
}

private let validClaude = ClaudeOAuthCredentials(
  accessToken: "tok", refreshToken: "ref", expiresAt: fixedNow.addingTimeInterval(86400), subscriptionType: "max",
  rateLimitTier: "default_claude_max_20x")
private let expiredClaude = ClaudeOAuthCredentials(
  accessToken: "old", refreshToken: "ref", expiresAt: fixedNow.addingTimeInterval(-10))

private func claudeProvider(
  _ store: any ClaudeCredentialStore, transport: StubTransport, allowRefresh: Bool = false, localAccount: URL? = nil,
  transcripts: URL? = nil
) -> ClaudeProvider {
  ClaudeProvider(
    credentials: store, localAccountURL: localAccount,
    transcripts: transcripts.map { ClaudeTranscriptReader(root: $0) },
    client: APIClient(transport: transport, log: makeLog(), clock: testClock), log: makeLog(),
    allowRefresh: { allowRefresh })
}

@Test func claudeProviderFetchesUsageAndProfile() async {
  let transport = StubTransport()
  transport.on(path: "/api/oauth/usage", .json("claude_usage"))
  transport.on(path: "/api/oauth/profile", .json("claude_profile"))
  let provider = claudeProvider(MemoryClaudeStore(validClaude), transport: transport)
  #expect(provider.id == .claude)
  #expect(provider.credentialDescription == "memory")
  #expect(provider.credentialState(now: fixedNow) == .valid(expiresAt: validClaude.expiresAt))
  let result = await provider.fetch(now: fixedNow, options: FetchOptions())
  guard case .success(let snapshot) = result.outcome else {
    Issue.record("expected success, got \(result.outcome)")
    return
  }
  #expect(snapshot.identity?.planName == "Max 20x")
  #expect(snapshot.identity?.email == "user@example.com")
  #expect(snapshot.windows.map(\.id) == ["session", "weekly:fable"])
  #expect(snapshot.spend?.enabled == false)
  #expect(result.warnings.isEmpty)
  #expect(result.analytics == nil)
  let usageRequest = transport.requests(matching: "/api/oauth/usage")[0]
  #expect(usageRequest.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
  #expect(usageRequest.value(forHTTPHeaderField: "anthropic-beta") == ClaudeAPI.betaHeader)
  #expect(usageRequest.value(forHTTPHeaderField: "User-Agent") == ClaudeAPI.userAgent)
  _ = await provider.fetch(now: fixedNow.addingTimeInterval(60), options: FetchOptions())
  #expect(transport.requests(matching: "/api/oauth/profile").count == 1)
  _ = await provider.fetch(now: fixedNow.addingTimeInterval(7 * 3600), options: FetchOptions())
  #expect(transport.requests(matching: "/api/oauth/profile").count == 2)
}

@Test func claudeProviderReportsMissingAndUnreadableCredentials() async {
  let transport = StubTransport()
  let missing = await claudeProvider(MemoryClaudeStore(nil), transport: transport).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(missing.outcome == .notAuthenticated("No Claude Code credentials. \(ProviderID.claude.loginHint)"))
  let store = MemoryClaudeStore(nil)
  store.loadError = CredentialStoreError.keychain(-25300)
  let provider = claudeProvider(store, transport: transport)
  let unreadable = await provider.fetch(now: fixedNow, options: FetchOptions())
  #expect(unreadable.outcome == .notAuthenticated("Cannot read Claude credentials: keychain(-25300)"))
  #expect(provider.credentialState(now: fixedNow) == .missing("keychain(-25300)"))
  #expect(
    claudeProvider(MemoryClaudeStore(nil), transport: transport).credentialState(now: fixedNow)
      == .missing("no Claude Code sign-in found"))
}

@Test func claudeProviderExpiredTokenWithoutRefresh() async {
  let result = await claudeProvider(MemoryClaudeStore(expiredClaude), transport: StubTransport()).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(result.outcome == .notAuthenticated("Claude token expired. \(ProviderID.claude.loginHint)"))
}

@Test func claudeProviderRefreshesAndStoresToken() async {
  let transport = StubTransport()
  transport.on(path: "/v1/oauth/token", .text(#"{"access_token":"fresh","refresh_token":"fresh-r","expires_in":7200}"#))
  transport.on(path: "/api/oauth/usage", .json("claude_usage"))
  transport.on(path: "/api/oauth/profile", .text("{}", status: 500))
  let store = MemoryClaudeStore(expiredClaude)
  let result = await claudeProvider(store, transport: transport, allowRefresh: true).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(result.outcome.snapshot != nil)
  #expect(result.warnings == ["Profile unavailable: HTTP 500: {}"])
  #expect(store.saved.first?.accessToken == "fresh")
  #expect(store.saved.first?.refreshToken == "fresh-r")
  #expect(
    transport.requests(matching: "/api/oauth/usage")[0].value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
  let body = try! JSONDecoder().decode(
    [String: String].self, from: transport.requests(matching: "/v1/oauth/token")[0].httpBody!)
  #expect(body == ["grant_type": "refresh_token", "refresh_token": "ref", "client_id": ClaudeAPI.clientID])
}

@Test func claudeProviderRefreshFailuresAndUnsavableTokens() async {
  let transport = StubTransport()
  transport.on(path: "/v1/oauth/token", .text(#"{"error":"invalid_grant"}"#, status: 400))
  let failed = await claudeProvider(MemoryClaudeStore(expiredClaude), transport: transport, allowRefresh: true).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(failed.outcome == .notAuthenticated(#"Claude token refresh failed: HTTP 400: {"error":"invalid_grant"}"#))
  let noRefresh = ClaudeOAuthCredentials(
    accessToken: "old", refreshToken: nil, expiresAt: fixedNow.addingTimeInterval(-10))
  let noToken = await claudeProvider(MemoryClaudeStore(noRefresh), transport: transport, allowRefresh: true).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(noToken.outcome == .notAuthenticated("Claude token refresh failed: HTTP 401: no refresh token"))
  let saving = StubTransport()
  saving.on(path: "/v1/oauth/token", .text(#"{"access_token":"fresh"}"#))
  saving.on(path: "/api/oauth/usage", .json("claude_usage"))
  saving.on(path: "/api/oauth/profile", .json("claude_profile"))
  let store = MemoryClaudeStore(expiredClaude)
  store.saveError = CredentialStoreError.keychain(-1)
  let unsaved = await claudeProvider(store, transport: saving, allowRefresh: true).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(unsaved.outcome.snapshot != nil)
  #expect(store.saved.isEmpty)
  let malformed = StubTransport()
  malformed.on(path: "/v1/oauth/token", .text("nope"))
  let decoding = await claudeProvider(MemoryClaudeStore(expiredClaude), transport: malformed, allowRefresh: true).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(decoding.outcome.errorDescription?.hasPrefix("Claude token refresh failed: Unexpected response") == true)
}

@Test func claudeProviderMapsUsageErrors() async {
  let transport = StubTransport()
  transport.on(path: "/api/oauth/usage", .text("busy", status: 429, headers: ["Retry-After": "90"]))
  transport.on(path: "/api/oauth/profile", .json("claude_profile"))
  let limited = await claudeProvider(MemoryClaudeStore(validClaude), transport: transport).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(limited.outcome == .rateLimited("HTTP 429: busy", retryAfter: 90))
  #expect(limited.warnings.isEmpty)
  let unauthorized = StubTransport()
  unauthorized.on(path: "/api/oauth/usage", .text("", status: 403))
  unauthorized.on(path: "/api/oauth/profile", .json("claude_profile"))
  let scoped = ClaudeOAuthCredentials(accessToken: "tok", refreshToken: nil, expiresAt: nil, scopes: ["user:inference"])
  let denied = await claudeProvider(MemoryClaudeStore(scoped), transport: unauthorized).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(denied.outcome == .notAuthenticated("HTTP 403. \(ProviderID.claude.loginHint)"))
  #expect(denied.warnings.first?.contains("user:profile") == true)
  let offline = StubTransport()
  offline.on(path: "/api/oauth/usage", error: URLError(.notConnectedToInternet))
  offline.on(path: "/api/oauth/profile", error: URLError(.notConnectedToInternet))
  let down = await claudeProvider(MemoryClaudeStore(validClaude), transport: offline).fetch(
    now: fixedNow, options: FetchOptions())
  guard case .networkUnavailable = down.outcome else {
    Issue.record("expected network failure")
    return
  }
  #expect(down.warnings.count == 1)
}

@Test func claudeProviderUsesCachedProfileWhenProfileFails() async throws {
  let transport = StubTransport()
  transport.on(path: "/api/oauth/usage", .json("claude_usage"))
  transport.on(
    { $0.url?.path.hasSuffix("/profile") == true && $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok" },
    .respond(.json("claude_profile")))
  let localURL = temporaryDirectory().appendingPathComponent(".claude.json")
  try Data(#"{"oauthAccount":{"emailAddress":"local@example.com","organizationName":"Local"}}"#.utf8).write(
    to: localURL)
  let store = MemoryClaudeStore(validClaude)
  let provider = claudeProvider(store, transport: transport, localAccount: localURL)
  let first = await provider.fetch(now: fixedNow, options: FetchOptions())
  #expect(first.outcome.snapshot?.identity?.email == "user@example.com")
  try store.save(
    ClaudeOAuthCredentials(accessToken: "other", refreshToken: nil, expiresAt: nil, subscriptionType: "max"))
  let second = await provider.fetch(now: fixedNow.addingTimeInterval(7200), options: FetchOptions())
  #expect(second.outcome.snapshot?.identity?.email == "user@example.com")
  #expect(second.warnings.isEmpty)
}

private let validCodex = CodexAuth(
  accessToken: "codex-tok", refreshToken: "codex-ref",
  idToken: CodexAuth(document: Fixtures.json("codex_auth"))!.idToken, accountID: "acct")

private func codexProvider(
  _ store: any CodexAuthStore, transport: StubTransport, allowRefresh: Bool = false, rollouts: URL? = nil
) -> CodexProvider {
  CodexProvider(
    auth: store, rollouts: rollouts.map { CodexRolloutReader(sessionsRoot: $0) },
    client: APIClient(transport: transport, log: makeLog(), clock: testClock), log: makeLog(),
    allowRefresh: { allowRefresh })
}

private func stubCodexAnalytics(_ transport: StubTransport) {
  transport.on(path: "daily-token-usage-breakdown", .json("codex_daily_token_usage"))
  transport.on(path: "daily-workspace-usage-counts", .json("codex_daily_workspace_usage"))
  transport.on(path: "daily-skill-usage-metrics", .json("codex_daily_skills"))
  transport.on(path: "daily-plugin-usage-metrics", .json("codex_daily_plugins"))
  transport.on(path: "daily-code-review-metrics", .json("codex_daily_code_review"))
  transport.on(path: "credit-usage-events", .json("codex_credit_events"))
}

@Test func codexProviderFetchesUsageAndAnalytics() async {
  let transport = StubTransport()
  transport.on(path: "/wham/usage", .json("codex_usage"))
  transport.on(
    path: "rate-limit-reset-credits",
    .text(
      #"{"available_count":2,"applicable_available_count":1,"total_earned_count":3,"immediate_reset_purchase_eligible":true}"#
    ))
  stubCodexAnalytics(transport)
  let provider = codexProvider(MemoryCodexStore(validCodex), transport: transport)
  #expect(provider.id == .codex)
  #expect(provider.credentialDescription == "memory")
  #expect(provider.credentialState(now: fixedNow) == .valid(expiresAt: nil))
  let result = await provider.fetch(now: fixedNow, options: FetchOptions(includeAnalytics: true, analyticsDays: 7))
  guard case .success(let snapshot) = result.outcome else {
    Issue.record("expected success, got \(result.outcome)")
    return
  }
  #expect(snapshot.identity?.planName == "Pro")
  #expect(snapshot.window("weekly") != nil)
  #expect(
    snapshot.resetCredits == ResetCredits(available: 2, applicable: 1, totalEarned: 3, immediatePurchaseEligible: true))
  #expect(snapshot.credits?.balance == 0)
  #expect(result.warnings.isEmpty)
  #expect(result.analytics?.points.contains { $0.metric == .surfaceUsagePercent } == true)
  #expect(result.analytics?.creditEvents.isEmpty == true)
  let usage = transport.requests(matching: "/wham/usage")[0]
  #expect(usage.value(forHTTPHeaderField: "Authorization") == "Bearer codex-tok")
  #expect(usage.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct")
  #expect(usage.value(forHTTPHeaderField: "originator") == CodexAPI.originator)
  let breakdown = transport.requests(matching: "daily-token-usage-breakdown")[0].url!.query!
  #expect(breakdown.contains("start_date=2026-08-23&end_date=2026-08-29"))
}

@Test func codexProviderAnalyticsWarningsAndEmptyResult() async {
  let transport = StubTransport()
  transport.on(path: "/wham/usage", .json("codex_usage"))
  let result = await codexProvider(MemoryCodexStore(validCodex), transport: transport).fetch(
    now: fixedNow, options: FetchOptions(includeAnalytics: true))
  #expect(result.outcome.snapshot?.resetCredits == ResetCredits(available: 0, applicable: 0))
  #expect(result.analytics == nil)
  #expect(result.warnings.count == CodexAPI.Analytics.allCases.count + 1)
  #expect(result.warnings.contains { $0.hasPrefix("Credit usage history unavailable") })
  #expect(result.warnings.contains { $0.hasPrefix("Skills analytics unavailable") })
}

@Test func codexProviderFallsBackToRolloutsWhenSignedOut() async throws {
  let root = temporaryDirectory()
  let line =
    #"{"timestamp":"2026-08-29T09:00:00Z","payload":{"rate_limits":{"primary":{"used_percent":44,"window_minutes":300,"resets_at":1788040000},"secondary":null,"plan_type":"plus"}}}"#
  try (line + "\n").write(to: root.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)
  let transport = StubTransport()
  let result = await codexProvider(MemoryCodexStore(nil), transport: transport, rollouts: root).fetch(
    now: fixedNow, options: FetchOptions())
  guard case .partial(let snapshot, let reason) = result.outcome else {
    Issue.record("expected partial, got \(result.outcome)")
    return
  }
  #expect(reason == "No Codex credentials. \(ProviderID.codex.loginHint)")
  #expect(snapshot.source == .localLog)
  #expect(snapshot.identity?.planName == "Plus")
  #expect(snapshot.windows.map(\.id) == ["session"])
  #expect(snapshot.windows[0].usedPercent == 44)
  #expect(snapshot.fetchedAt == ISODate.parse("2026-08-29T09:00:00Z"))
  #expect(result.warnings == ["Showing the last values Codex CLI logged locally."])
  #expect(transport.requests.isEmpty)
  let store = MemoryCodexStore(nil)
  store.loadError = CredentialStoreError.malformed("x")
  let unreadable = await codexProvider(store, transport: transport).fetch(now: fixedNow, options: FetchOptions())
  #expect(unreadable.outcome == .notAuthenticated("Cannot read Codex credentials: malformed(\"x\")"))
  #expect(codexProvider(store, transport: transport).credentialState(now: fixedNow) == .missing("malformed(\"x\")"))
  #expect(
    codexProvider(MemoryCodexStore(nil), transport: transport).credentialState(now: fixedNow)
      == .missing("no Codex sign-in found"))
}

@Test func codexProviderNetworkFailuresUseFallbackOrReport() async throws {
  let transport = StubTransport()
  transport.on(path: "/wham/usage", error: URLError(.timedOut))
  let noRollouts = await codexProvider(MemoryCodexStore(validCodex), transport: transport).fetch(
    now: fixedNow, options: FetchOptions())
  guard case .networkUnavailable = noRollouts.outcome else {
    Issue.record("expected network failure")
    return
  }
  let root = temporaryDirectory()
  try
    (#"{"payload":{"rate_limits":{"primary":{"used_percent":9,"window_minutes":10080,"resets_at":1788540000}}}}"# + "\n")
    .write(to: root.appendingPathComponent("rollout-b.jsonl"), atomically: true, encoding: .utf8)
  let fallback = await codexProvider(MemoryCodexStore(validCodex), transport: transport, rollouts: root).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(fallback.outcome.snapshot?.windows.map(\.id) == ["weekly"])
  #expect(fallback.outcome.snapshot?.fetchedAt == fixedNow)
  #expect(fallback.outcome.snapshot?.identity?.email == "user@example.com")
  let server = StubTransport()
  server.on(path: "/wham/usage", .text("boom", status: 500))
  let failed = await codexProvider(MemoryCodexStore(validCodex), transport: server, rollouts: root).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(failed.outcome == .failed("HTTP 500: boom"))
  let unauthorized = StubTransport()
  unauthorized.on(path: "/wham/usage", .text("", status: 401))
  let denied = await codexProvider(MemoryCodexStore(validCodex), transport: unauthorized).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(denied.outcome == .notAuthenticated("HTTP 401. \(ProviderID.codex.loginHint)"))
}

@Test func codexProviderRefreshesTokens() async {
  let expired = CodexAuth(
    accessToken: makeJWT(.object(["exp": .number(fixedNow.timeIntervalSince1970 - 5)])), refreshToken: "r")
  let transport = StubTransport()
  transport.on(
    path: "/oauth/token", .text(#"{"access_token":"new-access","refresh_token":"new-refresh","id_token":"new-id"}"#))
  transport.on(path: "/wham/usage", .json("codex_usage"))
  let store = MemoryCodexStore(expired)
  let result = await codexProvider(store, transport: transport, allowRefresh: true).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(result.outcome.snapshot != nil)
  #expect(store.saved.first?.accessToken == "new-access")
  #expect(store.saved.first?.refreshToken == "new-refresh")
  #expect(store.saved.first?.idToken == "new-id")
  let body = try! JSONDecoder().decode(
    [String: String].self, from: transport.requests(matching: "/oauth/token")[0].httpBody!)
  #expect(body == ["client_id": CodexAPI.clientID, "grant_type": "refresh_token", "refresh_token": "r"])
  #expect(
    transport.requests(matching: "/wham/usage")[0].value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
}

@Test func codexProviderRefreshFailures() async {
  let expired = CodexAuth(
    accessToken: makeJWT(.object(["exp": .number(fixedNow.timeIntervalSince1970 - 5)])), refreshToken: "r")
  let noRefresh = await codexProvider(MemoryCodexStore(expired), transport: StubTransport()).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(noRefresh.outcome == .notAuthenticated("Codex token expired. \(ProviderID.codex.loginHint)"))
  let rejected = StubTransport()
  rejected.on(path: "/oauth/token", .text(#"{"error":"refresh_token_expired"}"#, status: 400))
  let failed = await codexProvider(MemoryCodexStore(expired), transport: rejected, allowRefresh: true).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(
    failed.outcome == .notAuthenticated(#"Codex token refresh failed: HTTP 400: {"error":"refresh_token_expired"}"#))
  let empty = StubTransport()
  empty.on(path: "/oauth/token", .text(#"{"error":"odd"}"#))
  let noToken = await codexProvider(MemoryCodexStore(expired), transport: empty, allowRefresh: true).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(noToken.outcome == .notAuthenticated("Codex token refresh failed: HTTP 401: odd"))
  let blank = StubTransport()
  blank.on(path: "/oauth/token", .text("{}"))
  let blankToken = await codexProvider(MemoryCodexStore(expired), transport: blank, allowRefresh: true).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(
    blankToken.outcome == .notAuthenticated("Codex token refresh failed: HTTP 401: refresh returned no access token"))
  let withoutRefreshToken = CodexAuth(accessToken: makeJWT(.object(["exp": .number(1)])))
  let missing = await codexProvider(MemoryCodexStore(withoutRefreshToken), transport: blank, allowRefresh: true).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(missing.outcome == .notAuthenticated("Codex token refresh failed: HTTP 401: no refresh token"))
  let saving = StubTransport()
  saving.on(path: "/oauth/token", .text(#"{"access_token":"n"}"#))
  saving.on(path: "/wham/usage", .json("codex_usage"))
  let store = MemoryCodexStore(expired)
  store.saveError = CredentialStoreError.malformed("ro")
  let unsaved = await codexProvider(store, transport: saving, allowRefresh: true).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(unsaved.outcome.snapshot != nil)
  #expect(store.saved.isEmpty)
}

@Test func claudeProviderReportsLocalUsageAndAnalytics() async throws {
  let root = temporaryDirectory()
  let project = root.appendingPathComponent("-Users-me-repo")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  let stamp = ISODate.string(fixedNow.addingTimeInterval(-600))
  let record =
    #"{"type":"assistant","uuid":"u1","requestId":"r1","sessionId":"s1","timestamp":"\#(stamp)","message":{"id":"m1","model":"claude-opus-5","content":[],"usage":{"input_tokens":10,"output_tokens":1000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
  try (record + "\n").write(to: project.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
  let transport = StubTransport()
  transport.on(path: "/api/oauth/usage", .json("claude_usage"))
  transport.on(path: "/api/oauth/profile", .json("claude_profile"))
  let provider = claudeProvider(MemoryClaudeStore(validClaude), transport: transport, transcripts: root)
  let plain = await provider.fetch(now: fixedNow, options: FetchOptions())
  #expect(plain.outcome.snapshot?.localUsage?.windowTokens == 1_000_010)
  #expect(plain.analytics == nil)
  let withAnalytics = await provider.fetch(now: fixedNow, options: FetchOptions(includeAnalytics: true))
  #expect(withAnalytics.analytics?.provider == .claude)
  #expect(withAnalytics.analytics?.points.contains { $0.metric == .costUSD && $0.value == 75.00015 } == true)
}
