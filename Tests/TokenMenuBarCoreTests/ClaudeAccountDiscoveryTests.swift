import Foundation
import Security
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

private let baseService = ClaudeOAuthCredentials.keychainService
private let hashedService = ClaudeOAuthCredentials.keychainService(configDir: "/Users/me/.claude-work")
private let hashedLabel = "configuration \(hashedService.suffix(8))"
private let mcpOnlyItem = Data(#"{"mcpOAuth":{"server":{"accessToken":"mcp"}}}"#.utf8)

private func claudeItem(token: String, expiresAt: Date?) -> Data {
  try! JSONEncoder().encode(
    ClaudeOAuthCredentials(accessToken: token, refreshToken: nil, expiresAt: expiresAt).document)
}

private func keychain(_ items: [(service: String, data: Data)]) throws -> MemoryKeychain {
  let keychain = MemoryKeychain()
  for item in items { try keychain.client.save(item.data, service: item.service, account: "me") }
  return keychain
}

@Test(arguments: ["subject", "refresh", "access", "different", "unknown-expiry", "new-unknown-expiry"])
func claudeFallbackRefreshesOnlyTheSelectedAccount(identity: String) throws {
  let firstToken = identity == "subject" ? makeJWT(.object(["sub": .string("same"), "iat": .number(1)])) : "first"
  let nextToken =
    identity == "subject"
    ? makeJWT(.object(["sub": .string("same"), "iat": .number(2)]))
    : ["access", "unknown-expiry", "new-unknown-expiry"].contains(identity) ? "first" : "next"
  let first = ClaudeOAuthCredentials(
    accessToken: firstToken, refreshToken: identity == "refresh" ? "shared" : nil,
    expiresAt: identity == "unknown-expiry" ? nil : fixedNow)
  let next = ClaudeOAuthCredentials(
    accessToken: nextToken, refreshToken: identity == "refresh" ? "shared" : nil,
    expiresAt: identity == "new-unknown-expiry" ? nil : fixedNow.addingTimeInterval(3600))
  let chain = ChainedClaudeCredentialStore([MemoryClaudeStore(first), MemoryClaudeStore(next)])
  #expect(try chain.load() == (["different", "unknown-expiry"].contains(identity) ? first : next))
}

@Test func discoveredClaudeChoosesAStableAccountWhenTheDefaultIsAbsent() throws {
  let services = [baseService + "-bbb", baseService + "-aaa"]
  let store = DiscoveredClaudeKeychainStore(
    account: "me",
    keychain: try keychain(services.map { ($0, claudeItem(token: $0, expiresAt: nil)) }).client)
  #expect(try store.load()?.accessToken == services[1])
}

@Test func keychainItemWithOnlyMCPOAuthReportsAMissingUsageToken() throws {
  let store = KeychainClaudeCredentialStore(
    account: "me", keychain: try keychain([(baseService, mcpOnlyItem)]).client)

  #expect(throws: CredentialStoreError.incomplete(ClaudeOAuthCredentials.usageTokenMissingDetail)) {
    try store.load()
  }
}

@Test func incompleteKeychainItemFallsBackToTheCredentialFile() throws {
  let file = FileClaudeCredentialStore(url: temporaryDirectory().appendingPathComponent(".credentials.json"))
  try file.save(ClaudeOAuthCredentials(accessToken: "file", refreshToken: nil, expiresAt: nil))
  let chain = ChainedClaudeCredentialStore([
    KeychainClaudeCredentialStore(account: "me", keychain: try keychain([(baseService, mcpOnlyItem)]).client), file,
  ])

  let found = try #require(try chain.loadWithSource())

  #expect(found.credentials.accessToken == "file")
  #expect(found.source.id == "claude.file")
  #expect(chain.credentialHealth(now: fixedNow) == .valid(source: file.source, expiresAt: nil))
}

@Test func incompleteKeychainItemWithoutAFileTellsTheUserToRunClaude() throws {
  let chain = ChainedClaudeCredentialStore([
    DiscoveredClaudeKeychainStore(account: "me", keychain: try keychain([(baseService, mcpOnlyItem)]).client),
    FileClaudeCredentialStore(url: temporaryDirectory().appendingPathComponent(".credentials.json")),
  ])

  #expect(
    chain.credentialHealth(now: fixedNow)
      == .unreadable(
        source: ProviderID.claude.credentialSource("claude.keychain"),
        detail: "Claude Code has not stored a usage token yet; run `claude` once."))
}

