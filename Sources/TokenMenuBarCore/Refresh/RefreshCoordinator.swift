import Foundation

public struct RefreshRequest: Sendable, Equatable {
  public var interactive: Bool
  public var force: Bool
  public var analytics: Bool

  public init(interactive: Bool = false, force: Bool = false, analytics: Bool = false) {
    self.interactive = interactive
    self.force = force
    self.analytics = analytics
  }

  func merged(with other: RefreshRequest) -> RefreshRequest {
    RefreshRequest(
      interactive: interactive || other.interactive, force: force || other.force,
      analytics: analytics || other.analytics)
  }
}

@MainActor
public final class RefreshCoordinator {
  public static let rateLimitBackoff: TimeInterval = 300
  public static let minimumBackoff: TimeInterval = 60
  public static let maximumBackoff: TimeInterval = 1800
  public static let networkBackoff: TimeInterval = 60
  public static let tickInterval: TimeInterval = 60

  public var registry: ProviderRegistry
  private let settings: Settings
  private let state: AppState
  private let history: UsageHistoryStore
  private let log: LogBuffer
  private let clock: Clock
  private let notify: @MainActor ([NotificationEvent]) -> Void
  private var loop: Task<Void, Never>?
  private var inFlight: Task<Void, Never>?
  private var pending: RefreshRequest?
  private var retryNotBefore: [ProviderID: Date] = [:]
  private var lastAnalytics: [ProviderID: Date] = [:]
  private var lastAttempt: [ProviderID: Date] = [:]
  private var rateLimitStrikes: [ProviderID: Int] = [:]

  public init(
    registry: ProviderRegistry,
    settings: Settings,
    state: AppState,
    history: UsageHistoryStore,
    log: LogBuffer,
    clock: Clock = .system,
    notify: @escaping @MainActor ([NotificationEvent]) -> Void
  ) {
    self.registry = registry
    self.settings = settings
    self.state = state
    self.history = history
    self.log = log
    self.clock = clock
    self.notify = notify
  }

  public var isRunning: Bool {
    loop != nil
  }

  public func start() {
    guard loop == nil else { return }
    loop = Task {
      var keepGoing = true
      while keepGoing {
        await refresh(RefreshRequest())
        keepGoing = (try? await clock.sleep(Self.tickInterval)) != nil
      }
    }
  }

  public func stop() {
    loop?.cancel()
    loop = nil
  }

  public func refresh(_ request: RefreshRequest) async {
    if let inFlight {
      pending = pending.map { $0.merged(with: request) } ?? request
      await inFlight.value
      return
    }
    let task = Task { await perform(request) }
    inFlight = task
    await task.value
    inFlight = nil
    if let next = pending {
      pending = nil
      await refresh(next)
    }
  }

  private func perform(_ request: RefreshRequest) async {
    let now = clock.now()
    state.setRefreshing(true, at: nil)
    defer { state.setRefreshing(false, at: clock.now()) }
    let enabled = settings.enabledProviders
    for provider in registry.ids where !enabled.contains(provider) {
      state.update(provider) { $0 = ProviderState(availability: .disabled) }
    }
    let due = registry.providers.filter { isDue($0, request: request, now: now) }
    for provider in due { state.update(provider.id) { $0.isRefreshing = true } }
    let analyticsDue = Set(
      due.map(\.id).filter { id in
        request.analytics || request.force
          || lastAnalytics[id].map { now.timeIntervalSince($0) >= TimeInterval(settings.analyticsRefreshMinutes * 60) }
            ?? true
      }
    )
    var events: [NotificationEvent] = []
    await withTaskGroup(of: (ProviderID, ProviderFetchResult, CredentialState).self) { group in
      for provider in due {
        let options = FetchOptions(includeAnalytics: analyticsDue.contains(provider.id))
        group.addTask {
          (provider.id, await provider.fetch(now: now, options: options), provider.credentialState(now: now))
        }
      }
      for await (id, result, credentialState) in group {
        events += await apply(id, result: result, credentialState: credentialState, now: now)
        rebuildStatus(now: now)
      }
    }
    rebuildStatus(now: now)
    if !events.isEmpty { notify(events) }
  }

  func isDue(_ provider: any UsageProvider, request: RefreshRequest, now: Date) -> Bool {
    guard settings.enabledProviders.contains(provider.id) else { return false }
    if request.force { return true }
    if let blocked = retryNotBefore[provider.id], blocked > now { return false }
    let interval = provider.pollingPolicy.interval(
      active: state.popoverVisible, requested: TimeInterval(settings.refreshInterval(for: provider.id)))
    return lastAttempt[provider.id].map { now.timeIntervalSince($0) >= interval - 1 } ?? true
  }

