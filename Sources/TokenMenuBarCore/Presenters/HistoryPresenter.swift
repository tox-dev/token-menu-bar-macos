import Foundation
import Observation

public enum HistoryLoadState: Equatable, Sendable {
  case loading
  case loaded(HistoryChartModel, isRefreshing: Bool, error: String?)
  case failed(String)

  public var data: HistoryChartModel? {
    if case .loaded(let data, _, _) = self { return data }
    return nil
  }
}

private struct HistoryCacheKey: Hashable, Sendable {
  let metric: HistoryMetric
  let keys: [WindowKey]
  let start: Date
  let end: Date
  let rollup: Rollup
  let timeZoneID: String
}

private enum HistoryCachedRows: Sendable {
  case windows(samples: [UsageSample], labels: [WindowKey: String])
  case analytics([HistoryAnalyticsRow])

  var rowCount: Int {
    switch self {
    case .windows(let samples, _): samples.count
    case .analytics(let rows): rows.count
    }
  }
}

private struct HistoryIsolation {
  let id: HistorySeriesID
  let hidden: Set<HistorySeriesID>
}

@MainActor
@Observable
public final class HistoryPresenter {
  public private(set) var state: HistoryLoadState = .loading
  public private(set) var availableWindows: [WindowSummary] = []
  public private(set) var earliest: Date?
  public private(set) var selectedMetric: HistoryMetric
  public private(set) var exportError: String?
  public var customStart: Date
  public var customEnd: Date
  public var followNow = true
  public var selectedDate: Date?
  public var hoveredKey: WindowKey?
  public var hoveredSeriesID: HistorySeriesID?

  private let history: UsageHistoryStore
  private let settings: Settings
  private let clock: Clock
  private let persistMetric: @MainActor (HistoryMetric) -> Void
  private var loadTask: Task<Void, Never>?
  private var hasLoaded = false
  private var anchorEnd: Date?
  private var cache: [HistoryCacheKey: HistoryCachedRows] = [:]
  private var cacheOrder: [HistoryCacheKey] = []
  private var hiddenAnalytics: [HistoryMetric: Set<HistorySeriesID>] = [:]
  private var isolation: [HistoryMetric: HistoryIsolation] = [:]
  private var dataScope = HistoryDataScope.all
  private var lastRequest: HistoryRequest?
  private var earliestMetric: HistoryMetric?
  static let maxQueryPointsPerSeries = 800
  static let maxCachedRows = 24_000

  public init(
    history: UsageHistoryStore, settings: Settings, clock: Clock = .system,
    initialMetric: HistoryMetric = .windowUsagePercent,
    persistMetric: @escaping @MainActor (HistoryMetric) -> Void = { _ in }
  ) {
    self.history = history
    self.settings = settings
    self.clock = clock
    self.selectedMetric = initialMetric
    self.persistMetric = persistMetric
    let now = clock.now()
    customStart = now.addingTimeInterval(-86400)
    customEnd = now
  }

  public var timeZone: TimeZone {
    settings.historyUseUTC ? Self.utc : .current
  }

  public var chartTimeZone: TimeZone {
    selectedMetric.usesDailyUTC ? Self.utc : timeZone
  }

  public var period: HistoryPeriod {
    followNow ? .now : .range(settings.historyRange)
  }

  public var effectiveRollup: Rollup {
    selectedMetric.usesDailyUTC ? .day : settings.historyRollup
  }

  public var canStack: Bool {
    selectedMetric.supportsStacking && (state.data?.visibleSeries.count ?? 0) > 1
  }

  public var currentViewport: ClosedRange<Date> {
    let viewport = viewport(now: clock.now())
    return viewport.start...viewport.end
  }

  public func request(now: Date) -> HistoryRequest {
    let viewport = viewport(now: now)
    let allKeys = availableWindows.map(\.key).filter(dataScope.includes)
    let keys = allKeys.filter { !settings.historyHiddenKeys.contains($0) }
    return HistoryRequest(
      keys: keys, allKeys: allKeys, start: viewport.start, end: viewport.end, rollup: effectiveRollup,
      stacked: settings.historyStacked && selectedMetric.supportsStacking, timeZone: chartTimeZone,
      includesEnd: followNow && !selectedMetric.usesDailyUTC)
  }

