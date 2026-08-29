import Foundation

public enum AnalyticsMetric: String, Codable, CaseIterable, Sendable, Hashable {
  case surfaceUsagePercent
  case modelCredits
  case turns
  case threads
  case credits
  case inputTokens
  case cachedInputTokens
  case outputTokens
  case skillInvocations
  case pluginInvocations
  case codeReviews

  public var title: String {
    switch self {
    case .surfaceUsagePercent: "Usage by surface"
    case .modelCredits: "Credits by model"
    case .turns: "Turns"
    case .threads: "Threads"
    case .credits: "Credits"
    case .inputTokens: "Input tokens"
    case .cachedInputTokens: "Cached input tokens"
    case .outputTokens: "Output tokens"
    case .skillInvocations: "Skills used"
    case .pluginInvocations: "Plugin calls"
    case .codeReviews: "Code reviews"
    }
  }

  public var unit: String {
    switch self {
    case .surfaceUsagePercent: "%"
    case .modelCredits, .credits: "credits"
    case .inputTokens, .cachedInputTokens, .outputTokens: "tokens"
    default: "count"
    }
  }
}

public struct AnalyticsPoint: Codable, Sendable, Hashable {
  public let day: String
  public let metric: AnalyticsMetric
  public let series: String
  public let value: Double

  public init(day: String, metric: AnalyticsMetric, series: String, value: Double) {
    self.day = day
    self.metric = metric
    self.series = series
    self.value = value
  }
}

public struct CreditEvent: Codable, Sendable, Hashable, Identifiable {
  public let id: String
  public let date: Date
  public let service: String
  public let creditsUsed: Double

  public init(id: String, date: Date, service: String, creditsUsed: Double) {
    self.id = id
    self.date = date
    self.service = service
    self.creditsUsed = creditsUsed
  }
}

public struct ProviderAnalytics: Codable, Sendable, Hashable {
  public let provider: ProviderID
  public let points: [AnalyticsPoint]
  public let creditEvents: [CreditEvent]
  public let fetchedAt: Date

  public init(provider: ProviderID, points: [AnalyticsPoint], creditEvents: [CreditEvent] = [], fetchedAt: Date) {
    self.provider = provider
    self.points = points
    self.creditEvents = creditEvents
    self.fetchedAt = fetchedAt
  }

  public func total(_ metric: AnalyticsMetric) -> Double {
    points.filter { $0.metric == metric }.reduce(0) { $0 + $1.value }
  }

  public func series(for metric: AnalyticsMetric) -> [String] {
    Array(Set(points.filter { $0.metric == metric }.map(\.series))).sorted()
  }
}

public enum DayStamp {
  private static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .iso8601)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  public static func string(_ date: Date) -> String {
    formatter.string(from: date)
  }

  public static func date(_ stamp: String) -> Date? {
    formatter.date(from: stamp)
  }
}
