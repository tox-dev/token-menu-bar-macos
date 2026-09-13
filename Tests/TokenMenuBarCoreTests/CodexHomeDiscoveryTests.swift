import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

private func codexHome(auth: CodexAuth? = nil, config: String? = nil) throws -> URL {
  let home = temporaryDirectory().appendingPathComponent("codex")
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  if let auth { try FileCodexAuthStore(url: home.appendingPathComponent("auth.json")).save(auth) }
  if let config { try Data(config.utf8).write(to: home.appendingPathComponent("config.toml")) }
  return home
}

private func fileStore(_ home: URL) -> CodexHomeAuthStore {
  CodexHomeAuthStore(home: home, store: FileCodexAuthStore(url: home.appendingPathComponent("auth.json")))
}

@Test func codexHomeDiscoveryKeepsTheConfiguredHomeAndExistingDefaults() throws {
  let root = temporaryDirectory()
  let home = root.appendingPathComponent("home")
  let defaults = [home.appendingPathComponent(".codex"), home.appendingPathComponent(".config/codex")]
  for url in defaults { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
  let configured = root.appendingPathComponent("elsewhere")

  #expect(
    CodexHomeDiscovery.homes(configured: configured, home: home).map(\.path) == ([configured] + defaults).map(\.path))
}

@Test func codexHomeDiscoveryDropsDuplicatesAndMissingDirectories() {
  let home = temporaryDirectory().appendingPathComponent("home")
  let configured = home.appendingPathComponent(".codex")

  #expect(CodexHomeDiscovery.homes(configured: configured, home: home) == [configured])
}

@Test(arguments: [
  (#"cli_auth_credentials_store = "file""#, false),
  (#"cli_auth_credentials_store = "keyring""#, true),
  (nil, true),
])
func codexAuthStoresFollowTheConfiguredCredentialStore(config: String?, usesKeychain: Bool) throws {
  let home = try codexHome(config: config)
  let file = FileCodexAuthStore(url: home.appendingPathComponent("auth.json"))
  let expected =
    usesKeychain
    ? "\(KeychainCodexAuthStore(codexHome: home, keychain: .empty).description), \(file.description)"
    : file.description

  #expect(CodexAuthStores.store(codexHome: home, keychain: .empty).description == expected)
}

@Test func codexAuthStoresUseThePlainStoreForASingleHome() throws {
  let root = temporaryDirectory()
  let configured = root.appendingPathComponent("codex")

  let store = CodexAuthStores.discovering(configured: configured, home: root, keychain: .empty)

  #expect(!(store is DiscoveredCodexAuthStore))
  #expect(store.description == CodexAuthStores.store(codexHome: configured, keychain: .empty).description)
}

@Test func codexAuthStoresDiscoverEveryHome() throws {
  let root = temporaryDirectory()
  let home = root.appendingPathComponent("home")
  let defaultHome = home.appendingPathComponent(".codex")
  try FileManager.default.createDirectory(at: defaultHome, withIntermediateDirectories: true)
  let configured = root.appendingPathComponent("elsewhere")

  let store = try #require(
    CodexAuthStores.discovering(configured: configured, home: home, keychain: .empty) as? DiscoveredCodexAuthStore)

  #expect(store.stores.map(\.home.path) == [configured, defaultHome].map(\.path))
  #expect(
    store.description
      == [configured, defaultHome].map { CodexAuthStores.store(codexHome: $0, keychain: .empty).description }
      .joined(separator: ", "))
  #expect(store.source.id == "codex.automatic")
  #expect(
    store.source.detail
      == [configured, defaultHome].map { ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "))
}

@Test func discoveredCodexStoreKeepsTheConfiguredAccountWhenAnotherRefreshes() throws {
  let stale = try codexHome(auth: CodexAuth(accessToken: "stale", lastRefresh: fixedNow.addingTimeInterval(-100)))
  let fresh = try codexHome(auth: CodexAuth(accessToken: "fresh", lastRefresh: fixedNow))
  let store = DiscoveredCodexAuthStore([fileStore(stale), fileStore(fresh)])

  let found = try #require(try store.loadWithSource())

  #expect(found.auth.accessToken == "stale")
  #expect(
    found.source
      == CredentialSource(
        id: "codex.file", provider: .codex, title: "Codex auth.json",
        detail: "2 accounts found; showing \((stale.path as NSString).abbreviatingWithTildeInPath)"))
  #expect(try store.accounts().map(\.home) == [stale, fresh])
}