  public func ensureLoaded() {
    guard !hasLoaded, loadTask == nil else { return }
    startLoad(useCache: true, refreshMetadata: true)
  }

  public func reload() {
    cache.removeAll(keepingCapacity: true)
    cacheOrder.removeAll(keepingCapacity: true)
    startLoad(useCache: false, refreshMetadata: true)
  }

  public func reset() {
    selectedMetric = HistoryMetric(storageID: settings.historyMetricID) ?? .windowUsagePercent
    followNow = true
    anchorEnd = nil
    let now = clock.now()
    customStart = now.addingTimeInterval(-86400)
    customEnd = now
    hiddenAnalytics.removeAll(keepingCapacity: true)
    isolation.removeAll(keepingCapacity: true)
    invalidateData()
  }

  public func invalidateData() {
    loadTask?.cancel()
    loadTask = nil
    cache.removeAll(keepingCapacity: true)
    cacheOrder.removeAll(keepingCapacity: true)
    availableWindows = []
    earliest = nil
    earliestMetric = nil
    lastRequest = nil
    selectedDate = nil
    hoveredKey = nil
    hoveredSeriesID = nil
    hasLoaded = false
    state = .loading
    startLoad(useCache: false, refreshMetadata: true)
  }

  public func setDataScope(_ scope: HistoryDataScope) {
    guard scope != dataScope else { return }
    dataScope = scope
    invalidateData()
  }

  public func redraw() {
    guard let previous = lastRequest, let cached = cache[cacheKey(request: previous)] else {
      startLoad(useCache: true, now: lastRequest?.end)
      return
    }
    render(cached, request: updatingVisibility(in: previous))
  }

  public func waitForLoad() async {
    var waiting = loadTask
    while let task = waiting {
      await task.value
      waiting = loadTask == task ? nil : loadTask
    }
  }

  public func setMetric(_ metric: HistoryMetric) {
    guard metric != selectedMetric else { return }
    selectedMetric = metric
    persistMetric(metric)
    if case .analytics(let analyticsMetric) = metric { settings.historyAnalyticsMetric = analyticsMetric }
    selectedDate = nil
    hoveredSeriesID = nil
    hoveredKey = nil
    startLoad(useCache: true, now: followNow ? clock.now() : anchorEnd ?? lastRequest?.end)
  }

  public func setPeriod(_ period: HistoryPeriod) {
    switch period {
    case .now:
      let customDuration = max(customEnd.timeIntervalSince(customStart), 60)
      followNow = true
      anchorEnd = nil
      if settings.historyRange == .custom {
        customEnd = clock.now()
        customStart = customEnd.addingTimeInterval(-customDuration)
      }
    case .range(let range):
      settings.historyRange = range
      if range == .today, settings.historyRollup == .day { settings.historyRollup = .hour }
      followNow = false
      anchorEnd = clock.now()
      if range == .custom {
        customEnd = clock.now()
        customStart = min(customStart, customEnd.addingTimeInterval(-60))
      }
    }
    selectedDate = nil
    startLoad(useCache: true)
  }

  public func setRange(_ range: HistoryRange) {
    setPeriod(.range(range))
  }

  public func setRollup(_ rollup: Rollup) {
    guard !selectedMetric.usesDailyUTC else { return }
    settings.historyRollup = rollup
    if rollup == .day, settings.historyRange == .today { settings.historyRange = .week }
    startLoad(useCache: true, now: lastRequest?.end)
  }

  public func setStacked(_ stacked: Bool) {
    settings.historyStacked = stacked
    redraw()
  }

