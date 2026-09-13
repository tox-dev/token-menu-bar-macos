import Foundation

public enum ProviderFetchOutcome: Sendable, Equatable {
  case success(ProviderSnapshot)
  case partial(ProviderSnapshot, String)
  case notAuthenticated(String)
  case networkUnavailable(String)
  case rateLimited(String, retryAfter: TimeInterval?)
  case failed(String)

  public var snapshot: ProviderSnapshot? {
    switch self {
    case .success(let snapshot), .partial(let snapshot, _): snapshot
    default: nil
    }
  }

  public var errorDescription: String? {
    switch self {
    case .success: nil
    case .partial(_, let message), .notAuthenticated(let message), .networkUnavailable(let message),
      .failed(let message), .rateLimited(let message, _):
      message
    }
  }
}

public enum QuotaAvailability: String, Sendable, Equatable {
  case loading
  case current
  case stale
  case authenticationRequired
  case networkUnavailable
  case rateLimited
  case unavailable
  case disabled

  public var title: String {
    switch self {
    case .loading: "Loading"
    case .current: "Up to date"
    case .stale: "Showing last known values"
    case .authenticationRequired: "Sign-in required"
    case .networkUnavailable: "Offline"
    case .rateLimited: "Rate limited"
    case .unavailable: "Unavailable"
    case .disabled: "Disabled"
    }
  }
}

public struct ProviderCredentialStatus: Sendable, Equatable {
  public let state: CredentialState
  public let health: ProviderCredentialHealth

  public init(state: CredentialState, health: ProviderCredentialHealth) {
    self.state = state
    self.health = health
  }
}

public struct ProviderFetchResult: Sendable, Equatable {
  public let outcome: ProviderFetchOutcome
  public let warnings: [String]
  public let analytics: ProviderAnalytics?
  public let recoveryIssue: ProviderRecoveryIssue?
  public let credentialStatus: ProviderCredentialStatus?

  public init(
    outcome: ProviderFetchOutcome,
    warnings: [String] = [],
    analytics: ProviderAnalytics? = nil,
    recoveryIssue: ProviderRecoveryIssue? = nil,
    credentialStatus: ProviderCredentialStatus? = nil
  ) {
    self.outcome = outcome
    self.warnings = warnings
    self.analytics = analytics
    self.recoveryIssue = recoveryIssue
    self.credentialStatus = credentialStatus
  }

  func withCredentialStatus(_ credentialStatus: ProviderCredentialStatus) -> ProviderFetchResult {
    ProviderFetchResult(
      outcome: outcome,
      warnings: warnings,
      analytics: analytics,
      recoveryIssue: recoveryIssue,
      credentialStatus: credentialStatus)
  }
}

extension ProviderCredentialStatus {
  static func resolved(
    _ state: CredentialState,
    provider: ProviderID,
    source: CredentialSource
  ) -> ProviderCredentialStatus {
    ProviderCredentialStatus(
      state: state,
      health: .from(state, source: source, expected: provider.setup.credentialSources))
  }

  static func missing(_ reason: String, provider: ProviderID) -> ProviderCredentialStatus {
    ProviderCredentialStatus(
      state: .missing(reason),
      health: .missing(expected: provider.setup.credentialSources))
  }

  static func unreadable(
    _ error: any Error,
    provider: ProviderID,
    fallbackSource: CredentialSource
  ) -> ProviderCredentialStatus {
    ProviderCredentialStatus(
      state: .missing(String(describing: error)),
      health: .from(readError: error, fallbackSource: fallbackSource))
  }
}
