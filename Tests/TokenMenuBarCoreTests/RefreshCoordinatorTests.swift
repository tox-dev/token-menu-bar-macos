import Foundation
import Testing

@testable import TokenMenuBarCore

@Test @MainActor func coordinatorAppliesSuccessAndRecordsHistory() async throws {
  let claude = ScriptedProvider(
    id: .claude, results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 20)), warnings: ["w"])])
  let codex = ScriptedProvider(
    id: .codex,
    results: [
      ProviderFetchResult(
        outcome: .success(snapshot(.codex, 50)),
        analytics: ProviderAnalytics(
          provider: .codex, points: [AnalyticsPoint(day: "2026-08-29", metric: .turns, series: "m", value: 1)],
          fetchedAt: fixedNow))
    ])
  let (coordinator, state, _, history, sink) = try makeCoordinator([claude, codex])
  await coordinator.refresh(RefreshRequest())
  #expect(state.state(for: .claude).availability == .current)
  #expect(state.state(for: .claude).warnings == ["w"])
  #expect(state.state(for: .claude).lastSuccess == fixedNow)
  #expect(state.state(for: .claude).credentialState == .valid(expiresAt: nil))
  #expect(state.state(for: .codex).analytics?.points.count == 1)
  #expect(state.lastRefresh == fixedNow)
  #expect(state.sampleRevision == 1)
  #expect(state.historyRevision == 1)
  #expect(!state.isRefreshing)
  #expect(state.statusModel.cells.map(\.id) == ["claude:session", "codex:session"])
  #expect(try await history.samples(from: .distantPast, to: .distantFuture).count == 2)
  #expect(try await history.analytics(provider: .codex, from: "2026-01-01", to: "2026-12-31").count == 1)
  #expect(sink.events.isEmpty)
  #expect(codex.calls.first?.includeAnalytics == true)
  #expect(state.orderedProviders == [.claude, .codex])
  #expect(!state.state(for: .claude).isStale)
}

private func snapshot(_ provider: ProviderID, _ percent: Double, resets: TimeInterval = 3600) -> ProviderSnapshot {
  ProviderSnapshot(
    provider: provider,
    windows: [
      QuotaWindow(
        id: "session", label: "Session", group: .session, usedPercent: percent,
        resetsAt: fixedNow.addingTimeInterval(resets), duration: 18000)
    ],
    fetchedAt: fixedNow
  )
}

@MainActor
private func makeCoordinator(
  _ providers: [any UsageProvider], settings: Settings? = nil, clock: Clock = testClock,
  history: UsageHistoryStore? = nil, log: LogBuffer? = nil, activateProviders: Bool = true
) throws -> (RefreshCoordinator, AppState, Settings, UsageHistoryStore, NotificationSink) {
  let settings = settings ?? makeSettings()
  if activateProviders {
    for provider in providers where settings.providerOverride(for: provider.id) == nil {
      settings.setProvider(provider.id, enabled: true)
    }
  }
  for provider in ProviderID.allCases { settings.setRefreshInterval(60, for: provider) }
  let state = AppState()
  if activateProviders {
    for provider in providers {
      state.update(provider.id) { $0.credentialState = .valid(expiresAt: nil) }
    }
  }
  let history = try history ?? UsageHistoryStore(url: nil)
  let sink = NotificationSink()
  let coordinator = RefreshCoordinator(
    registry: ProviderRegistry(providers), settings: settings, state: state, history: history, log: log ?? makeLog(),
    clock: clock
  ) { sink.events += $0 }
  return (coordinator, state, settings, history, sink)
}

@MainActor
final class NotificationSink {
  var events: [NotificationEvent] = []
}

@Test func refreshRequestMergesReasonAndPoliciesByPriority() {
  let merged = RefreshRequest(reason: .export, usage: .skip, analytics: .force)
    .merged(with: RefreshRequest(reason: .scheduled, usage: .ifDue, analytics: .skip))
  #expect(merged == RefreshRequest(reason: .export, usage: .ifDue, analytics: .force))
}

@Test @MainActor func coordinatorCoalescesHistoryRevisionAndSkipsItWhenNoSamplesChange() async throws {
  let claude = ScriptedProvider(
    id: .claude, results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 20)))])
  let codex = ScriptedProvider(
    id: .codex, results: [ProviderFetchResult(outcome: .success(snapshot(.codex, 50)))])
  let (coordinator, state, _, _, _) = try makeCoordinator([claude, codex])

  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  #expect(state.sampleRevision == 1)
  #expect(state.historyRevision == 1)

  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  #expect(state.sampleRevision == 1)
  #expect(claude.callCount == 2)
  #expect(codex.callCount == 2)
}

