import Foundation

public enum HistoryRange: String, CaseIterable, Codable, Sendable {
  case today = "Today"
  case week = "7d"
  case month = "30d"
  case twoMonths = "60d"
  case custom = "Custom"

  public var days: Int? {
    switch self {
    case .today: 1
    case .week: 7
    case .month: 30
    case .twoMonths: 60
    case .custom: nil
    }
  }
}

public enum Rollup: String, CaseIterable, Codable, Sendable {
  case minute = "Minute"
  case hour = "Hour"
  case day = "Day"

  public var seconds: TimeInterval {
    switch self {
    case .minute: 60
    case .hour: 3600
    case .day: 86400
    }
  }
}

public struct HistoryRequest: Hashable, Sendable {
  public let keys: [WindowKey]
  public let allKeys: [WindowKey]
  public let start: Date
  public let end: Date
  public let rollup: Rollup
  public let stacked: Bool
  public let timeZone: TimeZone
  public let includesEnd: Bool

  public init(
    keys: [WindowKey], allKeys: [WindowKey]? = nil, start: Date, end: Date, rollup: Rollup, stacked: Bool = false,
    timeZone: TimeZone = .current, includesEnd: Bool = true
  ) {
    self.keys = keys
    self.allKeys = allKeys ?? keys
    self.start = start
    self.end = end
    self.rollup = rollup
    self.stacked = stacked
    self.timeZone = timeZone
    self.includesEnd = includesEnd
  }
}

public struct SeriesPoint: Hashable, Sendable {
  public let date: Date
  public let value: Double
  public let stackBase: Double
  public let resetsAt: Date?
  public let segment: Int
  public let isReset: Bool

  public init(
    date: Date, value: Double, stackBase: Double = 0, resetsAt: Date? = nil, segment: Int = 0,
    isReset: Bool = false
  ) {
    self.date = date
    self.value = value
    self.stackBase = stackBase
    self.resetsAt = resetsAt
    self.segment = segment
    self.isReset = isReset
  }

  public var stackTop: Double { stackBase + value }
}

public struct HistorySeries: Hashable, Sendable, Identifiable {
  public let id: HistorySeriesID
  public let label: String
  public let points: [SeriesPoint]
  public let style: HistoryStyleSlot
  public let isVisible: Bool
  public let summaryValue: Double?

  public init(
    id: HistorySeriesID, label: String, points: [SeriesPoint], style: HistoryStyleSlot = .init(index: 0),
    isVisible: Bool = true, summaryValue: Double? = nil
  ) {
    self.id = id
    self.label = label
    self.points = points
    self.style = style
    self.isVisible = isVisible
    self.summaryValue = summaryValue
  }

  public init(key: WindowKey, label: String, points: [SeriesPoint]) {
    self.init(id: .window(key), label: label, points: points, summaryValue: points.last?.value)
  }

  public var key: WindowKey {
    switch id {
    case .window(let key): key
    case .analytics(let provider, let series): WindowKey(provider: provider, windowID: series)
    }
  }

  public func value(at date: Date, metric: HistoryMetric = .windowUsagePercent) -> SeriesPoint? {
    guard !points.isEmpty else { return nil }
    var lower = 0
    var upper = points.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if points[middle].date < date { lower = middle + 1 } else { upper = middle }
    }
    if lower < points.count, points[lower].date == date { return points[lower] }
    guard lower > 0, lower < points.count else { return nil }
    let before = points[lower - 1]
    let after = points[lower]
    switch metric.markKind {
    case .bars:
      return nil
    case .stepLine:
      return SeriesPoint(
        date: date, value: before.value, resetsAt: before.resetsAt, segment: before.segment)
    case .line:
      let duration = after.date.timeIntervalSince(before.date)
      guard duration > 0 else { return before }
      let progress = date.timeIntervalSince(before.date) / duration
      return SeriesPoint(
        date: date, value: before.value + (after.value - before.value) * progress, segment: before.segment)
    }
  }
}

public struct HistoryChartModel: Hashable, Sendable {
  public let metric: HistoryMetric
  public let series: [HistorySeries]
  public let domain: ClosedRange<Date>
  public let yMax: Double
  public let timeline: [Date]
  public let resetEvents: [HistoryResetEvent]
  public let summaryText: String
  public let dataPointCount: Int

