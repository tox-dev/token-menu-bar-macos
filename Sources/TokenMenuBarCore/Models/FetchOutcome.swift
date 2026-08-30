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

public struct ProviderFetchResult: Sendable, Equatable {
  public let outcome: ProviderFetchOutcome
  public let warnings: [String]
  public let analytics: ProviderAnalytics?

  public init(outcome: ProviderFetchOutcome, warnings: [String] = [], analytics: ProviderAnalytics? = nil) {
    self.outcome = outcome
    self.warnings = warnings
    self.analytics = analytics
  }
}
