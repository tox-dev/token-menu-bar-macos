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
  history: UsageHistoryStore? = nil
) throws -> (RefreshCoordinator, AppState, Settings, UsageHistoryStore, NotificationSink) {
  let settings = settings ?? makeSettings()
  for provider in ProviderID.allCases { settings.setRefreshInterval(60, for: provider) }
  let state = AppState()
  let history = try history ?? UsageHistoryStore(url: nil)
  let sink = NotificationSink()
  let coordinator = RefreshCoordinator(
    registry: ProviderRegistry(providers), settings: settings, state: state, history: history, log: makeLog(),
    clock: clock
  ) { sink.events += $0 }
  return (coordinator, state, settings, history, sink)
}

@MainActor
final class NotificationSink {
  var events: [NotificationEvent] = []
}

actor Ticks {
  var count = 0
  func increment() { count += 1 }
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
  await coordinator.refresh(RefreshRequest(force: true))
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
  await coordinator.refresh(RefreshRequest(force: true))
  #expect(state.state(for: .codex).snapshot == newer)
  #expect(state.state(for: .codex).availability == .stale)
}

@Test @MainActor func coordinatorSkipsDisabledProvidersAndCoalesces() async throws {
  let claude = ScriptedProvider(id: .claude, results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 10)))])
  let codex = ScriptedProvider(id: .codex, results: [ProviderFetchResult(outcome: .success(snapshot(.codex, 10)))])
  let settings = makeSettings()
  settings.enabledProviders = [.claude]
  let (coordinator, state, _, _, _) = try makeCoordinator([claude, codex], settings: settings)
  async let first: Void = coordinator.refresh(RefreshRequest())
  async let second: Void = coordinator.refresh(RefreshRequest(analytics: true))
  async let third: Void = coordinator.refresh(RefreshRequest(interactive: true))
  _ = await (first, second, third)
  #expect(state.state(for: .codex).availability == .disabled)
  #expect(codex.calls.isEmpty)
  #expect(claude.calls.count <= 2)
  #expect(claude.calls.count >= 1)
  #expect(
    RefreshRequest(interactive: true).merged(with: RefreshRequest(force: true, analytics: true))
      == RefreshRequest(interactive: true, force: true, analytics: true))
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
  try await Task.sleep(for: .milliseconds(50))
  #expect(claude.calls.count == 3)
  #expect(state.state(for: .claude).availability == .current)
  coordinator.stop()
  #expect(!coordinator.isRunning)
  coordinator.stop()
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
  let (coordinator, state, settings, _, _) = try makeCoordinator([codex], clock: box.clock, history: history)
  await coordinator.refresh(RefreshRequest())
  #expect(codex.calls[0].includeAnalytics)
  box.date = fixedNow.addingTimeInterval(60)
  await coordinator.refresh(RefreshRequest())
  #expect(!codex.calls[1].includeAnalytics)
  #expect(state.state(for: .codex).analytics == analytics)
  box.date = fixedNow.addingTimeInterval(TimeInterval(settings.analyticsRefreshMinutes * 60 + 1))
  await coordinator.refresh(RefreshRequest())
  #expect(codex.calls[2].includeAnalytics)
  let fresh = ScriptedProvider(id: .codex, results: [ProviderFetchResult(outcome: .success(snapshot(.codex, 3)))])
  let (second, secondState, _, _, _) = try makeCoordinator([fresh], history: history)
  await second.refresh(RefreshRequest())
  #expect(secondState.state(for: .codex).analytics?.points.map(\.value) == [4])
  let empty = ScriptedProvider(id: .claude, results: [ProviderFetchResult(outcome: .success(snapshot(.claude, 3)))])
  let (third, thirdState, _, _, _) = try makeCoordinator([empty])
  await third.refresh(RefreshRequest())
  #expect(thirdState.state(for: .claude).analytics == nil)
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
  #expect(coordinator.nextAttempt(for: .codex) == fixedNow.addingTimeInterval(60))
  await coordinator.refresh(RefreshRequest(force: true))
  #expect(coordinator.nextAttempt(for: .codex) == fixedNow.addingTimeInterval(600))
  await coordinator.refresh(RefreshRequest(force: true))
  #expect(coordinator.nextAttempt(for: .codex) == fixedNow.addingTimeInterval(1800))
  #expect(codex.calls.count == 3)
  box.date = fixedNow.addingTimeInterval(1700)
  await coordinator.refresh(RefreshRequest())
  #expect(codex.calls.count == 3)
  box.date = fixedNow.addingTimeInterval(1800)
  await coordinator.refresh(RefreshRequest())
  #expect(codex.calls.count == 4)
  #expect(state.state(for: .codex).availability == .current)
  #expect(coordinator.nextAttempt(for: .codex) == nil)
  box.date = fixedNow.addingTimeInterval(1800 + 100)
  await coordinator.refresh(RefreshRequest())
  #expect(codex.calls.count == 4)
  state.popoverVisible = true
  await coordinator.refresh(RefreshRequest())
  #expect(codex.calls.count == 5)
  #expect(state.state(for: .codex).availability == .unavailable)
  #expect(coordinator.nextAttempt(for: .codex) == box.date.addingTimeInterval(RefreshCoordinator.networkBackoff))
}

@Test @MainActor func coordinatorRestoresAndStoresCachedSnapshots() async throws {
  let root = temporaryDirectory()
  let cache = SnapshotCache(url: root.appendingPathComponent("snapshots.json"))
  #expect(cache.load().isEmpty)
  try cache.store([.codex: DemoData.snapshot(.codex, now: fixedNow)])
  let restored = cache.load()
  #expect(restored[.codex]?.source == .cache)
  #expect(restored[.codex]?.fetchedAt == fixedNow)
  let provider = DemoProvider(id: .codex)
  let state = AppState()
  let settings = makeSettings()
  let history = try UsageHistoryStore(url: nil)
  let coordinator = RefreshCoordinator(
    registry: ProviderRegistry([provider]), settings: settings, state: state, history: history, log: makeLog(),
    clock: testClock, cache: cache
  ) { _ in }
  #expect(state.state(for: .codex).snapshot?.source == .cache)
  #expect(state.state(for: .codex).availability == .stale)
  #expect(!state.statusModel.cells.isEmpty)
  await coordinator.refresh(RefreshRequest(force: true))
  #expect(state.state(for: .codex).snapshot?.source == .network)
  #expect(cache.load()[.codex]?.windows.isEmpty == false)
  let unwritable = SnapshotCache(url: URL(fileURLWithPath: "/dev/null/snapshots.json"))
  #expect(unwritable.load().isEmpty)
  let log = makeLog()
  let failing = RefreshCoordinator(
    registry: ProviderRegistry([provider]), settings: settings, state: AppState(), history: history, log: log,
    clock: testClock, cache: unwritable
  ) { _ in }
  failing.storeCache()
  #expect(log.text.contains("snapshot cache write failed"))
  #expect(SnapshotCache(url: nil).load().isEmpty)
  try SnapshotCache(url: nil).store([:])
}
