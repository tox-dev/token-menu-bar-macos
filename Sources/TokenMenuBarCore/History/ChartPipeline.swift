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
  public let start: Date
  public let end: Date
  public let rollup: Rollup
  public let stacked: Bool
  public let timeZone: TimeZone

  public init(
    keys: [WindowKey], start: Date, end: Date, rollup: Rollup, stacked: Bool = false, timeZone: TimeZone = .current
  ) {
    self.keys = keys
    self.start = start
    self.end = end
    self.rollup = rollup
    self.stacked = stacked
    self.timeZone = timeZone
  }
}

public struct SeriesPoint: Hashable, Sendable {
  public let date: Date
  public let value: Double
  public let stackBase: Double

  public init(date: Date, value: Double, stackBase: Double = 0) {
    self.date = date
    self.value = value
    self.stackBase = stackBase
  }

  public var stackTop: Double { stackBase + value }
}

public struct HistorySeries: Hashable, Sendable, Identifiable {
  public let key: WindowKey
  public let label: String
  public let points: [SeriesPoint]

  public var id: WindowKey { key }

  public init(key: WindowKey, label: String, points: [SeriesPoint]) {
    self.key = key
    self.label = label
    self.points = points
  }

  public func value(at date: Date) -> SeriesPoint? {
    points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
  }
}

public struct HistoryRenderData: Hashable, Sendable {
  public let series: [HistorySeries]
  public let domain: ClosedRange<Date>
  public let yMax: Double
  public let isEmpty: Bool

  public init(series: [HistorySeries], domain: ClosedRange<Date>, yMax: Double) {
    self.series = series
    self.domain = domain
    self.yMax = yMax
    isEmpty = series.allSatisfy(\.points.isEmpty)
  }
}

public enum ChartPipeline {
  public static let maxPoints = 400

  public static func render(
    samples: [UsageSample], request: HistoryRequest, labels: [WindowKey: String], now: Date
  ) -> HistoryRenderData {
    let clampedEnd = min(request.end, now)
    let grouped = Dictionary(grouping: samples.filter { request.keys.contains($0.key) }, by: \.key)
    let lines: [HistorySeries] = request.keys.map { key in
      var points = bucket(grouped[key] ?? [], rollup: request.rollup, timeZone: request.timeZone)
      points = insertResetZeros(points)
      points = clip(points, start: request.start, end: clampedEnd)
      points = changePoints(points)
      points = extendToNow(points, end: clampedEnd)
      points = downsample(points, limit: maxPoints)
      return HistorySeries(
        key: key, label: labels[key] ?? key.windowID, points: points.map { SeriesPoint(date: $0.date, value: $0.value) }
      )
    }
    let series = request.stacked ? stack(lines) : lines
    let top: Double = series.flatMap { $0.points.map { $0.stackTop } }.max() ?? 0
    return HistoryRenderData(
      series: series, domain: request.start...max(clampedEnd, request.start), yMax: max(100, top))
  }

  struct Raw: Hashable {
    let date: Date
    let value: Double
    let resetsAt: Date?
  }

  static func bucket(_ samples: [UsageSample], rollup: Rollup, timeZone: TimeZone) -> [Raw] {
    var latest: [TimeInterval: Raw] = [:]
    let offset = TimeInterval(timeZone.secondsFromGMT())
    for sample in samples {
      let local = sample.timestamp.timeIntervalSince1970 + offset
      let bucketStart = (local / rollup.seconds).rounded(.down) * rollup.seconds - offset
      let candidate = Raw(date: sample.timestamp, value: sample.usedPercent, resetsAt: sample.resetsAt)
      if let existing = latest[bucketStart], existing.date > candidate.date { continue }
      latest[bucketStart] = candidate
    }
    return latest.values.sorted { $0.date < $1.date }
  }

  static func insertResetZeros(_ points: [Raw]) -> [Raw] {
    guard points.count > 1 else { return points }
    var result: [Raw] = [points[0]]
    for (previous, current) in zip(points, points.dropFirst()) {
      if let previousReset = previous.resetsAt, let currentReset = current.resetsAt, currentReset > previousReset,
        previousReset > previous.date, previousReset < current.date
      {
        result.append(Raw(date: previousReset, value: 0, resetsAt: currentReset))
      } else if previous.resetsAt != nil, current.resetsAt != nil, current.resetsAt! > previous.resetsAt!,
        current.value < previous.value
      {
        result.append(Raw(date: current.date.addingTimeInterval(-1), value: 0, resetsAt: current.resetsAt))
      }
      result.append(current)
    }
    return result
  }

