import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func claudeCredentialsParseKeychainDocument() {
  let credentials = ClaudeOAuthCredentials(document: Fixtures.json("claude_keychain"))!
  #expect(credentials.accessToken == "sk-ant-oat01-EXAMPLE")
  #expect(credentials.refreshToken == "sk-ant-ort01-EXAMPLE")
  #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_788_039_901.877))
  #expect(credentials.hasProfileScope)
  #expect(credentials.subscriptionType == "max")
  #expect(credentials.rateLimitTier == "default_claude_max_20x")
  #expect(credentials.state(now: fixedNow) == .valid(expiresAt: credentials.expiresAt))
  #expect(credentials.state(now: fixedNow.addingTimeInterval(20000)) == .expired(credentials.expiresAt!))
}

@Test func claudeCredentialsRejectDocumentsWithoutToken() {
  #expect(ClaudeOAuthCredentials(document: .object(["mcpOAuth": .object([:])])) == nil)
  #expect(ClaudeOAuthCredentials(document: .object(["claudeAiOauth": .object(["scopes": .array([])])])) == nil)
}

@Test func claudeCredentialsDefaultToNoScopesWhenTheDocumentOmitsThem() throws {
  let document = JSONValue.object(["claudeAiOauth": .object(["accessToken": .string("token")])])
  let credentials = try #require(ClaudeOAuthCredentials(document: document))

  #expect(credentials.scopes.isEmpty)
  #expect(!credentials.hasProfileScope)
}

@Test func claudeCredentialsRefreshPreservesUnknownKeys() {
  let document = Fixtures.json("claude_keychain").merging("mcpOAuth", .object(["x": .number(1)]))
  let credentials = ClaudeOAuthCredentials(document: document)!
  let refreshed = credentials.refreshed(accessToken: "new", refreshToken: "newer", expiresIn: 3600, now: fixedNow)
  #expect(refreshed.accessToken == "new")
  #expect(refreshed.refreshToken == "newer")
  #expect(refreshed.expiresAt == fixedNow.addingTimeInterval(3600))
  #expect(refreshed.document["mcpOAuth"] == .object(["x": .number(1)]))
  #expect(refreshed.rateLimitTier == "default_claude_max_20x")
  let keepRefresh = credentials.refreshed(accessToken: "n", refreshToken: nil, expiresIn: 1, now: fixedNow)
  #expect(keepRefresh.refreshToken == "sk-ant-ort01-EXAMPLE")
}

@Test func claudeCredentialsConvenienceInit() {
  let credentials = ClaudeOAuthCredentials(
    accessToken: "a", refreshToken: "r", expiresAt: fixedNow, subscriptionType: "pro", rateLimitTier: nil)
  #expect(
    credentials.document["claudeAiOauth"]?["expiresAt"]?.doubleValue
      == (fixedNow.timeIntervalSince1970 * 1000).rounded())
  #expect(credentials.scopes == ["user:profile"])
  #expect(ClaudeOAuthCredentials(accessToken: "a", refreshToken: nil, expiresAt: nil).expiresAt == nil)
}

@Test func claudeKeychainServiceNameHashesConfigDir() {
  #expect(ClaudeOAuthCredentials.keychainService(configDir: nil) == "Claude Code-credentials")
  #expect(ClaudeOAuthCredentials.keychainService(configDir: "") == "Claude Code-credentials")
  let hashed = ClaudeOAuthCredentials.keychainService(configDir: "/Users/me/.claude-work")
  #expect(hashed.hasPrefix("Claude Code-credentials-"))
  #expect(hashed.count == "Claude Code-credentials-".count + 8)
}

@Test func keychainParseRejectsNonJSON() throws {
  #expect(throws: CredentialStoreError.malformed("Keychain item is not JSON")) {
    try KeychainClaudeCredentialStore.parse(Data("nope".utf8))
  }
  #expect(
    try KeychainClaudeCredentialStore.parse(Fixtures.data("claude_keychain"))?.accessToken == "sk-ant-oat01-EXAMPLE")
  #expect(
    KeychainClaudeCredentialStore(account: "me", keychain: .empty).description
      == "Keychain item Claude Code-credentials")
}