  public func nextAttempt(for id: ProviderID) -> Date? {
    retryNotBefore[id]
  }

  func rateLimitBlock(for id: ProviderID, retryAfter: TimeInterval?) -> TimeInterval {
    let strikes = (rateLimitStrikes[id] ?? 0) + 1
    rateLimitStrikes[id] = strikes
    let base = max(retryAfter ?? Self.rateLimitBackoff, Self.minimumBackoff)
    return min(base * pow(2, Double(strikes - 1)), Self.maximumBackoff)
  }

  private func apply(
    _ id: ProviderID, result: ProviderFetchResult, credentialState: CredentialState, now: Date
  ) async -> [NotificationEvent] {
    let previous = state.state(for: id)
    var next = previous
    next.isRefreshing = false
    next.lastAttempt = now
    lastAttempt[id] = now
    next.warnings = result.warnings
    next.credentialState = credentialState
    switch result.outcome {
    case .success(let snapshot):
      next.snapshot = snapshot
      next.availability = .current
      next.lastError = nil
      next.lastSuccess = now
      retryNotBefore[id] = nil
      rateLimitStrikes[id] = nil
      await record(snapshot, now: now)
    case .partial(let snapshot, let reason):
      if previous.snapshot == nil || snapshot.fetchedAt >= (previous.snapshot?.fetchedAt ?? .distantPast) {
        next.snapshot = snapshot
      }
      next.availability = .stale
      next.lastError = reason
      retryNotBefore[id] = now.addingTimeInterval(Self.networkBackoff)
    case .notAuthenticated(let reason):
      next.availability = .authenticationRequired
      next.lastError = reason
      retryNotBefore[id] = now.addingTimeInterval(Self.networkBackoff)
    case .networkUnavailable(let reason):
      next.availability = .networkUnavailable
      next.lastError = reason
      retryNotBefore[id] = now.addingTimeInterval(Self.networkBackoff)
    case .rateLimited(let reason, let retryAfter):
      let block = rateLimitBlock(for: id, retryAfter: retryAfter)
      let until = now.addingTimeInterval(block)
      next.availability = .rateLimited
      next.lastError = "\(reason). Next attempt \(Format.resetClock(until, now: now))."
      retryNotBefore[id] = until
    case .failed(let reason):
      next.availability = .unavailable
      next.lastError = reason
      retryNotBefore[id] = now.addingTimeInterval(Self.networkBackoff)
    }
    if let analytics = result.analytics {
      next.analytics = analytics
      lastAnalytics[id] = now
      do {
        try await history.record(analytics)
      } catch {
        log.logError("history analytics write failed provider=\(id.rawValue) error=\(error)")
      }
    } else if result.outcome.snapshot != nil, next.analytics == nil {
      next.analytics = await storedAnalytics(id, now: now)
    }
    if let error = next.lastError, error != previous.lastError {
      log.logError("refresh provider=\(id.rawValue) outcome=\(next.availability.rawValue) error=\(error)")
    }
    log.logDebug(
      "refresh provider=\(id.rawValue) outcome=\(next.availability.rawValue) windows=\(next.snapshot?.windows.count ?? 0)"
    )
    state.update(id) { $0 = next }
    return NotificationPlanner.events(
      previous: previous.snapshot,
      current: next.snapshot,
      previousAvailability: previous.availability,
      currentAvailability: next.availability,
      provider: id,
      settings: settings.notifications,
      now: now
    )
  }

  private func record(_ snapshot: ProviderSnapshot, now: Date) async {
    do {
      try await history.record(snapshot, now: now)
    } catch {
      log.logError("history write failed provider=\(snapshot.provider.rawValue) error=\(error)")
    }
  }

  private func storedAnalytics(_ id: ProviderID, now: Date) async -> ProviderAnalytics? {
    let start = DayStamp.string(now.addingTimeInterval(-60 * 86400))
    guard let points = try? await history.analytics(provider: id, from: start, to: DayStamp.string(now)),
      !points.isEmpty
    else { return nil }
    return ProviderAnalytics(provider: id, points: points, fetchedAt: now)
  }

  public func rebuildStatus(now: Date? = nil) {
    let snapshots = state.snapshots
    let selection =
      settings.hasCustomSelection ? settings.selectedWindows : StatusItemBuilder.defaultSelection(snapshots)
    let model = StatusItemBuilder.build(
      StatusItemInput(
        snapshots: snapshots,
        availability: state.availability,
        selectedKeys: selection,
        format: settings.statusFormat,
        customTemplate: settings.customTemplate,
        decimals: settings.percentDecimals,
        hideZeroCells: settings.hideZeroCells,
        order: settings.windowOrder,
        labels: settings.shortLabels,
        now: now ?? clock.now()
      )
    )
    state.setStatusModel(model)
  }
}