  public init(
    metric: HistoryMetric = .windowUsagePercent, series: [HistorySeries], domain: ClosedRange<Date>, yMax: Double,
    timeline: [Date]? = nil, resetEvents: [HistoryResetEvent] = [], summaryText: String = "",
    dataPointCount: Int? = nil
  ) {
    self.metric = metric
    self.series = series
    self.domain = domain
    self.yMax = yMax
    self.timeline = timeline ?? Array(Set(series.flatMap { $0.points.map(\.date) })).sorted()
    self.resetEvents = resetEvents
    self.summaryText = summaryText
    self.dataPointCount = dataPointCount ?? series.reduce(0) { $0 + $1.points.count }
  }

  public var visibleSeries: [HistorySeries] { series.filter(\.isVisible) }
  public var isEmpty: Bool { series.allSatisfy(\.points.isEmpty) }

  public func replacingSeries(_ series: [HistorySeries]) -> HistoryChartModel {
    HistoryChartModel(
      metric: metric, series: series, domain: domain, yMax: yMax, timeline: timeline, resetEvents: resetEvents,
      summaryText: summaryText, dataPointCount: dataPointCount)
  }
}

public typealias HistoryRenderData = HistoryChartModel

public enum ChartPipeline {
  public static let maxPoints = 400
  public static let maxTotalPoints = 1_200

  public static func render(
    samples: [UsageSample], request: HistoryRequest, labels: [WindowKey: String], now: Date
  ) -> HistoryChartModel {
    let clampedEnd = min(request.end, now)
    let wanted = Set(request.allKeys)
    let visible = Set(request.keys)
    let grouped = Dictionary(grouping: samples.filter { wanted.contains($0.key) }, by: \.key)
    let minimumCadence = max(request.rollup.seconds, UsageHistoryStore.sampleInterval)
    var resets: [HistoryResetEvent] = []
    let lines = request.allKeys.compactMap { key -> HistorySeries? in
      guard !Task.isCancelled else { return nil }
      var raw = bucket(grouped[key] ?? [], rollup: request.rollup, timeZone: request.timeZone)
      let cadence = inferredCadence(in: raw, minimum: minimumCadence)
      raw = insertResetZeros(raw)
      raw = clip(raw, start: request.start, end: clampedEnd, cadence: cadence, includesEnd: request.includesEnd)
      let gapStarts = gapStarts(in: raw, cadence: cadence)
      raw = changePoints(raw, cadence: cadence)
      raw = extendFresh(raw, end: clampedEnd, cadence: cadence)
      raw = downsample(raw, limit: maxPoints, cadence: cadence)
      guard !raw.isEmpty else { return nil }
      let segmented = segments(raw, gapStarts: gapStarts)
      let id = HistorySeriesID.window(key)
      resets += segmented.compactMap { point in
        guard point.raw.isReset, let resetsAt = point.raw.resetsAt else { return nil }
        return HistoryResetEvent(seriesID: id, date: point.raw.date, resetsAt: resetsAt)
      }
      let points = segmented.map {
        SeriesPoint(
          date: $0.raw.date, value: $0.raw.value, resetsAt: $0.raw.resetsAt, segment: $0.segment,
          isReset: $0.raw.isReset)
      }
      return HistorySeries(
        id: id, label: labels[key] ?? key.windowID, points: points, isVisible: visible.contains(key),
        summaryValue: points.last?.value)
    }
    let rendered = budgeted(request.stacked ? stack(lines) : lines)
    let top = rendered.lazy.filter(\.isVisible).flatMap(\.points).map(\.stackTop).max() ?? 0
    let timeline = Array(Set(rendered.filter(\.isVisible).flatMap { $0.points.map(\.date) })).sorted()
    return HistoryChartModel(
      series: rendered, domain: request.start...max(clampedEnd, request.start), yMax: max(100, top), timeline: timeline,
      resetEvents: resets.sorted { $0.date < $1.date }, summaryText: "\(rendered.count) models",
      dataPointCount: samples.count {
        wanted.contains($0.key) && $0.timestamp >= request.start
          && (request.includesEnd ? $0.timestamp <= clampedEnd : $0.timestamp < clampedEnd)
      })
  }

