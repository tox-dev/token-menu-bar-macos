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

private struct ProviderApplyResult {
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

  public private(set) var registry: ProviderRegistry
  private let settings: Settings
  private let state: AppState
  private let history: UsageHistoryStore
  private let log: LogBuffer
  private let clock: Clock
  private let notify: @MainActor ([NotificationEvent]) -> Void
  private var loop: Task<Void, Never>?
  private var refreshRun: RefreshRun?
  private var activeRequest: RefreshRequest?
  private var activeGeneration: Int?
  private var pending: RefreshRequest?
  private var rateLimitStrikes: [ProviderID: Int] = [:]
  private var refreshGeneration = 0
  private var registryGeneration = 0
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
    cache: SnapshotCache = SnapshotCache(url: nil),
    persistence: SnapshotPersistence? = nil,
    notify: @escaping @MainActor ([NotificationEvent]) -> Void
  ) {
    self.registry = registry
    self.settings = settings
    self.state = state
    self.history = history
    self.log = log
    self.clock = clock
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
    guard loop == nil else { return }
    observeScheduleInputs()
    loop = makeLoop()
  }

  public func stop() {
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
            provider.pollingPolicy.interval(
              active: state.popoverVisible, requested: TimeInterval(settings.refreshInterval(for: provider.id))))
        } ?? now
      guard provider.supportsAnalytics else { return usage }
      let analytics =
        providerState.lastAnalyticsAttempt.map {
          $0.addingTimeInterval(TimeInterval(settings.analyticsRefreshMinutes * 60))
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

  private func makeLoop() -> Task<Void, Never> {
    Task { [weak self] in
      guard let self else { return }
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

  private func observeScheduleInputs() {
    withObservationTracking {
      _ = state.popoverVisible
      _ = settings.enabledProviders
      _ = settings.configuredProviders
      _ = settings.refreshSeconds
      _ = settings.analyticsRefreshMinutes
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.loop != nil else { return }
        self.observeScheduleInputs()
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
    var events: [NotificationEvent] = []
    var providerStates: [ProviderID: ProviderState] = [:]
    var samplesChanged = false
    var analyticsChanged = false
    await withTaskGroup(
      of: (ProviderID, ProviderFetchResult, ProviderCredentialStatus, Bool, TimeInterval, Int).self
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
          return (
            provider.id,
            result,
            credentialStatus,
            options.includeAnalytics,
            plan.retryInterval,
            Self.milliseconds(started.duration(to: clock.now))
          )
        }
      }
      for await (id, result, credentialStatus, includedAnalytics, retryInterval, duration) in group {
        guard !Task.isCancelled else {
          group.cancelAll()
          break
        }
        let applied = await apply(
          id,
          result: result,
          credentialStatus: credentialStatus,
          includedAnalytics: includedAnalytics,
          retryInterval: retryInterval,
          registryGeneration: registryGeneration,
          now: now)
        events += applied.events
        if let providerState = applied.providerState { providerStates[id] = providerState }
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
    state.applyProviderStates(providerStates)
    if samplesChanged {
      state.markSamplesChanged()
    } else if analyticsChanged {
      state.markHistoryChanged()
    }
    rebuildStatus(now: now)
    storeCache()
    if !events.isEmpty { notify(events) }
    completed = true
  }

  nonisolated private static func milliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
  }

  func storeCache() {
    let snapshots = state.snapshots
    let previous = cacheSubmissionTask
    cacheSubmissionTask = Task { [persistence] in
      await previous?.value
      await persistence.submitSnapshots(snapshots)
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
    let usageDue =
      request.usage != .skip
      && (retryDue || due(request.usage, lastAttempt: providerState.lastAttempt, interval: interval, now: now))
    let analyticsDue =
      provider.supportsAnalytics
      && due(
        request.analytics,
        lastAttempt: providerState.lastAnalyticsAttempt,
        interval: TimeInterval(settings.analyticsRefreshMinutes * 60),
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
    let base = max(max(retryAfter ?? Self.rateLimitBackoff, Self.minimumBackoff), retryInterval)
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
    guard registryGeneration == self.registryGeneration, registry[id] != nil else { return .empty }
    guard settings.providerOverride(for: id) != false else {
      return ProviderApplyResult(
        providerState: ProviderState(availability: .disabled), events: [], samplesChanged: false,
        analyticsChanged: false)
    }
    let previous = state.state(for: id)
    var next = previous
    next.isRefreshing = false
    next.lastAttempt = now
    if includedAnalytics { next.lastAnalyticsAttempt = now }
    next.warnings = result.warnings
    next.credentialState = credentialStatus.state
    if credentialStatus.health != .unchecked { next.credentialHealth = credentialStatus.health }
    next.recoveryIssue = result.recoveryIssue
    var samplesChanged = false
    var analyticsChanged = false
    switch result.outcome {
    case .success(let snapshot):
      next.snapshot = snapshot
      next.availability = .current
      next.lastError = nil
      next.lastSuccess = now
      next.retryNotBefore = nil
      rateLimitStrikes[id] = nil
      samplesChanged = await record(snapshot, now: now)
    case .partial(let snapshot, let reason):
      if previous.snapshot.map({ snapshot.fetchedAt >= $0.fetchedAt }) ?? true {
        next.snapshot = snapshot
      }
      next.availability = .stale
      next.lastError = reason
      next.retryNotBefore = now.addingTimeInterval(max(Self.networkBackoff, retryInterval))
    case .notAuthenticated(let reason):
      next.availability = .authenticationRequired
      next.lastError = reason
      next.retryNotBefore = now.addingTimeInterval(max(Self.networkBackoff, retryInterval))
    case .networkUnavailable(let reason):
      next.availability = .networkUnavailable
      next.lastError = reason
      next.retryNotBefore = now.addingTimeInterval(max(Self.networkBackoff, retryInterval))
    case .rateLimited(let reason, let retryAfter):
      let block = rateLimitBlock(for: id, retryAfter: retryAfter, retryInterval: retryInterval)
      let until = now.addingTimeInterval(block)
      next.availability = .rateLimited
      next.lastError = "\(reason). Next attempt \(Format.resetClock(until, now: now))."
      next.retryNotBefore = until
    case .failed(let reason):
      next.availability = .unavailable
      next.lastError = reason
      next.retryNotBefore = now.addingTimeInterval(max(Self.networkBackoff, retryInterval))
    }
    if let analytics = result.analytics {
      next.analytics = previous.analytics?.merging(analytics, retentionDays: settings.historyRetentionDays) ?? analytics
      do {
        analyticsChanged = try await history.record(analytics) > 0
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
    return ProviderApplyResult(
      providerState: next,
      events: isActive
        ? NotificationPlanner.events(
          previous: previous.snapshot,
          current: next.snapshot,
          previousAvailability: previous.availability,
          currentAvailability: next.availability,
          provider: id,
          settings: settings.notifications,
          credentialMissing: credentialStatus.state.isMissing,
          now: now)
        : [],
      samplesChanged: samplesChanged,
      analyticsChanged: analyticsChanged
    )
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
    let start = DayStamp.string(now.addingTimeInterval(-60 * 86400))
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
      now: now ?? clock.now()
    )
    state.setStatusLadder(
      settings.adaptiveWidth ? StatusItemBuilder.candidates(input) : [StatusItemBuilder.build(input)])
    // Reloading widget timelines is an XPC round trip, so it waits for the cycle to finish rather than firing once
    // per provider as each one reports.
    guard publishWidget else { return }
    let widget = WidgetSnapshot.build(
      snapshots: snapshots, availability: availability, selectedKeys: selection,
      now: snapshots.values.map(\.fetchedAt).max() ?? input.now)
    if widget != lastWidget {
      lastWidget = widget
      widgetSink?(widget)
    }
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