@Test func keychainStoreReadsAndWritesInMemoryCredentials() throws {
  let keychain = MemoryKeychain()
  let store = KeychainClaudeCredentialStore(service: "claude-test", account: "tests", keychain: keychain.client)
  #expect(try store.load() == nil)
  let credentials = ClaudeOAuthCredentials(accessToken: "first", refreshToken: nil, expiresAt: nil)
  try store.save(credentials)
  #expect(try store.load()?.accessToken == "first")
  try store.save(ClaudeOAuthCredentials(accessToken: "second", refreshToken: nil, expiresAt: nil))
  #expect(try store.load()?.accessToken == "second")
}

@Test func keychainClientAddsUpdatesAndFindsAnAccountInMemory() throws {
  let client = MemoryKeychain().client

  #expect(try client.load(service: "test", account: "account") == nil)
  try client.save(Data("first".utf8), service: "test", account: "account")
  #expect(try client.load(service: "test", account: "account")?.data == Data("first".utf8))
  #expect(try client.load(service: "test")?.account == "account")
  try client.save(Data("second".utf8), service: "test", account: "account")
  #expect(try client.load(service: "test", account: "account")?.data == Data("second".utf8))
}

@Test func fileClaudeStoreRoundTripsAndRejectsGarbage() throws {
  let directory = temporaryDirectory()
  let store = FileClaudeCredentialStore(url: directory.appendingPathComponent(".credentials.json"))
  #expect(try store.load() == nil)
  #expect(store.description == store.url.path)
  try store.save(ClaudeOAuthCredentials(accessToken: "tok", refreshToken: nil, expiresAt: nil))
  #expect(try store.load()?.accessToken == "tok")
  try Data("{".utf8).write(to: store.url)
  #expect(throws: CredentialStoreError.malformed(".credentials.json is not JSON")) { try store.load() }
}

@Test func chainedClaudeStorePrefersFirstHitAndSavesWhereFound() throws {
  let directory = temporaryDirectory()
  let empty = FileClaudeCredentialStore(url: directory.appendingPathComponent("empty.json"))
  let filled = FileClaudeCredentialStore(url: directory.appendingPathComponent("filled.json"))
  try filled.save(ClaudeOAuthCredentials(accessToken: "filled", refreshToken: nil, expiresAt: nil))
  let chain = ChainedClaudeCredentialStore([empty, filled])
  #expect(chain.description == "\(empty.url.path), \(filled.url.path)")
  #expect(try chain.load()?.accessToken == "filled")
  try chain.save(ClaudeOAuthCredentials(accessToken: "updated", refreshToken: nil, expiresAt: nil))
  #expect(try filled.load()?.accessToken == "updated")
  #expect(try empty.load() == nil)
  let broken = FileClaudeCredentialStore(url: directory.appendingPathComponent("broken.json"))
  try Data("{".utf8).write(to: broken.url)
  #expect(throws: CredentialReadFailure.self) { try ChainedClaudeCredentialStore([broken, empty]).load() }
  #expect(try ChainedClaudeCredentialStore([broken, filled]).load()?.accessToken == "updated")
  let onlyEmpty = ChainedClaudeCredentialStore([empty])
  try onlyEmpty.save(ClaudeOAuthCredentials(accessToken: "fresh", refreshToken: nil, expiresAt: nil))
  #expect(try empty.load()?.accessToken == "fresh")
  #expect(try ChainedClaudeCredentialStore([]).load() == nil)
  try ChainedClaudeCredentialStore([]).save(ClaudeOAuthCredentials(accessToken: "x", refreshToken: nil, expiresAt: nil))
}

