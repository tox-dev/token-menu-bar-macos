import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func providerActivationDiscoversCredentialsAndData() {
  let source = ProviderID.claude.setup.credentialSources[0]
  let snapshot = DemoData.snapshot(.claude, now: Date(timeIntervalSince1970: 1_000))
  let analytics = ProviderAnalytics(provider: .claude, points: [], fetchedAt: snapshot.fetchedAt)
  let discovered = [
    ProviderState(credentialHealth: .valid(source: source, expiresAt: nil)),
    ProviderState(credentialState: .valid(expiresAt: nil)),
    ProviderState(snapshot: snapshot),
    ProviderState(analytics: analytics),
  ]

  for state in discovered {
    #expect(ProviderSettingsVisibility.discovered(state))
  }
}

@Test func providerActivationRejectsMissingOrUnknownCredentialsWithoutData() {
  let expected = ProviderID.claude.setup.credentialSources
  #expect(!ProviderSettingsVisibility.discovered(nil))
  #expect(!ProviderSettingsVisibility.discovered(ProviderState()))
  #expect(!ProviderSettingsVisibility.discovered(ProviderState(credentialHealth: .missing(expected: expected))))
  #expect(
    !ProviderSettingsVisibility.discovered(
      ProviderState(credentialHealth: .expired(source: expected[0], at: fixedNow))))
  #expect(
    !ProviderSettingsVisibility.discovered(
      ProviderState(credentialHealth: .unreadable(source: expected[0], detail: "permission denied"))))
  #expect(
    !ProviderSettingsVisibility.discovered(
      ProviderState(credentialHealth: .unreadable(source: nil, detail: "credential store unavailable"))))
}

@Test func providerSettingsHideConfiguredAuthenticationFailuresUntilShowAllIsEnabled() {
  let state = ProviderState(
    credentialHealth: .expired(source: ProviderID.gemini.setup.credentialSources[0], at: fixedNow))

  #expect(
    ProviderSettingsVisibility.providers(
      states: [.gemini: state], configured: [.gemini], showAll: false
    ).isEmpty)
  #expect(
    ProviderSettingsVisibility.providers(
      states: [.gemini: state], configured: [.gemini], showAll: true
    ) == ProviderID.allCases)
}

@Test @MainActor func providerActivationRequiresDiscoveryAndHonorsExplicitOverrides() {
  let defaults = UserDefaults(suiteName: "ProviderActivationTests.overrides")!
  defaults.removePersistentDomain(forName: "ProviderActivationTests.overrides")
  let settings = Settings(defaults: defaults)
  let discovered = ProviderState(snapshot: DemoData.snapshot(.claude, now: Date()))

  #expect(settings.isProviderActive(.claude, state: discovered))
  settings.setProvider(.claude, enabled: false)
  #expect(!settings.isProviderActive(.claude, state: discovered))
  settings.setProvider(.claude, enabled: true)
  #expect(settings.isProviderActive(.claude, state: discovered))
  #expect(!settings.isProviderActive(.claude, state: nil))
}

@Test @MainActor func providerActivationMigratesLegacySelectionsToExplicitOverrides() throws {
  let name = "ProviderActivationTests.legacy"
  let defaults = UserDefaults(suiteName: name)!
  defaults.removePersistentDomain(forName: name)
  defaults.set(try JSONEncoder().encode(Set([ProviderID.codex])), forKey: "enabledProviders")

  let settings = Settings(defaults: defaults)

  #expect(settings.providerOverride(for: .codex) == true)
  #expect(settings.providerOverride(for: .claude) == false)
}

@Test @MainActor func providerActivationResetReturnsEveryProviderToAutomaticDiscovery() {
  let defaults = UserDefaults(suiteName: "ProviderActivationTests.reset")!
  defaults.removePersistentDomain(forName: "ProviderActivationTests.reset")
  let settings = Settings(defaults: defaults)
  settings.setProvider(.claude, enabled: false)
  settings.showAllProviders = true

  settings.resetToDefaults()

  #expect(settings.providerOverride(for: .claude) == nil)
  #expect(!settings.showAllProviders)
}

@Test @MainActor func configuredProviderSettingsRetainRowsWithoutChangingAutomaticActivation() {
  let defaults = UserDefaults(suiteName: "ProviderActivationTests.configuration")!
  defaults.removePersistentDomain(forName: "ProviderActivationTests.configuration")
  let settings = Settings(defaults: defaults)

  settings.setRefreshInterval(300, for: .gemini)

  #expect(settings.configuredProviderSettings.contains(.gemini))
  #expect(settings.providerOverride(for: .gemini) == nil)
  #expect(!settings.isProviderActive(.gemini, state: nil))
}