@Test func refreshRequestMergesProviderScopes() {
  let scoped = RefreshRequest(providers: [.claude])
    .merged(with: RefreshRequest(providers: [.codex]))
  #expect(scoped.providers == [.claude, .codex])
  #expect(RefreshRequest().merged(with: scoped).providers == nil)
}

@Test @MainActor func coordinatorLogsDisabledProviderSkips() async throws {
  let log = makeLog()
  log.debugEnabled = true
  let settings = makeSettings()
  settings.setProvider(.gemini, enabled: false)
  let (coordinator, _, _, _, _) = try makeCoordinator([scriptedProvider(.gemini)], settings: settings, log: log)

  await coordinator.refresh(RefreshRequest())

  #expect(log.text.contains("provider=gemini"))
  #expect(log.text.contains("skipReason=disabled"))
}

@Test @MainActor func coordinatorDoesNotPollAnUndiscoveredProviderAutomatically() async throws {
  let provider = scriptedProvider(.gemini)
  let (coordinator, state, _, _, _) = try makeCoordinator([provider], activateProviders: false)

  await coordinator.refresh(RefreshRequest())

  #expect(provider.calls.isEmpty)
  #expect(state.state(for: .gemini).availability == .disabled)
  #expect(coordinator.nextRefreshDate() == nil)
}

@Test @MainActor func coordinatorTargetedRefreshCanDiscoverAndActivateAProvider() async throws {
  let provider = scriptedProvider(
    .gemini, ProviderFetchResult(outcome: .success(snapshot(.gemini, 25))))
  let (coordinator, state, settings, _, _) = try makeCoordinator([provider], activateProviders: false)

  await coordinator.refresh(
    RefreshRequest(reason: .userInitiated, usage: .force, providers: [.gemini]))

  #expect(provider.calls.count == 1)
  #expect(state.state(for: .gemini).availability == .current)
  #expect(settings.isProviderActive(.gemini, state: state.state(for: .gemini)))
  #expect(coordinator.nextRefreshDate() != nil)
}

@Test @MainActor func coordinatorLogsAnalyticsNotDueSkips() async throws {
  let log = makeLog()
  log.debugEnabled = true
  let provider = scriptedProvider(.codex, ProviderFetchResult(outcome: .success(snapshot(.codex, 20))))
  let (coordinator, _, _, _, _) = try makeCoordinator([provider], log: log)
  await coordinator.refresh(RefreshRequest(usage: .skip, analytics: .force))

  await coordinator.refresh(RefreshRequest(usage: .skip, analytics: .ifDue))

  #expect(log.text.contains("skipReason=analytics-not-due"))
}

@Test @MainActor func coordinatorLogsNoWorkSkips() async throws {
  let log = makeLog()
  log.debugEnabled = true
  let (coordinator, _, _, _, _) = try makeCoordinator([scriptedProvider(.gemini)], log: log)

  await coordinator.refresh(RefreshRequest(usage: .skip, analytics: .skip))

  #expect(log.text.contains("skipReason=no-work"))
}

@Test @MainActor func coordinatorLogsRetryBackoffSkips() async throws {
  let log = makeLog()
  log.debugEnabled = true
  let provider = scriptedProvider(.codex, ProviderFetchResult(outcome: .rateLimited("busy", retryAfter: 60)))
  let (coordinator, _, _, _, _) = try makeCoordinator([provider], log: log)
  await coordinator.refresh(RefreshRequest())

  await coordinator.refresh(RefreshRequest())
  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))

  #expect(log.text.contains("skipReason=retry-backoff"))
  #expect(provider.callCount == 1)
}

@Test @MainActor func coordinatorRefreshesOnlyRequestedProvider() async throws {
  let claude = scriptedProvider(.claude, ProviderFetchResult(outcome: .success(snapshot(.claude, 20))))
  let codex = scriptedProvider(.codex, ProviderFetchResult(outcome: .success(snapshot(.codex, 30))))
  let (coordinator, _, _, _, _) = try makeCoordinator([claude, codex])

  await coordinator.refresh(
    RefreshRequest(reason: .userInitiated, usage: .force, analytics: .ifDue, providers: [.codex]))

  #expect(claude.callCount == 0)
  #expect(codex.callCount == 1)
}

actor Ticks {
  var count = 0
  func increment() { count += 1 }
}

actor SleepRecorder {
  private(set) var durations: [TimeInterval] = []
  let gate = TestGate()

  func sleep(_ duration: TimeInterval) async throws {
    durations.append(duration)
    try await gate.wait()
  }
}

