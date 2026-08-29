import Foundation

public struct FetchOptions: Sendable, Equatable {
  public let includeAnalytics: Bool
  public let analyticsDays: Int

  public init(includeAnalytics: Bool = false, analyticsDays: Int = 30) {
    self.includeAnalytics = includeAnalytics
    self.analyticsDays = analyticsDays
  }
}

public struct PollingPolicy: Sendable, Equatable {
  public let idleInterval: TimeInterval
  public let activeInterval: TimeInterval

  public init(idleInterval: TimeInterval, activeInterval: TimeInterval) {
    self.idleInterval = idleInterval
    self.activeInterval = activeInterval
  }

  public func interval(active: Bool, requested: TimeInterval) -> TimeInterval {
    max(requested, active ? activeInterval : idleInterval)
  }
}

public protocol UsageProvider: Sendable {
  var id: ProviderID { get }
  var credentialDescription: String { get }
  var pollingPolicy: PollingPolicy { get }
  func credentialState(now: Date) -> CredentialState
  func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult
}

public struct ProviderRegistry: Sendable {
  public let providers: [any UsageProvider]

  public init(_ providers: [any UsageProvider]) {
    self.providers = providers.sorted { $0.id < $1.id }
  }

  public subscript(id: ProviderID) -> (any UsageProvider)? {
    providers.first { $0.id == id }
  }

  public var ids: [ProviderID] {
    providers.map(\.id)
  }
}

public enum ProviderOutcomeBuilder {
  public static func outcome(for error: APIError, hint: String) -> ProviderFetchOutcome {
    switch error {
    case .network(let text): .networkUnavailable(text)
    case .http where error.isAuthenticationFailure: .notAuthenticated("\(error.message). \(hint)")
    case .http where error.isRateLimited: .rateLimited(error.message, retryAfter: error.retryAfter)
    default: .failed(error.message)
    }
  }
}
