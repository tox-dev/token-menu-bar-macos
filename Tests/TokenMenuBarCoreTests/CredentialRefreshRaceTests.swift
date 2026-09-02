import Foundation
import Security
import Testing

@testable import TokenMenuBarCore

@Test func claudeRefreshUsesCredentialsChangedByTheCLI() async {
  let expired = ClaudeOAuthCredentials(
    accessToken: "old", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(-1))
  let current = ClaudeOAuthCredentials(accessToken: "cli", refreshToken: "new", expiresAt: nil)
  let store = SwitchingCredentialStore(expired: expired, current: current)
  let transport = StubTransport()
  transport.on(path: "/v1/oauth/token", .text(#"{"access_token":"app","expires_in":3600}"#))
  transport.on(path: "/api/oauth/usage", .json("claude_usage"))
  transport.on(path: "/api/oauth/profile", .json("claude_profile"))
  let result = await claudeProvider(store, transport: transport, allowRefresh: true).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(result.outcome.snapshot != nil)
  #expect(store.saved.isEmpty)
  #expect(
    transport.requests(matching: "/api/oauth/usage")[0].value(forHTTPHeaderField: "Authorization") == "Bearer cli")
}

@Test func codexRefreshUsesCredentialsChangedByTheCLI() async {
  let expired = CodexAuth(
    accessToken: makeJWT(.object(["exp": .number(fixedNow.timeIntervalSince1970 - 1)])), refreshToken: "refresh")
  let current = CodexAuth(accessToken: "cli", refreshToken: "new", accountID: "acct")
  let store = SwitchingCredentialStore(expired: expired, current: current)
  let transport = StubTransport()
  transport.on(path: "/oauth/token", .text(#"{"access_token":"app"}"#))
  transport.on(path: "/wham/usage", .json("codex_usage"))
  let result = await codexProvider(store, transport: transport, allowRefresh: true).fetch(
    now: fixedNow, options: FetchOptions())
  #expect(result.outcome.snapshot != nil)
  #expect(store.saved.isEmpty)
  #expect(
    transport.requests(matching: "/wham/usage")[0].value(forHTTPHeaderField: "Authorization") == "Bearer cli")
}

@Test func geminiRefreshUsesCredentialsChangedByTheCLI() async {
  let expired = GeminiAuth(
    accessToken: "old", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(-1))
  let current = GeminiAuth(accessToken: "cli", refreshToken: "new", expiresAt: nil)
  let store = SwitchingCredentialStore(expired: expired, current: current)
  let transport = StubTransport()
  transport.on(path: "/token", .text(#"{"access_token":"app","expires_in":3600}"#))
  transport.on(path: ":loadCodeAssist", .json("gemini_load_code_assist"))
  transport.on(path: ":retrieveUserQuota", .json("gemini_quota"))
  let provider = GeminiProvider(
    auth: store, client: APIClient(transport: transport, log: makeLog(), clock: testClock), log: makeLog(),
    allowRefresh: { true }, oauthClient: { GeminiOAuthClient(id: "client", secret: "secret") })
  let result = await provider.fetch(now: fixedNow, options: FetchOptions())
  #expect(result.outcome.snapshot != nil)
  #expect(store.saved.isEmpty)
  #expect(
    transport.requests(matching: ":retrieveUserQuota")[0].value(forHTTPHeaderField: "Authorization") == "Bearer cli")
}

@Test func claudeRefreshStopsWhenCredentialsWereRemoved() async {
  let expired = ClaudeOAuthCredentials(
    accessToken: "old", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(-1))
  let store = SwitchingCredentialStore<ClaudeOAuthCredentials>(expired: expired, current: nil)
  let transport = StubTransport()
  transport.on(path: "/v1/oauth/token", .text(#"{"access_token":"app","expires_in":3600}"#))
  let result = await claudeProvider(store, transport: transport, allowRefresh: true).fetch(
    now: fixedNow, options: FetchOptions())
  guard case .notAuthenticated(let reason) = result.outcome else {
    Issue.record("expected authentication cancellation")
    return
  }
  #expect(reason.contains("HTTP 401"))
  #expect(transport.requests(matching: "/api/oauth/usage").isEmpty)
}

@Test func codexRefreshStopsWhenCredentialsWereRemoved() async {
  let expired = CodexAuth(
    accessToken: makeJWT(.object(["exp": .number(fixedNow.timeIntervalSince1970 - 1)])), refreshToken: "refresh")
  let store = SwitchingCredentialStore<CodexAuth>(expired: expired, current: nil)
  let transport = StubTransport()
  transport.on(path: "/oauth/token", .text(#"{"access_token":"app"}"#))
  let result = await codexProvider(store, transport: transport, allowRefresh: true).fetch(
    now: fixedNow, options: FetchOptions())
  guard case .notAuthenticated(let reason) = result.outcome else {
    Issue.record("expected authentication cancellation")
    return
  }
  #expect(reason.contains("HTTP 401"))
  #expect(transport.requests(matching: "/wham/usage").isEmpty)
}

@Test func geminiRefreshStopsWhenCredentialsWereRemoved() async {
  let expired = GeminiAuth(
    accessToken: "old", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(-1))
  let store = SwitchingCredentialStore<GeminiAuth>(expired: expired, current: nil)
  let transport = StubTransport()
  transport.on(path: "/token", .text(#"{"access_token":"app","expires_in":3600}"#))
  let provider = GeminiProvider(
    auth: store, client: APIClient(transport: transport, log: makeLog(), clock: testClock), log: makeLog(),
    allowRefresh: { true }, oauthClient: { GeminiOAuthClient(id: "client", secret: "secret") })
  let result = await provider.fetch(now: fixedNow, options: FetchOptions())
  guard case .notAuthenticated(let reason) = result.outcome else {
    Issue.record("expected authentication cancellation")
    return
  }
  #expect(reason.contains("HTTP 401"))
  #expect(transport.requests(matching: ":retrieveUserQuota").isEmpty)
}

@Test func claudeRetriesAFailedCredentialSaveWithoutRefreshingAgain() async {
  let expired = ClaudeOAuthCredentials(
    accessToken: "old", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(-1))
  let store = RetryCredentialStore(expired)
  let transport = StubTransport()
  transport.on(path: "/v1/oauth/token", .text(#"{"access_token":"app","expires_in":3600}"#))
  transport.on(path: "/api/oauth/usage", .json("claude_usage"))
  transport.on(path: "/api/oauth/profile", .json("claude_profile"))
  let provider = claudeProvider(store, transport: transport, allowRefresh: true)
  let first = await provider.fetch(now: fixedNow, options: FetchOptions())
  #expect(first.recoveryIssue?.kind == .credentialPersistence)
  let second = await provider.fetch(now: fixedNow.addingTimeInterval(60), options: FetchOptions())
  #expect(second.recoveryIssue == nil)
  #expect(transport.requests(matching: "/v1/oauth/token").count == 1)
  #expect(store.saved.count == 1)
}

@Test func claudeKeepsARefreshedCredentialWhenTheSourceTemporarilyCannotBeRead() async {
  let expired = ClaudeOAuthCredentials(
    accessToken: "old", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(-1))
  let store = RetryCredentialStore(expired)
  let transport = claudePersistenceTransport()
  let provider = claudeProvider(store, transport: transport, allowRefresh: true)
  _ = await provider.fetch(now: fixedNow, options: FetchOptions())
  store.failReads(CredentialStoreError.keychain(errSecNotAvailable))

  let result = await provider.fetch(now: fixedNow.addingTimeInterval(60), options: FetchOptions())
  #expect(result.outcome.snapshot != nil)
  #expect(result.recoveryIssue?.kind == .credentialPersistence)
  #expect(await provider.credentialHealth(now: fixedNow).isUsable)
}

@Test func claudeClearsPendingPersistenceWhenTheCLIAlreadyStoredTheRefresh() async {
  let expired = ClaudeOAuthCredentials(
    accessToken: "old", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(-1))
  let refreshed = expired.refreshed(accessToken: "app", refreshToken: nil, expiresIn: 3600, now: fixedNow)
  let store = RetryCredentialStore(expired)
  let transport = claudePersistenceTransport()
  let provider = claudeProvider(store, transport: transport, allowRefresh: true)
  _ = await provider.fetch(now: fixedNow, options: FetchOptions())
  store.replace(refreshed)

  let result = await provider.fetch(now: fixedNow.addingTimeInterval(60), options: FetchOptions())
  #expect(result.outcome.snapshot != nil)
  #expect(result.recoveryIssue == nil)
  #expect(store.saved.isEmpty)
}

@Test func claudeUsesANewerCLICredentialInsteadOfRetryingPersistence() async {
  let expired = ClaudeOAuthCredentials(
    accessToken: "old", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(-1))
  let current = ClaudeOAuthCredentials(accessToken: "cli", refreshToken: nil, expiresAt: nil)
  let store = RetryCredentialStore(expired)
  let transport = claudePersistenceTransport()
  let provider = claudeProvider(store, transport: transport, allowRefresh: true)
  _ = await provider.fetch(now: fixedNow, options: FetchOptions())
  store.replace(current)

  let result = await provider.fetch(now: fixedNow.addingTimeInterval(60), options: FetchOptions())
  #expect(result.outcome.snapshot != nil)
  #expect(result.recoveryIssue == nil)
  #expect(
    transport.requests(matching: "/api/oauth/usage").last?.value(forHTTPHeaderField: "Authorization")
      == "Bearer cli")
}

@Test func claudeUsesACredentialChangedDuringPersistenceRetry() async {
  let expired = ClaudeOAuthCredentials(
    accessToken: "old", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(-1))
  let current = ClaudeOAuthCredentials(accessToken: "cli", refreshToken: nil, expiresAt: nil)
  let store = RetryCredentialStore(expired)
  let transport = claudePersistenceTransport()
  let provider = claudeProvider(store, transport: transport, allowRefresh: true)
  _ = await provider.fetch(now: fixedNow, options: FetchOptions())
  store.replace(current, onRead: 4)

  let result = await provider.fetch(now: fixedNow.addingTimeInterval(60), options: FetchOptions())
  #expect(result.outcome.snapshot != nil)
  #expect(result.recoveryIssue == nil)
  #expect(
    transport.requests(matching: "/api/oauth/usage").last?.value(forHTTPHeaderField: "Authorization")
      == "Bearer cli")
}

@Test func claudeRetainsPendingPersistenceAfterASecondWriteFailure() async {
  let expired = ClaudeOAuthCredentials(
    accessToken: "old", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(-1))
  let store = RetryCredentialStore(expired, failures: 2)
  let transport = claudePersistenceTransport()
  let provider = claudeProvider(store, transport: transport, allowRefresh: true)
  _ = await provider.fetch(now: fixedNow, options: FetchOptions())

  let result = await provider.fetch(now: fixedNow.addingTimeInterval(60), options: FetchOptions())
  #expect(result.outcome.snapshot != nil)
  #expect(result.recoveryIssue?.kind == .credentialPersistence)
  #expect(store.saved.isEmpty)
}

@Test func geminiUnsupportedAccountReturnsTypedRecovery() async {
  let auth = GeminiAuth(accessToken: "token", expiresAt: nil)
  let transport = StubTransport()
  transport.on(path: ":loadCodeAssist", .json("gemini_unsupported"))
  let provider = GeminiProvider(
    auth: MemoryGeminiStore(auth),
    client: APIClient(transport: transport, log: makeLog(), clock: testClock),
    log: makeLog(),
    allowRefresh: { false })
  let result = await provider.fetch(now: fixedNow, options: FetchOptions())
  #expect(result.recoveryIssue?.kind == .accountUnsupported)
  #expect(result.recoveryIssue?.action == .copyCommand("gemini"))
}

private final class SwitchingCredentialStore<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private let expired: Value
  private let current: Value?
  private var reads = 0
  private(set) var saved: [Value] = []

  init(expired: Value, current: Value?) {
    self.expired = expired
    self.current = current
  }

  var description: String { "switching memory" }

  func read() -> Value? {
    lock.withLock {
      reads += 1
      return reads == 1 ? expired : current
    }
  }

  func write(_ value: Value) {
    lock.withLock { saved.append(value) }
  }
}

extension SwitchingCredentialStore: ClaudeCredentialStore where Value == ClaudeOAuthCredentials {
  func load() throws -> ClaudeOAuthCredentials? { read() }
  func save(_ credentials: ClaudeOAuthCredentials) throws { write(credentials) }
}

extension SwitchingCredentialStore: CodexAuthStore where Value == CodexAuth {
  func load() throws -> CodexAuth? { read() }
  func save(_ auth: CodexAuth) throws { write(auth) }
}

extension SwitchingCredentialStore: GeminiAuthStore where Value == GeminiAuth {
  func load() throws -> GeminiAuth? { read() }
  func save(_ auth: GeminiAuth) throws { write(auth) }
}

private final class RetryCredentialStore<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  private var failures: Int
  private var loadError: (any Error)?
  private var reads = 0
  private var replacement: (value: Value, read: Int)?
  private(set) var saved: [Value] = []

  init(_ stored: Value, failures: Int = 1) {
    self.stored = stored
    self.failures = failures
  }

  var description: String { "retry memory" }

  func read() throws -> Value {
    try lock.withLock {
      if let loadError { throw loadError }
      reads += 1
      if let replacement, reads == replacement.read {
        stored = replacement.value
        self.replacement = nil
      }
      return stored
    }
  }

  func failReads(_ error: any Error) {
    lock.withLock { loadError = error }
  }

  func replace(_ value: Value, onRead: Int? = nil) {
    lock.withLock {
      if let onRead {
        replacement = (value, onRead)
      } else {
        stored = value
      }
    }
  }

  func write(_ value: Value) throws {
    try lock.withLock {
      guard failures == 0 else {
        failures -= 1
        throw CocoaError(.fileWriteUnknown)
      }
      stored = value
      saved.append(value)
    }
  }
}

extension RetryCredentialStore: ClaudeCredentialStore where Value == ClaudeOAuthCredentials {
  func load() throws -> ClaudeOAuthCredentials? { try read() }
  func save(_ credentials: ClaudeOAuthCredentials) throws { try write(credentials) }
}

private func claudePersistenceTransport() -> StubTransport {
  let transport = StubTransport()
  transport.on(path: "/v1/oauth/token", .text(#"{"access_token":"app","expires_in":3600}"#))
  transport.on(path: "/api/oauth/usage", .json("claude_usage"))
  transport.on(path: "/api/oauth/profile", .json("claude_profile"))
  return transport
}