  public func setCustomStart(_ date: Date) {
    let currentEnd = viewport(now: clock.now()).end
    settings.historyRange = .custom
    customEnd = currentEnd
    customStart = min(date, currentEnd.addingTimeInterval(-60))
    followNow = false
    anchorEnd = currentEnd
    selectedDate = nil
    startLoad(useCache: true)
  }

  public func setCustomEnd(_ date: Date) {
    let currentStart = viewport(now: clock.now()).start
    settings.historyRange = .custom
    customStart = currentStart
    customEnd = max(date, currentStart.addingTimeInterval(60))
    followNow = false
    anchorEnd = customEnd
    selectedDate = nil
    startLoad(useCache: true)
  }

  public func setFollowNow(_ follow: Bool) {
    if follow {
      setPeriod(.now)
    } else {
      followNow = false
      anchorEnd = clock.now()
      startLoad(useCache: true)
    }
  }

  public func setUseUTC(_ utc: Bool) {
    settings.historyUseUTC = utc
    guard !selectedMetric.usesDailyUTC else { return }
    startLoad(useCache: true, now: lastRequest?.end)
  }

  public func page(forward: Bool, now: Date) {
    let view = viewport(now: now)
    let calendar = calendar(for: selectedMetric.usesDailyUTC ? Self.utc : timeZone)
    if settings.historyRange == .custom {
      if selectedMetric.usesDailyUTC {
        let today = calendar.startOfDay(for: now)
        let dayCount = max(calendar.dateComponents([.day], from: view.start, to: view.end).day! + 1, 1)
        let proposedEnd =
          forward
          ? calendar.date(byAdding: .day, value: dayCount, to: view.end)!
          : calendar.date(byAdding: .day, value: -1, to: view.start)!
        let nextEnd = min(proposedEnd, today)
        let nextStart = calendar.date(byAdding: .day, value: -(dayCount - 1), to: nextEnd)!
        customStart = nextStart
        customEnd = nextEnd
        followNow = nextEnd >= today
        anchorEnd = followNow ? nil : nextEnd
      } else {
        let duration = max(view.end.timeIntervalSince(view.start), 60)
        let proposedEnd = forward ? view.end.addingTimeInterval(duration) : view.start
        let nextEnd = min(proposedEnd, now)
        customEnd = nextEnd
        customStart = nextEnd.addingTimeInterval(-duration)
        followNow = nextEnd >= now
        anchorEnd = followNow ? nil : nextEnd
      }
    } else {
      let days = settings.historyRange.days!
      let nextEnd: Date
      if selectedMetric.usesDailyUTC {
        let today = calendar.startOfDay(for: now)
        nextEnd = min(
          forward
            ? calendar.date(byAdding: .day, value: days, to: view.end)!
            : calendar.date(byAdding: .day, value: -1, to: view.start)!,
          today)
      } else {
        if settings.historyRange == .today, !forward, view.end > calendar.startOfDay(for: view.end) {
          nextEnd = calendar.startOfDay(for: view.end)
        } else {
          nextEnd = min(
            forward
              ? calendar.date(byAdding: .day, value: days, to: view.end)!
              : view.start,
            now)
        }
      }
      let currentEnd = selectedMetric.usesDailyUTC ? calendar.startOfDay(for: now) : now
      followNow = nextEnd >= currentEnd
      anchorEnd = followNow ? nil : nextEnd
    }
    selectedDate = nil
    startLoad(useCache: true)
  }

  public var canPageBack: Bool {
    earliest.map { $0 < viewport(now: clock.now()).start } ?? false
  }

  public var canPageForward: Bool {
    !followNow && viewport(now: clock.now()).end < clock.now()
  }

  public func toggleVisibility(_ id: HistorySeriesID) {
    guard let data = state.data else { return }
    if data.visibleSeries.count == 1, data.visibleSeries[0].id == id { return }
    isolation[selectedMetric] = nil
    switch id {
    case .window(let key):
      var hidden = settings.historyHiddenKeys
      if hidden.contains(key) { hidden.remove(key) } else { hidden.insert(key) }
      settings.historyHiddenKeys = hidden
    case .analytics:
      var hidden = hiddenAnalytics[selectedMetric] ?? []
      if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
      hiddenAnalytics[selectedMetric] = hidden
    }
    redraw()
  }

