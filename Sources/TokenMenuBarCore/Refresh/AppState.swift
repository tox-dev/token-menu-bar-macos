import Foundation
import Observation

public struct ProviderState: Sendable, Equatable {
  public var snapshot: ProviderSnapshot?
  public var analytics: ProviderAnalytics?
  public var availability: QuotaAvailability
  public var lastError: String?
  public var warnings: [String]
  public var lastAttempt: Date?
  public var lastAnalyticsAttempt: Date?
  public var lastSuccess: Date?
  public var retryNotBefore: Date?
  public var credentialState: CredentialState?
  public var credentialHealth: ProviderCredentialHealth
  public var serviceHealth: ProviderServiceHealth
  public var resourceAccess: [ResourceAccessState]
  public var recoveryIssue: ProviderRecoveryIssue?
  public var isRefreshing: Bool

  public init(
    snapshot: ProviderSnapshot? = nil,
    analytics: ProviderAnalytics? = nil,
    availability: QuotaAvailability = .loading,
    lastError: String? = nil,
    warnings: [String] = [],
    lastAttempt: Date? = nil,
    lastAnalyticsAttempt: Date? = nil,
    lastSuccess: Date? = nil,
    retryNotBefore: Date? = nil,
    credentialState: CredentialState? = nil,
    credentialHealth: ProviderCredentialHealth = .unchecked,
    serviceHealth: ProviderServiceHealth = .unchecked,
    resourceAccess: [ResourceAccessState] = [],
    recoveryIssue: ProviderRecoveryIssue? = nil,
    isRefreshing: Bool = false
  ) {
    self.snapshot = snapshot
    self.analytics = analytics
    self.availability = availability
    self.lastError = lastError
    self.warnings = warnings
    self.lastAttempt = lastAttempt
    self.lastAnalyticsAttempt = lastAnalyticsAttempt
    self.lastSuccess = lastSuccess
    self.retryNotBefore = retryNotBefore
    self.credentialState = credentialState
    self.credentialHealth = credentialHealth
    self.serviceHealth = serviceHealth
    self.resourceAccess = resourceAccess
    self.recoveryIssue = recoveryIssue
    self.isRefreshing = isRefreshing
  }

  public var isStale: Bool {
    snapshot != nil && availability != .current
  }
}

@MainActor
@Observable
public final class AppState {
  public private(set) var providers: [ProviderID: ProviderState] = [:]
  private var providerSetups: [ProviderID: ProviderSetupState] = [:]
  public private(set) var statusModel: StatusItemModel = .empty
  public private(set) var statusLadder: [StatusItemModel] = [.empty]
  public private(set) var sampleRevision: UInt64 = 0
  public private(set) var historyRevision: UInt64 = 0
  public private(set) var lastRefresh: Date?
  public private(set) var nextRefreshAt: Date?
  public private(set) var isRefreshing = false
  public var popoverVisible = false

  public init() {}

  public func state(for provider: ProviderID) -> ProviderState {
    providers[provider] ?? ProviderState()
  }

  public var snapshots: [ProviderID: ProviderSnapshot] {
    providers.compactMapValues(\.snapshot)
  }

  public var availability: [ProviderID: QuotaAvailability] {
    providers.mapValues(\.availability)
  }

  public var orderedProviders: [ProviderID] {
    providers.keys.sorted()
  }

  public func update(_ provider: ProviderID, _ mutate: (inout ProviderState) -> Void) {
    let state = updatedState(provider, mutate)
    // Observation fires on assignment rather than on change, so writing an identical state redraws every view that
    // reads it. The refresh tick rewrites disabled providers every minute.
    guard providers[provider] != state else { return }
    providers[provider] = state
  }

  func applyProviderStates(_ states: [ProviderID: ProviderState]) {
    var next = providers
    for (provider, state) in states {
      next[provider] = updatedState(provider, in: next) { $0 = state }
    }
    if providers != next { providers = next }
  }

  func beginRefreshing(_ refreshing: [ProviderID], disabling: [ProviderID]) {
    var next = providers
    for provider in disabling {
      next[provider] = updatedState(provider, in: next) { $0 = ProviderState(availability: .disabled) }
    }
    for provider in refreshing {
      next[provider] = updatedState(provider, in: next) { $0.isRefreshing = true }
    }
    if providers != next { providers = next }
    setRefreshing(true, at: nil)
  }

  func disable(_ disabled: [ProviderID]) {
    var next = providers
    for provider in disabled {
      next[provider] = updatedState(provider, in: next) { $0 = ProviderState(availability: .disabled) }
    }
    if providers != next { providers = next }
  }

  func finishRefreshing(_ refreshed: [ProviderID], at date: Date?) {
    var next = providers
    for provider in refreshed {
      next[provider] = updatedState(provider, in: next) { $0.isRefreshing = false }
    }
    if providers != next { providers = next }
    setRefreshing(false, at: date)
  }

  public func applySetupStates(_ setups: [ProviderID: ProviderSetupState]) {
    providerSetups = setups
    var next = providers
    for (provider, setup) in setups {
      next[provider] = updatedState(provider, in: next) { state in
        let resourcesChanged = state.resourceAccess != setup.resources
        guard case .unchecked = setup.credential else {
          let credentialChanged = state.credentialHealth != setup.credential
          state.credentialHealth = setup.credential
          state.credentialState = Self.credentialState(for: setup.credential, provider: provider)
          if credentialChanged {
            state.recoveryIssue = nil
            if setup.credential.isUsable, state.availability == .authenticationRequired {
              state.availability = state.snapshot == nil ? .loading : .stale
              state.lastError = nil
            }
          } else if resourcesChanged, state.recoveryIssue?.kind == .resourceAccess {
            state.recoveryIssue = nil
          }
          return
        }
        if resourcesChanged, state.recoveryIssue?.kind == .resourceAccess {
          state.recoveryIssue = nil
        }
      }
    }
    if providers != next { providers = next }
  }

