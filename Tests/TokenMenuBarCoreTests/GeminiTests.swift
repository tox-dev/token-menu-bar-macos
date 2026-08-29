import Foundation
import Testing

@testable import TokenMenuBarCore

final class MemoryGeminiStore: GeminiAuthStore, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: GeminiAuth?
  var loadError: (any Error)?
  var saveError: (any Error)?
  private(set) var saved: [GeminiAuth] = []

  init(_ auth: GeminiAuth?) {
    stored = auth
  }

  var description: String { "memory" }

  func load() throws -> GeminiAuth? {
    if let loadError { throw loadError }
    return lock.withLock { stored }
  }

  func save(_ auth: GeminiAuth) throws {
    if let saveError { throw saveError }
    lock.withLock {
      stored = auth
      saved.append(auth)
    }
  }
}

private func idToken(email: String, hd: String? = nil) -> String {
  var claims: [String: JSONValue] = ["email": .string(email), "exp": .number(1_900_000_000)]
  claims["hd"] = hd.map(JSONValue.string)
  let payload = try! JSONEncoder().encode(JSONValue.object(claims)).base64EncodedString()
    .replacingOccurrences(of: "=", with: "")
  return "eyJhbGciOiJIUzI1NiJ9.\(payload).sig"
}

private let validGemini = GeminiAuth(
  accessToken: "ya29.valid", refreshToken: "1//refresh", idToken: idToken(email: "you@example.com"),
  expiresAt: fixedNow.addingTimeInterval(3600))

private let testOAuth = GeminiOAuthClient(id: "test-client.apps.googleusercontent.com", secret: "test-secret")

private func makeProvider(
  _ auth: GeminiAuth?, allowRefresh: Bool = false, store: MemoryGeminiStore? = nil,
  oauth: GeminiOAuthClient? = testOAuth
) -> (GeminiProvider, StubTransport, MemoryGeminiStore) {
  let transport = StubTransport()
  let store = store ?? MemoryGeminiStore(auth)
  let provider = GeminiProvider(
    auth: store, client: APIClient(transport: transport, log: makeLog(), clock: testClock), log: makeLog(),
    allowRefresh: { allowRefresh }, oauthClient: { oauth })
  return (provider, transport, store)
}

@Test func geminiAuthParsesDocumentAndClaims() {
  let auth = GeminiAuth(document: Fixtures.json("gemini_creds"))!
  #expect(auth.accessToken == "ya29.test")
  #expect(auth.refreshToken == "1//0g-refresh")
  #expect(auth.expiresAt == Date(timeIntervalSince1970: 1_788_033_600))
  #expect(auth.email == nil)
  #expect(GeminiAuth(document: .object([:])) == nil)
  let workspace = GeminiAuth(accessToken: "t", idToken: idToken(email: "a@corp.example", hd: "corp.example"))
  #expect(workspace.email == "a@corp.example")
  #expect(workspace.hostedDomain == "corp.example")
  #expect(workspace.expiresAt == nil)
  #expect(workspace.state(now: fixedNow) == .valid(expiresAt: nil))
  #expect(validGemini.state(now: fixedNow.addingTimeInterval(3600)) == .expired(validGemini.expiresAt!))
  let refreshed = validGemini.refreshed(accessToken: "new", expiresIn: 60, idToken: "id2", now: fixedNow)
  #expect(refreshed.accessToken == "new")
  #expect(refreshed.idToken == "id2")
  #expect(refreshed.expiresAt == fixedNow.addingTimeInterval(60))
  #expect(refreshed.refreshToken == "1//refresh")
  #expect(
    validGemini.refreshed(accessToken: "n", expiresIn: 1, idToken: nil, now: fixedNow).idToken == validGemini.idToken)
}

@Test func geminiFileStoreRoundTripsAndValidates() throws {
  let root = temporaryDirectory()
  let url = root.appendingPathComponent("oauth_creds.json")
  let store = FileGeminiAuthStore(url: url)
  #expect(store.description == url.path)
  #expect(try store.load() == nil)
  try store.save(validGemini)
  #expect(try store.load() == validGemini)
  try Data("nope".utf8).write(to: url)
  #expect(throws: CredentialStoreError.self) { try store.load() }
  #expect(FileGeminiAuthStore.defaultURL(environment: [:], home: root).path == root.path + "/.gemini/oauth_creds.json")
  #expect(
    FileGeminiAuthStore.defaultURL(environment: ["GEMINI_CLI_HOME": "/custom"], home: root).path
      == "/custom/.gemini/oauth_creds.json")
}

