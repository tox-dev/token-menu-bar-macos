import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func geminiRefreshReportsTokenEndpointFailures() async {
  let expired = GeminiAuth(
    accessToken: "old", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(-10))
  let transport = StubTransport()
  transport.on(path: "/token", .text("unavailable", status: 503))
  let provider = GeminiProvider(
    auth: MemoryGeminiStore(expired),
    client: APIClient(transport: transport, log: makeLog(), clock: testClock),
    log: makeLog(),
    allowRefresh: { true },
    oauthClient: { GeminiOAuthClient(id: "client", secret: "secret") })

  let result = await provider.fetch(now: fixedNow, options: FetchOptions())

  #expect(result.outcome == .notAuthenticated("Gemini token refresh failed: HTTP 503"))
  #expect(transport.requests(matching: "/token").count == 1)
}

@Test @MainActor func appStateRestoresUnreadableCredentialHealthFromSetup() {
  let state = AppState()
  let source = ProviderID.codex.credentialSource("codex.file")
  state.applySetupStates([
    .codex: ProviderSetupState(
      enabled: true,
      credential: .unreadable(source: source, detail: "auth.json is not JSON"))
  ])

  state.update(.codex) {
    $0.availability = .authenticationRequired
    $0.credentialState = .missing("Cannot read Codex credentials")
    $0.credentialHealth = .unchecked
  }

  let provider = state.state(for: .codex)
  #expect(provider.credentialHealth == .unreadable(source: source, detail: "auth.json is not JSON"))
  #expect(provider.recoveryIssue?.kind == .credentialUnreadable)
}

@Test @MainActor func appStateBuildsNeededResourceRecovery() {
  let state = AppState()
  let resource = ProviderID.codex.sandboxResources[0]
  state.applySetupStates([
    .codex: ProviderSetupState(
      enabled: true,
      credential: .missing(expected: ProviderID.codex.setup.credentialSources),
      resources: [ResourceAccessState(resource: resource, health: .needed)])
  ])

  state.update(.codex) { $0.availability = .authenticationRequired }

  let issue = state.state(for: .codex).recoveryIssue
  #expect(issue?.kind == .resourceAccess)
  #expect(issue?.title == "File access needed")
  #expect(issue?.detail == "Grant access to ~/.codex so Codex data can be read.")
  #expect(issue?.action == .grantAccess(resource))
}

@Test @MainActor func coordinatorJoinsSubsetScopeCoveredByActiveRefresh() async throws {
  let gate = TestGate()
  let provider = ScriptedProvider(
    id: .claude,
    results: [ProviderFetchResult(outcome: .success(DemoData.snapshot(.claude, now: fixedNow)))],
    gate: gate)
  let settings = coverageSettings()
  settings.setProvider(.claude, enabled: true)
  let coordinator = RefreshCoordinator(
    registry: ProviderRegistry([provider]),
    settings: settings,
    state: AppState(),
    history: try UsageHistoryStore(url: nil),
    log: makeLog(),
    clock: testClock
  ) { _ in }
  let active = Task {
    await coordinator.refresh(
      RefreshRequest(reason: .userInitiated, usage: .force, providers: [.claude, .codex]))
  }
  while provider.callCount == 0 { await Task.yield() }

  async let covered: Void = coordinator.refresh(
    RefreshRequest(reason: .userInitiated, usage: .force, providers: [.claude]))
  await Task.yield()
  gate.open()
  await covered
  await active.value

  #expect(provider.callCount == 1)
}

@Test @MainActor func coordinatorDisablesUndiscoveredFailedProbe() async throws {
  let issue = ProviderRecoveryIssue(
    kind: .credentialMissing,
    title: "Claude sign-in required",
    detail: "Sign in to Claude.",
    action: .copyCommand("claude"))
  let provider = ScriptedProvider(
    id: .claude,
    results: [
      ProviderFetchResult(
        outcome: .failed("request failed"),
        warnings: ["stale warning"],
        recoveryIssue: issue,
        credentialStatus: ProviderCredentialStatus(
          state: .missing("not signed in"),
          health: .missing(expected: ProviderID.claude.setup.credentialSources)))
    ])
  let state = AppState()
  let coordinator = RefreshCoordinator(
    registry: ProviderRegistry([provider]),
    settings: coverageSettings(),
    state: state,
    history: try UsageHistoryStore(url: nil),
    log: makeLog(),
    clock: testClock
  ) { _ in }

  await coordinator.refresh(
    RefreshRequest(reason: .userInitiated, usage: .force, providers: [.claude]))

  let result = state.state(for: .claude)
  #expect(result.availability == .disabled)
  #expect(result.lastError == nil)
  #expect(result.warnings.isEmpty)
  #expect(result.recoveryIssue == nil)
}

@Test func snapshotPersistenceDefaultCallbacksHandleFailureAndReload() async throws {
  let root = temporaryDirectory()
  let cache = SnapshotCache(url: root.appendingPathComponent("malformed.json"))
  try Data("{".utf8).write(to: cache.url!)
  let widgetStore = WidgetSnapshotStore(url: root.appendingPathComponent("widget.json"))
  let persistence = SnapshotPersistence(cache: cache, widgetStore: widgetStore)

  #expect(await persistence.loadSnapshots().isEmpty)
  await persistence.submitWidget(.placeholder)
  await persistence.flush()

  #expect(widgetStore.read() != nil)
  let workload = await persistence.workload
  #expect(workload.cacheLoads == 1)
  #expect(workload.widgetWrites == 1)
  #expect(workload.widgetReloads == 1)
}

@Test func snapshotPersistenceIgnoresWidgetsWithoutStore() async {
  let persistence = SnapshotPersistence(cache: SnapshotCache(url: nil))

  await persistence.submitWidget(.placeholder)
  await persistence.flush()

  let workload = await persistence.workload
  #expect(workload.widgetSubmissions == 0)
  #expect(workload.widgetWrites == 0)
}

@MainActor
private func coverageSettings() -> Settings {
  Settings(defaults: UserDefaults(suiteName: "coverage-refresh-\(UUID().uuidString)")!)
}
