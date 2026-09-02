import Foundation
import Testing
import TokenMenuBarCore

@Test func coverageClosureDiagnosticMessagesRenderPresentOptionalsAndWarnings() {
  let status = DiagnosticEvent.status(
    StatusDiagnostic(
      action: .retier,
      trigger: "fit",
      buttonFrame: nil,
      oldTier: 1,
      newTier: 2,
      visible: true,
      popoverVisible: false,
      fits: true,
      layoutContext: nil))
  let refresh = DiagnosticEvent.refresh(
    RefreshDiagnostic(
      cycleID: "cycle",
      trigger: "scheduled",
      provider: .codex,
      usagePolicy: "force",
      analyticsPolicy: "skip",
      outcome: .partial,
      durationMilliseconds: 4,
      includeAnalytics: false,
      analyticsReturned: false,
      analyticsPointCount: 0,
      warnings: ["quota delayed"]))

  #expect(status.message.contains("oldTier=1"))
  #expect(status.message.contains("newTier=2"))
  #expect(refresh.message.contains("warning1=\"quota delayed\""))
}

@Test func coverageClosureLogBufferHandlesEmptyAndTruncatedRetainedFiles() async throws {
  #expect(LogLevel.warning < .error)

  let emptyURL = temporaryDirectory().appendingPathComponent("empty.log")
  let empty = LogBuffer(fileURL: emptyURL, clock: testClock)
  #expect(await empty.retainedSnapshot().isEmpty)
  empty.logWarning("persistence warning", category: .persistence)
  empty.flush()
  #expect(await empty.retainedSnapshot().map(\.message) == ["persistence warning"])

  let truncatedURL = temporaryDirectory().appendingPathComponent("truncated.log")
  try Data(repeating: 0x61, count: 64).write(to: truncatedURL)
  let truncated = LogBuffer(fileURL: truncatedURL, clock: testClock, maximumFileBytes: 8)
  #expect(truncated.snapshot.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: truncatedURL.path))
}

@Test func coverageClosureLogBufferRecordsNilDiagnosticGeometry() {
  let log = makeLog()
  log.record(
    .panel(
      PanelDiagnostic(
        action: .open,
        trigger: "test",
        tab: "Usage",
        anchor: nil,
        screenID: "main",
        screenFrame: nil,
        maximum: DiagnosticSize(width: 832, height: 700),
        proposed: DiagnosticSize(width: 832, height: 900),
        clamped: DiagnosticSize(width: 832, height: 700),
        resultFrame: nil,
        appActive: false,
        windowKey: nil,
        windowMain: nil,
        frontmostBundleID: nil)),
    level: .info)
  log.record(
    .status(
      StatusDiagnostic(
        action: .probe,
        trigger: "test",
        buttonFrame: nil,
        oldTier: nil,
        newTier: nil,
        visible: false,
        popoverVisible: false,
        fits: nil,
        layoutContext: nil)),
    level: .warning)
  log.record(
    .refresh(
      RefreshDiagnostic(
        cycleID: "coverage-cycle",
        trigger: "test",
        provider: .codex,
        usagePolicy: "force",
        analyticsPolicy: "force",
        outcome: .success,
        durationMilliseconds: 12,
        includeAnalytics: true,
        analyticsReturned: true,
        analyticsPointCount: 3,
        warnings: [])),
    level: .error)
  log.record(
    .request(
      RequestDiagnostic(
        requestID: "coverage-request",
        operation: "refresh",
        method: "GET",
        status: 200,
        byteCount: 42,
        durationMilliseconds: 7,
        errorDomain: "coverage",
        errorCode: 0)),
    level: .error)

  #expect(log.snapshot.map(\.category) == [.geometry, .status, .refresh, .network])
  #expect(log.snapshot[0].message.contains("screen=main"))
  #expect(!log.snapshot[0].message.contains("anchor="))
}

