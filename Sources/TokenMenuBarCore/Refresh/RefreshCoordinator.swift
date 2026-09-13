import Foundation
import Observation

public enum RefreshReason: Sendable, Equatable {
  case scheduled
  case popoverOpened
  case userInitiated
  case export
}

public enum RefreshPolicy: Int, Sendable, Equatable {
  case skip
  case ifDue
  case force
}

public struct RefreshRequest: Sendable, Equatable {
  public var reason: RefreshReason
  public var usage: RefreshPolicy
  public var analytics: RefreshPolicy
  public var providers: Set<ProviderID>?

  public init(
    reason: RefreshReason = .scheduled,
    usage: RefreshPolicy = .ifDue,
    analytics: RefreshPolicy = .ifDue,
    providers: Set<ProviderID>? = nil
  ) {
    self.reason = reason
    self.usage = usage
    self.analytics = analytics
    self.providers = providers
  }

  func merged(with other: RefreshRequest) -> RefreshRequest {
    RefreshRequest(
      reason: reason.priority >= other.reason.priority ? reason : other.reason,
      usage: max(usage, other.usage),
      analytics: max(analytics, other.analytics),
      providers: Self.union(providers, other.providers))
  }

  func covers(_ other: RefreshRequest) -> Bool {
    usage.rawValue >= other.usage.rawValue && analytics.rawValue >= other.analytics.rawValue
      && Self.covers(providers, other.providers)
  }

  private static func union(_ lhs: Set<ProviderID>?, _ rhs: Set<ProviderID>?) -> Set<ProviderID>? {
    guard let lhs, let rhs else { return nil }
    return lhs.union(rhs)
  }

  private static func covers(_ lhs: Set<ProviderID>?, _ rhs: Set<ProviderID>?) -> Bool {
    guard let lhs else { return true }
    guard let rhs else { return false }
    return lhs.isSuperset(of: rhs)
  }
}

private extension RefreshReason {
  var priority: Int {
    switch self {
    case .scheduled: 0
    case .popoverOpened: 1
    case .userInitiated: 2
    case .export: 3
    }
  }
}

private func max(_ lhs: RefreshPolicy, _ rhs: RefreshPolicy) -> RefreshPolicy {
  lhs.rawValue >= rhs.rawValue ? lhs : rhs
}

private struct RefreshRun {
  let generation: Int
  let registry: ProviderRegistry
  let task: Task<Void, Never>
}

private struct ProviderRefreshPlan {
  let provider: any UsageProvider
  let includeAnalytics: Bool
  let retryInterval: TimeInterval
}

private struct ProviderApplyResult: Sendable {
  let providerState: ProviderState?
  let events: [NotificationEvent]
  let samplesChanged: Bool
  let analyticsChanged: Bool

  static let empty = ProviderApplyResult(
    providerState: nil, events: [], samplesChanged: false, analyticsChanged: false)
}

@MainActor
public final class RefreshCoordinator {
  public static let rateLimitBackoff: TimeInterval = 300
  public static let minimumBackoff: TimeInterval = 60
  public static let maximumBackoff: TimeInterval = 1800
  public static let networkBackoff: TimeInterval = 60
  public static let wakeDelay: TimeInterval = 3
  public static let throttledMultiplier: Double = 2
  public static let idleMultiplier: Double = 3
  public static let idleThreshold: TimeInterval = 3600

  public private(set) var registry: ProviderRegistry
  private let settings: Settings
  private let state: AppState
  private let history: UsageHistoryStore
  private let log: LogBuffer
  private let clock: Clock
  private let publicationClock: Clock
  private let powerState: @Sendable () -> PowerState
  private var lastPopoverOpenedAt: Date
  private let notify: @MainActor ([NotificationEvent]) -> Void
  private var loop: Task<Void, Never>?
  private var refreshRun: RefreshRun?
  private var historyClearTask: Task<Int, any Error>?
  private var activeRequest: RefreshRequest?
  private var activeGeneration: Int?
  private var pending: RefreshRequest?
  private var rateLimitStrikes: [ProviderID: Int] = [:]
  private var failureStrikes: [ProviderID: Int] = [:]
  private var notifiedSignIns: [ProviderID: CredentialState] = [:]
  private var notifiedPace: [WindowKey: [NotificationEvent.Kind: String]] = [:]
  private var staggerPending: Set<ProviderID> = []
  private var refreshGeneration = 0
  private var registryGeneration = 0
  private var scheduleObservationGeneration = 0
  private var lastWidget: WidgetSnapshot?
  private let persistence: SnapshotPersistence
  private var cacheSubmissionTask: Task<Void, Never>?
  public var widgetSink: ((WidgetSnapshot) -> Void)? {
    didSet {
      // The status model is built during init, before AppController attaches the sink, so publish what is already
      // known rather than suppressing it as unchanged.
      guard let widget = lastWidget else { return }
      widgetSink?(widget)
    }
  }

