import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func providerSetupMetadataCoversEveryProvider() {
  for provider in ProviderID.allCases {
    #expect(provider.setup.provider == provider)
    #expect(!provider.setup.signInTitle.isEmpty)
    #expect(!provider.setup.signInDetail.isEmpty)
    #expect(!provider.setup.credentialSources.isEmpty)
    #expect(provider.setup.credentialSources.allSatisfy { $0.provider == provider })
  }
  #expect(ProviderID.codex.setup.signInCommand == "codex login")
  #expect(ProviderID.copilot.setup.signInCommand == "copilot login")
}

@Test func providerSetupPrefersARequiredResourceRecovery() {
  let resource = ProviderID.codex.sandboxResources[0]
  let state = ProviderSetupState.from(
    provider: .codex,
    enabled: true,
    credentialState: .missing("No credential source could be read."),
    source: ProviderID.codex.credentialSource("codex.file"),
    resources: [ResourceAccessState(resource: resource, health: .needed)])
  #expect(state.credential == .missing(expected: ProviderID.codex.setup.credentialSources))
  #expect(state.issue?.kind == .resourceAccess)
  #expect(state.issue?.action == .grantAccess(resource))
}

@Test func providerCredentialHealthExposesOnlyItsActiveSource() {
  let source = ProviderID.codex.credentialSource("codex.file")
  #expect(ProviderCredentialHealth.valid(source: source, expiresAt: fixedNow).source == source)
  #expect(ProviderCredentialHealth.expired(source: source, at: fixedNow).source == source)
  #expect(ProviderCredentialHealth.unreadable(source: source, detail: "broken").source == source)
  #expect(ProviderCredentialHealth.unreadable(source: nil, detail: "broken").source == nil)
  #expect(ProviderCredentialHealth.missing(expected: [source]).source == nil)
  #expect(ProviderCredentialHealth.unchecked.source == nil)
}

@Test func providerRecoveryActionsUseControlSpecificTitles() {
  let resource = ProviderID.codex.sandboxResources[0]
  #expect(ProviderRecoveryAction.copyCommand("codex login").title == "Copy command")
  #expect(ProviderRecoveryAction.checkAgain.title == "Check again")
  #expect(ProviderRecoveryAction.refreshProvider(.codex).title == "Check again")
  #expect(ProviderRecoveryAction.grantAccess(resource).title == "Grant access")
  #expect(ProviderRecoveryAction.openLoginItems.title == "Open Login Items")
  #expect(ProviderRecoveryAction.contactAdministrator.title == "Contact administrator")
}

@Test func providerSetupRetainsLegacyMissingDetailWithoutAResourceFailure() {
  let state = ProviderSetupState.from(
    provider: .codex,
    enabled: true,
    credentialState: .missing("The selected auth.json disappeared."),
    source: ProviderID.codex.credentialSource("codex.file"),
    resources: [])
  #expect(state.issue?.kind == .credentialMissing)
  #expect(state.issue?.detail == "The selected auth.json disappeared.")
  #expect(state.issue?.action == .copyCommand("codex login"))
}

@Test func providerSetupReportsExpiredCredentials() {
  let source = ProviderID.gemini.credentialSource("gemini.file")
  let state = ProviderSetupState.from(
    provider: .gemini,
    enabled: true,
    credential: .expired(source: source, at: fixedNow),
    resources: [])
  #expect(state.issue?.kind == .credentialExpired)
  #expect(state.issue?.title == "Gemini sign-in expired")
  #expect(state.issue?.action == .copyCommand("gemini"))
}

@Test func providerSetupDoesNotRequestAnUnusedResource() {
  let resource = ProviderID.copilot.sandboxResources[0]
  let source = ProviderID.copilot.credentialSource("copilot.environment")
  let state = ProviderSetupState.from(
    provider: .copilot,
    enabled: true,
    credentialState: .valid(expiresAt: nil),
    source: source,
    resources: [ResourceAccessState(resource: resource, health: .needed)])
  #expect(state.credential == .valid(source: source, expiresAt: nil))
  #expect(state.issue == nil)
}

