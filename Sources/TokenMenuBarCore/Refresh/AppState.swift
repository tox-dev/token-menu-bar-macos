import Foundation
import Observation

public struct ProviderState: Sendable, Equatable {
  public var snapshot: ProviderSnapshot?
  public var analytics: ProviderAnalytics?
  public var availability: QuotaAvailability
  public var lastError: String?
  public var warnings: [String]
  public var lastAttempt: Date?
  public var lastSuccess: Date?
  public var credentialState: CredentialState?
  public var isRefreshing: Bool

  public init(
    snapshot: ProviderSnapshot? = nil,
    analytics: ProviderAnalytics? = nil,
    availability: QuotaAvailability = .loading,
    lastError: String? = nil,
    warnings: [String] = [],
    lastAttempt: Date? = nil,
    lastSuccess: Date? = nil,
    credentialState: CredentialState? = nil,
    isRefreshing: Bool = false
  ) {
    self.snapshot = snapshot
    self.analytics = analytics
    self.availability = availability
    self.lastError = lastError
    self.warnings = warnings
    self.lastAttempt = lastAttempt
    self.lastSuccess = lastSuccess
    self.credentialState = credentialState
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
  public private(set) var statusModel: StatusItemModel = .empty
  public private(set) var lastRefresh: Date?
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
    var state = providers[provider] ?? ProviderState()
    mutate(&state)
    providers[provider] = state
  }

  public func setStatusModel(_ model: StatusItemModel) {
    if model != statusModel { statusModel = model }
  }

  public func setRefreshing(_ refreshing: Bool, at date: Date?) {
    isRefreshing = refreshing
    if let date { lastRefresh = date }
  }

  public func remove(_ provider: ProviderID) {
    providers[provider] = nil
  }
}