  public init(
    registry: ProviderRegistry,
    settings: Settings,
    state: AppState,
    history: UsageHistoryStore,
    log: LogBuffer,
    clock: Clock = .system,
    publicationClock: Clock = .system,
    cache: SnapshotCache = SnapshotCache(url: nil),
    persistence: SnapshotPersistence? = nil,
    powerState: @escaping @Sendable () -> PowerState = PowerState.current,
    notify: @escaping @MainActor ([NotificationEvent]) -> Void
  ) {
    self.registry = registry
    self.settings = settings
    self.state = state
    self.history = history
    self.log = log
    self.clock = clock
    self.publicationClock = publicationClock
    self.powerState = powerState
    lastPopoverOpenedAt = clock.now()
    self.persistence =
      persistence
      ?? SnapshotPersistence(
        cache: cache,
        failureHandler: { failure in log.logError(failure.message) })
    self.notify = notify
    rebuildStatus()
  }

  public func restoreCachedSnapshots() async {
    let snapshots = await persistence.loadSnapshots()
    var restored: [ProviderID: ProviderState] = [:]
    for (provider, snapshot) in snapshots where registry[provider] != nil {
      guard state.state(for: provider).snapshot == nil else { continue }
      var providerState = state.state(for: provider)
      providerState.snapshot = snapshot
      providerState.availability = .stale
      restored[provider] = providerState
    }
    if !restored.isEmpty {
      state.applyProviderStates(restored)
      rebuildStatus()
    }
  }

  public var isRunning: Bool {
    loop != nil
  }

  public func start() {
    start(after: 0)
  }

  public func resume() {
    start(after: Self.wakeDelay)
  }

  private func start(after delay: TimeInterval) {
    guard loop == nil else { return }
    scheduleObservationGeneration &+= 1
    let generation = scheduleObservationGeneration
    loop = makeLoop(initialDelay: delay)
    observeScheduleInputs(generation: generation)
  }

  public func stop() {
    scheduleObservationGeneration &+= 1
    loop?.cancel()
    loop = nil
    refreshRun?.task.cancel()
    refreshRun = nil
    activeRequest = nil
    activeGeneration = nil
    pending = nil
    state.setNextRefresh(nil)
    state.cancelRefreshing()
  }

  public func refresh(_ request: RefreshRequest) async {
    if let historyClearTask { _ = await historyClearTask.result }
    guard !Task.isCancelled else { return }
    enqueue(request)
    while pending != nil || refreshRun != nil {
      if let run = refreshRun {
        await run.task.value
        if refreshRun?.generation == run.generation { refreshRun = nil }
        continue
      }
      refreshGeneration += 1
      let generation = refreshGeneration
      let registry = registry
      let registryGeneration = registryGeneration
      let task = Task {
        await drainRefreshes(generation: generation, registry: registry, registryGeneration: registryGeneration)
      }
      refreshRun = RefreshRun(generation: generation, registry: registry, task: task)
    }
  }

  public func clearHistory() async throws -> Int {
    if let historyClearTask { return try await historyClearTask.value }
    let wasRunning = loop != nil
    let runningRefresh = refreshRun?.task
    stop()
    let stoppedGeneration = scheduleObservationGeneration
    let task = Task {
      await runningRefresh?.value
      let removed = try await history.clear()
      for provider in registry.providers { await provider.resetAnalyticsHistory() }
      for provider in registry.ids {
        state.update(provider) {
          $0.analytics = nil
          $0.lastAnalyticsAttempt = nil
        }
      }
      notifiedPace.removeAll()
      state.markSamplesChanged()
      return removed
    }
    historyClearTask = task
    defer {
      historyClearTask = nil
      if wasRunning, scheduleObservationGeneration == stoppedGeneration {
        start(after: registry.providers.map(\.pollingPolicy.minimumInterval).min() ?? Self.minimumBackoff)
      }
    }
    return try await task.value
  }