@Test func discoveredCodexStoreShowsTheAccountEmailWhenTheTokenCarriesOne() throws {
  let signedIn = try codexHome(auth: CodexAuth(document: Fixtures.codexAuth())!)
  let anonymous = try codexHome(auth: CodexAuth(accessToken: "anonymous"))
  let store = DiscoveredCodexAuthStore([fileStore(signedIn), fileStore(anonymous)])

  let found = try #require(try store.loadWithSource())

  #expect(found.auth.email == "user@example.com")
  #expect(found.source.detail == "2 accounts found; showing user@example.com")
}

@Test func discoveredCodexStoreKeepsTheStandardSourceForASingleAccount() throws {
  let home = try codexHome(auth: CodexAuth(accessToken: "only"))
  let store = DiscoveredCodexAuthStore([fileStore(try codexHome()), fileStore(home)])

  #expect(
    store.credentialHealth(now: fixedNow)
      == .valid(source: ProviderID.codex.credentialSource("codex.file"), expiresAt: nil))
}

@Test func discoveredCodexStoreReturnsNothingWhenEveryHomeIsEmpty() throws {
  let store = DiscoveredCodexAuthStore([fileStore(try codexHome()), fileStore(try codexHome())])

  #expect(try store.load() == nil)
  #expect(try store.accounts().isEmpty)
}

@Test func discoveredCodexStoreThrowsWhenNoHomeIsReadable() throws {
  let broken = try codexHome()
  try Data("{".utf8).write(to: broken.appendingPathComponent("auth.json"))
  let store = DiscoveredCodexAuthStore([fileStore(broken), fileStore(try codexHome())])

  #expect(throws: CredentialReadFailure.self) { try store.load() }
  #expect(throws: CredentialReadFailure.self) { try store.accounts() }
}

@Test func discoveredCodexStoreIgnoresAnUnreadableHomeWhenAnotherWorks() throws {
  let broken = try codexHome()
  try Data("{".utf8).write(to: broken.appendingPathComponent("auth.json"))
  let store = DiscoveredCodexAuthStore([
    fileStore(broken), fileStore(try codexHome(auth: CodexAuth(accessToken: "ok"))),
  ])

  #expect(try store.load()?.accessToken == "ok")
}

@Test func discoveredCodexStoreSavesToTheSelectedHome() throws {
  let stale = try codexHome(auth: CodexAuth(accessToken: "stale", lastRefresh: fixedNow.addingTimeInterval(-100)))
  let fresh = try codexHome(auth: CodexAuth(accessToken: "fresh", lastRefresh: fixedNow))
  let store = DiscoveredCodexAuthStore([fileStore(stale), fileStore(fresh)])

  try store.save(CodexAuth(accessToken: "refreshed"))

  #expect(try FileCodexAuthStore(url: fresh.appendingPathComponent("auth.json")).load()?.accessToken == "fresh")
  #expect(try FileCodexAuthStore(url: stale.appendingPathComponent("auth.json")).load()?.accessToken == "refreshed")
}

@Test func discoveredCodexStoreSavesToTheFirstHomeWhenNothingIsStored() throws {
  let first = try codexHome()
  let store = DiscoveredCodexAuthStore([fileStore(first), fileStore(try codexHome())])

  try store.save(CodexAuth(accessToken: "fresh"))

  #expect(try FileCodexAuthStore(url: first.appendingPathComponent("auth.json")).load()?.accessToken == "fresh")
  try DiscoveredCodexAuthStore([]).save(CodexAuth(accessToken: "ignored"))
  #expect(try DiscoveredCodexAuthStore([]).load() == nil)
}