@Test func geminiMapperBuildsWindowsIdentityAndCredits() {
  let assist = Fixtures.decode(GeminiAPI.LoadCodeAssistResponse.self, "gemini_load_code_assist")
  #expect(assist.projectID == "gen-lang-client-0123456789")
  #expect(assist.unsupportedReason == nil)
  let quota = Fixtures.decode(GeminiAPI.QuotaResponse.self, "gemini_quota")
  let windows = GeminiMapper.windows(quota)
  #expect(windows.map(\.id) == ["model:gemini-2.5-pro", "model:gemini-2.5-flash"])
  #expect(windows.first { $0.id == "model:gemini-2.5-pro" }?.usedPercent == 60)
  #expect(windows.first { $0.id == "model:gemini-2.5-flash" }?.label == "Gemini 2.5 Flash")
  #expect(windows.allSatisfy { $0.resetsAt == ISODate.parse("2026-08-30T07:00:00Z") && $0.duration == 86400 })
  let identity = GeminiMapper.identity(assist, auth: validGemini)
  #expect(identity.planName == "Google AI Pro")
  #expect(identity.email == "you@example.com")
  #expect(identity.tier == "standard-tier")
  #expect(GeminiMapper.credits(assist)?.balance == 1500)
  #expect(GeminiMapper.credits(nil) == nil)
  let unsupported = Fixtures.decode(GeminiAPI.LoadCodeAssistResponse.self, "gemini_unsupported")
  #expect(unsupported.projectID == "projects/legacy-123")
  #expect(unsupported.unsupportedReason?.contains("Antigravity") == true)
  let noTier = GeminiAPI.LoadCodeAssistResponse(
    currentTier: nil, paidTier: nil, cloudaicompanionProject: .object(["projectId": .string("p")]),
    ineligibleTiers: [GeminiAPI.IneligibleTier(reasonCode: "OTHER", reasonMessage: nil)])
  #expect(noTier.projectID == "p")
  #expect(noTier.unsupportedReason == GeminiAPI.unsupportedClientMessage)
  #expect(
    GeminiAPI.LoadCodeAssistResponse(
      currentTier: nil, paidTier: nil, cloudaicompanionProject: nil, ineligibleTiers: nil
    )
    .unsupportedReason == nil)
}

@Test(arguments: [
  ("standard-tier", nil as String?, "Standard"), ("legacy-tier", nil, "Legacy"), ("free-tier", nil, "Free"),
  ("free-tier", "corp.example", "Workspace"), ("other", nil, "Other tier"),
])
func geminiPlanNames(tier: String, hosted: String?, expected: String) {
  let assist = GeminiAPI.LoadCodeAssistResponse(
    currentTier: GeminiAPI.Tier(id: tier, name: "Other tier", availableCredits: nil), paidTier: nil,
    cloudaicompanionProject: nil, ineligibleTiers: nil)
  #expect(GeminiMapper.planName(assist, hostedDomain: hosted) == expected)
  #expect(GeminiMapper.planName(nil, hostedDomain: nil) == "Gemini")
}

@Test func geminiProviderFetchesQuota() async {
  let (provider, transport, _) = makeProvider(validGemini)
  transport.on(path: ":loadCodeAssist", .json("gemini_load_code_assist"))
  transport.on(path: ":retrieveUserQuota", .json("gemini_quota"))
  #expect(provider.credentialDescription == "memory")
  #expect(provider.credentialState(now: fixedNow) == .valid(expiresAt: validGemini.expiresAt))
  let result = await provider.fetch(now: fixedNow, options: FetchOptions())
  guard case .success(let snapshot) = result.outcome else {
    Issue.record("expected success")
    return
  }
  #expect(snapshot.windows.count == 2)
  #expect(snapshot.identity?.planName == "Google AI Pro")
  #expect(snapshot.credits?.balance == 1500)
  let quotaRequest = transport.requests(matching: ":retrieveUserQuota").first!
  #expect(String(decoding: quotaRequest.httpBody!, as: UTF8.self).contains("gen-lang-client"))
  #expect(quotaRequest.value(forHTTPHeaderField: "Authorization") == "Bearer ya29.valid")
  _ = await provider.fetch(now: fixedNow.addingTimeInterval(10), options: FetchOptions())
  #expect(transport.requests(matching: ":loadCodeAssist").count == 1)
}

