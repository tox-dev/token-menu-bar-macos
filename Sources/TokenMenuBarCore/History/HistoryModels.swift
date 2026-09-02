import Foundation

public enum HistoryMetricGroup: String, CaseIterable, Sendable {
  case windows = "Windows"
  case bothProviders = "Claude and Codex"
  case claude = "Claude"
  case codex = "Codex"
}

public enum HistoryMarkKind: Sendable, Hashable {
  case stepLine
  case line
  case bars
}

public enum HistoryUnit: Sendable, Hashable {
  case percentage
  case tokens
  case credits
  case usd
  case count
}

public enum HistorySummaryKind: Sendable, Hashable {
  case latest
  case sum
}

public enum HistoryMetric: Sendable, Hashable, Identifiable {
  case windowUsagePercent
  case analytics(AnalyticsMetric)

  public static let allCases: [HistoryMetric] =
    [.windowUsagePercent] + AnalyticsMetric.allCases.map(HistoryMetric.analytics)

  public var id: String {
    storageID
  }

  public var storageID: String {
    switch self {
    case .windowUsagePercent: "windowUsagePercent"
    case .analytics(let metric): "analytics:\(metric.rawValue)"
    }
  }

  public init?(storageID: String) {
    if storageID == "windowUsagePercent" {
      self = .windowUsagePercent
      return
    }
    let prefix = "analytics:"
    guard storageID.hasPrefix(prefix), let metric = AnalyticsMetric(rawValue: String(storageID.dropFirst(prefix.count)))
    else { return nil }
    self = .analytics(metric)
  }

  public var title: String {
    switch self {
    case .windowUsagePercent: "Usage %"
    case .analytics(let metric): metric.title
    }
  }

  public var group: HistoryMetricGroup {
    switch self {
    case .windowUsagePercent: .windows
    case .analytics(.inputTokens), .analytics(.cachedInputTokens), .analytics(.outputTokens): .bothProviders
    case .analytics(.cacheWriteTokens), .analytics(.costUSD), .analytics(.messages), .analytics(.sessions),
      .analytics(.toolCalls):
      .claude
    case .analytics: .codex
    }
  }

  public var suppliers: [ProviderID] {
    switch group {
    case .windows: ProviderID.allCases.sorted()
    case .bothProviders: [.claude, .codex]
    case .claude: [.claude]
    case .codex: [.codex]
    }
  }

  public var markKind: HistoryMarkKind {
    switch self {
    case .windowUsagePercent: .stepLine
    case .analytics(.surfaceUsagePercent): .line
    case .analytics: .bars
    }
  }

  public var unit: HistoryUnit {
    switch self {
    case .windowUsagePercent, .analytics(.surfaceUsagePercent): .percentage
    case .analytics(.inputTokens), .analytics(.cachedInputTokens), .analytics(.outputTokens),
      .analytics(.cacheWriteTokens):
      .tokens
    case .analytics(.modelCredits), .analytics(.credits): .credits
    case .analytics(.costUSD): .usd
    case .analytics: .count
    }
  }

  public var summaryKind: HistorySummaryKind {
    unit == .percentage ? .latest : .sum
  }

  public var supportsStacking: Bool {
    switch self {
    case .analytics(.turns), .analytics(.threads), .analytics(.credits): false
    default: markKind == .bars
    }
  }

  public var hasParallelBreakdowns: Bool {
    switch self {
    case .analytics(.turns), .analytics(.threads), .analytics(.credits): true
    default: false
    }
  }

  public var usesDailyUTC: Bool {
    if case .analytics = self { return true }
    return false
  }

  public var attribution: String {
    switch self {
    case .windowUsagePercent:
      "Every model · step line · selected time zone"
    case .analytics(.inputTokens), .analytics(.cachedInputTokens), .analytics(.outputTokens):
      "Claude + Codex · Claude by model, Codex total · daily UTC"
    case .analytics(.surfaceUsagePercent):
      "Codex · by surface · daily UTC"
    case .analytics(.modelCredits):
      "Codex · by model · daily UTC"
    case .analytics(.turns), .analytics(.threads), .analytics(.credits):
      "Codex · by model and surface · daily UTC"
    case .analytics(.skillInvocations):
      "Codex · by skill · daily UTC"
    case .analytics(.pluginInvocations):
      "Codex · by plugin · daily UTC"
    case .analytics(.codeReviews):
      "Codex · by review type · daily UTC"
    case .analytics(.cacheWriteTokens), .analytics(.costUSD):
      "Claude · by model · daily UTC"
    case .analytics(.messages), .analytics(.sessions), .analytics(.toolCalls):
      "Claude · one series · daily UTC"
    }
  }