  public static func renderAnalytics(
    rows: [HistoryAnalyticsRow], metric: HistoryMetric, start: Date, end: Date,
    hidden: Set<HistorySeriesID> = [], stacked: Bool = false
  ) -> HistoryChartModel {
    guard case .analytics(let analyticsMetric) = metric else {
      return HistoryChartModel(metric: metric, series: [], domain: start...max(start, end), yMax: 100)
    }
    let filtered = rows.filter { $0.point.metric == analyticsMetric }
    let detailedDays = Set(
      filtered.filter { $0.point.series != "total" }.map { "\($0.provider.rawValue):\($0.point.day)" })
    let chartRows =
      metric.hasParallelBreakdowns
      ? filtered.filter {
        $0.point.series != "total" || !detailedDays.contains("\($0.provider.rawValue):\($0.point.day)")
      } : filtered
    let grouped = Dictionary(grouping: chartRows) {
      HistorySeriesID.analytics(provider: $0.provider, series: $0.point.series)
    }
    let series = budgeted(
      grouped.keys.sorted().compactMap { id -> HistorySeries? in
        guard !Task.isCancelled else { return nil }
        guard let values = grouped[id] else { return nil }
        var byDay: [String: Double] = [:]
        for row in values { byDay[row.point.day, default: 0] += row.point.value }
        let dated = byDay.compactMap { day, value in DayStamp.date(day).map { ($0, value) } }.sorted { $0.0 < $1.0 }
        guard !dated.isEmpty else { return nil }
        var segment = 0
        var previous: Date?
        let points = dated.map { date, value -> SeriesPoint in
          if metric.markKind != .bars, let previous, date.timeIntervalSince(previous) > 1.5 * Rollup.day.seconds {
            segment += 1
          }
          defer { previous = date }
          return SeriesPoint(date: date, value: value, segment: segment)
        }
        let summary = metric.summaryKind == .sum ? points.reduce(0) { $0 + $1.value } : points.last?.value
        return HistorySeries(
          id: id, label: analyticsLabel(id, includeProvider: metric.suppliers.count > 1), points: points,
          isVisible: !hidden.contains(id), summaryValue: summary)
      })
    let visible = series.filter(\.isVisible)
    let values: [Double]
    if stacked, metric.supportsStacking {
      var totals: [Date: Double] = [:]
      for point in visible.flatMap(\.points) { totals[point.date, default: 0] += point.value }
      values = Array(totals.values)
    } else {
      values = visible.flatMap(\.points).map(\.value)
    }
    let yMax = metric.unit == .percentage ? 100 : paddedMaximum(values)
    let timeline = Array(Set(visible.flatMap { $0.points.map(\.date) })).sorted()
    return HistoryChartModel(
      metric: metric, series: series, domain: start...max(start, end), yMax: yMax, timeline: timeline,
      summaryText: summary(metric: metric, series: visible, rows: filtered, timeline: timeline),
      dataPointCount: chartRows.count)
  }

  struct Raw: Hashable {
    let date: Date
    let value: Double
    let resetsAt: Date?
    let isReset: Bool

    init(date: Date, value: Double, resetsAt: Date?, isReset: Bool = false) {
      self.date = date
      self.value = value
      self.resetsAt = resetsAt
      self.isReset = isReset
    }
  }

  static func bucket(_ samples: [UsageSample], rollup: Rollup, timeZone: TimeZone) -> [Raw] {
    var latest: [Date: Raw] = [:]
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    for sample in samples {
      if Task.isCancelled { break }
      let bucketStart: Date
      switch rollup {
      case .minute: bucketStart = calendar.dateInterval(of: .minute, for: sample.timestamp)!.start
      case .hour: bucketStart = calendar.dateInterval(of: .hour, for: sample.timestamp)!.start
      case .day: bucketStart = calendar.startOfDay(for: sample.timestamp)
      }
      let candidate = Raw(date: sample.timestamp, value: sample.usedPercent, resetsAt: sample.resetsAt)
      if let existing = latest[bucketStart], existing.date > candidate.date { continue }
      latest[bucketStart] = candidate
    }
    return latest.values.sorted { $0.date < $1.date }
  }