@Test(arguments: [
  (QuotaAvailability.loading, ProviderServiceHealth.checking),
  (.current, .available),
  (.stale, .available),
  (.networkUnavailable, .offline(detail: "detail")),
  (.rateLimited, .rateLimited(retryAt: nil, detail: "detail")),
  (.unavailable, .unavailable(detail: "detail")),
  (.authenticationRequired, .unavailable(detail: "detail")),
  (.disabled, .unchecked),
])
func providerServiceHealthUsesTypedAvailability(
  availability: QuotaAvailability,
  expected: ProviderServiceHealth
) {
  #expect(ProviderServiceHealth.from(availability: availability, detail: "detail") == expected)
}

@Test func providerStateCarriesSetupHealthWithoutReplacingLegacyState() {
  let source = ProviderID.claude.credentialSource("claude.keychain")
  let state = ProviderState(
    availability: .current,
    credentialState: .valid(expiresAt: nil),
    credentialHealth: .valid(source: source, expiresAt: nil),
    serviceHealth: .available)
  #expect(state.credentialState == .valid(expiresAt: nil))
  #expect(state.credentialHealth == .valid(source: source, expiresAt: nil))
  #expect(state.serviceHealth == .available)
}

@Test func unsupportedAccountsHaveATypedRecoveryAction() {
  let issue = ProviderRecoveryIssue.unsupportedAccount(provider: .gemini, detail: "Use a supported account.")
  #expect(issue.kind == .accountUnsupported)
  #expect(issue.action == .copyCommand("gemini"))
}

@MainActor
@Test func disablingAProviderRetainsItsLastKnownData() {
  let state = AppState()
  let snapshot = ProviderSnapshot(provider: .codex, windows: [], fetchedAt: fixedNow)
  let analytics = ProviderAnalytics(provider: .codex, points: [], fetchedAt: fixedNow)
  state.update(.codex) {
    $0.snapshot = snapshot
    $0.analytics = analytics
    $0.lastSuccess = fixedNow
    $0.availability = .current
  }
  state.update(.codex) {
    $0.snapshot = nil
    $0.analytics = nil
    $0.lastSuccess = nil
    $0.availability = .disabled
  }
  #expect(state.state(for: .codex).snapshot == snapshot)
  #expect(state.state(for: .codex).analytics == analytics)
  #expect(state.state(for: .codex).lastSuccess == fixedNow)
}

@MainActor
@Test func disablingAProviderRetainsItsFailureButSuppressesRecovery() {
  let state = AppState()
  let issue = ProviderRecoveryIssue(
    kind: .credentialUnreadable,
    title: "Codex credentials could not be read",
    detail: "auth.json is not JSON",
    action: .checkAgain)
  state.update(.codex) {
    $0.availability = .authenticationRequired
    $0.lastError = "auth.json is not JSON"
    $0.warnings = ["Using the last known quota."]
    $0.credentialState = .missing("Cannot read Codex credentials")
    $0.recoveryIssue = issue
  }
  state.update(.codex) {
    $0.availability = .disabled
    $0.lastError = nil
    $0.warnings = []
    $0.credentialState = nil
    $0.recoveryIssue = nil
  }
  let disabled = state.state(for: .codex)
  #expect(disabled.lastError == "auth.json is not JSON")
  #expect(disabled.warnings == ["Using the last known quota."])
  #expect(disabled.credentialState == .missing("Cannot read Codex credentials"))
  #expect(disabled.recoveryIssue == nil)
}

@MainActor
@Test func legacyMissingStateDoesNotReplaceUnreadableCredentialHealth() {
  let state = AppState()
  let source = ProviderID.codex.credentialSource("codex.file")
  state.applySetupStates([
    .codex: ProviderSetupState.from(
      provider: .codex,
      enabled: true,
      credential: .unreadable(source: source, detail: "auth.json is not JSON"),
      resources: [])
  ])
  state.update(.codex) {
    $0.availability = .authenticationRequired
    $0.credentialState = .missing("Cannot read Codex credentials")
    $0.recoveryIssue = nil
  }
  let provider = state.state(for: .codex)
  #expect(provider.credentialHealth == .unreadable(source: source, detail: "auth.json is not JSON"))
  #expect(provider.recoveryIssue?.kind == .credentialUnreadable)
}