  public func replaceRegistry(_ registry: ProviderRegistry) {
    let previous = self.registry
    self.registry = registry
    registryChanged(from: previous)
  }

  private func registryChanged(from previous: ProviderRegistry) {
    let removed = Set(previous.ids).subtracting(registry.ids)
    registryGeneration += 1
    refreshRun?.task.cancel()
    state.cancelRefreshing()
    state.applySetupStates(registry.setupStates)
    state.removeProviders(removed)
    rateLimitStrikes = rateLimitStrikes.filter { registry[$0.key] != nil }
    failureStrikes = failureStrikes.filter { registry[$0.key] != nil }
    notifiedSignIns = notifiedSignIns.filter { registry[$0.key] != nil }
    reschedule()
  }

  public func reschedule() {
    guard loop != nil else { return }
    loop?.cancel()
    loop = makeLoop()
  }

  public func nextRefreshDate(now: Date? = nil) -> Date? {
    let now = now ?? clock.now()
    return registry.providers.compactMap { provider -> Date? in
      let providerState = state.state(for: provider.id)
      guard settings.isProviderActive(provider.id, state: providerState) else { return nil }
      if let retry = providerState.retryNotBefore { return retry > now ? retry : now }
      let usage =
        providerState.lastAttempt.map {
          $0.addingTimeInterval(
            scheduledUsageInterval(
              provider.pollingPolicy.interval(
                active: state.popoverVisible, requested: TimeInterval(settings.refreshInterval(for: provider.id))),
              for: provider.id, now: now))
        } ?? now
      guard provider.supportsAnalytics else { return usage }
      let analytics =
        providerState.lastAnalyticsAttempt.map {
          $0.addingTimeInterval(
            scheduledInterval(TimeInterval(settings.analyticsRefreshMinutes * 60), for: provider.id))
        } ?? now
      return min(usage, analytics)
    }.min()
  }

  private func enqueue(_ request: RefreshRequest) {
    guard activeRequest?.covers(request) != true, pending?.covers(request) != true else { return }
    pending = pending.map { $0.merged(with: request) } ?? request
  }

  private func drainRefreshes(
    generation: Int,
    registry: ProviderRegistry,
    registryGeneration: Int
  ) async {
    while !Task.isCancelled, let request = pending {
      pending = nil
      activeRequest = request
      activeGeneration = generation
      await perform(request, registry: registry, registryGeneration: registryGeneration)
      if activeGeneration == generation {
        activeRequest = nil
        activeGeneration = nil
      }
    }
  }

  private func makeLoop(initialDelay: TimeInterval = 0) -> Task<Void, Never> {
    Task { [weak self] in
      guard let self, !Task.isCancelled else { return }
      if initialDelay > 0 {
        state.setNextRefresh(clock.now().addingTimeInterval(initialDelay))
        do {
          try await clock.sleep(initialDelay)
        } catch {
          return
        }
      }
      while !Task.isCancelled {
        await refresh(RefreshRequest())
        guard !Task.isCancelled, let deadline = nextRefreshDate() else { break }
        state.setNextRefresh(deadline)
        do {
          try await clock.sleep(max(0, deadline.timeIntervalSince(clock.now())))
        } catch {
          break
        }
      }
    }
  }