  static func insertResetZeros(_ points: [Raw]) -> [Raw] {
    guard points.count > 1 else { return points }
    var result = [points[0]]
    for (previous, current) in zip(points, points.dropFirst()) {
      if let previousReset = previous.resetsAt, let currentReset = current.resetsAt, currentReset > previousReset,
        previousReset > previous.date, previousReset < current.date
      {
        result.append(Raw(date: previousReset, value: 0, resetsAt: previousReset, isReset: true))
      } else if let previousReset = previous.resetsAt, let currentReset = current.resetsAt,
        currentReset > previousReset, current.value < previous.value
      {
        result.append(
          Raw(date: current.date.addingTimeInterval(-1), value: 0, resetsAt: current.date, isReset: true))
      }
      result.append(current)
    }
    return result
  }

  static func clip(
    _ points: [Raw], start: Date, end: Date, cadence: TimeInterval, includesEnd: Bool = true
  ) -> [Raw] {
    var inside = points.filter { $0.date >= start && (includesEnd ? $0.date <= end : $0.date < end) }
    if let last = points.last(where: { $0.date < start }), start.timeIntervalSince(last.date) <= cadence * 1.5,
      inside.first.map({ $0.date > start }) ?? true
    {
      inside.insert(Raw(date: start, value: last.value, resetsAt: last.resetsAt), at: 0)
    }
    return inside
  }

  static func changePoints(_ points: [Raw], cadence: TimeInterval? = nil) -> [Raw] {
    guard points.count > 2 else { return points }
    return points.enumerated().compactMap { index, point in
      let isFirst = index == 0
      let isLast = index == points.count - 1
      let next = isLast ? nil : points[index + 1]
      let previous = isFirst ? nil : points[index - 1]
      let valueChanges =
        (previous.map { $0.value != point.value } ?? true) || (next.map { $0.value != point.value } ?? true)
      let resetBoundary = point.isReset || (point.value == 0 && previous.map { $0.value > 0 } ?? false)
      let gapBefore =
        cadence.map { interval in
          previous.map { point.date.timeIntervalSince($0.date) > interval * 1.5 } ?? false
        } ?? false
      let gapAfter =
        cadence.map { interval in
          next.map { $0.date.timeIntervalSince(point.date) > interval * 1.5 } ?? false
        } ?? false
      return isFirst || isLast || valueChanges || resetBoundary || gapBefore || gapAfter ? point : nil
    }
  }

  static func extendToNow(_ points: [Raw], end: Date) -> [Raw] {
    guard let last = points.last, last.date < end else { return points }
    return points + [Raw(date: end, value: last.value, resetsAt: last.resetsAt)]
  }

  static func extendFresh(_ points: [Raw], end: Date, cadence: TimeInterval) -> [Raw] {
    guard let last = points.last, last.date < end, end.timeIntervalSince(last.date) <= cadence * 1.5 else {
      return points
    }
    return points + [Raw(date: end, value: last.value, resetsAt: last.resetsAt)]
  }

  static func downsample(_ points: [Raw], limit: Int, cadence: TimeInterval? = nil) -> [Raw] {
    guard limit > 0 else { return [] }
    guard points.count > limit else { return points }
    var protected = Set([points.startIndex, points.index(before: points.endIndex)])
    protected.formUnion(points.indices.filter { points[$0].isReset })
    if let cadence {
      for index in points.indices.dropFirst()
      where points[index].date.timeIntervalSince(points[index - 1].date) > cadence * 1.5 {
        protected.insert(index - 1)
        protected.insert(index)
      }
    }
    let selectedProtected = evenlySpaced(Array(protected).sorted(), limit: min(protected.count, limit))
    if selectedProtected.count == limit { return selectedProtected.map { points[$0] } }
    let budget = limit - selectedProtected.count
    if budget == 1 {
      let candidate = points.indices.filter { !protected.contains($0) }.max {
        abs(points[$0].value) < abs(points[$1].value)
      }
      let selected = selectedProtected + [candidate!]
      return selected.sorted().map { points[$0] }
    }
    let interior = points.dropFirst().dropLast()
    let bucketCount = max(budget / 2, 1)
    let bucketSize = Double(interior.count) / Double(bucketCount)
    var result: [Raw] = []
    for bucketIndex in 0..<bucketCount {
      if Task.isCancelled { break }
      let lower = Int((Double(bucketIndex) * bucketSize).rounded(.down))
      let upper = min(Int((Double(bucketIndex + 1) * bucketSize).rounded(.down)), interior.count)
      guard lower < upper else { continue }
      let slice = interior[interior.startIndex + lower..<interior.startIndex + upper]
      let minimum = slice.min { $0.value < $1.value }!
      let maximum = slice.max { $0.value < $1.value }!
      result += minimum.date <= maximum.date ? [minimum, maximum] : [maximum, minimum]
      if minimum == maximum { result.removeLast() }
    }
    result += selectedProtected.map { points[$0] }
    let unique = Dictionary(grouping: result, by: \.date).compactMap { $0.value.first }
    return unique.sorted { $0.date < $1.date }
  }