@Test func claudeProviderReportsAMissingUsageToken() async throws {
  let chain = ChainedClaudeCredentialStore([
    DiscoveredClaudeKeychainStore(account: "me", keychain: try keychain([(baseService, mcpOnlyItem)]).client)
  ])
  let provider = claudeProvider(chain, transport: StubTransport())

  let result = await provider.fetch(now: fixedNow, options: FetchOptions())

  #expect(
    result.outcome
      == .notAuthenticated(
        "Cannot read Claude credentials: Claude Code has not stored a usage token yet; run `claude` once."))
  #expect(provider.credentialState(now: fixedNow) == .missing(ClaudeOAuthCredentials.usageTokenMissingDetail))
}

@Test func discoveredClaudeKeychainKeepsTheConfiguredAccountRegardlessOfExpiry() throws {
  let store = DiscoveredClaudeKeychainStore(
    account: "me",
    keychain: try keychain([
      (baseService, claudeItem(token: "default", expiresAt: fixedNow.addingTimeInterval(3600))),
      (hashedService, claudeItem(token: "work", expiresAt: fixedNow.addingTimeInterval(7200))),
    ]).client)

  let found = try #require(try store.loadWithSource())

  #expect(found.credentials.accessToken == "default")
  #expect(
    found.source
      == CredentialSource(
        id: "claude.keychain:\(baseService)", provider: .claude, title: "Claude Code Keychain",
        detail: "2 accounts found; showing the default configuration"))
  #expect(try store.accounts().map(\.label) == ["the default configuration", hashedLabel])
  #expect(
    try store.accounts().map(\.source.id) == ["claude.keychain:\(baseService)", "claude.keychain:\(hashedService)"])
  #expect(try store.accounts()[1].source.detail == "Keychain item \(hashedService)")
}

@Test func discoveredClaudeKeychainDoesNotSwitchAccountsWhenExpiryIsUnknown() throws {
  let store = DiscoveredClaudeKeychainStore(
    account: "me",
    keychain: try keychain([
      (baseService, claudeItem(token: "default", expiresAt: nil)),
      (hashedService, claudeItem(token: "work", expiresAt: fixedNow)),
    ]).client)

  #expect(try store.load()?.accessToken == "default")
}

@Test func discoveredClaudeKeychainKeepsTheEarlierAccountOnATie() throws {
  let store = DiscoveredClaudeKeychainStore(
    account: "me",
    keychain: try keychain([
      (baseService, claudeItem(token: "default", expiresAt: fixedNow)),
      (hashedService, claudeItem(token: "work", expiresAt: fixedNow)),
    ]).client)

  #expect(try store.load()?.accessToken == "default")
}

@Test func discoveredClaudeKeychainIdentifiesTheSelectedServiceForASingleAccount() throws {
  let store = DiscoveredClaudeKeychainStore(
    account: "me", keychain: try keychain([(hashedService, claudeItem(token: "work", expiresAt: nil))]).client)

  let found = try #require(try store.loadWithSource())

  #expect(found.credentials.accessToken == "work")
  #expect(found.source == ClaudeKeychainAccount(service: hashedService, credentials: found.credentials).source)
  #expect(store.credentialHealth(now: fixedNow) == .valid(source: found.source, expiresAt: nil))
}

@Test func discoveredClaudeKeychainListsTheConfiguredServiceFirst() throws {
  let store = DiscoveredClaudeKeychainStore(
    service: hashedService, account: "me",
    keychain: try keychain([
      (baseService, claudeItem(token: "default", expiresAt: nil)),
      (hashedService, claudeItem(token: "work", expiresAt: nil)),
    ]).client)

  #expect(try store.accounts().map(\.service) == [hashedService, baseService])
}