@Test func coverageClosureNotificationsHandleMissingResetMetadataAndThresholds() {
  let previous = ProviderSnapshot(
    provider: .claude,
    windows: [QuotaWindow(id: "session", label: "Session", group: .session, usedPercent: 70, resetsAt: nil)],
    fetchedAt: fixedNow)
  let crossed = ProviderSnapshot(
    provider: .claude,
    windows: [QuotaWindow(id: "session", label: "Session", group: .session, usedPercent: 80, resetsAt: nil)],
    fetchedAt: fixedNow)
  let threshold = NotificationPlanner.events(
    previous: previous,
    current: crossed,
    previousAvailability: .current,
    currentAvailability: .current,
    provider: .claude,
    settings: NotificationSettings(thresholds: [75]),
    now: fixedNow)
  #expect(threshold.map(\.body) == ["Crossed 75% of the session limit."])
  #expect(threshold[0].id.hasSuffix(":0"))

  let reset = ProviderSnapshot(
    provider: .claude,
    windows: [QuotaWindow(id: "session", label: "Session", group: .session, usedPercent: 5, resetsAt: nil)],
    fetchedAt: fixedNow)
  let resetEvents = NotificationPlanner.events(
    previous: crossed,
    current: reset,
    previousAvailability: .current,
    currentAvailability: .current,
    provider: .claude,
    settings: NotificationSettings(thresholds: []),
    now: fixedNow)
  #expect(resetEvents.map(\.kind) == [.reset])
}

@Test func coverageClosurePaceSummaryDefaultsMissingExpectedUsage() {
  let projected = PaceEstimate(
    status: .ahead,
    expectedPercent: nil,
    ratio: nil,
    projectedExhaustion: fixedNow.addingTimeInterval(3_600))
  let lasting = PaceEstimate(status: .behind, expectedPercent: nil, ratio: nil, projectedExhaustion: nil)

  #expect(projected.summary(now: fixedNow).contains("expected 0%"))
  #expect(lasting.summary(now: fixedNow) == "Under pace (expected 0%); lasts until reset")
}

@Test @MainActor func coverageClosureAppStateRestoresCachedAndExpiredCredentials() {
  let state = AppState()
  let source = ProviderID.codex.credentialSource("codex.file")
  state.update(.codex) {
    $0.snapshot = DemoData.snapshot(.codex, now: fixedNow)
    $0.availability = .authenticationRequired
  }
  state.applySetupStates([
    .codex: ProviderSetupState(
      enabled: true,
      credential: .valid(source: source, expiresAt: fixedNow.addingTimeInterval(3_600)))
  ])
  #expect(state.state(for: .codex).availability == .stale)

  let expiry = fixedNow.addingTimeInterval(-60)
  state.applySetupStates([
    .codex: ProviderSetupState(enabled: true, credential: .expired(source: source, at: expiry))
  ])
  #expect(state.state(for: .codex).credentialState == .expired(expiry))

  state.setStatusLadder([])
  #expect(state.statusLadder == [.empty])
}

@Test @MainActor func coverageClosureAppStateUsesSetupAndProviderRecoveryFallbacks() throws {
  let source = ProviderID.codex.credentialSource("codex.file")
  let custom = ProviderRecoveryIssue(
    kind: .accountUnsupported,
    title: "Unsupported account",
    detail: "Use a supported account.",
    action: .contactAdministrator)
  let customState = AppState()
  customState.applySetupStates([
    .codex: ProviderSetupState(
      enabled: true,
      credential: .valid(source: source, expiresAt: nil),
      issue: custom)
  ])
  customState.update(.codex) { $0.availability = .authenticationRequired }
  #expect(customState.state(for: .codex).recoveryIssue == custom)

  let fallbackState = AppState()
  fallbackState.applySetupStates([
    .codex: ProviderSetupState(enabled: true, credential: .valid(source: source, expiresAt: nil))
  ])
  fallbackState.update(.codex) { $0.availability = .authenticationRequired }
  #expect(fallbackState.state(for: .codex).recoveryIssue == ProviderID.codex.setup.missingCredentialIssue)
}

@Test @MainActor func coverageClosureCoordinatorLogsEveryDetailedFailureOutcome() async throws {
  let cases: [(ProviderFetchResult, String)] = [
    (
      ProviderFetchResult(outcome: .partial(DemoData.snapshot(.codex, now: fixedNow), "partial")),
      "outcome=partial"
    ),
    (ProviderFetchResult(outcome: .notAuthenticated("expired")), "outcome=authentication-required"),
    (ProviderFetchResult(outcome: .networkUnavailable("offline")), "outcome=network-unavailable"),
    (ProviderFetchResult(outcome: .failed("failed")), "outcome=failed"),
  ]

  for (result, expected) in cases {
    let log = makeLog()
    log.debugEnabled = true
    let settings = coverageClosureSettings()
    settings.setProvider(.codex, enabled: true)
    let coordinator = try coverageClosureCoordinator(
      provider: ScriptedProvider(id: .codex, results: [result]), settings: settings, log: log)

    await coordinator.refresh(RefreshRequest(reason: .export, usage: .force, analytics: .skip))

    #expect(log.text.contains("trigger=export"))
    #expect(log.text.contains(expected))
  }
}

