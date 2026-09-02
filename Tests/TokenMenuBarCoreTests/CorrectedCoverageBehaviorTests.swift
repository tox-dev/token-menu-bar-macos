import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func correctedCoverageClaudeIgnoresNonStringScopes() throws {
  let credentials = try #require(
    ClaudeOAuthCredentials(
      document: .object([
        "claudeAiOauth": .object([
          "accessToken": .string("token"),
          "scopes": .array([.string("user:profile"), .number(1)]),
        ])
      ])))

  #expect(credentials.scopes == ["user:profile"])
}

@Test func correctedCoverageCodexRefreshesAnAPIKeyDocument() throws {
  let auth = try #require(CodexAuth(document: .object(["OPENAI_API_KEY": .string("old")])))

  let refreshed = auth.refreshed(accessToken: "new", refreshToken: nil, idToken: nil, now: fixedNow)

  #expect(refreshed.accessToken == "new")
  #expect(refreshed.apiKey == "old")
  #expect(refreshed.document["tokens"]?["access_token"] == .string("new"))
}

@Test func correctedCoverageCopilotCLIReadsAlternateAccountShapes() throws {
  let directory = temporaryDirectory()
  let url = directory.appendingPathComponent("config.json")
  try Data(
    #"{"loggedInUsers":{"a.example":{"username":"ada","oauthToken":"first"},"b.example":{"login":"bob","oauth_token":"second"},"c.example":"carol","d.example":{}}}"#
      .utf8
  ).write(to: url)
  let store = FileCopilotCLIAuthStore(url: url)

  #expect(try store.load() == CopilotAuth(token: "first", user: "ada", host: "a.example"))
  #expect(
    store.keychainAccounts() == [
      "https://a.example:ada", "https://b.example:bob", "https://c.example:carol", "d.example",
    ])

  try Data(#"{"loggedInUsers":1}"#.utf8).write(to: url)
  #expect(try store.load() == nil)
  #expect(store.keychainAccounts().isEmpty)
}

@Test func correctedCoverageCopilotKeychainReadsAlternateJSONFields() throws {
  let parsedAccessToken = try KeychainCopilotAuthStore.parse(
    Data(#"{"access_token":"access","login":"ada"}"#.utf8), account: nil)
  let accessToken = try #require(parsedAccessToken)
  #expect(accessToken == CopilotAuth(token: "access", user: "ada"))

  let parsedOAuthToken = try KeychainCopilotAuthStore.parse(
    Data(#"{"oauth_token":"oauth"}"#.utf8), account: "https://ghe.example:bob")
  let oauthToken = try #require(parsedOAuthToken)
  #expect(oauthToken == CopilotAuth(token: "oauth", user: "bob", host: "ghe.example"))
}

@Test func correctedCoverageCursorStateKeepsTheLastDuplicateValue() throws {
  let url = temporaryDirectory().appendingPathComponent("state.vscdb")
  let database = try SQLiteDatabase(path: url.path)
  try database.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)")
  try database.execute(
    "INSERT INTO ItemTable (key, value) VALUES (?, ?), (?, ?), (?, ?)",
    [
      .text("cursorAuth/accessToken"), .text("first"),
      .text("cursorAuth/accessToken"), .text("second"),
      .text("cursorAuth/cachedEmail"), .text("you@example.com"),
    ])

  let loaded = try CursorStateStore(url: url).load()
  let auth = try #require(loaded)

  #expect(auth.accessToken == "second")
  #expect(auth.email == "you@example.com")
}

@Test func correctedCoverageAPIClientEncodesAnEmptyFormAndOverridesItsContentType() async throws {
  let transport = StubTransport()
  transport.on(path: "/form", .text("ok"))
  let client = APIClient(transport: transport, log: makeLog())

  let data = try await client.post(
    URL(string: "https://example.com/form")!, form: [:], headers: ["Content-Type": "text/plain"],
    operation: "form")

  #expect(data == Data("ok".utf8))
  #expect(transport.requests[0].httpBody == Data())
  #expect(transport.requests[0].value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
}

@Test func correctedCoverageAPIClientRejectsANonHTTPResponse() async {
  let transport = StubTransport()
  let url = URL(string: "https://example.com/raw")!
  transport.on(
    path: "/raw", data: Data("body".utf8),
    response: URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 4, textEncodingName: nil))
  let client = APIClient(transport: transport, log: makeLog())

  await #expect(throws: APIError.http(status: 0, body: "body", retryAfter: nil)) {
    try await client.get(url, headers: [:], operation: "raw")
  }
}

@Test func correctedCoverageDiscoveryTreatsMissingSnapshotResourcesAsEmpty() {
  let discovery = ProviderDiscoverySnapshot(
    providerIDs: [.claude], credentials: [.claude: .unchecked], resources: [:])

  #expect(
    !discovery.differs(
      from: [.claude: ProviderState(credentialHealth: .unchecked, resourceAccess: [])], providerIDs: [.claude]))
}

