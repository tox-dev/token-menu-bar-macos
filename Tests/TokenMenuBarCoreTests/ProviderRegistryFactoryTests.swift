import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func providerRegistryFactoryDerivesSandboxRequirementsFromCredentialSources() {
  let all = Set(ProviderID.allSandboxResources)
  #expect(ProviderRegistryFactory.resourcesRequiringSandboxAccess(environment: [:]) == all)

  let token = ProviderRegistryFactory.resourcesRequiringSandboxAccess(
    environment: ["COPILOT_GITHUB_TOKEN": "token"])
  #expect(token == all.subtracting(ProviderID.copilot.sandboxResources))
  #expect(
    ProviderRegistryFactory.resourcesRequiringSandboxAccess(environment: ["COPILOT_GITHUB_TOKEN": ""]) == all)
}

@Test @MainActor func providerRegistryFactoryBuildsExactCredentialChainsAndSetup() async throws {
  let root = temporaryDirectory()
  let home = root.appendingPathComponent("home")
  let support = root.appendingPathComponent("support")
  let environment = [
    "CLAUDE_CONFIG_DIR": home.appendingPathComponent(".claude").path,
    "COPILOT_GITHUB_TOKEN": "copilot-token",
  ]
  let resourceURLs = providerResourceURLs(home: home, environment: environment)
  try prepareProviderCredentials(resourceURLs: resourceURLs)

  let codexResource = ProviderID.codex.sandboxResources[0]
  let codexAccess = ResourceAccessState(resource: codexResource, health: .granted)
  let transport = StubTransport()
  let registry = ProviderRegistryFactory.make(
    configuration: ProviderRegistryFactory.Configuration(
      home: home,
      supportDirectory: support,
      environment: environment,
      userName: "factory-test-\(UUID().uuidString)",
      resourceURLs: resourceURLs,
      resourceAccess: [.codex: [codexAccess]],
      enabledProviders: Set(ProviderID.allCases).subtracting([.gemini]),
      keychain: MemoryKeychain().client,
      allowTokenRefresh: { false }),
    client: APIClient(transport: transport, log: makeLog()),
    log: makeLog())

  #expect(registry.ids == ProviderID.allCases.sorted())
  #expect(registry.setupStates[.codex]?.resources == [codexAccess])
  #expect(registry.setupStates[.gemini]?.enabled == false)
  #expect(
    registry[.codex]?.credentialDescription
      == resourceURLs[codexResource.id]!.appendingPathComponent("auth.json").path)

  let expectedSources: [ProviderID: String] = [
    .claude: "claude.file",
    .codex: "codex.file",
    .copilot: "copilot.environment",
    .cursor: "cursor.agent",
    .gemini: "gemini.file",
  ]
  for (providerID, sourceID) in expectedSources {
    let provider = try #require(registry[providerID])
    let health = await provider.credentialHealth(now: fixedNow)
    #expect(health.source?.id == sourceID)
  }

  let claude = try #require(registry[.claude])
  _ = await claude.fetch(now: fixedNow, options: FetchOptions())
  #expect(transport.requests.isEmpty)
}

@Test @MainActor func providerRegistryFactoryFollowsKeychainStoragePolicies() {
  let root = temporaryDirectory()
  let home = root.appendingPathComponent("home")
  let environment = ["GEMINI_FORCE_ENCRYPTED_FILE_STORAGE": "true"]
  let registry = ProviderRegistryFactory.make(
    configuration: ProviderRegistryFactory.Configuration(
      home: home,
      supportDirectory: root.appendingPathComponent("support"),
      environment: environment,
      userName: "factory-test",
      resourceURLs: [:],
      enabledProviders: Set(ProviderID.allCases),
      keychain: MemoryKeychain().client,
      allowTokenRefresh: { true }),
    client: APIClient(transport: StubTransport(), log: makeLog()),
    log: makeLog())

  let codexHome = ProviderID.codex.sandboxResources[0].configuredURL(environment: environment, home: home)
  let codexDescription = [
    KeychainCodexAuthStore(codexHome: codexHome, keychain: .empty).description,
    FileCodexAuthStore(url: codexHome.appendingPathComponent("auth.json")).description,
  ].joined(separator: ", ")
  let geminiHome = ProviderID.gemini.sandboxResources[0].configuredURL(environment: environment, home: home)
  let geminiDescription = [
    KeychainGeminiAuthStore(keychain: .empty).description,
    FileGeminiAuthStore(url: geminiHome.appendingPathComponent("oauth_creds.json")).description,
  ].joined(separator: ", ")

  #expect(registry[.codex]?.credentialDescription == codexDescription)
  #expect(registry[.gemini]?.credentialDescription == geminiDescription)
}

