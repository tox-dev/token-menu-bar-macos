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
    case .gemini, .antigravity: PollingPolicy(minimumInterval: 60, activeInterval: 60, defaultInterval: 120)
    case .cursor, .copilot: PollingPolicy(minimumInterval: 60, activeInterval: 60, defaultInterval: 300)
    }
  }
}

public protocol UsageProvider: Sendable {
  var id: ProviderID { get }
  var credentialDescription: String { get }
  var pollingPolicy: PollingPolicy { get }
  var supportsAnalytics: Bool { get }
  func credentialState(now: Date) -> CredentialState
  func credentialHealth(now: Date) async -> ProviderCredentialHealth
  func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult
  func resetAnalyticsHistory() async
}

public extension UsageProvider {
  var supportsAnalytics: Bool { id == .claude || id == .codex }
  func credentialHealth(now: Date) async -> ProviderCredentialHealth { .unchecked }
  func resetAnalyticsHistory() async {}
}

public struct ProviderRegistry: Sendable {
  public let providers: [any UsageProvider]
  public let setupStates: [ProviderID: ProviderSetupState]
  private let resourceLeases: [SecurityScopedResourceLease]
  public let retryCredentialReads: @Sendable (Set<ProviderID>) -> Void

  public init(
    _ providers: [any UsageProvider],
    setupStates: [ProviderID: ProviderSetupState] = [:],
    resourceLeases: [SecurityScopedResourceLease] = [],
    retryCredentialReads: @escaping @Sendable (Set<ProviderID>) -> Void = { _ in }
  ) {
    self.providers = providers.sorted { $0.id < $1.id }
    self.setupStates = setupStates
    self.resourceLeases = resourceLeases
    self.retryCredentialReads = retryCredentialReads
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