@Test(arguments: [
  (
    CredentialState.missing("not signed in"),
    ProviderCredentialHealth.missing(expected: ProviderID.claude.setup.credentialSources)
  ),
  (
    CredentialState.expired(fixedNow),
    ProviderCredentialHealth.expired(source: ProviderID.claude.setup.credentialSources[0], at: fixedNow)
  ),
  (
    CredentialState.valid(expiresAt: fixedNow),
    ProviderCredentialHealth.valid(source: ProviderID.claude.setup.credentialSources[0], expiresAt: fixedNow)
  ),
])
@MainActor
func appStateMapsLegacyCredentialStates(
  credentialState: CredentialState,
  expected: ProviderCredentialHealth
) {
  let state = AppState()
  state.applySetupStates([.claude: ProviderSetupState(enabled: true)])

  state.update(.claude) { $0.credentialState = credentialState }

  #expect(state.state(for: .claude).credentialHealth == expected)
}

@Test @MainActor func appStatePrefersRequiredResourceRecoveryForAuthentication() {
  let state = AppState()
  let resource = ProviderID.codex.sandboxResources[0]
  state.applySetupStates([
    .codex: ProviderSetupState(
      enabled: true,
      credential: .missing(expected: ProviderID.codex.setup.credentialSources),
      resources: [ResourceAccessState(resource: resource, health: .stale)])
  ])

  state.update(.codex) { $0.availability = .authenticationRequired }

  let issue = state.state(for: .codex).recoveryIssue
  #expect(issue?.kind == .resourceAccess)
  #expect(issue?.title == "Access grant needs renewal")
  #expect(issue?.action == .grantAccess(resource))
}

@Test(arguments: [
  (QuotaAvailability.networkUnavailable, ProviderRecoveryIssue.Kind.network, "The provider could not be reached."),
  (
    QuotaAvailability.rateLimited,
    ProviderRecoveryIssue.Kind.rateLimited,
    "Token Menu Bar will retry after the provider allows another request."
  ),
  (QuotaAvailability.unavailable, ProviderRecoveryIssue.Kind.service, "The provider did not return usable data."),
])
@MainActor
func appStateBuildsServiceRecovery(
  availability: QuotaAvailability,
  kind: ProviderRecoveryIssue.Kind,
  detail: String
) {
  let state = AppState()
  let source = ProviderID.claude.setup.credentialSources[0]
  state.applySetupStates([
    .claude: ProviderSetupState(enabled: true, credential: .valid(source: source, expiresAt: nil))
  ])

  state.update(.claude) { $0.availability = availability }

  let issue = state.state(for: .claude).recoveryIssue
  #expect(issue?.kind == kind)
  #expect(issue?.detail == detail)
  #expect(issue?.action == .refreshProvider(.claude))
}

@Test(arguments: [QuotaAvailability.loading, .current, .stale])
@MainActor
func appStateOmitsRecoveryForHealthyAvailability(_ availability: QuotaAvailability) {
  let state = AppState()
  let source = ProviderID.claude.setup.credentialSources[0]
  state.applySetupStates([
    .claude: ProviderSetupState(enabled: true, credential: .valid(source: source, expiresAt: nil))
  ])

  state.update(.claude) { $0.availability = availability }

  #expect(state.state(for: .claude).recoveryIssue == nil)
}

@Test func credentialInspectionReportsTheWinningSource() throws {
  let first = SourcedCodexStore(auth: nil, sourceID: "first")
  let second = SourcedCodexStore(auth: CodexAuth(accessToken: "token"), sourceID: "second")
  let found = try #require(try ChainedCodexAuthStore([first, second]).loadWithSource())
  #expect(found.auth.accessToken == "token")
  #expect(found.source.id == "second")
}