  static func budgeted(_ series: [HistorySeries]) -> [HistorySeries] {
    let limits = pointLimits(series.map { $0.points.count })
    return zip(series, limits).map { series, limit in
      guard series.points.count > limit else { return series }
      let points = downsample(series.points, limit: limit)
      return HistorySeries(
        id: series.id, label: series.label, points: points, style: series.style,
        isVisible: series.isVisible, summaryValue: series.summaryValue)
    }
  }

  static func pointLimits(_ counts: [Int]) -> [Int] {
    let capacities = counts.map { min(max($0, 0), maxPoints) }
    let populated = capacities.indices.filter { capacities[$0] > 0 }
    var remaining = max(maxTotalPoints, populated.count)
    var limits = [Int](repeating: 0, count: counts.count)
    var active = populated
    while remaining > 0, !active.isEmpty {
      let share = max(remaining / active.count, 1)
      var next: [Int] = []
      for index in active {
        guard remaining > 0 else {
          next.append(index)
          continue
        }
        let grant = min(capacities[index] - limits[index], min(share, remaining))
        limits[index] += grant
        remaining -= grant
        if limits[index] < capacities[index] { next.append(index) }
      }
      active = next
    }
    return limits
  }

  private static func downsample(_ points: [SeriesPoint], limit: Int) -> [SeriesPoint] {
    let raw = points.map { Raw(date: $0.date, value: $0.value, resetsAt: $0.resetsAt, isReset: $0.isReset) }
    var selected = Dictionary(grouping: downsample(raw, limit: limit), by: { $0 }).mapValues(\.count)
    return zip(points, raw).compactMap { point, rawPoint in
      guard let count = selected[rawPoint], count > 0 else { return nil }
      selected[rawPoint] = count - 1
      return point
    }
  }

  static func stack(_ series: [HistorySeries]) -> [HistorySeries] {
    let dates = Array(Set(series.filter(\.isVisible).flatMap { $0.points.map(\.date) })).sorted()
    var bases = [Double](repeating: 0, count: dates.count)
    return series.map { line in
      guard line.isVisible else { return line }
      var cursor = line.points.startIndex
      var carried = 0.0
      let points = dates.enumerated().map { index, date -> SeriesPoint in
        while cursor < line.points.endIndex, line.points[cursor].date <= date {
          carried = line.points[cursor].value
          cursor += 1
        }
        let point = SeriesPoint(date: date, value: carried, stackBase: bases[index])
        bases[index] += carried
        return point
      }
      return HistorySeries(
        id: line.id, label: line.label, points: points, style: line.style, isVisible: true,
        summaryValue: line.summaryValue)
    }
  }

  public static func nearestDate(in data: HistoryChartModel, to date: Date) -> Date? {
    nearestDate(in: data.timeline, to: date)
  }