@Test @MainActor func coverageClosureCoordinatorRestoresOnlyMissingSnapshotsAndReportsCacheFailure() async throws {
  let root = temporaryDirectory()
  let cached = DemoData.snapshot(.codex, now: fixedNow.addingTimeInterval(600))
  let cache = SnapshotCache(url: root.appendingPathComponent("snapshot.json"))
  try cache.store([.codex: cached])
  let state = AppState()
  let current = DemoData.snapshot(.codex, now: fixedNow)
  state.update(.codex) {
    $0.snapshot = current
    $0.availability = .current
  }
  let settings = coverageClosureSettings()
  settings.setProvider(.codex, enabled: true)
  let coordinator = RefreshCoordinator(
    registry: ProviderRegistry([ScriptedProvider(id: .codex, results: [.init(outcome: .failed("unused"))])]),
    settings: settings,
    state: state,
    history: try UsageHistoryStore(url: nil),
    log: makeLog(),
    clock: testClock,
    cache: cache
  ) { _ in }
  await coordinator.restoreCachedSnapshots()
  #expect(state.state(for: .codex).snapshot?.fetchedAt == current.fetchedAt)

  let malformed = SnapshotCache(url: root.appendingPathComponent("malformed.json"))
  try Data("{".utf8).write(to: malformed.url!)
  let log = makeLog()
  let broken = RefreshCoordinator(
    registry: ProviderRegistry([]),
    settings: coverageClosureSettings(),
    state: AppState(),
    history: try UsageHistoryStore(url: nil),
    log: log,
    clock: testClock,
    cache: malformed
  ) { _ in }
  await broken.restoreCachedSnapshots()
  #expect(log.text.contains("snapshot cache load failed"))
}

@Test @MainActor func coverageClosureCoordinatorPreservesRateLimitStrikesAcrossRegistryReplacement() async throws {
  let first = ScriptedProvider(
    id: .codex,
    results: [ProviderFetchResult(outcome: .rateLimited("busy", retryAfter: 60))])
  let settings = coverageClosureSettings()
  settings.setProvider(.codex, enabled: true)
  let state = AppState()
  let coordinator = RefreshCoordinator(
    registry: ProviderRegistry([first]),
    settings: settings,
    state: state,
    history: try UsageHistoryStore(url: nil),
    log: makeLog(),
    clock: testClock
  ) { _ in }
  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force, providers: [.codex]))
  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force, providers: [.codex]))
  #expect(first.callCount == 1)

  let second = ScriptedProvider(
    id: .codex,
    results: [ProviderFetchResult(outcome: .rateLimited("busy", retryAfter: 60))])
  coordinator.replaceRegistry(ProviderRegistry([second]))
  state.update(.codex) {
    $0.availability = .current
    $0.retryNotBefore = nil
  }
  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force, providers: [.codex]))

  #expect(second.callCount == 1)
  #expect(coordinator.nextAttempt(for: .codex) == fixedNow.addingTimeInterval(240))
}

@Test @MainActor func coverageClosureCoordinatorCanSkipWidgetAndAdaptiveWidthPublication() throws {
  let settings = coverageClosureSettings()
  settings.adaptiveWidth = false
  let state = AppState()
  let coordinator = RefreshCoordinator(
    registry: ProviderRegistry([]),
    settings: settings,
    state: state,
    history: try UsageHistoryStore(url: nil),
    log: makeLog(),
    clock: testClock
  ) { _ in }
  var publications = 0
  coordinator.widgetSink = { _ in publications += 1 }
  let initialPublications = publications

  coordinator.rebuildStatus(now: fixedNow, publishWidget: false)

  #expect(state.statusLadder.count == 1)
  #expect(publications == initialPublications)
}

@Test @MainActor func coverageClosureCoordinatorLoopDoesNotRetainItsOwner() async throws {
  let provider = ScriptedProvider(
    id: .codex,
    results: [ProviderFetchResult(outcome: .success(DemoData.snapshot(.codex, now: fixedNow)))])
  let settings = coverageClosureSettings()
  settings.setProvider(.codex, enabled: true)
  var coordinator: RefreshCoordinator? = try coverageClosureCoordinator(provider: provider, settings: settings)
  weak let released = coordinator
  coordinator?.start()
  coordinator = nil

  await Task.yield()

  #expect(released == nil)
  #expect(provider.callCount == 0)
}