@Test func providerRediscoveryPolicyThrottlesApplicationActivation() {
  var policy = ProviderRediscoveryPolicy(activationInterval: 60)
  let first = policy.begin(.applicationActivated, at: fixedNow)
  let throttled = policy.begin(.applicationActivated, at: fixedNow.addingTimeInterval(59))
  let boundary = policy.begin(.applicationActivated, at: fixedNow.addingTimeInterval(60))

  #expect(first)
  #expect(!throttled)
  #expect(boundary)
}

@Test func providerRediscoveryPolicyRecordsStartupDiscovery() {
  var policy = ProviderRediscoveryPolicy(activationInterval: 60)
  policy.recordDiscovery(at: fixedNow)
  let allowed = policy.begin(.applicationActivated, at: fixedNow.addingTimeInterval(1))

  #expect(!allowed)
}

@Test func providerRediscoveryPolicyAlwaysAllowsManualRefresh() {
  var policy = ProviderRediscoveryPolicy(activationInterval: 60, lastDiscoveryAt: fixedNow)
  let first = policy.begin(.userInitiated, at: fixedNow.addingTimeInterval(1))
  let second = policy.begin(.userInitiated, at: fixedNow.addingTimeInterval(2))

  #expect(first)
  #expect(second)
}

@Test func providerRediscoveryPolicyRecoversFromAClockRollback() {
  var policy = ProviderRediscoveryPolicy(activationInterval: 60, lastDiscoveryAt: fixedNow)
  let allowed = policy.begin(.applicationActivated, at: fixedNow.addingTimeInterval(-1))

  #expect(allowed)
}

@Test func providerDiscoveryReadsCredentialProvenanceWithoutFetching() async {
  let source = ProviderID.claude.setup.credentialSources[0]
  let health = ProviderCredentialHealth.valid(source: source, expiresAt: fixedNow)
  let probe = ProviderDiscoveryProbe(health: health)
  let resource = ResourceAccessState(resource: ProviderID.claude.sandboxResources[0], health: .granted)
  let registry = ProviderRegistry(
    [ProviderDiscoveryTestProvider(probe: probe)],
    setupStates: [.claude: ProviderSetupState(enabled: true, resources: [resource])])

  let discovery = await ProviderDiscoverySnapshot.inspect(registry, now: fixedNow)

  #expect(discovery.providerIDs == [.claude])
  #expect(discovery.credentials == [.claude: health])
  #expect(discovery.resources == [.claude: [resource]])
  #expect(await probe.healthReads == 1)
  #expect(await probe.fetches == 0)
}

@Test func providerDiscoveryMatchesExactCredentialSourcesAndResources() {
  let source = ProviderID.claude.setup.credentialSources[0]
  let health = ProviderCredentialHealth.valid(source: source, expiresAt: fixedNow)
  let resource = ResourceAccessState(resource: ProviderID.claude.sandboxResources[0], health: .granted)
  let discovery = ProviderDiscoverySnapshot(
    providerIDs: [.claude], credentials: [.claude: health], resources: [.claude: [resource]])
  let state = ProviderState(credentialHealth: health, resourceAccess: [resource])

  #expect(!discovery.differs(from: [.claude: state], providerIDs: [.claude]))
}

@Test func providerDiscoveryDetectsACredentialSourceChange() {
  let keychain = ProviderID.claude.setup.credentialSources[0]
  let file = ProviderID.claude.setup.credentialSources[1]
  let discovery = ProviderDiscoverySnapshot(
    providerIDs: [.claude], credentials: [.claude: .valid(source: file, expiresAt: nil)], resources: [:])
  let state = ProviderState(credentialHealth: .valid(source: keychain, expiresAt: nil))

  #expect(discovery.differs(from: [.claude: state], providerIDs: [.claude]))
}

@Test func providerDiscoveryDetectsAResourceChange() {
  let resource = ProviderID.claude.sandboxResources[0]
  let discovery = ProviderDiscoverySnapshot(
    providerIDs: [.claude], credentials: [.claude: .unchecked],
    resources: [.claude: [ResourceAccessState(resource: resource, health: .granted)]])
  let state = ProviderState(
    credentialHealth: .unchecked,
    resourceAccess: [ResourceAccessState(resource: resource, health: .needed)])

  #expect(discovery.differs(from: [.claude: state], providerIDs: [.claude]))
}

@Test func providerDiscoveryDetectsAProviderSetChange() {
  let discovery = ProviderDiscoverySnapshot(providerIDs: [.claude], credentials: [.claude: .unchecked], resources: [:])

  #expect(discovery.differs(from: [.claude: ProviderState()], providerIDs: [.codex]))
}

