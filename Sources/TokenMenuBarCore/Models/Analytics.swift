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
  case cacheWriteTokens
  case costUSD
  case messages
  case sessions
  case toolCalls

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
    case .cacheWriteTokens: "Cache write tokens"
    case .costUSD: "API-equivalent cost"
    case .messages: "Messages"
    case .sessions: "Sessions"
    case .toolCalls: "Tool calls"
    }
  }

  public var unit: String {
    switch self {
    case .surfaceUsagePercent: "%"
    case .modelCredits, .credits: "credits"
    case .inputTokens, .cachedInputTokens, .outputTokens, .cacheWriteTokens: "tokens"
    case .costUSD: "USD"
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

public struct AnalyticsCoverageScope: Codable, Sendable, Hashable {
  public let metrics: Set<AnalyticsMetric>
  public let startDay: String
  public let endDay: String

  public init(metrics: Set<AnalyticsMetric>, startDay: String, endDay: String) {
    self.metrics = metrics
    self.startDay = startDay
    self.endDay = endDay
  }

  public func contains(_ point: AnalyticsPoint) -> Bool {
    metrics.contains(point.metric) && point.day >= startDay && point.day <= endDay
  }
}

public struct ProviderAnalytics: Codable, Sendable, Hashable {
  public let provider: ProviderID
  public let points: [AnalyticsPoint]
  public let creditEvents: [CreditEvent]
  public let fetchedAt: Date
  public let accountFingerprint: String?
  public let coveredScopes: [AnalyticsCoverageScope]

  public init(
    provider: ProviderID,
    points: [AnalyticsPoint],
    creditEvents: [CreditEvent] = [],
    fetchedAt: Date,
    accountFingerprint: String? = nil,
    coveredScopes: [AnalyticsCoverageScope] = []
  ) {
    self.provider = provider
    self.points = points
    self.creditEvents = creditEvents
    self.fetchedAt = fetchedAt
    self.accountFingerprint = accountFingerprint
    self.coveredScopes = coveredScopes
  }

  private enum CodingKeys: CodingKey {
    case provider, points, creditEvents, fetchedAt, accountFingerprint, coveredScopes
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(ProviderID.self, forKey: .provider)
    points = try container.decode([AnalyticsPoint].self, forKey: .points)
    creditEvents = try container.decode([CreditEvent].self, forKey: .creditEvents)
    fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
    accountFingerprint = try container.decodeIfPresent(String.self, forKey: .accountFingerprint)
    coveredScopes = try container.decodeIfPresent([AnalyticsCoverageScope].self, forKey: .coveredScopes) ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(provider, forKey: .provider)
    try container.encode(points, forKey: .points)
    try container.encode(creditEvents, forKey: .creditEvents)
    try container.encode(fetchedAt, forKey: .fetchedAt)
    try container.encodeIfPresent(accountFingerprint, forKey: .accountFingerprint)
    try container.encode(coveredScopes, forKey: .coveredScopes)
  }

  public func total(_ metric: AnalyticsMetric) -> Double {
    points.filter { $0.metric == metric }.reduce(0) { $0 + $1.value }
  }

  public func series(for metric: AnalyticsMetric) -> [String] {
    Array(Set(points.filter { $0.metric == metric }.map(\.series))).sorted()
  }

  public func merging(_ newer: ProviderAnalytics, retentionDays: Int) -> ProviderAnalytics {
    let cutoff = DayStamp.string(
      newer.fetchedAt.addingTimeInterval(-Double(max(retentionDays - 1, 0)) * 86400))
    let end = DayStamp.string(newer.fetchedAt)
    let cutoffDate = DayStamp.date(cutoff)!
    let endDate = DayStamp.date(end)!.addingTimeInterval(86400)
    let canMerge = provider == newer.provider && accountFingerprint == newer.accountFingerprint
    var mergedPoints: [AnalyticsPointKey: AnalyticsPoint] = [:]
    for point in canMerge ? points : []
    where point.day >= cutoff && point.day <= end && !newer.coveredScopes.contains(where: { $0.contains(point) }) {
      mergedPoints[AnalyticsPointKey(point)] = point
    }
    for point in newer.points where point.day >= cutoff && point.day <= end {
      mergedPoints[AnalyticsPointKey(point)] = point
    }
    var mergedEvents: [String: CreditEvent] = [:]
    for event in canMerge ? creditEvents : [] where event.date >= cutoffDate && event.date < endDate {
      mergedEvents[event.id] = event
    }
    for event in newer.creditEvents where event.date >= cutoffDate && event.date < endDate {
      mergedEvents[event.id] = event
    }
    return ProviderAnalytics(
      provider: newer.provider,
      points: mergedPoints.values.sorted {
        ($0.day, $0.metric.rawValue, $0.series) < ($1.day, $1.metric.rawValue, $1.series)
      },
      creditEvents: mergedEvents.values.sorted {
        $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
      },
      fetchedAt: newer.fetchedAt,
      accountFingerprint: newer.accountFingerprint,
      coveredScopes: newer.coveredScopes)
  }
}

private struct AnalyticsPointKey: Hashable {
  let day: String
  let metric: AnalyticsMetric
  let series: String

  init(_ point: AnalyticsPoint) {
    day = point.day
    metric = point.metric
    series = point.series
  }
}

public enum DayStamp {
  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  public static func string(_ date: Date) -> String {
    formatter.string(from: date)
  }

  public static func date(_ stamp: String) -> Date? {
    formatter.date(from: stamp)
  }
}