@Test @MainActor func coordinatorHandlesFailuresStaleAndBackoff() async throws {
  let claude = ScriptedProvider(
    id: .claude,
    results: [
      ProviderFetchResult(outcome: .success(snapshot(.claude, 20))),
      ProviderFetchResult(outcome: .networkUnavailable("down")),
      ProviderFetchResult(outcome: .success(snapshot(.claude, 25))),
    ])
  let codex = ScriptedProvider(
    id: .codex,
    results: [
      ProviderFetchResult(outcome: .rateLimited("HTTP 429: busy", retryAfter: nil)),
      ProviderFetchResult(outcome: .notAuthenticated("expired")),
      ProviderFetchResult(outcome: .partial(snapshot(.codex, 5), "stale reason")),
    ])
  let box = DateBox(fixedNow)
  let (coordinator, state, _, _, sink) = try makeCoordinator([claude, codex], clock: box.clock)
  await coordinator.refresh(RefreshRequest())
  #expect(state.state(for: .codex).availability == .rateLimited)
  #expect(state.state(for: .codex).lastError?.hasPrefix("HTTP 429: busy. Next attempt") == true)
  #expect(coordinator.nextAttempt(for: .codex) == fixedNow.addingTimeInterval(300))
  box.date = fixedNow.addingTimeInterval(120)
  await coordinator.refresh(RefreshRequest())
  #expect(claude.calls.count == 2)
  #expect(codex.calls.count == 1)
  #expect(state.state(for: .claude).availability == .networkUnavailable)
  #expect(state.state(for: .claude).snapshot?.windows.first?.usedPercent == 20)
  #expect(state.state(for: .claude).isStale)
  #expect(state.statusModel.iconTone == .offline)
  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  #expect(codex.calls.count == 1)
  box.date = fixedNow.addingTimeInterval(300)
  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  #expect(codex.calls.count == 2)
  #expect(state.state(for: .codex).availability == .authenticationRequired)
  #expect(sink.events.map(\.kind) == [.authentication])
  box.date = fixedNow.addingTimeInterval(400)
  await coordinator.refresh(RefreshRequest())
  #expect(state.state(for: .codex).availability == .stale)
  #expect(state.state(for: .codex).snapshot?.windows.first?.usedPercent == 5)
  #expect(state.state(for: .codex).lastError == "stale reason")
  #expect(state.state(for: .claude).availability == .current)
}

@Test @MainActor func coordinatorKeepsNewerSnapshotOverPartial() async throws {
  let newer = ProviderSnapshot(provider: .codex, windows: [], fetchedAt: fixedNow.addingTimeInterval(100))
  let older = ProviderSnapshot(
    provider: .codex, windows: [], source: .localLog, fetchedAt: fixedNow.addingTimeInterval(-100))
  let codex = ScriptedProvider(
    id: .codex,
    results: [ProviderFetchResult(outcome: .success(newer)), ProviderFetchResult(outcome: .partial(older, "old"))])
  let (coordinator, state, _, _, _) = try makeCoordinator([codex])
  await coordinator.refresh(RefreshRequest())
  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  #expect(state.state(for: .codex).snapshot == newer)
  #expect(state.state(for: .codex).availability == .stale)
}

@Test @MainActor func coordinatorSkipsDisabledProvidersAndCoalesces() async throws {
  let gate = TestGate()
  let claude = ScriptedProvider(
    id: .claude,
    results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 10)))],
    gate: gate)
  let codex = ScriptedProvider(id: .codex, results: [ProviderFetchResult(outcome: .success(snapshot(.codex, 10)))])
  let settings = makeSettings()
  settings.setProvider(.claude, enabled: true)
  settings.setProvider(.codex, enabled: false)
  let (coordinator, state, _, _, _) = try makeCoordinator([claude, codex], settings: settings)
  let first = Task { await coordinator.refresh(RefreshRequest()) }
  for _ in 0..<1000 {
    if claude.callCount > 0 { break }
    await Task.yield()
  }
  #expect(claude.callCount == 1)
  async let second: Void = coordinator.refresh(RefreshRequest(analytics: .force))
  async let third: Void = coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  gate.open()
  _ = await (second, third)
  await first.value
  #expect(state.state(for: .codex).availability == .disabled)
  #expect(codex.calls.isEmpty)
  #expect(claude.calls.count == 2)
  #expect(
    RefreshRequest(reason: .popoverOpened).merged(
      with: RefreshRequest(reason: .userInitiated, usage: .force, analytics: .force))
      == RefreshRequest(reason: .userInitiated, usage: .force, analytics: .force))
}

@Test @MainActor func coordinatorJoinsRepeatedManualRefreshes() async throws {
  let gate = TestGate()
  let claude = ScriptedProvider(
    id: .claude,
    results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 10)))],
    gate: gate)
  let (coordinator, _, _, _, _) = try makeCoordinator([claude])
  let first = Task { await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force)) }
  for _ in 0..<1000 {
    if claude.callCount > 0 { break }
    await Task.yield()
  }
  #expect(claude.callCount == 1)
  async let second: Void = coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  async let third: Void = coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  gate.open()
  _ = await (second, third)
  await first.value
  #expect(claude.calls.count == 1)
}