@Test func credentialInspectionReportsReadFailures() {
  let store = MemoryGeminiStore(nil)
  store.loadError = CredentialStoreError.malformed("broken")
  #expect(
    store.credentialHealth(now: fixedNow)
      == .unreadable(source: store.source, detail: #"malformed("broken")"#))
}

@Test func credentialChainsRetainTheFailingSource() throws {
  let malformed = temporaryDirectory().appendingPathComponent("broken.json")
  try Data("not JSON".utf8).write(to: malformed)

  let claude = FileClaudeCredentialStore(url: malformed)
  let codex = FileCodexAuthStore(url: malformed)
  let gemini = FileGeminiAuthStore(url: malformed)
  let cursor = FileCursorAuthStore(url: malformed)
  let copilot = FileCopilotCLIAuthStore(url: malformed)

  expectUnreadable(
    ChainedClaudeCredentialStore([claude, MemoryClaudeStore(nil)]).credentialHealth(now: fixedNow),
    source: claude.source)
  expectUnreadable(
    ChainedCodexAuthStore([codex, MemoryCodexStore(nil)]).credentialHealth(now: fixedNow),
    source: codex.source)
  expectUnreadable(
    ChainedGeminiAuthStore([gemini, MemoryGeminiStore(nil)]).credentialHealth(now: fixedNow),
    source: gemini.source)
  expectUnreadable(
    ChainedCursorAuthStore([cursor, MemoryCursorStore(nil)]).credentialHealth(now: fixedNow),
    source: cursor.source)
  expectUnreadable(
    ChainedCopilotAuthStore([copilot, MemoryCopilotStore(nil)]).credentialHealth(now: fixedNow),
    source: copilot.source)
}

@Test(arguments: [
  ("", CodexCredentialStorage.automatic),
  (#"cli_auth_credentials_store = "file""#, .file),
  (#"cli_auth_credentials_store='keyring' # secure"#, .keyring),
  (#"cli_auth_credentials_store = "auto""#, .automatic),
  (#"cli_auth_credentials_store = "future""#, .unknown("future")),
  ("[profile.work]\ncli_auth_credentials_store = \"file\"", .automatic),
])
func codexCredentialStorageReadsOnlyTheUserLevelSetting(text: String, expected: CodexCredentialStorage) {
  #expect(CodexCredentialStorageReader.parse(text) == expected)
}

@Test func codexKeychainReaderUsesTheCLIsAccountAndDocument() throws {
  let root = temporaryDirectory().appendingPathComponent(".codex")
  let linked = root.deletingLastPathComponent().appendingPathComponent("codex-link")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
  #expect(KeychainCodexAuthStore.account(codexHome: linked) == KeychainCodexAuthStore.account(codexHome: root))
  #expect(KeychainCodexAuthStore.account(codexHome: root).hasPrefix("cli|"))
  #expect(KeychainCodexAuthStore.account(codexHome: root).count == 20)
  let data = try JSONEncoder().encode(CodexAuth(accessToken: "token").document)
  #expect(try KeychainCodexAuthStore.parse(data)?.accessToken == "token")
  #expect(throws: CredentialStoreError.malformed("Codex Keychain item is not JSON")) {
    try KeychainCodexAuthStore.parse(Data("bad".utf8))
  }
}

@Test func geminiStorageAndKeychainDocumentFollowTheCLIFormats() throws {
  #expect(GeminiCredentialStorage.resolve(environment: [:]) == .file)
  #expect(
    GeminiCredentialStorage.resolve(environment: ["GEMINI_FORCE_ENCRYPTED_FILE_STORAGE": "true"]) == .keychain)
  #expect(
    GeminiCredentialStorage.resolve(environment: ["GEMINI_FORCE_ENCRYPTED_FILE_STORAGE": "TRUE"]) == .file)
  let document: JSONValue = .object([
    "serverName": .string("main-account"),
    "token": .object([
      "accessToken": .string("access"),
      "refreshToken": .string("refresh"),
      "expiresAt": .number(1_900_000_000_000),
    ]),
  ])
  let data = try JSONEncoder().encode(document)
  let auth = try #require(try KeychainGeminiAuthStore.parse(data))
  #expect(auth.accessToken == "access")
  #expect(auth.refreshToken == "refresh")
  #expect(auth.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
}

@Test func geminiKeychainRefreshPreservesWrapperMetadata() throws {
  let document: JSONValue = .object([
    "futureTopLevel": .string("keep"),
    "serverName": .string("main-account"),
    "token": .object([
      "accessToken": .string("old"),
      "expiresAt": .number(1_900_000_000_000),
      "futureTokenField": .string("keep"),
      "refreshToken": .string("refresh"),
      "scope": .string("openid profile"),
      "tokenType": .string("Bearer"),
    ]),
  ])
  let auth = try #require(GeminiAuth(document: document))
  let refreshed = auth.refreshed(accessToken: "new", expiresIn: 3600, idToken: nil, now: fixedNow)
  let saved = KeychainGeminiAuthStore.document(for: refreshed, updatedAt: fixedNow)

  #expect(saved["futureTopLevel"] == .string("keep"))
  #expect(saved["token"]?["accessToken"] == .string("new"))
  #expect(saved["token"]?["futureTokenField"] == .string("keep"))
  #expect(saved["token"]?["refreshToken"] == .string("refresh"))
  #expect(saved["token"]?["scope"] == .string("openid profile"))
  #expect(saved["token"]?["tokenType"] == .string("Bearer"))
  #expect(saved["updatedAt"] == .number(fixedNow.timeIntervalSince1970 * 1000))
}

@Test func credentialBackedResourcesAreNotRequired() {
  let source = ProviderID.copilot.credentialSource("copilot.environment")
  let resources = ProviderID.copilot.sandboxResources.map(ResourceAccessState.notRequired)
  let state = ProviderSetupState.from(
    provider: .copilot,
    enabled: true,
    credential: .valid(source: source, expiresAt: nil),
    resources: resources)

  #expect(!ProviderID.copilot.needsSandboxResources(for: source))
  #expect(ProviderID.copilot.needsSandboxResources(for: ProviderID.copilot.credentialSource("copilot.keychain")))
  #expect(resources.allSatisfy { !$0.isRequired && $0.health == .notRequired })
  #expect(state.issue == nil)
}

@Test func notRequiredResourcesNeverMaskCredentialRecovery() {
  let resources = ProviderID.copilot.sandboxResources.map(ResourceAccessState.notRequired)
  let state = ProviderSetupState.from(
    provider: .copilot,
    enabled: true,
    credential: .missing(expected: ProviderID.copilot.setup.credentialSources),
    resources: resources)
  #expect(state.issue?.kind == .credentialMissing)
  #expect(state.issue?.action == .copyCommand("copilot login"))
}

@Test func copilotCurrentSourcesFollowDocumentedPrecedence() throws {
  let environment = EnvironmentCopilotAuthStore(environment: [
    "COPILOT_GITHUB_TOKEN": "copilot", "GH_TOKEN": "gh", "GITHUB_TOKEN": "github", "GH_HOST": "ghe.example",
  ])
  #expect(try environment.load() == CopilotAuth(token: "copilot", host: "ghe.example"))
  #expect(
    CopilotCredentialStorageReader.detect(
      environmentTokenExists: true,
      keychainItemExists: true,
      cliFileExists: true,
      legacyFileExists: true) == .environment)
  #expect(
    CopilotCredentialStorageReader.detect(
      environmentTokenExists: false,
      keychainItemExists: false,
      cliFileExists: true,
      legacyFileExists: true) == .cliFile)
  #expect(CopilotCredentialStorageReader.detect(keychainItemExists: true, legacyFileExists: true) == .cliKeychain)
  #expect(CopilotCredentialStorageReader.detect(keychainItemExists: false, legacyFileExists: true) == .legacyFile)
  #expect(CopilotCredentialStorageReader.detect(keychainItemExists: false, legacyFileExists: false) == .missing)
}