@Test func correctedCoverageDiscoveryTreatsMissingProviderStateResourcesAsEmpty() {
  let discovery = ProviderDiscoverySnapshot(providerIDs: [.claude], credentials: [:], resources: [.claude: []])

  #expect(!discovery.differs(from: [:], providerIDs: [.claude]))
}

@Test func correctedCoverageCustomSetupWithoutACommandRefreshesTheProvider() {
  let metadata = ProviderSetupMetadata(
    provider: .gemini, signInTitle: "Sign in", signInDetail: "Authenticate", signInCommand: nil,
    credentialSources: [])

  #expect(metadata.missingCredentialIssue.action == .refreshProvider(.gemini))
}

@Test func correctedCoverageCopilotUsesTheGeneralResetAndIgnoresInvalidCredits() async throws {
  let transport = StubTransport()
  transport.on(
    path: "/copilot_internal/user",
    .text(
      #"{"quota_reset_date":"2026-09-01","quota_snapshots":{"chat":{"percent_remaining":50,"credits_used":"invalid"}},"limited_user_quotas":{"completions":5},"monthly_quotas":{"completions":10},"token_based_billing":true}"#
    ))
  let provider = CopilotProvider(
    auth: MemoryCopilotStore(CopilotAuth(token: "token")),
    client: APIClient(transport: transport, log: makeLog(), clock: testClock), log: makeLog())

  let snapshot = try #require(await provider.fetch(now: fixedNow, options: FetchOptions()).outcome.snapshot)

  #expect(snapshot.windows.map(\.id) == ["chat", "free:completions"])
  #expect(snapshot.windows.map(\.resetsAt) == [DayStamp.date("2026-09-01"), DayStamp.date("2026-09-01")])
  #expect(snapshot.notices.map(\.text) == ["Token-based billing: 0 credits used this cycle."])
}