  private func observeScheduleInputs(generation: Int) {
    withObservationTracking {
      _ = state.popoverVisible
      _ = settings.enabledProviders
      _ = settings.configuredProviders
      _ = settings.refreshSeconds
      _ = settings.analyticsRefreshMinutes
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.loop != nil, self.scheduleObservationGeneration == generation else { return }
        if self.state.popoverVisible { self.lastPopoverOpenedAt = self.clock.now() }
        self.observeScheduleInputs(generation: generation)
        self.reschedule()
      }
    }
  }

  private func perform(
    _ request: RefreshRequest,
    registry: ProviderRegistry,
    registryGeneration: Int
  ) async {
    let now = clock.now()
    let cycleID = log.debugEnabled ? UUID().uuidString : ""
    let active = settings.activeProviders(states: state.providers)
    let inactive = registry.ids.filter { !active.contains($0) }
    let plans: [ProviderRefreshPlan] = registry.providers.compactMap { provider in
      guard request.providers?.contains(provider.id) ?? true else { return nil }
      guard let plan = plan(for: provider, request: request, now: now) else {
        log.detailed(
          .refresh(
            RefreshDiagnostic.skipped(
              cycleID: cycleID,
              trigger: request.reason.diagnosticName,
              provider: provider.id,
              usagePolicy: request.usage.diagnosticName,
              analyticsPolicy: request.analytics.diagnosticName,
              reason: skipReason(for: provider, request: request, now: now))))
        return nil
      }
      return plan
    }
    guard !plans.isEmpty, !Task.isCancelled else {
      state.disable(inactive)
      return
    }
    let planIDs = plans.map(\.provider.id)
    state.beginRefreshing(planIDs, disabling: inactive)
    var completed = false
    defer {
      if registryGeneration == self.registryGeneration {
        state.finishRefreshing(planIDs, at: completed ? clock.now() : nil)
      }
    }
    var samplesChanged = false
    var analyticsChanged = false
    let generation = refreshGeneration
    let publication = ProviderPublication(clock: publicationClock) { [weak self] providers, events in
      guard let self, activeGeneration == generation, registryGeneration == self.registryGeneration else { return }
      state.applyProviderStates(providers)
      rebuildStatus(now: clock.now())
      let eventsByProvider = Dictionary(grouping: events, by: \.provider)
      let notifications = providers.flatMap { id, providerState in
        paceNotifiedOnce(
          signInNotifiedOnce(eventsByProvider[id] ?? [], for: id, credential: providerState.credentialState),
          snapshot: providerState.snapshot)
      }
      if !notifications.isEmpty { notify(notifications) }
    }
    defer { publication.cancel() }
    await withTaskGroup(
      of: (ProviderID, ProviderFetchResult, ProviderApplyResult, Bool, Int).self
    ) { group in
      for plan in plans {
        let provider = plan.provider
        let options = FetchOptions(
          includeAnalytics: plan.includeAnalytics, analyticsDays: settings.historyRetentionDays)
        group.addTask {
          let clock = ContinuousClock()
          let started = clock.now
          let result = await DiagnosticSignposts.refresh.withInterval("Provider refresh") {
            await provider.fetch(now: now, options: options)
          }
          let credentialStatus: ProviderCredentialStatus
          if let fetched = result.credentialStatus {
            credentialStatus = fetched
          } else {
            credentialStatus = await ProviderCredentialStatus(
              state: provider.credentialState(now: now),
              health: provider.credentialHealth(now: now))
          }
          let duration = Self.milliseconds(started.duration(to: clock.now))
          // Serial persistence lets SwiftUI lay out between each ready provider result.
          let applied = await self.apply(
            provider.id,
            result: result,
            credentialStatus: credentialStatus,
            includedAnalytics: options.includeAnalytics,
            retryInterval: plan.retryInterval,
            registryGeneration: registryGeneration,
            now: now)
          return (
            provider.id,
            result,
            applied,
            options.includeAnalytics,
            duration
          )
        }
      }
      for await (id, result, applied, includedAnalytics, duration) in group {
        guard !Task.isCancelled else {
          group.cancelAll()
          break
        }
        guard registryGeneration == self.registryGeneration else { continue }
        if let providerState = applied.providerState {
          publication.append(id, state: providerState, events: applied.events)
        }
        samplesChanged = applied.samplesChanged || samplesChanged
        analyticsChanged = applied.analyticsChanged || analyticsChanged
        log.detailed(
          .refresh(
            RefreshDiagnostic(
              cycleID: cycleID,
              trigger: request.reason.diagnosticName,
              provider: id,
              usagePolicy: request.usage.diagnosticName,
              analyticsPolicy: request.analytics.diagnosticName,
              outcome: result.outcome.diagnosticOutcome,
              durationMilliseconds: duration,
              includeAnalytics: includedAnalytics,
              analyticsReturned: result.analytics != nil,
              analyticsPointCount: result.analytics?.points.count ?? 0,
              warnings: result.warnings)))
      }
    }
    guard !Task.isCancelled, registryGeneration == self.registryGeneration else { return }
    publication.flush()
    if samplesChanged {
      state.markSamplesChanged()
    } else if analyticsChanged {
      state.markHistoryChanged()
    }
    storeCache()
    completed = true
  }

  nonisolated private static func milliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
  }

  func storeCache() {
    let snapshots = state.snapshots
    let writesUsageFile = settings.writeUsageFile
    let previous = cacheSubmissionTask
    cacheSubmissionTask = Task { [persistence] in
      await previous?.value
      await persistence.submitSnapshots(snapshots, writesUsageFile: writesUsageFile)
    }
  }

  public func flushPersistence() async {
    await cacheSubmissionTask?.value
    await persistence.flush()
  }

  private func plan(
    for provider: any UsageProvider, request: RefreshRequest, now: Date
  ) -> ProviderRefreshPlan? {
    let providerState = state.state(for: provider.id)
    let targetedProbe = request.reason == .userInitiated && request.providers?.contains(provider.id) == true
    guard settings.isProviderActive(provider.id, state: providerState) || targetedProbe else { return nil }
    if let blocked = providerState.retryNotBefore, blocked > now,
      request.reason != .userInitiated || providerState.availability == .rateLimited
    {
      return nil
    }
    let retryDue = providerState.retryNotBefore != nil
    let interval = provider.pollingPolicy.interval(
      active: state.popoverVisible, requested: TimeInterval(settings.refreshInterval(for: provider.id)))
    let usageInterval =
      request.reason == .scheduled ? scheduledUsageInterval(interval, for: provider.id, now: now) : interval
    let analyticsInterval = TimeInterval(settings.analyticsRefreshMinutes * 60)
    let usageDue =
      request.usage != .skip
      && (retryDue || due(request.usage, lastAttempt: providerState.lastAttempt, interval: usageInterval, now: now))
    let analyticsDue =
      provider.supportsAnalytics
      && due(
        request.analytics,
        lastAttempt: providerState.lastAnalyticsAttempt,
        interval: request.reason == .scheduled
          ? scheduledInterval(analyticsInterval, for: provider.id) : analyticsInterval,
        now: now)
    guard usageDue || analyticsDue else { return nil }
    return ProviderRefreshPlan(provider: provider, includeAnalytics: analyticsDue, retryInterval: interval)
  }

  private func skipReason(
    for provider: any UsageProvider, request: RefreshRequest, now: Date
  ) -> DiagnosticRefreshSkipReason {
    let providerState = state.state(for: provider.id)
    guard settings.isProviderActive(provider.id, state: providerState) else {
      return settings.providerOverride(for: provider.id) == false ? .disabled : .notDiscovered
    }
    if let blocked = providerState.retryNotBefore, blocked > now,
      request.reason != .userInitiated || providerState.availability == .rateLimited
    {
      return .retryBackoff
    }
    if request.usage == .skip, request.analytics != .skip, provider.supportsAnalytics { return .analyticsNotDue }
    return .noWork
  }

  private func due(_ policy: RefreshPolicy, lastAttempt: Date?, interval: TimeInterval, now: Date) -> Bool {
    switch policy {
    case .skip: false
    case .force: true
    case .ifDue: lastAttempt.map { now.timeIntervalSince($0) >= interval - 1 } ?? true
    }
  }

  // Every provider's first attempt shares one timestamp, so the second is pushed out by a provider-specific phase;
  // after that each keeps the user's interval and the offsets persist through the differing attempt times.
  private func scheduledInterval(_ interval: TimeInterval, for id: ProviderID) -> TimeInterval {
    guard !state.popoverVisible, registry.providers.count > 1, staggerPending.contains(id),
      let index = ProviderID.allCases.firstIndex(of: id)
    else { return interval }
    return interval * (1 + Double(index) * 0.02)
  }

  // Low power or thermal pressure doubles the wait and an hour without the popover triples it; the input already
  // sits at or above the vendor floor, so only the ceiling needs enforcing.
  private func scheduledUsageInterval(_ interval: TimeInterval, for id: ProviderID, now: Date) -> TimeInterval {
    let throttled = powerState().throttlesScanning ? Self.throttledMultiplier : 1
    let idle =
      !state.popoverVisible && now.timeIntervalSince(lastPopoverOpenedAt) >= Self.idleThreshold
      ? Self.idleMultiplier : 1
    return min(scheduledInterval(interval, for: id) * throttled * idle, TimeInterval(Settings.maximumRefreshSeconds))
  }

  public func nextAttempt(for id: ProviderID) -> Date? {
    state.state(for: id).retryNotBefore
  }

  func rateLimitBlock(
    for id: ProviderID,
    retryAfter: TimeInterval?,
    retryInterval: TimeInterval = RefreshCoordinator.minimumBackoff
  ) -> TimeInterval {
    let strikes = (rateLimitStrikes[id] ?? 0) + 1
    rateLimitStrikes[id] = strikes
    let base = max(max(Self.rateLimitBackoff, Self.minimumBackoff), retryInterval)
    let localBackoff = min(base * pow(2, Double(strikes - 1)), Self.maximumBackoff)
    return max(retryAfter ?? 0, localBackoff)
  }

  func failureBlock(
    for id: ProviderID,
    retryInterval: TimeInterval = RefreshCoordinator.minimumBackoff
  ) -> TimeInterval {
    let strikes = (failureStrikes[id] ?? 0) + 1
    failureStrikes[id] = strikes
    let base = max(max(Self.networkBackoff, Self.minimumBackoff), retryInterval)
    return min(base * pow(2, Double(strikes - 1)), Self.maximumBackoff)
  }

  private func apply(
    _ id: ProviderID,
    result: ProviderFetchResult,
    credentialStatus: ProviderCredentialStatus,
    includedAnalytics: Bool,
    retryInterval: TimeInterval,
    registryGeneration: Int,
    now: Date
  ) async -> ProviderApplyResult {
    guard !Task.isCancelled, registryGeneration == self.registryGeneration, registry[id] != nil else {
      return .empty
    }
    guard settings.providerOverride(for: id) != false else {
      return ProviderApplyResult(
        providerState: ProviderState(availability: .disabled), events: [], samplesChanged: false,
        analyticsChanged: false)
    }
    let previous = state.state(for: id)
    var next = previous
    let accountChanged =
      result.outcome.snapshot?.accountFingerprint != nil
      && result.outcome.snapshot?.accountFingerprint != previous.snapshot?.accountFingerprint
    if accountChanged {
      next.analytics = nil
      notifiedPace = notifiedPace.filter { $0.key.provider != id }
    }
    next.isRefreshing = false
    if previous.lastAttempt == nil { staggerPending.insert(id) } else { staggerPending.remove(id) }
    next.lastAttempt = now
    if includedAnalytics { next.lastAnalyticsAttempt = now }
    next.warnings = result.warnings
    next.credentialState = credentialStatus.state
    if credentialStatus.health != .unchecked { next.credentialHealth = credentialStatus.health }
    next.recoveryIssue = result.recoveryIssue
    var samplesChanged = false
    var analyticsChanged = accountChanged
    switch result.outcome {
    case .success(let snapshot):
      next.snapshot = snapshot
      next.availability = .current
      next.lastError = nil
      next.lastSuccess = now
      next.retryNotBefore = nil
      rateLimitStrikes[id] = nil
      failureStrikes[id] = nil
      notifiedSignIns[id] = nil
      samplesChanged = await record(snapshot, now: now)
    case .partial(let snapshot, let reason):
      rateLimitStrikes[id] = nil
      if accountChanged, let fingerprint = snapshot.accountFingerprint {
        do {
          try await history.activateAccount(id, fingerprint: fingerprint)
          analyticsChanged = true
        } catch {
          log.logError("history account change failed provider=\(id.rawValue) error=\(error)")
        }
      }
      if accountChanged || (previous.snapshot.map({ snapshot.fetchedAt >= $0.fetchedAt }) ?? true) {
        next.snapshot = snapshot
      }
      next.availability = .stale
      next.lastError = reason
      next.retryNotBefore = now.addingTimeInterval(failureBlock(for: id, retryInterval: retryInterval))
    case .notAuthenticated(let reason):
      rateLimitStrikes[id] = nil
      next.availability = .authenticationRequired
      next.lastError = reason
      next.retryNotBefore = now.addingTimeInterval(failureBlock(for: id, retryInterval: retryInterval))
    case .networkUnavailable(let reason):
      rateLimitStrikes[id] = nil
      next.availability = .networkUnavailable
      next.lastError = reason
      next.retryNotBefore = now.addingTimeInterval(failureBlock(for: id, retryInterval: retryInterval))
    case .rateLimited(let reason, let retryAfter):
      failureStrikes[id] = nil
      let block = rateLimitBlock(for: id, retryAfter: retryAfter, retryInterval: retryInterval)
      let until = now.addingTimeInterval(block)
      next.availability = .rateLimited
      next.lastError = "\(reason). Next attempt \(Format.resetClock(until, now: now))."
      next.retryNotBefore = until
    case .failed(let reason):
      rateLimitStrikes[id] = nil
      next.availability = .unavailable
      next.lastError = reason
      next.retryNotBefore = now.addingTimeInterval(failureBlock(for: id, retryInterval: retryInterval))
    }
    if let analytics = result.analytics {
      next.analytics = next.analytics?.merging(analytics, retentionDays: settings.historyRetentionDays) ?? analytics
      do {
        let recorded = try await history.record(analytics)
        analyticsChanged = analyticsChanged || recorded > 0
      } catch {
        log.logError("history analytics write failed provider=\(id.rawValue) error=\(error)")
      }
    } else if result.outcome.snapshot != nil, next.analytics == nil {
      next.analytics = await storedAnalytics(id, now: now)
    }
    let isActive = settings.isProviderActive(id, state: next)
    if !isActive {
      next.availability = .disabled
      next.lastError = nil
      next.warnings = []
      next.recoveryIssue = nil
    }
    if isActive, let error = next.lastError, error != previous.lastError {
      log.logError(
        "refresh provider=\(id.rawValue) outcome=\(next.availability.rawValue) error=\(error)", category: .refresh)
    }
    log.logDebug(
      "refresh provider=\(id.rawValue) outcome=\(next.availability.rawValue) "
        + "windows=\(next.snapshot?.windows.count ?? 0)"
    )
    var recentSamples: [WindowKey: [UsageSample]] = [:]
    if isActive, settings.notifications.enabled, settings.notifications.notifyOnPace, let snapshot = next.snapshot {
      do {
        recentSamples = Dictionary(
          grouping: try await history.samples(
            keys: snapshot.windows.map { WindowKey(id, $0) },
            from: now.addingTimeInterval(-PaceEstimate.slopeWindow), to: now), by: \.key)
      } catch {
        log.logDebug("pace notification samples unavailable provider=\(id.rawValue) error=\(error)")
      }
    }
    let events =
      isActive
      ? NotificationPlanner.events(
        previous: accountChanged ? nil : previous.snapshot,
        current: next.snapshot,
        previousAvailability: previous.availability,
        currentAvailability: next.availability,
        provider: id,
        settings: settings.notifications,
        credentialMissing: credentialStatus.state.isMissing,
        workdays: settings.paceWorkdays,
        samples: recentSamples,
        now: now)
      : []
    return ProviderApplyResult(
      providerState: next,
      events: events,
      samplesChanged: samplesChanged,
      analyticsChanged: analyticsChanged
    )
  }

  private func paceNotifiedOnce(_ events: [NotificationEvent], snapshot: ProviderSnapshot?) -> [NotificationEvent] {
    if let snapshot {
      let keys = Set(snapshot.windows.map { WindowKey(snapshot.provider, $0) })
      notifiedPace = notifiedPace.filter { $0.key.provider != snapshot.provider || keys.contains($0.key) }
    }
    return events.filter { event in
      guard event.kind == .willRunOut || event.kind == .aheadOfPace, let key = event.window else { return true }
      guard notifiedPace[key]?[event.kind] != event.id else { return false }
      notifiedPace[key, default: [:]][event.kind] = event.id
      return true
    }
  }

  // Availability flaps (sign-in needed, stale, sign-in needed) would otherwise re-announce the same dead credential.
  private func signInNotifiedOnce(
    _ events: [NotificationEvent], for id: ProviderID, credential: CredentialState?
  ) -> [NotificationEvent] {
    guard events.contains(where: { $0.kind == .authentication }) else { return events }
    guard notifiedSignIns[id] != credential else { return events.filter { $0.kind != .authentication } }
    notifiedSignIns[id] = credential
    return events
  }

  private func record(_ snapshot: ProviderSnapshot, now: Date) async -> Bool {
    do {
      return try await history.record(snapshot, now: now) > 0
    } catch {
      log.logError("history write failed provider=\(snapshot.provider.rawValue) error=\(error)")
      return false
    }
  }

  private func storedAnalytics(_ id: ProviderID, now: Date) async -> ProviderAnalytics? {
    let start = DayStamp.string(now.addingTimeInterval(-TimeInterval(settings.historyRetentionDays) * 86400))
    guard let points = try? await history.analytics(provider: id, from: start, to: DayStamp.string(now)),
      !points.isEmpty
    else { return nil }
    return ProviderAnalytics(provider: id, points: points, fetchedAt: now)
  }

  public func rebuildStatus(now: Date? = nil, publishWidget: Bool = true) {
    let active = settings.activeProviders(states: state.providers)
    let snapshots = state.snapshots.filter { active.contains($0.key) }
    let availability = state.availability.filter { active.contains($0.key) }
    let available = snapshots.keys.sorted().flatMap { provider in
      snapshots[provider]!.windows.map { WindowKey(provider, $0) }
    }
    let selected =
      settings.hasCustomSelection ? settings.selectedWindows : StatusItemBuilder.defaultSelection(snapshots)
    let selection = SettingsOrderDraft(
      providers: settings.providerOrder, models: settings.modelOrder, available: available
    ).orderedSelection(selected)
    let input = StatusItemInput(
      snapshots: snapshots,
      availability: availability,
      selectedKeys: selection,
      format: settings.statusFormat,
      customTemplate: settings.customTemplate,
      decimals: settings.percentDecimals,
      hideZeroCells: settings.hideZeroCells,
      order: settings.windowOrder,
      labels: settings.shortLabels,
      now: now ?? clock.now(),
      display: settings.usageDisplay
    )
    state.setStatusLadder(
      settings.adaptiveWidth ? StatusItemBuilder.candidates(input) : [StatusItemBuilder.build(input)])
    // Reloading widget timelines is an XPC round trip, so it waits for the cycle to finish rather than firing once
    // per provider as each one reports.
    guard publishWidget else { return }
    let widget = WidgetSnapshot.build(
      snapshots: snapshots, availability: availability, selectedKeys: selection, display: settings.usageDisplay,
      now: snapshots.values.map(\.fetchedAt).max() ?? input.now)
    if widget.shouldPublish(after: lastWidget) {
      lastWidget = widget
      widgetSink?(widget)
    }
  }
}