@Test func coverageClosureSnapshotPersistenceCachesLoadsAndCoalescesWidgets() async throws {
  let root = temporaryDirectory()
  let cache = SnapshotCache(url: root.appendingPathComponent("snapshot.json"))
  let failures = CoverageClosureFailureRecorder()
  try Data("{".utf8).write(to: cache.url!)
  let persistence = SnapshotPersistence(
    cache: cache,
    widgetStore: WidgetSnapshotStore(url: root.appendingPathComponent("widget.json"))
  ) { await failures.record($0.message) }

  #expect(await persistence.loadSnapshots().isEmpty)
  #expect(await persistence.loadSnapshots().isEmpty)
  await withTaskGroup(of: Void.self) { group in
    for offset in 0..<100 {
      group.addTask {
        await persistence.submitWidget(
          WidgetSnapshot(
            rows: [], attention: offset.isMultiple(of: 2),
            updatedAt: fixedNow.addingTimeInterval(Double(offset))))
      }
    }
  }
  await persistence.flush()

  #expect(await failures.messages.first?.hasPrefix("snapshot cache load failed:") == true)
  let workload = await persistence.workload
  #expect(workload.cacheLoads == 1)
  #expect(workload.coalescedWidgetSubmissions > 0)
}

@Test func coverageClosureStatusLabelsAndTagsHandleEverySemanticFallback() {
  let labels: [(ProviderID, QuotaWindow, String)] = [
    (.claude, coverageClosureWindow(id: "opus", label: "Opus"), "OP"),
    (.claude, coverageClosureWindow(id: "haiku", label: "Haiku"), "HA"),
    (.codex, coverageClosureWindow(id: "flash", label: "Flash"), "FLA"),
    (.copilot, coverageClosureWindow(id: "completion", label: "Completion"), "GHX"),
    (.copilot, coverageClosureWindow(id: "chat", label: "Chat"), "GHC"),
  ]
  for (provider, window, expected) in labels {
    #expect(StatusItemBuilder.defaultShortLabel(provider: provider, window: window) == expected)
  }

  #expect(StatusTemplate.windowTag(coverageClosureWindow(id: "scope", label: "Scope", scope: "")) == "")
  #expect(StatusTemplate.windowTag(coverageClosureWindow(id: "", label: "Empty")) == "")
}

@Test func coverageClosureUsagePresentationExplainsUnselectedAndInitiallyRefreshingRows() throws {
  let window = coverageClosureWindow(id: "session", label: "Session")
  let row = WindowRow(
    key: WindowKey(provider: .codex, windowID: window.id),
    window: window,
    pace: PaceEstimate(status: .unknown, expectedPercent: nil, ratio: nil, projectedExhaustion: nil),
    countdown: "--",
    resetClock: "--",
    isSelected: false)
  #expect(row.accessibilityValue(at: fixedNow).contains("not shown in the menu bar"))

  let refreshing = UsagePresenter.card(
    provider: .codex,
    state: ProviderState(availability: .loading, isRefreshing: true),
    samples: [:],
    now: fixedNow)
  #expect(refreshing.statusHelp == "Fetching the first values.")

  let snapshot = ProviderSnapshot(provider: .codex, windows: [window], fetchedAt: fixedNow)
  let card = UsagePresenter.card(
    provider: .codex,
    state: ProviderState(snapshot: snapshot, availability: .current),
    samples: [:],
    now: fixedNow)
  #expect(try #require(card.rows.first).detail == "window")
}

@MainActor
private func coverageClosureCoordinator(
  provider: ScriptedProvider,
  settings: Settings,
  log: LogBuffer = makeLog()
) throws -> RefreshCoordinator {
  let state = AppState()
  state.update(provider.id) { $0.credentialState = .valid(expiresAt: nil) }
  return RefreshCoordinator(
    registry: ProviderRegistry([provider]),
    settings: settings,
    state: state,
    history: try UsageHistoryStore(url: nil),
    log: log,
    clock: testClock
  ) { _ in }
}

@MainActor
private func coverageClosureSettings() -> Settings {
  Settings(defaults: UserDefaults(suiteName: "core-coverage-closure-\(UUID().uuidString)")!)
}

private func coverageClosureWindow(
  id: String,
  label: String,
  scope: String? = nil
) -> QuotaWindow {
  QuotaWindow(id: id, label: label, group: .other, usedPercent: 25, resetsAt: nil, scope: scope)
}

private actor CoverageClosureFailureRecorder {
  private(set) var messages: [String] = []

  func record(_ message: String) {
    messages.append(message)
  }
}