@Test @MainActor func coordinatorRunsAnUnscopedRefreshAfterAScopedRefresh() async throws {
  let gate = TestGate()
  let claude = ScriptedProvider(
    id: .claude,
    results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 10)))],
    gate: gate)
  let codex = scriptedProvider(.codex, ProviderFetchResult(outcome: .success(snapshot(.codex, 20))))
  let (coordinator, _, _, _, _) = try makeCoordinator([claude, codex])
  let scoped = Task {
    await coordinator.refresh(
      RefreshRequest(reason: .userInitiated, usage: .force, providers: [.claude]))
  }
  while claude.callCount == 0 { await Task.yield() }

  let unscoped = Task { await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force)) }
  await Task.yield()
  gate.open()
  await unscoped.value
  await scoped.value

  #expect(claude.callCount == 2)
  #expect(codex.callCount == 1)
}

@Test @MainActor func coordinatorStopCancelsRefreshAndClearsTransientState() async throws {
  let gate = TestGate()
  let claude = ScriptedProvider(
    id: .claude,
    results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 10)))],
    gate: gate)
  let (coordinator, state, _, _, _) = try makeCoordinator([claude])
  let refresh = Task { await coordinator.refresh(RefreshRequest()) }
  for _ in 0..<1000 {
    if state.isRefreshing { break }
    await Task.yield()
  }
  #expect(state.isRefreshing)
  coordinator.stop()
  await refresh.value
  #expect(!state.isRefreshing)
  #expect(!state.state(for: .claude).isRefreshing)
  #expect(state.state(for: .claude).lastAttempt == nil)
}

@MainActor
private func makeSettings() -> Settings {
  let defaults = UserDefaults(suiteName: "tests-\(UUID().uuidString)")!
  return Settings(defaults: defaults)
}

@Test @MainActor func coordinatorLoopRunsUntilStopped() async throws {
  let claude = ScriptedProvider(id: .claude, results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 10)))])
  let ticks = Ticks()
  let box = DateBox(fixedNow)
  let clock = Clock(
    now: { box.date },
    sleep: { _ in
      box.date = box.date.addingTimeInterval(120)
      await ticks.increment()
      if await ticks.count >= 3 { throw CancellationError() }
    })
  let (coordinator, state, _, _, _) = try makeCoordinator([claude], clock: clock)
  #expect(!coordinator.isRunning)
  coordinator.start()
  coordinator.start()
  #expect(coordinator.isRunning)
  while await ticks.count < 3 { await Task.yield() }
  while claude.calls.count < 3 { await Task.yield() }
  #expect(claude.calls.count == 3)
  #expect(state.state(for: .claude).availability == .current)
  coordinator.stop()
  #expect(!coordinator.isRunning)
  coordinator.stop()
}

@Test @MainActor func coordinatorUsesProviderAndVisibilityDeadlines() async throws {
  let codex = ScriptedProvider(id: .codex, results: [ProviderFetchResult(outcome: .success(snapshot(.codex, 10)))])
  codex.pollingPolicy = PollingPolicy(minimumInterval: 60, activeInterval: 90, defaultInterval: 300)
  let box = DateBox(fixedNow)
  let (coordinator, state, settings, _, _) = try makeCoordinator([codex], clock: box.clock)
  settings.setRefreshInterval(300, for: .codex)
  #expect(coordinator.nextRefreshDate() == fixedNow)
  await coordinator.refresh(RefreshRequest())
  #expect(coordinator.nextRefreshDate() == fixedNow.addingTimeInterval(300))
  state.popoverVisible = true
  #expect(coordinator.nextRefreshDate() == fixedNow.addingTimeInterval(90))
  coordinator.stop()
  #expect(state.nextRefreshAt == nil)
}

@Test @MainActor func coordinatorReschedulesWhenVisibilityChanges() async throws {
  let codex = ScriptedProvider(id: .codex, results: [ProviderFetchResult(outcome: .success(snapshot(.codex, 10)))])
  codex.pollingPolicy = PollingPolicy(minimumInterval: 60, activeInterval: 90, defaultInterval: 300)
  let recorder = SleepRecorder()
  let clock = Clock(now: { fixedNow }, sleep: { try await recorder.sleep($0) })
  let (coordinator, state, settings, _, _) = try makeCoordinator([codex], clock: clock)
  settings.setRefreshInterval(300, for: .codex)
  coordinator.start()
  for _ in 0..<1000 {
    if await recorder.durations.count >= 1 { break }
    await Task.yield()
  }
  #expect(await recorder.durations.count == 1)
  state.popoverVisible = true
  for _ in 0..<1000 {
    if await recorder.durations.count >= 2 { break }
    await Task.yield()
  }
  #expect(await recorder.durations == [300, 90])
  coordinator.stop()
}