  public func attribution(providers: [ProviderID]) -> String {
    let active = suppliers.filter(Set(providers).contains)
    guard !active.isEmpty else { return "No enabled provider data in this period" }
    let names = active.map(\.displayName).joined(separator: " + ")
    switch self {
    case .windowUsagePercent:
      return "\(names) · enabled models · step line · selected time zone"
    case .analytics(.inputTokens), .analytics(.cachedInputTokens), .analytics(.outputTokens):
      let breakdown =
        active == [.claude, .codex] ? "Claude by model, Codex total" : active == [.claude] ? "by model" : "total"
      return "\(names) · \(breakdown) · daily UTC"
    case .analytics:
      return "\(names) · " + attribution.split(separator: " · ").dropFirst().joined(separator: " · ")
    }
  }
}

public enum HistoryPeriod: Sendable, Hashable, Identifiable {
  case now
  case range(HistoryRange)

  public static let allCases: [HistoryPeriod] = [.now] + HistoryRange.allCases.map(HistoryPeriod.range)

  public var id: String {
    switch self {
    case .now: "Now"
    case .range(let range): range.rawValue
    }
  }

  public var title: String { id }
}

public struct HistoryDataScope: Hashable, Sendable {
  public let activeProviders: Set<ProviderID>
  public let selectedWindows: Set<WindowKey>?

  public init(activeProviders: Set<ProviderID>, selectedWindows: Set<WindowKey>? = nil) {
    self.activeProviders = activeProviders
    self.selectedWindows = selectedWindows
  }

  public static let all = HistoryDataScope(activeProviders: Set(ProviderID.allCases))

  public func includes(_ key: WindowKey) -> Bool {
    activeProviders.contains(key.provider) && (selectedWindows?.contains(key) ?? true)
  }
}

public enum HistorySeriesID: Sendable, Hashable, Comparable {
  case window(WindowKey)
  case analytics(provider: ProviderID, series: String)

  public var provider: ProviderID {
    switch self {
    case .window(let key): key.provider
    case .analytics(let provider, _): provider
    }
  }

  public var storageKey: String {
    switch self {
    case .window(let key): "window:\(key.storageKey)"
    case .analytics(let provider, let series): "analytics:\(provider.rawValue):\(series)"
    }
  }

  public static func < (lhs: HistorySeriesID, rhs: HistorySeriesID) -> Bool {
    lhs.storageKey < rhs.storageKey
  }
}

public struct HistoryStyleSlot: Sendable, Hashable {
  public let seed: UInt64

  public init(index: Int) {
    seed = UInt64(max(index, 0))
  }

  public init(storageKey: String) {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in storageKey.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    hash ^= hash >> 33
    hash &*= 0xff51afd7ed558ccd
    hash ^= hash >> 33
    seed = hash
  }

  public var hueIndex: Int { Int(seed % 8) }
  public var variant: Int { Int((seed / 8) % UInt64(Int.max)) }
  public var visualIdentity: String { "\(hueIndex):\(variant)" }

  public static func allocate<S: Sequence>(_ ids: S) -> [HistorySeriesID: HistoryStyleSlot]
  where S.Element == HistorySeriesID {
    Dictionary(
      uniqueKeysWithValues: Set(ids).sorted().enumerated().map { index, id in
        (id, HistoryStyleSlot(index: index))
      })
  }
}

public struct HistoryResetEvent: Sendable, Hashable, Identifiable {
  public let seriesID: HistorySeriesID
  public let date: Date
  public let resetsAt: Date

  public init(seriesID: HistorySeriesID, date: Date, resetsAt: Date) {
    self.seriesID = seriesID
    self.date = date
    self.resetsAt = resetsAt
  }

  public var id: String { "\(seriesID.storageKey):\(date.timeIntervalSinceReferenceDate)" }
}

public struct HistoryAnalyticsRow: Sendable, Hashable {
  public let provider: ProviderID
  public let point: AnalyticsPoint

  public init(provider: ProviderID, point: AnalyticsPoint) {
    self.provider = provider
    self.point = point
  }
}
