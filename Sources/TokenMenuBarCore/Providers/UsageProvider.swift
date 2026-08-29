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
  public let minimumInterval: TimeInterval
  public let activeInterval: TimeInterval
  public let defaultInterval: TimeInterval

  public init(minimumInterval: TimeInterval, activeInterval: TimeInterval, defaultInterval: TimeInterval) {
    self.minimumInterval = minimumInterval
    self.activeInterval = activeInterval
    self.defaultInterval = defaultInterval
  }

  public func interval(active: Bool, requested: TimeInterval) -> TimeInterval {
    max(active ? min(requested, activeInterval) : requested, minimumInterval)
  }

  public static func defaults(for provider: ProviderID) -> PollingPolicy {
    switch provider {
    case .claude: PollingPolicy(minimumInterval: 120, activeInterval: 120, defaultInterval: 300)
    case .codex: PollingPolicy(minimumInterval: 60, activeInterval: 60, defaultInterval: 120)
    case .gemini: PollingPolicy(minimumInterval: 60, activeInterval: 60, defaultInterval: 120)
    case .cursor, .copilot: PollingPolicy(minimumInterval: 60, activeInterval: 60, defaultInterval: 300)
    }
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