@Test(arguments: [#"{"individualUsage":{"onDemand":{}}}"#, #"{"individualUsage":{"onDemand":{"remaining":0}}}"#])
func correctedCoverageCursorTreatsMissingSpendLimitsAsNotReached(body: String) async throws {
  let transport = StubTransport()
  transport.on(path: "/api/usage-summary", .text(body))
  transport.on(path: "/api/auth/me", .text("{}"))
  let provider = CursorProvider(
    auth: MemoryCursorStore(CursorAuth(accessToken: "token")),
    client: APIClient(transport: transport, log: makeLog(), clock: testClock), log: makeLog())

  let snapshot = try #require(await provider.fetch(now: fixedNow, options: FetchOptions()).outcome.snapshot)

  #expect(snapshot.spend?.enabled == true)
  #expect(snapshot.spend?.limit == nil)
  #expect(snapshot.spend?.limitReached == false)
}

@Test func correctedCoverageGeminiUsesTheAlternateProjectIDAndAllowsEmptyQuota() async throws {
  let (provider, transport, _) = correctedCoverageGeminiProvider(
    GeminiAuth(accessToken: "token", expiresAt: nil), allowRefresh: false)
  transport.on(
    path: ":loadCodeAssist",
    .text(#"{"currentTier":{"id":"free-tier"},"cloudaicompanionProject":{"projectId":"projects/fallback"}}"#))
  transport.on(path: ":retrieveUserQuota", .text("{}"))

  let snapshot = try #require(await provider.fetch(now: fixedNow, options: FetchOptions()).outcome.snapshot)

  #expect(snapshot.windows.isEmpty)
  #expect(snapshot.identity?.planName == "Free")
  let body = try #require(transport.requests(matching: ":retrieveUserQuota")[0].httpBody)
  #expect(try JSONDecoder().decode(JSONValue.self, from: body)["project"] == .string("projects/fallback"))
}

@Test func correctedCoverageGeminiExplainsAnUnsupportedClientWithoutAReasonMessage() async {
  let (provider, transport, _) = correctedCoverageGeminiProvider(
    GeminiAuth(accessToken: "token", expiresAt: nil), allowRefresh: false)
  transport.on(
    path: ":loadCodeAssist",
    .text(#"{"ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT"}]}"#))

  let result = await provider.fetch(now: fixedNow, options: FetchOptions())

  #expect(result.outcome == .notAuthenticated(GeminiAPI.unsupportedClientMessage))
  #expect(result.recoveryIssue?.kind == .accountUnsupported)
}

@Test(arguments: [#"{"error":"invalid_grant"}"#, #"{}"#])
func correctedCoverageGeminiRejectsRefreshResponsesWithoutAnAccessToken(body: String) async {
  let expired = GeminiAuth(
    accessToken: "old", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(-1))
  let (provider, transport, _) = correctedCoverageGeminiProvider(expired, allowRefresh: true)
  transport.on(path: "/token", .text(body))

  let result = await provider.fetch(now: fixedNow, options: FetchOptions())

  #expect(result.outcome == .notAuthenticated("Gemini token refresh failed: HTTP 401"))
  #expect(transport.requests(matching: "/token").count == 1)
}

@Test func correctedCoverageGeminiDefaultsTheRefreshedTokenLifetime() async throws {
  let expired = GeminiAuth(
    accessToken: "old", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(-1))
  let (provider, transport, store) = correctedCoverageGeminiProvider(expired, allowRefresh: true)
  transport.on(path: "/token", .text(#"{"access_token":"fresh"}"#))
  transport.on(path: ":loadCodeAssist", .text(#"{"currentTier":{"id":"free-tier"}}"#))
  transport.on(path: ":retrieveUserQuota", .text("{}"))

  _ = try #require(await provider.fetch(now: fixedNow, options: FetchOptions()).outcome.snapshot)

  #expect(store.saved.first?.expiresAt == fixedNow.addingTimeInterval(3600))
}

@Test func correctedCoverageGeminiRetriesCredentialPersistenceWithoutRefreshingAgain() async throws {
  let expired = GeminiAuth(
    accessToken: "old", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(-1))
  let (provider, transport, store) = correctedCoverageGeminiProvider(expired, allowRefresh: true)
  store.saveError = TestError()
  transport.on(path: "/token", .text(#"{"access_token":"fresh","expires_in":1800}"#))
  transport.on(path: ":loadCodeAssist", .text(#"{"currentTier":{"id":"free-tier"}}"#))
  transport.on(path: ":retrieveUserQuota", .text("{}"))

  let first = await provider.fetch(now: fixedNow, options: FetchOptions())
  store.saveError = nil
  let second = await provider.fetch(now: fixedNow.addingTimeInterval(60), options: FetchOptions())

  #expect(first.recoveryIssue?.kind == .credentialPersistence)
  #expect(second.recoveryIssue == nil)
  #expect(second.outcome.snapshot != nil)
  #expect(store.saved.first?.accessToken == "fresh")
  #expect(transport.requests(matching: "/token").count == 1)
}

private func correctedCoverageGeminiProvider(
  _ auth: GeminiAuth?, allowRefresh: Bool
) -> (GeminiProvider, StubTransport, MemoryGeminiStore) {
  let transport = StubTransport()
  let store = MemoryGeminiStore(auth)
  let provider = GeminiProvider(
    auth: store, client: APIClient(transport: transport, log: makeLog(), clock: testClock), log: makeLog(),
    allowRefresh: { allowRefresh },
    oauthClient: { GeminiOAuthClient(id: "client", secret: "secret") })
  return (provider, transport, store)
}