@Test func discoveredClaudeKeychainReturnsNothingWithoutItems() throws {
  let store = DiscoveredClaudeKeychainStore(account: "me", keychain: MemoryKeychain().client)

  #expect(try store.loadWithSource() == nil)
  #expect(try store.accounts().isEmpty)
  #expect(store.description == "Keychain Claude Code-credentials, plus any Claude Code-credentials* item")
  #expect(store.source.id == "claude.keychain")
}

@Test func discoveredClaudeKeychainReportsAnIncompleteItemWhenNoAccountIsUsable() throws {
  let store = DiscoveredClaudeKeychainStore(
    account: "me", keychain: try keychain([(hashedService, mcpOnlyItem)]).client)

  #expect(try store.accounts().isEmpty)
  #expect(throws: CredentialStoreError.incomplete(ClaudeOAuthCredentials.usageTokenMissingDetail)) {
    try store.load()
  }
}

@Test func discoveredClaudeKeychainPrefersAReadErrorOverAnIncompleteItem() {
  let client = KeychainCredentialClient(
    load: { service, account in
      guard service == hashedService else { throw CredentialStoreError.keychain(errSecAuthFailed) }
      return KeychainCredentialItem(data: mcpOnlyItem, account: account)
    },
    save: { _, _, _ in },
    list: { _ in [hashedService] })
  let store = DiscoveredClaudeKeychainStore(account: "me", keychain: client)

  #expect(throws: CredentialStoreError.keychain(errSecAuthFailed)) { try store.load() }
  #expect(throws: CredentialStoreError.keychain(errSecAuthFailed)) { try store.accounts() }
}

@Test func discoveredClaudeKeychainIgnoresAReadErrorWhenAnotherAccountIsUsable() throws {
  let client = KeychainCredentialClient(
    load: { service, account in
      guard service == hashedService else { throw CredentialStoreError.keychain(errSecAuthFailed) }
      return KeychainCredentialItem(data: claudeItem(token: "work", expiresAt: nil), account: account)
    },
    save: { _, _, _ in },
    list: { _ in [hashedService] })
  let store = DiscoveredClaudeKeychainStore(account: "me", keychain: client)

  let found = try #require(try store.loadWithSource())

  #expect(found.credentials.accessToken == "work")
  #expect(found.source == ClaudeKeychainAccount(service: hashedService, credentials: found.credentials).source)
}

@Test func discoveredClaudeKeychainFallsBackToTheConfiguredServiceWhenListingFails() throws {
  let keychain = try keychain([(baseService, claudeItem(token: "default", expiresAt: nil))])
  let client = KeychainCredentialClient(
    load: { try keychain.client.load(service: $0, account: $1) },
    save: { _, _, _ in },
    list: { _ in throw CredentialStoreError.keychain(errSecNotAvailable) })

  #expect(try DiscoveredClaudeKeychainStore(account: "me", keychain: client).load()?.accessToken == "default")
}

@Test func discoveredClaudeKeychainSavesToTheSelectedAccount() throws {
  let keychain = try keychain([
    (baseService, claudeItem(token: "default", expiresAt: fixedNow)),
    (hashedService, claudeItem(token: "work", expiresAt: fixedNow.addingTimeInterval(60))),
  ])
  let store = DiscoveredClaudeKeychainStore(account: "me", keychain: keychain.client)

  try store.save(ClaudeOAuthCredentials(accessToken: "refreshed", refreshToken: nil, expiresAt: nil))

  #expect(
    try KeychainClaudeCredentialStore(service: hashedService, account: "me", keychain: keychain.client).load()?
      .accessToken == "work")
  #expect(
    try KeychainClaudeCredentialStore(service: baseService, account: "me", keychain: keychain.client).load()?
      .accessToken == "refreshed")
}

@Test func discoveredClaudeKeychainSavesToTheConfiguredServiceWhenNothingIsStored() throws {
  let keychain = MemoryKeychain()
  let store = DiscoveredClaudeKeychainStore(service: hashedService, account: "me", keychain: keychain.client)

  try store.save(ClaudeOAuthCredentials(accessToken: "fresh", refreshToken: nil, expiresAt: nil))

  #expect(try keychain.client.services(prefix: baseService) == [hashedService])
  #expect(try store.load()?.accessToken == "fresh")
}