  public func setStatusLadder(_ ladder: [StatusItemModel]) {
    let models = ladder.isEmpty ? [.empty] : ladder
    if models != statusLadder { statusLadder = models }
    if models[0] != statusModel { statusModel = models[0] }
  }

  public func markSamplesChanged() {
    sampleRevision &+= 1
    markHistoryChanged()
  }

  public func markHistoryChanged() {
    historyRevision &+= 1
  }

  public func setRefreshing(_ refreshing: Bool, at date: Date?) {
    if isRefreshing != refreshing { isRefreshing = refreshing }
    if let date { lastRefresh = date }
  }

  public func setNextRefresh(_ date: Date?) {
    if nextRefreshAt != date { nextRefreshAt = date }
  }

  public func cancelRefreshing() {
    finishRefreshing(Array(providers.keys), at: nil)
  }

  public func remove(_ provider: ProviderID) {
    removeProviders([provider])
  }

  func removeProviders(_ removed: Set<ProviderID>) {
    var next = providers
    for provider in removed {
      next[provider] = nil
      providerSetups[provider] = nil
    }
    if providers != next { providers = next }
  }

  private func updatedState(
    _ provider: ProviderID,
    in states: [ProviderID: ProviderState]? = nil,
    _ mutate: (inout ProviderState) -> Void
  ) -> ProviderState {
    var state = states?[provider] ?? providers[provider] ?? ProviderState()
    let previous = state
    mutate(&state)
    if state.availability == .disabled {
      state.snapshot = state.snapshot ?? previous.snapshot
      state.analytics = state.analytics ?? previous.analytics
      state.lastSuccess = state.lastSuccess ?? previous.lastSuccess
      state.lastError = state.lastError ?? previous.lastError
      if state.warnings.isEmpty { state.warnings = previous.warnings }
      state.credentialState = state.credentialState ?? previous.credentialState
      if case .unchecked = state.credentialHealth { state.credentialHealth = previous.credentialHealth }
    }
    if let setup = providerSetups[provider] { merge(setup, provider: provider, into: &state) }
    return state
  }

  private static func credentialState(
    for health: ProviderCredentialHealth,
    provider: ProviderID
  ) -> CredentialState? {
    switch health {
    case .unchecked: nil
    case .missing: .missing(provider.setup.signInDetail)
    case .valid(_, let expiresAt): .valid(expiresAt: expiresAt)
    case .expired(_, let date): .expired(date)
    case .unreadable(_, let detail): .missing(detail)
    }
  }

  private func merge(_ setup: ProviderSetupState, provider: ProviderID, into state: inout ProviderState) {
    state.resourceAccess = setup.resources
    state.serviceHealth = .from(
      availability: state.availability, detail: state.lastError, retryAt: state.retryNotBefore)
    if case .unchecked = state.credentialHealth, let credentialState = state.credentialState {
      let source = setup.credential.source ?? provider.setup.credentialSources[0]
      switch credentialState {
      case .missing:
        if case .unreadable = setup.credential {
          state.credentialHealth = setup.credential
        } else {
          state.credentialHealth = .missing(expected: provider.setup.credentialSources)
        }
      case .expired(let date):
        state.credentialHealth = .expired(source: source, at: date)
      case .valid(let expiresAt):
        state.credentialHealth = .valid(source: source, expiresAt: expiresAt)
      }
    } else if case .unchecked = state.credentialHealth {
      state.credentialHealth = setup.credential
    }
    state.recoveryIssue = recoveryIssue(
      setup: setup, provider: provider, state: state, providerIssue: state.recoveryIssue)
  }

  private func recoveryIssue(
    setup: ProviderSetupState,
    provider: ProviderID,
    state: ProviderState,
    providerIssue: ProviderRecoveryIssue?
  ) -> ProviderRecoveryIssue? {
    guard state.availability != .disabled else { return nil }
    if let providerIssue { return providerIssue }
    let credentialIssue = ProviderSetupState.from(
      provider: provider, enabled: true, credential: state.credentialHealth, resources: setup.resources
    ).issue
    switch state.availability {
    case .authenticationRequired:
      if let resource = setup.resources.first(where: { $0.isRequired && $0.health != .granted }) {
        return ProviderRecoveryIssue(
          kind: .resourceAccess,
          title: resource.health == .stale ? "Access grant needs renewal" : "File access needed",
          detail: "Grant access to \(resource.resource.label) so \(provider.displayName) data can be read.",
          action: .grantAccess(resource.resource))
      }
      return credentialIssue ?? setup.issue ?? provider.setup.missingCredentialIssue
    case .networkUnavailable:
      return ProviderRecoveryIssue(
        kind: .network,
        title: "\(provider.displayName) is offline",
        detail: state.lastError ?? "The provider could not be reached.",
        action: .refreshProvider(provider))
    case .rateLimited:
      return ProviderRecoveryIssue(
        kind: .rateLimited,
        title: "\(provider.displayName) is rate limited",
        detail: state.lastError ?? "Token Menu Bar will retry after the provider allows another request.",
        action: .refreshProvider(provider))
    case .unavailable:
      return ProviderRecoveryIssue(
        kind: .service,
        title: "\(provider.displayName) is unavailable",
        detail: state.lastError ?? "The provider did not return usable data.",
        action: .refreshProvider(provider))
    case .loading:
      return state.credentialHealth.isUsable ? nil : credentialIssue ?? setup.issue
    case .current, .stale, .disabled:
      return nil
    }
  }
}