@Test func geminiProviderHandlesMissingExpiredAndErrors() async {
  let (missing, _, _) = makeProvider(nil)
  #expect(missing.credentialState(now: fixedNow) == .missing("no Gemini CLI sign-in found"))
  guard case .notAuthenticated = await missing.fetch(now: fixedNow, options: FetchOptions()).outcome else {
    Issue.record("expected notAuthenticated")
    return
  }
  let broken = MemoryGeminiStore(validGemini)
  broken.loadError = TestError()
  let (failing, _, _) = makeProvider(nil, store: broken)
  #expect(failing.credentialState(now: fixedNow).isMissing)
  guard case .notAuthenticated(let reason) = await failing.fetch(now: fixedNow, options: FetchOptions()).outcome else {
    Issue.record("expected notAuthenticated")
    return
  }
  #expect(reason.contains("Cannot read"))
  let (expired, _, _) = makeProvider(validGemini)
  guard
    case .notAuthenticated(let expiredReason) = await expired.fetch(
      now: fixedNow.addingTimeInterval(7200), options: FetchOptions()
    ).outcome
  else {
    Issue.record("expected notAuthenticated")
    return
  }
  #expect(expiredReason.contains("expired"))
}

@Test func geminiProviderReportsUnsupportedAccounts() async {
  let (provider, transport, _) = makeProvider(validGemini)
  transport.on(path: ":loadCodeAssist", .json("gemini_unsupported"))
  guard case .notAuthenticated(let reason) = await provider.fetch(now: fixedNow, options: FetchOptions()).outcome
  else {
    Issue.record("expected notAuthenticated")
    return
  }
  #expect(reason.contains("Antigravity"))
  let (subscription, transport2, _) = makeProvider(validGemini)
  transport2.on(path: ":loadCodeAssist", .text("boom", status: 500))
  transport2.on(path: ":retrieveUserQuota", .text(#"{"error":{"status":"SUBSCRIPTION_REQUIRED"}}"#, status: 403))
  let result = await subscription.fetch(now: fixedNow, options: FetchOptions())
  #expect(result.outcome == .notAuthenticated(GeminiAPI.unsupportedClientMessage))
}

@Test func geminiProviderPropagatesHTTPFailures() async {
  let (authFailure, transport, _) = makeProvider(validGemini)
  transport.on(path: ":loadCodeAssist", .text("denied", status: 401))
  guard case .notAuthenticated = await authFailure.fetch(now: fixedNow, options: FetchOptions()).outcome else {
    Issue.record("expected notAuthenticated")
    return
  }
  let (partial, transport2, _) = makeProvider(validGemini)
  transport2.on(path: ":loadCodeAssist", .text("boom", status: 500))
  transport2.on(path: ":retrieveUserQuota", .json("gemini_quota"))
  let result = await partial.fetch(now: fixedNow, options: FetchOptions())
  #expect(result.warnings.first?.contains("Plan details unavailable") == true)
  #expect(result.outcome.snapshot?.identity?.planName == "Gemini")
  let (quotaFailure, transport3, _) = makeProvider(validGemini)
  transport3.on(path: ":loadCodeAssist", .json("gemini_load_code_assist"))
  transport3.on(path: ":retrieveUserQuota", .text("slow", status: 429, headers: ["Retry-After": "30"]))
  #expect(
    await quotaFailure.fetch(now: fixedNow, options: FetchOptions()).outcome
      == .rateLimited("HTTP 429: slow", retryAfter: 30))
  let (offline, transport4, _) = makeProvider(validGemini)
  transport4.on(path: ":loadCodeAssist", error: URLError(.notConnectedToInternet))
  transport4.on(path: ":retrieveUserQuota", error: URLError(.notConnectedToInternet))
  guard case .networkUnavailable = await offline.fetch(now: fixedNow, options: FetchOptions()).outcome else {
    Issue.record("expected networkUnavailable")
    return
  }
}

@Test func geminiProviderRefreshesExpiredTokens() async {
  let expired = GeminiAuth(
    accessToken: "old", refreshToken: "1//refresh", idToken: nil, expiresAt: fixedNow.addingTimeInterval(-10))
  let (provider, transport, store) = makeProvider(expired, allowRefresh: true)
  transport.on(path: "/token", .text(#"{"access_token":"fresh","expires_in":1800,"id_token":"id"}"#))
  transport.on(path: ":loadCodeAssist", .json("gemini_load_code_assist"))
  transport.on(path: ":retrieveUserQuota", .json("gemini_quota"))
  let result = await provider.fetch(now: fixedNow, options: FetchOptions())
  #expect(result.outcome.snapshot != nil)
  #expect(store.saved.first?.accessToken == "fresh")
  let body = String(decoding: transport.requests(matching: "/token").first!.httpBody!, as: UTF8.self)
  #expect(body.contains("grant_type=refresh_token") && body.contains("refresh_token=1//refresh"))
  #expect(body.contains("client_id=test-client.apps.googleusercontent.com"))
  #expect(
    transport.requests(matching: "/token").first?.value(forHTTPHeaderField: "Content-Type")
      == "application/x-www-form-urlencoded")
}

@Test func geminiProviderReportsRefreshFailures() async {
  let expired = GeminiAuth(accessToken: "old", refreshToken: nil, expiresAt: fixedNow.addingTimeInterval(-10))
  let (noToken, _, _) = makeProvider(expired, allowRefresh: true)
  guard case .notAuthenticated(let reason) = await noToken.fetch(now: fixedNow, options: FetchOptions()).outcome
  else {
    Issue.record("expected notAuthenticated")
    return
  }
  #expect(reason.contains("no refresh token"))
  let withToken = GeminiAuth(accessToken: "old", refreshToken: "r", expiresAt: fixedNow.addingTimeInterval(-10))
  let (rejected, transport, _) = makeProvider(withToken, allowRefresh: true)
  transport.on(path: "/token", .text(#"{"error":"invalid_grant","error_description":"Token has been revoked."}"#))
  guard case .notAuthenticated(let revoked) = await rejected.fetch(now: fixedNow, options: FetchOptions()).outcome
  else {
    Issue.record("expected notAuthenticated")
    return
  }
  #expect(revoked.contains("revoked"))
  let store = MemoryGeminiStore(withToken)
  store.saveError = TestError()
  let (unsaved, transport2, _) = makeProvider(nil, allowRefresh: true, store: store)
  transport2.on(path: "/token", .text(#"{"access_token":"fresh","expires_in":1800}"#))
  transport2.on(path: ":loadCodeAssist", .json("gemini_load_code_assist"))
  transport2.on(path: ":retrieveUserQuota", .json("gemini_quota"))
  #expect(await unsaved.fetch(now: fixedNow, options: FetchOptions()).outcome.snapshot != nil)
  #expect(store.saved.isEmpty)
}

@Test func geminiOAuthClientComesFromTheEnvironmentOrTheInstalledCLI() {
  let home = URL(fileURLWithPath: "/Users/tester")
  let fromEnvironment = GeminiOAuthConfig.resolve(
    environment: ["GEMINI_OAUTH_CLIENT_ID": "env-id", "GEMINI_OAUTH_CLIENT_SECRET": "env-secret"], home: home,
    read: { _ in nil })
  #expect(fromEnvironment == GeminiOAuthClient(id: "env-id", secret: "env-secret"))
  let source = """
    const OAUTH_CLIENT_ID = '123-abc.apps.googleusercontent.com';
    const OAUTH_CLIENT_SECRET = 'SECRET-value';
    """
  #expect(
    GeminiOAuthConfig.extract(from: source)
      == GeminiOAuthClient(id: "123-abc.apps.googleusercontent.com", secret: "SECRET-value"))
  #expect(GeminiOAuthConfig.extract(from: "const OAUTH_CLIENT_ID = 'only-id';") == nil)
  #expect(GeminiOAuthConfig.value(of: "MISSING", in: source) == nil)
  var probed: [String] = []
  let found = GeminiOAuthConfig.resolve(
    environment: [:], home: home,
    read: { url in
      probed.append(url.path)
      return url.path.hasSuffix(GeminiOAuthConfig.relativePaths[1]) ? source : nil
    })
  #expect(found?.id == "123-abc.apps.googleusercontent.com")
  #expect(probed.contains { $0.hasPrefix("/Users/tester/.npm-global") })
  #expect(GeminiOAuthConfig.resolve(environment: [:], home: home, read: { _ in nil }) == nil)
  #expect(
    GeminiOAuthConfig.searchRoots(environment: ["NPM_CONFIG_PREFIX": "/custom"], home: home).first?.path == "/custom")
}

@Test func geminiRefreshNeedsTheCLIOAuthClient() async {
  let expired = GeminiAuth(accessToken: "old", refreshToken: "r", expiresAt: fixedNow.addingTimeInterval(-10))
  let (provider, _, _) = makeProvider(expired, allowRefresh: true, oauth: nil)
  guard case .notAuthenticated(let reason) = await provider.fetch(now: fixedNow, options: FetchOptions()).outcome
  else {
    Issue.record("expected notAuthenticated")
    return
  }
  #expect(reason.contains("OAuth client could not be read"))
}