  public func toggleVisibility(_ key: WindowKey) {
    toggleVisibility(.window(key))
  }

  public func isolate(_ id: HistorySeriesID) {
    guard let data = state.data else { return }
    let metric = selectedMetric
    if let active = isolation[metric], active.id == id {
      applyHidden(active.hidden, for: metric)
      isolation[metric] = nil
      redraw()
      return
    }
    let original = isolation[metric]?.hidden ?? hiddenIDs(for: metric)
    let others = Set(data.series.map(\.id)).subtracting([id])
    isolation[metric] = HistoryIsolation(id: id, hidden: original)
    applyHidden(original.union(others).subtracting([id]), for: metric)
    redraw()
  }

  public func isolate(_ key: WindowKey) {
    isolate(.window(key))
  }

  public func isVisible(_ id: HistorySeriesID) -> Bool {
    switch id {
    case .window(let key): !settings.historyHiddenKeys.contains(key)
    case .analytics: !(hiddenAnalytics[selectedMetric] ?? []).contains(id)
    }
  }

  public func isVisible(_ key: WindowKey) -> Bool {
    isVisible(.window(key))
  }

  public func select(x date: Date?) {
    guard let date, let data = state.data else {
      if selectedDate != nil { selectedDate = nil }
      return
    }
    let nearest = ChartPipeline.nearestDate(in: data, to: date)
    if nearest != selectedDate { selectedDate = nearest }
  }

  public func setHovered(_ id: HistorySeriesID?) {
    hoveredSeriesID = id
    if case .window(let key) = id { hoveredKey = key } else { hoveredKey = nil }
  }

  public func moveSelection(_ offset: Int) {
    guard let data = state.data, !data.timeline.isEmpty else { return }
    let current = selectedDate.flatMap { data.timeline.firstIndex(of: $0) } ?? (offset > 0 ? -1 : data.timeline.count)
    selectedDate = data.timeline[min(max(current + offset, 0), data.timeline.count - 1)]
  }

  public func value(for series: HistorySeries) -> String {
    let value = selectedDate.map { series.value(at: $0, metric: selectedMetric)?.value } ?? series.summaryValue
    return value.map { format($0, unit: selectedMetric.unit) } ?? "—"
  }

  public func resetDescription(for series: HistorySeries) -> String? {
    guard let selectedDate, let point = series.value(at: selectedDate, metric: selectedMetric), point.isReset,
      let resetsAt = point.resetsAt
    else {
      return nil
    }
    return "Reset \(resetsAt.formatted(date: .abbreviated, time: .shortened))"
  }

  @discardableResult
  public func exportCSV(to url: URL) -> Task<Void, Never> {
    exportError = nil
    let metric = selectedMetric
    let viewport = viewport(now: clock.now())
    let keys = availableWindows.map(\.key).filter(dataScope.includes)
    let providers = selectedMetric.suppliers.filter(dataScope.activeProviders.contains)
    return Task { [weak self] in
      guard let self else { return }
      do {
        try await history.exportCSV(
          to: url, metric: metric, from: viewport.start, to: viewport.end, keys: keys,
          providers: providers, includesEnd: followNow && !metric.usesDailyUTC)
      } catch {
        exportError = "Export failed: \(error)"
      }
    }
  }