@Test @MainActor func providerDiscoveryReplacesMissingHealthWithTheExactSource() {
  let state = AppState()
  let file = ProviderID.claude.setup.credentialSources[1]
  state.applySetupStates([
    .claude: ProviderSetupState.from(
      provider: .claude, enabled: false,
      credential: .missing(expected: ProviderID.claude.setup.credentialSources), resources: [])
  ])
  state.update(.claude) { $0.availability = .authenticationRequired }

  state.applySetupStates([
    .claude: ProviderSetupState.from(
      provider: .claude, enabled: true, credential: .valid(source: file, expiresAt: fixedNow), resources: [])
  ])

  #expect(state.state(for: .claude).credentialHealth == .valid(source: file, expiresAt: fixedNow))
  #expect(state.state(for: .claude).credentialState == .valid(expiresAt: fixedNow))
  #expect(state.state(for: .claude).availability == .loading)
  #expect(state.state(for: .claude).recoveryIssue == nil)
}

@Test @MainActor func providerDiscoveryKeepsLastKnownDataWhenCredentialsDisappear() {
  let state = AppState()
  let snapshot = DemoData.snapshot(.claude, now: fixedNow)
  let source = ProviderID.claude.setup.credentialSources[0]
  state.update(.claude) {
    $0.snapshot = snapshot
    $0.availability = .current
    $0.credentialHealth = .valid(source: source, expiresAt: nil)
  }

  state.applySetupStates([
    .claude: ProviderSetupState.from(
      provider: .claude, enabled: false,
      credential: .missing(expected: ProviderID.claude.setup.credentialSources), resources: [])
  ])

  #expect(state.state(for: .claude).snapshot == snapshot)
  #expect(
    state.state(for: .claude).credentialHealth
      == .missing(expected: ProviderID.claude.setup.credentialSources))
  #expect(
    !ProviderSettingsVisibility.discovered(ProviderState(credentialHealth: state.state(for: .claude).credentialHealth)))
}

@Test @MainActor func providerDiscoveryClearsAResolvedResourceIssue() {
  let state = AppState()
  let resource = ProviderID.claude.sandboxResources[0]
  let source = ProviderID.claude.setup.credentialSources[0]
  state.applySetupStates([
    .claude: ProviderSetupState.from(
      provider: .claude, enabled: true, credential: .valid(source: source, expiresAt: nil),
      resources: [ResourceAccessState(resource: resource, health: .needed)])
  ])
  state.update(.claude) {
    $0.recoveryIssue = ProviderRecoveryIssue(
      kind: .resourceAccess, title: "File access needed", detail: "Grant access.",
      action: .grantAccess(resource))
  }

  state.applySetupStates([
    .claude: ProviderSetupState.from(
      provider: .claude, enabled: true, credential: .valid(source: source, expiresAt: nil),
      resources: [ResourceAccessState(resource: resource, health: .granted)])
  ])

  #expect(state.state(for: .claude).resourceAccess == [ResourceAccessState(resource: resource, health: .granted)])
  #expect(state.state(for: .claude).recoveryIssue == nil)
}

@Test @MainActor func providerDiscoveryClearsAResolvedResourceIssueWhileCredentialsRemainUnchecked() {
  let state = AppState()
  let resource = ProviderID.claude.sandboxResources[0]
  state.applySetupStates([
    .claude: ProviderSetupState(
      enabled: true, credential: .unchecked,
      resources: [ResourceAccessState(resource: resource, health: .needed)])
  ])
  #expect(state.state(for: .claude).recoveryIssue?.kind == .resourceAccess)

  state.applySetupStates([
    .claude: ProviderSetupState(
      enabled: true, credential: .unchecked,
      resources: [ResourceAccessState(resource: resource, health: .granted)])
  ])

  #expect(state.state(for: .claude).credentialHealth == .unchecked)
  #expect(state.state(for: .claude).resourceAccess == [ResourceAccessState(resource: resource, health: .granted)])
  #expect(state.state(for: .claude).recoveryIssue == nil)
}

private actor ProviderDiscoveryProbe {
  let health: ProviderCredentialHealth
  private(set) var healthReads = 0
  private(set) var fetches = 0

  init(health: ProviderCredentialHealth) {
    self.health = health
  }

  func readHealth() -> ProviderCredentialHealth {
    healthReads += 1
    return health
  }

  func fetch() -> ProviderFetchResult {
    fetches += 1
    return ProviderFetchResult(outcome: .failed("fetch should not run during discovery"))
  }
}

private struct ProviderDiscoveryTestProvider: UsageProvider {
  let id = ProviderID.claude
  let probe: ProviderDiscoveryProbe
  let pollingPolicy = PollingPolicy(minimumInterval: 60, activeInterval: 60, defaultInterval: 300)

  var credentialDescription: String { "discovery test" }
  func credentialState(now: Date) -> CredentialState { .valid(expiresAt: nil) }
  func credentialHealth(now: Date) async -> ProviderCredentialHealth { await probe.readHealth() }
  func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult { await probe.fetch() }
}
