import Foundation

public struct SpendTile: Sendable, Equatable, Identifiable {
  public let title: String
  public let cost: Double

  public init(title: String, cost: Double) {
    self.title = title
    self.cost = cost
  }

  public var id: String { title }

  public var text: String {
    Format.currency(cost)
  }
}

public struct SpendModelShare: Sendable, Equatable, Identifiable {
  public let provider: ProviderID
  public let model: String
  public let cost: Double

  public init(provider: ProviderID, model: String, cost: Double) {
    self.provider = provider
    self.model = model
    self.cost = cost
  }

  public var id: String { "\(provider.rawValue):\(model)" }

  public var text: String {
    "\(provider.displayName) · \(model): \(Format.currency(cost))"
  }
}

public struct SpendSummary: Sendable, Equatable {
  public static let windowDays = 30

  public let today: Double
  public let yesterday: Double
  public let lastWindow: Double
  public let models: [SpendModelShare]
  public let providers: [ProviderID]

  public init(
    today: Double, yesterday: Double, lastWindow: Double, models: [SpendModelShare], providers: [ProviderID]
  ) {
    self.today = today
    self.yesterday = yesterday
    self.lastWindow = lastWindow
    self.models = models
    self.providers = providers
  }

  public static let empty = SpendSummary(today: 0, yesterday: 0, lastWindow: 0, models: [], providers: [])

  public var hasData: Bool {
    !providers.isEmpty
  }

  public var tiles: [SpendTile] {
    [
      SpendTile(title: "Today (UTC)", cost: today), SpendTile(title: "Yesterday (UTC)", cost: yesterday),
      SpendTile(title: "Last \(Self.windowDays) days", cost: lastWindow),
    ]
  }

  public var attribution: String {
    "\(providers.map(\.displayName).joined(separator: " + ")) API-equivalent estimates · daily UTC"
  }

  public var breakdown: String {
    (["Models over the last \(Self.windowDays) days:"] + models.map(\.text)).joined(separator: "\n")
  }
}

public struct SpendReport: Sendable, Equatable {
  public let total: SpendSummary
  public let byProvider: [ProviderID: SpendSummary]
}

public enum SpendSummaryPresenter {
  // The History metric lists Claude alone because that is who reports cost today; demo data and future readers
  // store Codex cost under the same metric, so the summary asks for both.
  public static let suppliers: [ProviderID] = [.claude, .codex]

  public static func load(
    history: UsageHistoryStore, providers: [ProviderID], now: Date, timeZone: TimeZone
  ) async throws -> SpendReport {
    let days = dayStamps(now: now, timeZone: timeZone)
    let rows = try await history.analytics(
      metric: .costUSD, providers: suppliers.filter(Set(providers).contains), from: days.start, to: days.today)
    return SpendReport(
      total: summary(rows: rows, now: now, timeZone: timeZone),
      byProvider: Dictionary(grouping: rows, by: \.provider).mapValues {
        summary(rows: $0, now: now, timeZone: timeZone)
      })
  }

  public static func summary(rows: [HistoryAnalyticsRow], now: Date, timeZone: TimeZone) -> SpendSummary {
    let days = dayStamps(now: now, timeZone: timeZone)
    let window = rows.filter { $0.point.day >= days.start && $0.point.day <= days.today }
    var byModel: [String: SpendModelShare] = [:]
    for row in window {
      let share = SpendModelShare(provider: row.provider, model: row.point.series, cost: row.point.value)
      byModel[share.id] =
        byModel[share.id].map {
          SpendModelShare(provider: $0.provider, model: $0.model, cost: $0.cost + share.cost)
        } ?? share
    }
    return SpendSummary(
      today: total(window, day: days.today),
      yesterday: total(window, day: days.yesterday),
      lastWindow: window.reduce(0) { $0 + $1.point.value },
      models: byModel.values.sorted { ($1.cost, $0.id) < ($0.cost, $1.id) },
      providers: Array(Set(window.map(\.provider))).sorted())
  }

  private static func total(_ rows: [HistoryAnalyticsRow], day: String) -> Double {
    rows.filter { $0.point.day == day }.reduce(0) { $0 + $1.point.value }
  }

  // Daily totals cannot be reallocated to a local day without their event timestamps.
  static func dayStamps(now: Date, timeZone _: TimeZone) -> (start: String, yesterday: String, today: String) {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let today = calendar.startOfDay(for: now)
    return (
      DayStamp.string(calendar.date(byAdding: .day, value: -(SpendSummary.windowDays - 1), to: today)!),
      DayStamp.string(calendar.date(byAdding: .day, value: -1, to: today)!),
      DayStamp.string(today)
    )
  }
}