  private func startLoad(useCache: Bool, now requestedNow: Date? = nil, refreshMetadata: Bool = false) {
    loadTask?.cancel()
    let now = requestedNow ?? clock.now()
    if case .loaded(let data, _, _) = state { state = .loaded(data, isRefreshing: true, error: nil) }
    loadTask = Task { [weak self] in
      guard let self else { return }
      do {
        if refreshMetadata || !hasLoaded {
          let summaries = try await history.summaries()
          guard !Task.isCancelled else { return }
          availableWindows = summaries
        }
        let metric = selectedMetric
        if refreshMetadata || earliestMetric != metric {
          let loadedEarliest = try await earliestDate(for: metric)
          guard !Task.isCancelled else { return }
          earliest = loadedEarliest
          earliestMetric = metric
        }
        let request = request(now: now)
        lastRequest = request
        let key = cacheKey(request: request)
        let rows: HistoryCachedRows
        if useCache, let cached = cache[key] {
          rows = cached
        } else {
          rows = try await loadRows(request: request)
          store(rows, for: key)
        }
        guard !Task.isCancelled else { return }
        await renderRows(rows, request: request)
        guard !Task.isCancelled else { return }
        hasLoaded = true
      } catch {
        guard !Task.isCancelled else { return }
        if let data = state.data {
          state = .loaded(data, isRefreshing: false, error: "\(error)")
        } else {
          state = .failed("\(error)")
        }
      }
    }
  }

  private func loadRows(request: HistoryRequest) async throws -> HistoryCachedRows {
    switch selectedMetric {
    case .windowUsagePercent:
      let queryRollup = Self.queryRollup(for: request)
      let lookback = max(queryRollup, UsageHistoryStore.sampleInterval) * 1.5
      let samples = try await history.samples(
        keys: request.allKeys, from: request.start.addingTimeInterval(-lookback), to: request.end,
        rollup: queryRollup, timeZone: request.timeZone, includesEnd: request.includesEnd)
      let labels = Dictionary(
        uniqueKeysWithValues: availableWindows.map { ($0.key, "\($0.key.provider.displayName) \($0.label)") })
      return .windows(samples: samples, labels: labels)
    case .analytics(let metric):
      let exclusiveEnd = calendar(for: Self.utc).date(byAdding: .day, value: 1, to: request.end)!
      return .analytics(
        try await history.analytics(
          metric: metric, providers: selectedMetric.suppliers.filter(dataScope.activeProviders.contains),
          from: DayStamp.string(request.start),
          before: DayStamp.string(exclusiveEnd)))
    }
  }

  private func render(_ cached: HistoryCachedRows, request: HistoryRequest) {
    loadTask?.cancel()
    loadTask = Task { [weak self] in
      await self?.renderRows(cached, request: request)
    }
  }

  private func renderRows(_ cached: HistoryCachedRows, request: HistoryRequest) async {
    let metric = selectedMetric
    let hidden = hiddenAnalytics[metric] ?? []
    let renderTask = Task.detached(priority: .userInitiated) {
      switch cached {
      case .windows(let samples, let labels):
        return ChartPipeline.render(samples: samples, request: request, labels: labels, now: request.end)
      case .analytics(let rows):
        let start = DayStamp.date(DayStamp.string(request.start))!
        let lastDay = DayStamp.date(DayStamp.string(request.end))!
        return ChartPipeline.renderAnalytics(
          rows: rows, metric: metric, start: start, end: lastDay.addingTimeInterval(Rollup.day.seconds), hidden: hidden,
          stacked: request.stacked)
      }
    }
    let model = await withTaskCancellationHandler {
      await renderTask.value
    } onCancel: {
      renderTask.cancel()
    }
    guard !Task.isCancelled else { return }
    let styled = applyingStyles(to: model)
    state = .loaded(styled, isRefreshing: false, error: nil)
  }

  private func applyingStyles(to model: HistoryChartModel) -> HistoryChartModel {
    let slots = HistoryStyleSlot.allocate(model.series.map(\.id))
    let styled = model.series.map { series -> HistorySeries in
      return HistorySeries(
        id: series.id, label: series.label, points: series.points,
        style: slots[series.id]!, isVisible: series.isVisible,
        summaryValue: series.summaryValue)
    }
    return model.replacingSeries(styled)
  }