@Test func copilotCLIConfigReadsPlaintextFallbackAndKeychainAccounts() throws {
  let url = temporaryDirectory().appendingPathComponent("config.json")
  try Data(
    #"{"loggedInUsers":{"https://github.com":{"login":"octo","token":"plain"},"https://corp.ghe.com":"ada"}}"#
      .utf8
  ).write(to: url)
  let store = FileCopilotCLIAuthStore(url: url)
  #expect(try store.load() == CopilotAuth(token: "plain", user: "octo", host: "github.com"))
  #expect(store.keychainAccounts() == ["https://corp.ghe.com:ada", "https://github.com:octo"])
  #expect(try KeychainCopilotAuthStore.parse(Data("token".utf8), account: "octo")?.token == "token")
  #expect(
    try KeychainCopilotAuthStore.parse(Data("enterprise".utf8), account: "https://corp.ghe.com:ada")
      == CopilotAuth(token: "enterprise", user: "ada", host: "corp.ghe.com"))
  let json = Data(#"{"oauth_token":"json-token","user":"hubot","host":"github.com"}"#.utf8)
  #expect(try KeychainCopilotAuthStore.parse(json, account: nil) == CopilotAuth(token: "json-token", user: "hubot"))
}

@Test func credentialRefreshSaveDoesNotOverwriteAChangedSource() throws {
  let original = ClaudeOAuthCredentials(accessToken: "old", refreshToken: "refresh", expiresAt: fixedNow)
  let current = ClaudeOAuthCredentials(accessToken: "cli", refreshToken: "new", expiresAt: nil)
  let refreshed = original.refreshed(accessToken: "app", refreshToken: nil, expiresIn: 3600, now: fixedNow)
  let store = MemoryClaudeStore(original)
  try store.save(current)
  guard case .changed(let found, let source) = try store.save(refreshed, replacing: original) else {
    Issue.record("expected the changed credential")
    return
  }
  #expect(found == current)
  #expect(source == store.source)
  #expect(try store.load() == current)
}

