import Foundation
import Observation

public enum HistoryLoadState: Equatable, Sendable {
  case loading
  case loaded(HistoryRenderData, isRefreshing: Bool, error: String?)
  case failed(String)

  public var data: HistoryRenderData? {
    if case .loaded(let data, _, _) = self { return data }
    return nil
  }
}

public struct AnalyticsBar: Hashable, Sendable, Identifiable {
  public let day: String
  public let series: String
  public let value: Double

  public var id: String { "\(day)|\(series)" }

  public var date: Date {
    DayStamp.date(day) ?? .distantPast
  }
}

public struct AnalyticsSection: Hashable, Sendable, Identifiable {
  public let metric: AnalyticsMetric
  public let total: Double
  public let bars: [AnalyticsBar]
  public let series: [String]

  public var id: AnalyticsMetric { metric }

  public var totalText: String {
    metric == .surfaceUsagePercent
      ? Format.percent(total / Double(max(Set(bars.map(\.day)).count, 1))) : Format.compactNumber(total)
  }
}

@MainActor
@Observable
public final class HistoryPresenter {
  public private(set) var state: HistoryLoadState = .loading
  public private(set) var availableWindows: [WindowSummary] = []
  public private(set) var analytics: [ProviderID: [AnalyticsSection]] = [:]
  public private(set) var earliest: Date?
  public var customStart: Date
  public var customEnd: Date
  public var followNow = true
  public var selectedDate: Date?
  public var hoveredKey: WindowKey?
  private let history: UsageHistoryStore
  private let settings: Settings
  private let clock: Clock
  private var loadTask: Task<Void, Never>?

  public init(history: UsageHistoryStore, settings: Settings, clock: Clock = .system) {
    self.history = history
    self.settings = settings
    self.clock = clock
    let now = clock.now()
    customStart = now.addingTimeInterval(-86400)
    customEnd = now
  }

  public var timeZone: TimeZone {
    settings.historyUseUTC ? TimeZone(identifier: "UTC")! : .current
  }

  public func request(now: Date) -> HistoryRequest {
    let end: Date
    let start: Date
    if settings.historyRange == .custom {
      end = followNow ? now : customEnd
      start = min(customStart, end.addingTimeInterval(-60))
    } else {
      end = now
      let days = settings.historyRange.days ?? 1
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = timeZone
      start =
        settings.historyRange == .today ? calendar.startOfDay(for: now) : now.addingTimeInterval(-Double(days) * 86400)
    }
    let keys = availableWindows.map(\.key).filter { !settings.historyHiddenKeys.contains($0) }
    return HistoryRequest(
      keys: keys, start: start, end: end, rollup: settings.historyRollup, stacked: settings.historyStacked,
      timeZone: timeZone)
  }

  public func reload() {
    loadTask?.cancel()
    let now = clock.now()
    if case .loaded(let data, _, _) = state { state = .loaded(data, isRefreshing: true, error: nil) }
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        let summaries = try await history.summaries()
        let earliest = try await history.earliestSample()
        guard !Task.isCancelled else { return }
        availableWindows = summaries
        self.earliest = earliest
        let request = request(now: now)
        let samples = try await history.samples(
          keys: request.keys, from: request.start.addingTimeInterval(-7 * 86400), to: request.end)
        let labels = Dictionary(
          uniqueKeysWithValues: summaries.map { ($0.key, "\($0.key.provider.displayName) \($0.label)") })
        let data = ChartPipeline.render(samples: samples, request: request, labels: labels, now: now)
        var sections: [ProviderID: [AnalyticsSection]] = [:]
        for provider in ProviderID.allCases {
          let points = try await history.analytics(
            provider: provider, from: DayStamp.string(request.start), to: DayStamp.string(request.end))
          sections[provider] = Self.sections(points)
        }
        guard !Task.isCancelled else { return }
        analytics = sections.filter { !$0.value.isEmpty }
        state = .loaded(data, isRefreshing: false, error: nil)
      } catch {
        guard !Task.isCancelled else { return }
        state = .failed("\(error)")
      }
    }
  }

  public func waitForLoad() async {
    var waiting = loadTask
    while let task = waiting {
      await task.value
      waiting = loadTask == task ? nil : loadTask
    }
  }

  static func sections(_ points: [AnalyticsPoint]) -> [AnalyticsSection] {
    AnalyticsMetric.allCases.compactMap { metric in
      let bars = ChartPipeline.dailyBuckets(points, metric: metric).map {
        AnalyticsBar(day: $0.day, series: $0.series, value: $0.value)
      }
      guard !bars.isEmpty else { return nil }
      let total = bars.reduce(0) { $0 + $1.value }
      return AnalyticsSection(metric: metric, total: total, bars: bars, series: Array(Set(bars.map(\.series))).sorted())
    }
  }

  public func toggleVisibility(_ key: WindowKey) {
    var hidden = settings.historyHiddenKeys
    if hidden.contains(key) {
      hidden.remove(key)
    } else if availableWindows.count - hidden.count > 1 {
      hidden.insert(key)
    }
    settings.historyHiddenKeys = hidden
    reload()
  }

  public func isolate(_ key: WindowKey) {
    let others = Set(availableWindows.map(\.key)).subtracting([key])
    settings.historyHiddenKeys = settings.historyHiddenKeys == others ? [] : others
    reload()
  }

  public func isVisible(_ key: WindowKey) -> Bool {
    !settings.historyHiddenKeys.contains(key)
  }

  public func select(x date: Date?) {
    guard let date, let data = state.data else {
      selectedDate = nil
      return
    }
    selectedDate = ChartPipeline.nearestDate(in: data, to: date)
  }

  public func value(for series: HistorySeries) -> String {
    guard let selectedDate, let point = series.value(at: selectedDate) else {
      return series.points.last.map { Format.percent($0.value) } ?? "—"
    }
    return Format.percent(point.value)
  }

  public func page(forward: Bool, now: Date) {
    let span = customEnd.timeIntervalSince(customStart)
    let delta = forward ? span : -span
    customStart = customStart.addingTimeInterval(delta)
    customEnd = min(customEnd.addingTimeInterval(delta), now)
    followNow = customEnd >= now
    reload()
  }

  public var canPageBack: Bool {
    earliest.map { $0 < customStart } ?? false
  }

  public var canPageForward: Bool {
    !followNow
  }

  public func setRange(_ range: HistoryRange) {
    settings.historyRange = range
    if range == .today, settings.historyRollup == .day { settings.historyRollup = .hour }
    reload()
  }

  public func setRollup(_ rollup: Rollup) {
    settings.historyRollup = rollup
    if rollup == .day, settings.historyRange == .today { settings.historyRange = .week }
    reload()
  }

  public func setStacked(_ stacked: Bool) {
    settings.historyStacked = stacked
    reload()
  }

  public func setCustomStart(_ date: Date) {
    customStart = date
    reload()
  }

  public func setCustomEnd(_ date: Date) {
    customEnd = date
    followNow = false
    reload()
  }

  public func setFollowNow(_ follow: Bool) {
    followNow = follow
    reload()
  }

  public func setUseUTC(_ utc: Bool) {
    settings.historyUseUTC = utc
    reload()
  }
}