@Test func claudeLocalAccountReadsOauthAccount() throws {
  let directory = temporaryDirectory()
  let url = directory.appendingPathComponent(".claude.json")
  #expect(ClaudeLocalAccount.load(from: url) == nil)
  try Data(
    #"""
    {"oauthAccount":{"emailAddress":"a@b.c","organizationName":"Org",
    "organizationRateLimitTier":"default_claude_max_5x","hasExtraUsageEnabled":true}}
    """#
    .utf8
  ).write(to: url)
  #expect(
    ClaudeLocalAccount.load(from: url)
      == ClaudeLocalAccount(
        email: "a@b.c", organizationName: "Org", rateLimitTier: "default_claude_max_5x", hasExtraUsageEnabled: true))
  try Data(#"{"other":1}"#.utf8).write(to: url)
  #expect(ClaudeLocalAccount.load(from: url) == nil)
}

@Test func codexAuthParsesTokensAndClaims() {
  let auth = CodexAuth(document: Fixtures.codexAuth())!
  #expect(auth.accessToken == "ACCESS-EXAMPLE")
  #expect(auth.refreshToken == "REFRESH-EXAMPLE")
  #expect(auth.accountID == "00000000-0000-4000-8000-000000000000")
  #expect(auth.email == "user@example.com")
  #expect(auth.planType == "pro")
  #expect(auth.subscriptionActiveUntil == ISODate.parse("2026-07-23T19:57:23+00:00"))
  #expect(auth.lastRefresh == ISODate.parse("2026-08-28T19:59:48.413665Z"))
  #expect(auth.apiKey == nil)
  #expect(auth.state(now: fixedNow) == .valid(expiresAt: nil))
}

@Test func codexAuthFallsBackToAPIKeyAndClaimAccount() {
  let claims = JWT.payload(CodexAuth(document: Fixtures.codexAuth())!.idToken!)!
  let idToken = makeJWT(claims)
  let auth = CodexAuth(
    document: .object(["OPENAI_API_KEY": .string("sk-key"), "tokens": .object(["id_token": .string(idToken)])]))!
  #expect(auth.accessToken == "sk-key")
  #expect(auth.accountID == claims["https://api.openai.com/auth"]?["chatgpt_account_id"]?.stringValue)
  #expect(CodexAuth(document: .object(["tokens": .object([:])])) == nil)
  #expect(CodexAuth(document: .object(["OPENAI_API_KEY": .null])) == nil)
}

@Test func codexAuthExpiryComesFromAccessTokenJWT() {
  let auth = CodexAuth(accessToken: makeJWT(.object(["exp": .number(fixedNow.timeIntervalSince1970 + 60)])))
  #expect(auth.state(now: fixedNow) == .expired(Date(timeIntervalSince1970: fixedNow.timeIntervalSince1970 + 60)))
  #expect(auth.claims == nil)
  #expect(auth.email == nil)
  #expect(auth.planType == nil)
  #expect(auth.subscriptionActiveUntil == nil)
}

@Test func codexAuthRefreshedPreservesUnknownKeysAndStampsTime() {
  let document = Fixtures.codexAuth().merging("custom", .bool(true))
  let auth = CodexAuth(document: document)!
  let refreshed = auth.refreshed(accessToken: "A2", refreshToken: nil, idToken: nil, now: fixedNow)
  #expect(refreshed.accessToken == "A2")
  #expect(refreshed.refreshToken == "REFRESH-EXAMPLE")
  #expect(refreshed.idToken == auth.idToken)
  #expect(refreshed.lastRefresh == Date(timeIntervalSince1970: fixedNow.timeIntervalSince1970.rounded(.down)))
  #expect(refreshed.document["custom"] == .bool(true))
  let full = auth.refreshed(accessToken: "A3", refreshToken: "R3", idToken: "I3", now: fixedNow)
  #expect(full.refreshToken == "R3")
  #expect(full.idToken == "I3")
}

@Test func codexAuthConvenienceInit() {
  let auth = CodexAuth(accessToken: "a", refreshToken: "r", idToken: nil, accountID: "acct", lastRefresh: fixedNow)
  #expect(auth.accountID == "acct")
  #expect(auth.document["auth_mode"]?.stringValue == "chatgpt")
  #expect(auth.lastRefresh == Date(timeIntervalSince1970: fixedNow.timeIntervalSince1970.rounded(.down)))
}

@Test func fileCodexStoreRoundTripsAndDefaultsLocation() throws {
  let store = FileCodexAuthStore(url: temporaryDirectory().appendingPathComponent("auth.json"))
  #expect(try store.load() == nil)
  #expect(store.description == store.url.path)
  try store.save(CodexAuth(accessToken: "tok"))
  #expect(try store.load()?.accessToken == "tok")
  try Data("nope".utf8).write(to: store.url)
  #expect(throws: CredentialStoreError.malformed("auth.json is not JSON")) { try store.load() }
  let home = URL(fileURLWithPath: "/Users/me")
  #expect(FileCodexAuthStore.defaultURL(environment: [:], home: home).path == "/Users/me/.codex/auth.json")
  #expect(
    FileCodexAuthStore.defaultURL(environment: ["CODEX_HOME": "/tmp/codex"], home: home).path == "/tmp/codex/auth.json")
}

@Test func codexKeychainStoreRoundTripsInMemoryCredentials() throws {
  #expect(KeychainCodexAuthStore(account: "public-tests", keychain: .empty).account == "public-tests")
  let store = KeychainCodexAuthStore(account: "tests", keychain: MemoryKeychain().client)

  #expect(store.source == ProviderID.codex.credentialSource("codex.keyring"))
  #expect(try store.load() == nil)
  try store.save(CodexAuth(accessToken: "first"))
  #expect(try store.load()?.accessToken == "first")
  try store.save(CodexAuth(accessToken: "second"))
  #expect(try store.load()?.accessToken == "second")
}

@Test func codexChainSavesToTheExistingStoreOrFirstFallback() throws {
  let directory = temporaryDirectory()
  let empty = FileCodexAuthStore(url: directory.appendingPathComponent("empty.json"))
  let filled = FileCodexAuthStore(url: directory.appendingPathComponent("filled.json"))
  try filled.save(CodexAuth(accessToken: "existing"))

  try ChainedCodexAuthStore([empty, filled]).save(CodexAuth(accessToken: "updated"))
  #expect(try empty.load() == nil)
  #expect(try filled.load()?.accessToken == "updated")

  try ChainedCodexAuthStore([empty]).save(CodexAuth(accessToken: "fallback"))
  #expect(try empty.load()?.accessToken == "fallback")
  try ChainedCodexAuthStore([]).save(CodexAuth(accessToken: "ignored"))
}

@Test func codexCredentialStorageLoadsReadableConfiguration() {
  let url = URL(fileURLWithPath: "/configuration.toml")
  #expect(
    CodexCredentialStorageReader.load(from: url, read: { _ in "cli_auth_credentials_store = 'keyring'" })
      == .keyring)
  #expect(
    CodexCredentialStorageReader.load(from: url, read: { _ in throw CocoaError(.fileReadNoSuchFile) })
      == .automatic)
}

@Test func concreteCredentialStoresIdentifyTheirSources() {
  let directory = temporaryDirectory()
  #expect(KeychainClaudeCredentialStore(account: "tests", keychain: .empty).source.id == "claude.keychain")
  #expect(CursorStateStore(url: directory.appendingPathComponent("state.vscdb")).source.id == "cursor.app")
  #expect(KeychainGeminiAuthStore(keychain: .empty).source.id == "gemini.keychain")
  #expect(KeychainGeminiAuthStore(keychain: .empty).description == "Keychain item gemini-cli-oauth")
  #expect(FileCopilotAuthStore(urls: []).source.id == "copilot.legacy-file")
  #expect(EnvironmentCopilotAuthStore(environment: [:]).source.id == "copilot.environment")
  #expect(KeychainCopilotAuthStore(keychain: .empty).source.id == "copilot.keychain")
}

@Test func cursorCredentialHealthReportsAReadableSession() {
  let store = MemoryCursorStore(CursorAuth(accessToken: "token"))
  #expect(store.credentialHealth(now: fixedNow) == .valid(source: store.source, expiresAt: nil))
}

@Test func geminiKeychainFormatsFlatCredentialsAndRejectsMalformedData() throws {
  let auth = GeminiAuth(
    accessToken: "access", refreshToken: "refresh", idToken: "identity", expiresAt: fixedNow)
  let document = KeychainGeminiAuthStore.document(for: auth, updatedAt: fixedNow)
  #expect(document["serverName"] == .string("main-account"))
  #expect(document["token"]?["accessToken"] == .string("access"))
  #expect(document["token"]?["refreshToken"] == .string("refresh"))
  #expect(document["token"]?["idToken"] == .string("identity"))
  #expect(document["token"]?["expiresAt"] == .number(fixedNow.timeIntervalSince1970 * 1000))
  #expect(document["updatedAt"] == .number(fixedNow.timeIntervalSince1970 * 1000))
  #expect(throws: CredentialStoreError.malformed("Gemini Keychain item is not JSON")) {
    try KeychainGeminiAuthStore.parse(Data("not-json".utf8))
  }
}

@Test func geminiKeychainStoreRoundTripsInMemoryCredentials() throws {
  let store = KeychainGeminiAuthStore(service: "gemini-test", keychain: MemoryKeychain().client)

  #expect(try store.load() == nil)
  try store.save(GeminiAuth(accessToken: "first", refreshToken: "refresh"))
  #expect(try store.load()?.accessToken == "first")
  try store.save(GeminiAuth(accessToken: "second", refreshToken: "refresh"))
  #expect(try store.load()?.accessToken == "second")
}

@Test func geminiChainLoadsAndSavesThroughItsAvailableStore() throws {
  let directory = temporaryDirectory()
  let empty = FileGeminiAuthStore(url: directory.appendingPathComponent("empty.json"))
  let filled = FileGeminiAuthStore(url: directory.appendingPathComponent("filled.json"))
  try filled.save(GeminiAuth(accessToken: "existing"))
  let chain = ChainedGeminiAuthStore([empty, filled])
  #expect(chain.description == "\(empty.url.path), \(filled.url.path)")
  #expect(try chain.load()?.accessToken == "existing")

  try chain.save(GeminiAuth(accessToken: "updated"))
  #expect(try filled.load()?.accessToken == "updated")
  #expect(try empty.load() == nil)
  try ChainedGeminiAuthStore([empty]).save(GeminiAuth(accessToken: "fallback"))
  #expect(try empty.load()?.accessToken == "fallback")
  #expect(try ChainedGeminiAuthStore([]).load() == nil)
  try ChainedGeminiAuthStore([]).save(GeminiAuth(accessToken: "ignored"))
}

@Test func copilotCLIConfigReadsArrayAccounts() throws {
  let url = temporaryDirectory().appendingPathComponent("config.json")
  try Data(
    #"{"loggedInUsers":[{"user":"ada","host":"corp.example","token":"enterprise"}]}"#.utf8
  ).write(to: url)
  let store = FileCopilotCLIAuthStore(url: url)
  #expect(try store.load() == CopilotAuth(token: "enterprise", user: "ada", host: "corp.example"))
  #expect(store.keychainAccounts() == ["https://corp.example:ada"])
}

@Test func copilotCLIConfigDefaultsAnArrayAccountToGitHub() throws {
  let url = temporaryDirectory().appendingPathComponent("config.json")
  try Data(#"{"loggedInUsers":[{"user":"ada","token":"enterprise"}]}"#.utf8).write(to: url)
  let store = FileCopilotCLIAuthStore(url: url)

  #expect(try store.load() == CopilotAuth(token: "enterprise", user: "ada"))
  #expect(store.keychainAccounts() == ["https://github.com:ada"])
}

@Test func legacyCopilotCredentialDefaultsAnEmptyAccountKeyToGitHub() throws {
  let url = temporaryDirectory().appendingPathComponent("hosts.json")
  try Data(#"{"":{"oauth_token":"token"}}"#.utf8).write(to: url)

  #expect(try FileCopilotAuthStore(urls: [url]).load() == CopilotAuth(token: "token"))
}

@Test func copilotKeychainParsesHTTPAndMalformedEnterpriseAccounts() throws {
  #expect(
    try KeychainCopilotAuthStore.parse(Data("token".utf8), account: "http://corp.example:ada")
      == CopilotAuth(token: "token", user: "ada", host: "corp.example"))
  #expect(
    try KeychainCopilotAuthStore.parse(Data("token".utf8), account: "https://bad/path:ada")
      == CopilotAuth(token: "token", host: "github.com"))
}

@Test func copilotKeychainStoreReadsInMemoryCredentials() throws {
  let service = "copilot-test"
  let account = "https://tests.example:tester"
  let keychain = MemoryKeychain()
  try keychain.client.save(Data("copilot-token".utf8), service: service, account: account)

  let auth = try KeychainCopilotAuthStore(service: service, accounts: [account], keychain: keychain.client).load()
  #expect(auth?.token == "copilot-token")
  #expect(auth?.host == "tests.example")
}

@Test func copilotKeychainStoreReportsMalformedCredentialData() throws {
  let service = "copilot-test"
  let account = "broken"
  let keychain = MemoryKeychain()
  try keychain.client.save(Data([0xFF]), service: service, account: account)

  #expect(throws: CredentialReadFailure.self) {
    try KeychainCopilotAuthStore(service: service, accounts: [account], keychain: keychain.client).load()
  }
}

@Test func copilotChainReturnsTheFirstReadableCredential() throws {
  let empty = MemoryCopilotStore(nil)
  let filled = MemoryCopilotStore(CopilotAuth(token: "token"))
  #expect(try ChainedCopilotAuthStore([empty, filled]).load()?.token == "token")
  #expect(try ChainedCopilotAuthStore([]).load() == nil)
}

@Test func jwtPayloadHandlesMalformedTokens() {
  #expect(JWT.payload("abc") == nil)
  #expect(JWT.payload("a.!!!.c") == nil)
  #expect(JWT.payload("a.bm90anNvbg.c") == nil)
  #expect(JWT.expiry(makeJWT(.object(["exp": .number(10)]))) == Date(timeIntervalSince1970: 10))
  #expect(JWT.expiry(makeJWT(.object(["sub": .string("x")]))) == nil)
}

@Test func credentialStateDescriptions() {
  #expect(CredentialState.missing("nothing").description == "No credentials: nothing")
  #expect(CredentialState.valid(expiresAt: nil).description == "Token present")
  #expect(CredentialState.valid(expiresAt: fixedNow).description.hasPrefix("Token valid until"))
  #expect(CredentialState.expired(fixedNow).description.hasPrefix("Token expired"))
  #expect(!CredentialState.expired(fixedNow).isUsable)
  #expect(CredentialState.from(expiresAt: nil, now: fixedNow).isUsable)
}

@Test func isoDateParsesFractionalAndPlain() {
  #expect(ISODate.parse("2026-08-29T18:49:59.521847+00:00") != nil)
  #expect(ISODate.parse("2026-08-29T18:49:59Z") == Date(timeIntervalSince1970: 1_788_029_399))
  #expect(ISODate.parse("not a date") == nil)
  #expect(ISODate.parse(nil) == nil)
  #expect(ISODate.string(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
}