@MainActor
private final class ProviderPublication {
  private let clock: Clock
  private let publish: ([ProviderID: ProviderState], [NotificationEvent]) -> Void
  private var states: [ProviderID: ProviderState] = [:]
  private var events: [NotificationEvent] = []
  private var scheduled: Task<Void, Never>?

  init(clock: Clock, publish: @escaping ([ProviderID: ProviderState], [NotificationEvent]) -> Void) {
    self.clock = clock
    self.publish = publish
  }

  func append(_ provider: ProviderID, state: ProviderState, events: [NotificationEvent]) {
    states[provider] = state
    self.events += events
    guard scheduled == nil else { return }
    // Ready providers share one UI update without waiting for a slow provider to finish.
    scheduled = Task { [weak self, clock] in
      guard (try? await clock.sleep(1.0 / 60)) != nil, !Task.isCancelled else { return }
      self?.flush()
    }
  }

  func flush() {
    guard !states.isEmpty else { return }
    publish(states, events)
    cancel()
  }

  func cancel() {
    scheduled?.cancel()
    scheduled = nil
    states.removeAll()
    events.removeAll()
  }
}

private extension RefreshReason {
  var diagnosticName: String {
    switch self {
    case .scheduled: "scheduled"
    case .popoverOpened: "popover-opened"
    case .userInitiated: "user-initiated"
    case .export: "export"
    }
  }
}

private extension RefreshPolicy {
  var diagnosticName: String {
    switch self {
    case .skip: "skip"
    case .ifDue: "if-due"
    case .force: "force"
    }
  }
}

private extension ProviderFetchOutcome {
  var diagnosticOutcome: DiagnosticRefreshOutcome {
    switch self {
    case .success: .success
    case .partial: .partial
    case .notAuthenticated: .authenticationRequired
    case .networkUnavailable: .networkUnavailable
    case .rateLimited: .rateLimited
    case .failed: .failed
    }
  }
}