@Test func codexRefreshSaveDoesNotOverwriteAChangedSource() throws {
  let originalCodex = CodexAuth(accessToken: "old")
  let currentCodex = CodexAuth(accessToken: "cli")
  let codex = MemoryCodexStore(originalCodex)
  try codex.save(currentCodex)
  guard
    case .changed(let foundCodex, let source) = try codex.save(
      CodexAuth(accessToken: "app"), replacing: originalCodex)
  else {
    Issue.record("expected the changed Codex credential")
    return
  }
  #expect(foundCodex == currentCodex)
  #expect(source == codex.source)
}

@Test func geminiRefreshSaveDoesNotOverwriteAChangedSource() throws {
  let originalGemini = GeminiAuth(accessToken: "old")
  let currentGemini = GeminiAuth(accessToken: "cli")
  let gemini = MemoryGeminiStore(originalGemini)
  try gemini.save(currentGemini)
  guard
    case .changed(let foundGemini, let source) = try gemini.save(
      GeminiAuth(accessToken: "app"), replacing: originalGemini)
  else {
    Issue.record("expected the changed Gemini credential")
    return
  }
  #expect(foundGemini == currentGemini)
  #expect(source == gemini.source)
}

private struct SourcedCodexStore: CodexAuthStore {
  let auth: CodexAuth?
  let sourceID: String

  var description: String { sourceID }
  var source: CredentialSource {
    CredentialSource(id: sourceID, provider: .codex, title: sourceID, detail: sourceID)
  }

  func load() throws -> CodexAuth? { auth }
  func save(_ auth: CodexAuth) throws {}
}

private func expectUnreadable(_ health: ProviderCredentialHealth, source: CredentialSource) {
  guard case .unreadable(let found, _) = health else {
    Issue.record("expected unreadable credential health")
    return
  }
  #expect(found == source)
}