@Test @MainActor func coordinatorDoesNotScheduleAnalyticsForUnsupportedProviders() async throws {
  let gemini = ScriptedProvider(
    id: .gemini, results: [ProviderFetchResult(outcome: .success(snapshot(.gemini, 10)))])
  gemini.pollingPolicy = PollingPolicy(minimumInterval: 60, activeInterval: 90, defaultInterval: 3600)
  let box = DateBox(fixedNow)
  let (coordinator, _, settings, _, _) = try makeCoordinator([gemini], clock: box.clock)
  settings.setRefreshInterval(3600, for: .gemini)
  settings.analyticsRefreshMinutes = 5
  await coordinator.refresh(RefreshRequest())
  #expect(
    gemini.calls == [FetchOptions(includeAnalytics: false, analyticsDays: settings.historyRetentionDays)])
  let usageInterval = gemini.pollingPolicy.interval(
    active: false, requested: TimeInterval(settings.refreshInterval(for: .gemini)))
  #expect(usageInterval > TimeInterval(settings.analyticsRefreshMinutes * 60))
  #expect(coordinator.nextRefreshDate() == fixedNow.addingTimeInterval(usageInterval))
  settings.setProvider(.gemini, enabled: false)
  #expect(coordinator.nextRefreshDate() == nil)
}

@Test @MainActor func coordinatorRetriesAtConfiguredClosedPopoverInterval() async throws {
  let claude = ScriptedProvider(
    id: .claude,
    results: [
      ProviderFetchResult(outcome: .networkUnavailable("down")),
      ProviderFetchResult(outcome: .success(snapshot(.claude, 10))),
    ])
  claude.pollingPolicy = PollingPolicy(minimumInterval: 120, activeInterval: 120, defaultInterval: 300)
  let box = DateBox(fixedNow)
  let (coordinator, state, settings, _, _) = try makeCoordinator([claude], clock: box.clock)
  settings.setRefreshInterval(300, for: .claude)
  await coordinator.refresh(RefreshRequest())
  #expect(coordinator.nextRefreshDate() == fixedNow.addingTimeInterval(300))
  box.date = fixedNow.addingTimeInterval(300)
  #expect(coordinator.nextRefreshDate() == box.date)
  await coordinator.refresh(RefreshRequest())
  #expect(claude.calls.count == 2)
  #expect(state.state(for: .claude).availability == .current)
}

@Test @MainActor func providerRecoveryRefreshBypassesANonRateLimitDeadline() async throws {
  let claude = ScriptedProvider(
    id: .claude,
    results: [
      ProviderFetchResult(outcome: .networkUnavailable("down")),
      ProviderFetchResult(outcome: .success(snapshot(.claude, 10))),
    ])
  let (coordinator, state, _, _, _) = try makeCoordinator([claude])
  await coordinator.refresh(RefreshRequest())
  await coordinator.refresh(
    RefreshRequest(reason: .userInitiated, usage: .force, providers: [.claude]))
  #expect(claude.calls.count == 2)
  #expect(state.state(for: .claude).availability == .current)
}

@Test @MainActor func coordinatorAnalyticsCadenceAndStoredFallback() async throws {
  let analytics = ProviderAnalytics(
    provider: .codex, points: [AnalyticsPoint(day: "2026-08-29", metric: .turns, series: "m", value: 4)],
    fetchedAt: fixedNow)
  let codex = ScriptedProvider(
    id: .codex,
    results: [
      ProviderFetchResult(outcome: .success(snapshot(.codex, 1)), analytics: analytics),
      ProviderFetchResult(outcome: .success(snapshot(.codex, 2))),
    ])
  let box = DateBox(fixedNow)
  let history = try UsageHistoryStore(url: nil)
  let (coordinator, state, _, _, _) = try makeCoordinator([codex], clock: box.clock, history: history)
  await coordinator.refresh(RefreshRequest())
  #expect(codex.calls[0].includeAnalytics)
  #expect(state.state(for: .codex).lastAnalyticsAttempt == fixedNow)
  box.date = fixedNow.addingTimeInterval(60)
  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  #expect(!codex.calls[1].includeAnalytics)
  #expect(state.state(for: .codex).lastAnalyticsAttempt == fixedNow)
  #expect(state.state(for: .codex).analytics == analytics)
  box.date = fixedNow.addingTimeInterval(61)
  await coordinator.refresh(RefreshRequest(usage: .skip, analytics: .force))
  #expect(codex.calls[2].includeAnalytics)
  #expect(state.state(for: .codex).lastAnalyticsAttempt == box.date)
  let fresh = ScriptedProvider(id: .codex, results: [ProviderFetchResult(outcome: .success(snapshot(.codex, 3)))])
  let (second, secondState, _, _, _) = try makeCoordinator([fresh], history: history)
  await second.refresh(RefreshRequest())
  #expect(secondState.state(for: .codex).analytics?.points.map(\.value) == [4])
  let empty = ScriptedProvider(id: .claude, results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 3)))])
  let (third, thirdState, _, _, _) = try makeCoordinator([empty])
  await third.refresh(RefreshRequest())
  #expect(thirdState.state(for: .claude).analytics == nil)
}