  public static func nearestDate(in dates: [Date], to date: Date) -> Date? {
    guard !dates.isEmpty else { return nil }
    var lower = 0
    var upper = dates.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if dates[middle] < date { lower = middle + 1 } else { upper = middle }
    }
    if lower == 0 { return dates[0] }
    if lower == dates.count { return dates[dates.count - 1] }
    let before = dates[lower - 1]
    let after = dates[lower]
    return date.timeIntervalSince(before) <= after.timeIntervalSince(date) ? before : after
  }

  public static func dailyBuckets(
    _ points: [AnalyticsPoint], metric: AnalyticsMetric, topSeries _: Int? = nil
  ) -> [(day: String, series: String, value: Double)] {
    var buckets: [String: [String: Double]] = [:]
    for point in points where point.metric == metric {
      buckets[point.day, default: [:]][point.series, default: 0] += point.value
    }
    return buckets.keys.sorted().flatMap { day in
      buckets[day]!.keys.sorted().map { (day: day, series: $0, value: buckets[day]![$0]!) }
    }
  }

  static func canonicalTotal(_ rows: [HistoryAnalyticsRow], metric _: HistoryMetric) -> Double {
    let grouped = Dictionary(grouping: rows) { "\($0.provider.rawValue):\($0.point.day)" }
    return grouped.values.reduce(0) { result, dayRows in
      let total = dayRows.filter { $0.point.series == "total" }
      if !total.isEmpty { return result + total.reduce(0) { $0 + $1.point.value } }
      let surfaces = dayRows.filter { $0.point.series.hasPrefix("surface:") }
      return result + (surfaces.isEmpty ? dayRows : surfaces).reduce(0) { $0 + $1.point.value }
    }
  }

  static func canonicalTotal(_ points: [AnalyticsPoint], metric: HistoryMetric) -> Double {
    canonicalTotal(points.map { HistoryAnalyticsRow(provider: .codex, point: $0) }, metric: metric)
  }

  private static func gapStarts(in points: [Raw], cadence: TimeInterval) -> Set<Date> {
    Set(
      zip(points, points.dropFirst()).compactMap { previous, point in
        point.date.timeIntervalSince(previous.date) > cadence * 1.5 ? point.date : nil
      })
  }

  private static func inferredCadence(in points: [Raw], minimum: TimeInterval) -> TimeInterval {
    let intervals = zip(points, points.dropFirst()).map { $1.date.timeIntervalSince($0.date) }.filter { $0 > 0 }
      .sorted()
    guard !intervals.isEmpty else { return minimum }
    return max(minimum, intervals[(intervals.count - 1) / 4])
  }

  private static func segments(_ points: [Raw], gapStarts: Set<Date>) -> [(raw: Raw, segment: Int)] {
    var segment = 0
    return points.map { point in
      if gapStarts.contains(point.date) { segment += 1 }
      return (point, segment)
    }
  }

  private static func paddedMaximum(_ values: [Double]) -> Double {
    guard let maximum = values.max(), maximum > 0 else { return 1 }
    return maximum * 1.08
  }

  private static func evenlySpaced<Element>(_ values: [Element], limit: Int) -> [Element] {
    guard values.count > limit, limit > 1 else { return Array(values.prefix(max(limit, 0))) }
    let last = Double(values.count - 1)
    return (0..<limit).map { values[Int((Double($0) * last / Double(limit - 1)).rounded())] }
  }

  private static func analyticsLabel(_ id: HistorySeriesID, includeProvider: Bool) -> String {
    guard case .analytics(let provider, let raw) = id else { return id.storageKey }
    let label: String
    if raw.hasPrefix("model:") {
      label = "Model · \(raw.dropFirst("model:".count))"
    } else if raw.hasPrefix("surface:") {
      label = "Surface · \(raw.dropFirst("surface:".count))"
    } else {
      label = raw
    }
    return includeProvider ? "\(provider.displayName) · \(label)" : label
  }

  private static func summary(
    metric: HistoryMetric, series: [HistorySeries], rows: [HistoryAnalyticsRow], timeline: [Date]
  ) -> String {
    if metric.summaryKind == .latest {
      guard let latest = timeline.last else { return "No data in this period" }
      var style = Date.FormatStyle().month(.abbreviated).day()
      style.timeZone = TimeZone(secondsFromGMT: 0)!
      return "\(series.count) series · latest \(latest.formatted(style))"
    }
    let total =
      metric.hasParallelBreakdowns
      ? canonicalTotal(rows, metric: metric) : series.compactMap(\.summaryValue).reduce(0, +)
    return switch metric.unit {
    case .usd: "$\(total.formatted(.number.precision(.fractionLength(2)))) total"
    case .percentage: Format.percent(total)
    case .tokens: "\(Format.compactNumber(total)) tokens"
    case .credits: "\(Format.compactNumber(total)) credits"
    case .count: "\(Format.compactNumber(total)) total"
    }
  }
}