@Test @MainActor func providerRegistryFactoryResolvesGeminiOAuthWhenItsProviderRefreshes() async throws {
  let root = temporaryDirectory()
  let home = root.appendingPathComponent("home")
  let support = root.appendingPathComponent("support")
  let environment = [
    "GEMINI_OAUTH_CLIENT_ID": "factory-client",
    "GEMINI_OAUTH_CLIENT_SECRET": "factory-secret",
  ]
  let resourceURLs = providerResourceURLs(home: home, environment: environment)
  let geminiHome = resourceURLs[ProviderID.gemini.sandboxResources[0].id]!
  try FileManager.default.createDirectory(at: geminiHome, withIntermediateDirectories: true)
  let expired = GeminiAuth(
    accessToken: "expired",
    refreshToken: "refresh",
    expiresAt: fixedNow.addingTimeInterval(-60))
  try JSONEncoder().encode(expired.document).write(to: geminiHome.appendingPathComponent("oauth_creds.json"))
  let transport = StubTransport()
  transport.on(path: "/token", .text("unavailable", status: 503))
  let registry = ProviderRegistryFactory.make(
    configuration: ProviderRegistryFactory.Configuration(
      home: home,
      supportDirectory: support,
      environment: environment,
      userName: "factory-gemini",
      resourceURLs: resourceURLs,
      enabledProviders: [.gemini],
      keychain: MemoryKeychain().client,
      allowTokenRefresh: { true }),
    client: APIClient(transport: transport, log: makeLog()),
    log: makeLog())
  let provider = try #require(registry[.gemini])

  let result = await provider.fetch(now: fixedNow, options: FetchOptions())

  #expect(result.outcome == .notAuthenticated("Gemini token refresh failed: HTTP 503"))
  #expect(transport.requests(matching: "/token").count == 1)
}

@Test @MainActor func providerRegistryFactoryTransfersResourceLeaseOwnership() throws {
  let root = temporaryDirectory()
  let probe = RegistryLeaseProbe()
  var lease: SecurityScopedResourceLease? = SecurityScopedResourceLease(url: root, stop: probe.release)
  var configuration: ProviderRegistryFactory.Configuration? = ProviderRegistryFactory.Configuration(
    home: root,
    supportDirectory: root.appendingPathComponent("support"),
    environment: [:],
    userName: "factory-test",
    resourceURLs: [:],
    resourceLeases: [try #require(lease)],
    enabledProviders: Set(ProviderID.allCases),
    keychain: MemoryKeychain().client,
    allowTokenRefresh: { false })
  var registry: ProviderRegistry? = ProviderRegistryFactory.make(
    configuration: try #require(configuration),
    client: APIClient(transport: StubTransport(), log: makeLog()),
    log: makeLog())

  configuration = nil
  lease = nil
  #expect(registry?.ids.count == ProviderID.allCases.count)
  #expect(probe.releases == 0)
  registry = nil
  #expect(probe.releases == 1)
}

private func providerResourceURLs(home: URL, environment: [String: String]) -> [String: URL] {
  Dictionary(
    uniqueKeysWithValues: ProviderID.allSandboxResources.map {
      ($0.id, $0.configuredURL(environment: environment, home: home))
    })
}

private func prepareProviderCredentials(resourceURLs: [String: URL]) throws {
  for resource in ProviderID.allSandboxResources {
    let url = resourceURLs[resource.id]!
    try FileManager.default.createDirectory(
      at: resource.kind == .file ? url.deletingLastPathComponent() : url,
      withIntermediateDirectories: true)
  }

  let claudeHome = resourceURLs[ProviderID.claude.sandboxResources[0].id]!
  let claude = ClaudeOAuthCredentials(
    accessToken: "claude-token", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(-1))
  try JSONEncoder().encode(claude.document).write(to: claudeHome.appendingPathComponent(".credentials.json"))

  let codexHome = resourceURLs[ProviderID.codex.sandboxResources[0].id]!
  let codex = CodexAuth(accessToken: "codex-token")
  try JSONEncoder().encode(codex.document).write(to: codexHome.appendingPathComponent("auth.json"))
  try Data(#"cli_auth_credentials_store = "file""#.utf8).write(to: codexHome.appendingPathComponent("config.toml"))

  let geminiHome = resourceURLs[ProviderID.gemini.sandboxResources[0].id]!
  let gemini = GeminiAuth(accessToken: "gemini-token", expiresAt: fixedNow.addingTimeInterval(3600))
  try JSONEncoder().encode(gemini.document).write(to: geminiHome.appendingPathComponent("oauth_creds.json"))

  let cursorHome = resourceURLs[ProviderID.cursor.sandboxResources[1].id]!
  try Data(#"{"accessToken":"cursor-token"}"#.utf8).write(to: cursorHome.appendingPathComponent("auth.json"))
}

private final class RegistryLeaseProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var releases: Int { lock.withLock { count } }

  func release(_: URL) {
    lock.withLock { count += 1 }
  }
}