@Test @MainActor func coordinatorMergesOverlappingIncrementalAnalytics() async throws {
  let first = ProviderAnalytics(
    provider: .codex,
    points: [
      AnalyticsPoint(day: "2026-08-28", metric: .turns, series: "m", value: 1),
      AnalyticsPoint(day: "2026-08-28", metric: .turns, series: "m", value: 2),
    ],
    creditEvents: [CreditEvent(id: "event", date: fixedNow, service: "api", creditsUsed: 1)],
    fetchedAt: fixedNow)
  let second = ProviderAnalytics(
    provider: .codex,
    points: [
      AnalyticsPoint(day: "2026-08-28", metric: .turns, series: "m", value: 3),
      AnalyticsPoint(day: "2026-08-29", metric: .turns, series: "m", value: 4),
    ],
    creditEvents: [CreditEvent(id: "event", date: fixedNow, service: "api", creditsUsed: 2)],
    fetchedAt: fixedNow.addingTimeInterval(60))
  let codex = ScriptedProvider(
    id: .codex,
    results: [
      ProviderFetchResult(outcome: .success(snapshot(.codex, 1)), analytics: first),
      ProviderFetchResult(outcome: .success(snapshot(.codex, 2)), analytics: second),
    ])
  let (coordinator, state, _, _, _) = try makeCoordinator([codex])
  await coordinator.refresh(RefreshRequest())
  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force, analytics: .force))
  #expect(state.state(for: .codex).analytics?.points.map(\.value) == [3, 4])
  #expect(state.state(for: .codex).analytics?.creditEvents.map(\.creditsUsed) == [2])
}

@Test @MainActor func coordinatorRebuildsStatusFromCustomSelection() async throws {
  let claude = ScriptedProvider(id: .claude, results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 10)))])
  let (coordinator, state, settings, _, _) = try makeCoordinator([claude])
  await coordinator.refresh(RefreshRequest())
  settings.hasCustomSelection = true
  settings.selectedWindows = []
  coordinator.rebuildStatus()
  #expect(state.statusModel.cells.isEmpty)
  settings.selectedWindows = [WindowKey(provider: .claude, windowID: "session")]
  coordinator.rebuildStatus(now: fixedNow)
  #expect(state.statusModel.cells.count == 1)
  state.remove(.claude)
  #expect(state.providers.isEmpty)
  state.popoverVisible = true
  #expect(state.popoverVisible)
}

@Test @MainActor func coordinatorSurvivesHistoryErrors() async throws {
  let claude = ScriptedProvider(
    id: .claude,
    results: [
      ProviderFetchResult(
        outcome: .success(snapshot(.claude, 10)),
        analytics: ProviderAnalytics(
          provider: .claude, points: [AnalyticsPoint(day: "d", metric: .turns, series: "s", value: 1)],
          fetchedAt: fixedNow))
    ])
  let history = try UsageHistoryStore(url: nil)
  try await history.breakDatabase()
  let (coordinator, state, _, _, _) = try makeCoordinator([claude], history: history)
  await coordinator.refresh(RefreshRequest())
  #expect(state.state(for: .claude).availability == .current)
}

extension UsageHistoryStore {
  func breakDatabase() throws {
    try database.execute("DROP TABLE samples")
    try database.execute("DROP TABLE analytics")
  }
}