  private func viewport(now: Date) -> (start: Date, end: Date) {
    let calendar = calendar(for: selectedMetric.usesDailyUTC ? Self.utc : timeZone)
    if settings.historyRange == .custom {
      let end = followNow ? now : min(customEnd, now)
      if selectedMetric.usesDailyUTC {
        let endDay = calendar.startOfDay(for: end)
        return (min(calendar.startOfDay(for: customStart), endDay), endDay)
      }
      return (min(customStart, end.addingTimeInterval(-60)), end)
    }
    let end = followNow ? now : min(anchorEnd ?? now, now)
    let days = settings.historyRange.days!
    if selectedMetric.usesDailyUTC {
      let endDay = calendar.startOfDay(for: end)
      let start = calendar.date(byAdding: .day, value: -(days - 1), to: endDay)!
      return (start, endDay)
    }
    if settings.historyRange == .today {
      let start =
        followNow
        ? calendar.startOfDay(for: end)
        : calendar.date(byAdding: .day, value: -1, to: end)!
      return (start, end)
    }
    return (calendar.date(byAdding: .day, value: -days, to: end)!, end)
  }

  private func cacheKey(request: HistoryRequest) -> HistoryCacheKey {
    HistoryCacheKey(
      metric: selectedMetric, keys: request.allKeys, start: request.start, end: request.end, rollup: request.rollup,
      timeZoneID: request.timeZone.identifier)
  }

  private func updatingVisibility(in request: HistoryRequest) -> HistoryRequest {
    HistoryRequest(
      keys: request.allKeys.filter { !settings.historyHiddenKeys.contains($0) }, allKeys: request.allKeys,
      start: request.start, end: request.end, rollup: request.rollup,
      stacked: settings.historyStacked && selectedMetric.supportsStacking,
      timeZone: request.timeZone, includesEnd: request.includesEnd)
  }

  private func store(_ rows: HistoryCachedRows, for key: HistoryCacheKey) {
    cache[key] = rows
    cacheOrder.removeAll { $0 == key }
    cacheOrder.append(key)
    while cacheOrder.count > 2 || cache.values.reduce(0, { $0 + $1.rowCount }) > Self.maxCachedRows {
      cache[cacheOrder.removeFirst()] = nil
    }
  }

  static func queryRollup(for request: HistoryRequest) -> TimeInterval {
    let duration = max(request.end.timeIntervalSince(request.start), 0)
    let budgetInterval =
      ceil(duration / Double(maxQueryPointsPerSeries) / UsageHistoryStore.sampleInterval)
      * UsageHistoryStore.sampleInterval
    return max(request.rollup.seconds, max(UsageHistoryStore.sampleInterval, budgetInterval))
  }

  private func earliestDate(for metric: HistoryMetric) async throws -> Date? {
    switch metric {
    case .windowUsagePercent:
      try await history.earliestSample(keys: availableWindows.map(\.key).filter(dataScope.includes))
    case .analytics(let analyticsMetric):
      try await history.earliestAnalytics(
        metric: analyticsMetric, providers: metric.suppliers.filter(dataScope.activeProviders.contains))
    }
  }

  private func hiddenIDs(for metric: HistoryMetric) -> Set<HistorySeriesID> {
    switch metric {
    case .windowUsagePercent: Set(settings.historyHiddenKeys.map(HistorySeriesID.window))
    case .analytics: hiddenAnalytics[metric] ?? []
    }
  }

  private func applyHidden(_ ids: Set<HistorySeriesID>, for metric: HistoryMetric) {
    switch metric {
    case .windowUsagePercent:
      settings.historyHiddenKeys = Set(ids.compactMap { if case .window(let key) = $0 { key } else { nil } })
    case .analytics:
      hiddenAnalytics[metric] = ids
    }
  }

  private func format(_ value: Double, unit: HistoryUnit) -> String {
    switch unit {
    case .percentage: Format.percent(value)
    case .tokens, .credits, .count: Format.compactNumber(value)
    case .usd: "$\(value.formatted(.number.precision(.fractionLength(2))))"
    }
  }

  private func calendar(for timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
  }

  private static let utc = TimeZone(identifier: "UTC")!
}