  static func clip(_ points: [Raw], start: Date, end: Date) -> [Raw] {
    var inside = points.filter { $0.date >= start && $0.date <= end }
    if let last = points.last(where: { $0.date < start }), inside.first.map({ $0.date > start }) ?? true {
      inside.insert(Raw(date: start, value: last.value, resetsAt: last.resetsAt), at: 0)
    }
    return inside
  }

  static func changePoints(_ points: [Raw]) -> [Raw] {
    guard points.count > 2 else { return points }
    var kept: [Raw] = []
    for (index, point) in points.enumerated() {
      let isFirst = index == 0
      let isLast = index == points.count - 1
      let next = isLast ? nil : points[index + 1]
      let previous = isFirst ? nil : points[index - 1]
      let valueChanges = next.map { $0.value != point.value } ?? true
      let resetBoundary = point.value == 0 && previous.map { $0.value > 0 } ?? false
      if isFirst || isLast || valueChanges || resetBoundary { kept.append(point) }
    }
    return kept
  }

  static func extendToNow(_ points: [Raw], end: Date) -> [Raw] {
    guard let last = points.last, last.date < end else { return points }
    return points + [Raw(date: end, value: last.value, resetsAt: last.resetsAt)]
  }

  static func downsample(_ points: [Raw], limit: Int) -> [Raw] {
    guard points.count > limit, limit >= 4 else { return points }
    let interior = points.dropFirst().dropLast()
    let bucketCount = (limit - 2) / 2
    let bucketSize = Double(interior.count) / Double(bucketCount)
    var result: [Raw] = [points[0]]
    for bucketIndex in 0..<bucketCount {
      let lower = Int((Double(bucketIndex) * bucketSize).rounded(.down))
      let upper = min(Int((Double(bucketIndex + 1) * bucketSize).rounded(.down)), interior.count)
      guard lower < upper else { continue }
      let slice = Array(interior[interior.startIndex + lower..<interior.startIndex + upper])
      let minimum = slice.min { $0.value < $1.value }!
      let maximum = slice.max { $0.value < $1.value }!
      result += minimum.date <= maximum.date ? [minimum, maximum] : [maximum, minimum]
      if minimum == maximum { result.removeLast() }
    }
    result.append(points[points.count - 1])
    return result
  }

  static func stack(_ series: [HistorySeries]) -> [HistorySeries] {
    let dates = Array(Set(series.flatMap { $0.points.map(\.date) })).sorted()
    var bases = [Double](repeating: 0, count: dates.count)
    return series.map { line in
      let points = dates.enumerated().map { index, date -> SeriesPoint in
        let value = stepValue(line.points, at: date)
        let point = SeriesPoint(date: date, value: value, stackBase: bases[index])
        bases[index] += value
        return point
      }
      return HistorySeries(key: line.key, label: line.label, points: points)
    }
  }

  static func stepValue(_ points: [SeriesPoint], at date: Date) -> Double {
    points.last { $0.date <= date }?.value ?? 0
  }

  public static func nearestDate(in data: HistoryRenderData, to date: Date) -> Date? {
    data.series.flatMap { $0.points.map(\.date) }.min {
      abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date))
    }
  }

  public static func dailyBuckets(
    _ points: [AnalyticsPoint], metric: AnalyticsMetric, topSeries: Int = 8
  ) -> [(day: String, series: String, value: Double)] {
    let filtered = points.filter { $0.metric == metric }
    let totals = Dictionary(grouping: filtered, by: \.series).mapValues { $0.reduce(0) { $0 + $1.value } }
    let ranked = totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    let keep = Set(ranked.prefix(topSeries).map(\.key))
    var merged: [String: [String: Double]] = [:]
    for point in filtered where point.value != 0 {
      let name = keep.contains(point.series) ? point.series : "Other"
      merged[point.day, default: [:]][name, default: 0] += point.value
    }
    return merged.keys.sorted().flatMap { day in
      merged[day]!.keys.sorted().map { (day: day, series: $0, value: merged[day]![$0]!) }
    }
  }
}