@Test @MainActor func coordinatorDoublesRateLimitBackoffAndRespectsPolicies() async throws {
  let codex = ScriptedProvider(
    id: .codex,
    results: [
      ProviderFetchResult(outcome: .rateLimited("HTTP 429", retryAfter: 30)),
      ProviderFetchResult(outcome: .rateLimited("HTTP 429", retryAfter: nil)),
      ProviderFetchResult(outcome: .rateLimited("HTTP 429", retryAfter: 5000)),
      ProviderFetchResult(outcome: .success(snapshot(.codex, 5))),
      ProviderFetchResult(outcome: .failed("HTTP 500")),
    ])
  codex.pollingPolicy = PollingPolicy(minimumInterval: 60, activeInterval: 90, defaultInterval: 300)
  let box = DateBox(fixedNow)
  let (coordinator, state, settings, _, _) = try makeCoordinator([codex], clock: box.clock)
  settings.setRefreshInterval(300, for: .codex)
  await coordinator.refresh(RefreshRequest())
  #expect(coordinator.nextAttempt(for: .codex) == fixedNow.addingTimeInterval(300))
  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  #expect(codex.calls.count == 1)
  box.date = fixedNow.addingTimeInterval(300)
  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  #expect(coordinator.nextAttempt(for: .codex) == box.date.addingTimeInterval(600))
  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  #expect(codex.calls.count == 2)
  box.date = fixedNow.addingTimeInterval(900)
  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  #expect(coordinator.nextAttempt(for: .codex) == box.date.addingTimeInterval(1800))
  #expect(codex.calls.count == 3)
  box.date = fixedNow.addingTimeInterval(2699)
  await coordinator.refresh(RefreshRequest())
  #expect(codex.calls.count == 3)
  box.date = fixedNow.addingTimeInterval(2700)
  await coordinator.refresh(RefreshRequest())
  #expect(codex.calls.count == 4)
  #expect(state.state(for: .codex).availability == .current)
  #expect(coordinator.nextAttempt(for: .codex) == nil)
  box.date = fixedNow.addingTimeInterval(2800)
  await coordinator.refresh(RefreshRequest())
  #expect(codex.calls.count == 4)
  state.popoverVisible = true
  await coordinator.refresh(RefreshRequest())
  #expect(codex.calls.count == 5)
  #expect(state.state(for: .codex).availability == .unavailable)
  #expect(coordinator.nextAttempt(for: .codex) == box.date.addingTimeInterval(90))
}

@Test @MainActor func coordinatorDiscardsResultsFromAReplacedRegistry() async throws {
  let gate = TestGate()
  let old = ScriptedProvider(
    id: .claude,
    results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 10)))],
    gate: gate)
  let replacement = ScriptedProvider(
    id: .claude,
    results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 80)))])
  let (coordinator, state, _, _, _) = try makeCoordinator([old])
  let refresh = Task { await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force)) }
  while old.callCount == 0 { await Task.yield() }
  coordinator.replaceRegistry(ProviderRegistry([replacement]))
  await refresh.value
  #expect(state.state(for: .claude).snapshot == nil)
  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  #expect(state.state(for: .claude).snapshot?.windows.first?.usedPercent == 80)
}

@Test @MainActor func coordinatorDiscardsAResultWhenTheProviderWasDisabled() async throws {
  let gate = TestGate()
  let provider = ScriptedProvider(
    id: .claude,
    results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 70)))],
    gate: gate)
  let (coordinator, state, settings, _, _) = try makeCoordinator([provider])
  let refresh = Task { await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force)) }
  while provider.callCount == 0 { await Task.yield() }
  settings.setProvider(.claude, enabled: false)
  gate.open()
  await refresh.value
  #expect(state.state(for: .claude).availability == .disabled)
  #expect(state.state(for: .claude).snapshot == nil)
}

@Test @MainActor func coordinatorCarriesTypedCredentialHealthFromTheFetch() async throws {
  let provider = ScriptedProvider(
    id: .copilot,
    results: [ProviderFetchResult(outcome: .success(snapshot(.copilot, 30)))])
  let source = ProviderID.copilot.credentialSource("copilot.environment")
  provider.health = .valid(source: source, expiresAt: nil)
  let (coordinator, state, _, _, _) = try makeCoordinator([provider])
  await coordinator.refresh(RefreshRequest())
  #expect(state.state(for: .copilot).credentialHealth == .valid(source: source, expiresAt: nil))
  #expect(provider.credentialStateCallCount == 1)
  #expect(provider.credentialHealthCallCount == 1)
}

@Test @MainActor func coordinatorReusesCredentialStatusReturnedByTheFetch() async throws {
  let source = ProviderID.copilot.credentialSource("copilot.environment")
  let credentialStatus = ProviderCredentialStatus(
    state: .valid(expiresAt: nil),
    health: .valid(source: source, expiresAt: nil))
  let provider = ScriptedProvider(
    id: .copilot,
    results: [
      ProviderFetchResult(
        outcome: .success(snapshot(.copilot, 30)),
        credentialStatus: credentialStatus)
    ])
  provider.credentials = .missing("the coordinator must not read this")
  provider.health = .unreadable(source: nil, detail: "the coordinator must not read this")
  let (coordinator, state, _, _, _) = try makeCoordinator([provider])

  await coordinator.refresh(RefreshRequest())

  #expect(state.state(for: .copilot).credentialState == credentialStatus.state)
  #expect(state.state(for: .copilot).credentialHealth == credentialStatus.health)
  #expect(provider.credentialStateCallCount == 0)
  #expect(provider.credentialHealthCallCount == 0)
}

@Test @MainActor func coordinatorBatchesProviderResultsBeforeTheCoalescedStatus() async throws {
  let gate = TestGate()
  let claude = ScriptedProvider(
    id: .claude,
    results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 10)))])
  let codex = ScriptedProvider(
    id: .codex,
    results: [ProviderFetchResult(outcome: .success(snapshot(.codex, 20)))],
    gate: gate)
  let (coordinator, state, _, _, _) = try makeCoordinator([claude, codex])
  let refresh = Task { await coordinator.refresh(RefreshRequest()) }

  while claude.callCount == 0 { await Task.yield() }

  #expect(state.state(for: .claude).snapshot == nil)
  #expect(state.state(for: .claude).isRefreshing)
  #expect(state.state(for: .codex).isRefreshing)
  #expect(state.isRefreshing)
  #expect(state.statusModel.cells.isEmpty)

  gate.open()
  await refresh.value

  #expect(!state.isRefreshing)
  #expect(state.statusModel.cells.map(\.id) == ["claude:session", "codex:session"])
}

@Test @MainActor func coordinatorRetainsTheReplacedRegistryUntilItsRefreshDrains() async throws {
  let gate = TestGate()
  let provider = ScriptedProvider(
    id: .claude,
    results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 10)))],
    gate: gate)
  let leaseProbe = LeaseProbe()
  var original: ProviderRegistry? = ProviderRegistry(
    [provider],
    resourceLeases: [
      SecurityScopedResourceLease(url: URL(fileURLWithPath: "/leased")) { _ in leaseProbe.stopped() }
    ])
  let state = AppState()
  state.update(.claude) { $0.credentialState = .valid(expiresAt: nil) }
  let settings = makeSettings()
  settings.setProvider(.claude, enabled: true)
  let coordinator = RefreshCoordinator(
    registry: original!, settings: settings, state: state, history: try UsageHistoryStore(url: nil), log: makeLog(),
    clock: testClock
  ) { _ in }
  original = nil
  let refresh = Task { await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force)) }
  while provider.callCount == 0 { await Task.yield() }
  coordinator.replaceRegistry(ProviderRegistry([]))
  #expect(leaseProbe.stopCount == 0)
  gate.open()
  await refresh.value
  #expect(leaseProbe.stopCount == 1)
}

@Test @MainActor func coordinatorOrdersDefaultSelectionByTheStableDraft() async throws {
  let claude = ScriptedProvider(
    id: .claude, results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 10)))])
  let codex = ScriptedProvider(
    id: .codex, results: [ProviderFetchResult(outcome: .success(snapshot(.codex, 20)))])
  let settings = makeSettings()
  settings.providerOrder = [.codex, .claude]
  let (coordinator, state, _, _, _) = try makeCoordinator([claude, codex], settings: settings)
  await coordinator.refresh(RefreshRequest())
  #expect(state.statusModel.cells.map(\.id) == ["codex:session", "claude:session"])
}

private final class LeaseProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var stops = 0

  var stopCount: Int { lock.withLock { stops } }
  func stopped() { lock.withLock { stops += 1 } }
}

@Test @MainActor func coordinatorRestoresAndStoresCachedSnapshots() async throws {
  let cache = SnapshotCache(url: temporaryDirectory().appendingPathComponent("snapshots.json"))
  #expect(cache.load().isEmpty)
  try cache.store([.codex: DemoData.snapshot(.codex, now: fixedNow)])
  let restored = cache.load()
  #expect(restored[.codex]?.source == .cache)
  #expect(restored[.codex]?.fetchedAt == fixedNow)
  let provider = DemoProvider(id: .codex)
  let state = AppState()
  let settings = makeSettings()
  let history = try UsageHistoryStore(url: nil)
  let persistence = SnapshotPersistence(cache: cache)
  let coordinator = RefreshCoordinator(
    registry: ProviderRegistry([provider]), settings: settings, state: state, history: history, log: makeLog(),
    clock: testClock, cache: cache, persistence: persistence
  ) { _ in }
  await coordinator.restoreCachedSnapshots()
  #expect(state.state(for: .codex).snapshot?.source == .cache)
  #expect(state.state(for: .codex).availability == .stale)
  #expect(!state.statusModel.cells.isEmpty)
  await coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  await coordinator.flushPersistence()
  #expect(state.state(for: .codex).snapshot?.source == .network)
  #expect(cache.load()[.codex]?.windows.isEmpty == false)
  let unwritable = SnapshotCache(url: URL(fileURLWithPath: "/dev/null/snapshots.json"))
  #expect(unwritable.load().isEmpty)
  let log = makeLog()
  let failingPersistence = SnapshotPersistence(
    cache: unwritable,
    failureHandler: { failure in log.logError(failure.message) })
  let failing = RefreshCoordinator(
    registry: ProviderRegistry([provider]), settings: settings, state: AppState(), history: history, log: log,
    clock: testClock, cache: unwritable, persistence: failingPersistence
  ) { _ in }
  failing.storeCache()
  await failing.flushPersistence()
  #expect(log.text.contains("snapshot cache write failed"))
  #expect(SnapshotCache(url: nil).load().isEmpty)
  try SnapshotCache(url: nil).store([:])
}
