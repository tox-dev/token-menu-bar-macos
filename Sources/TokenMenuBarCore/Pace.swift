import Foundation

public enum PaceStatus: String, Sendable, Equatable {
  case unknown
  case onTrack
  case ahead
  case behind
  case exhausted

  public var title: String {
    switch self {
    case .unknown: "Learning pace"
    case .onTrack: "On pace"
    case .ahead: "Ahead of pace"
    case .behind: "Under pace"
    case .exhausted: "Limit reached"
    }
  }
}

public struct PaceEstimate: Sendable, Hashable {
  public static let aheadRatio = 1.25
  public static let behindRatio = 0.75
  public static let minimumElapsedPercent = 5.0
  public static let slopeWindow: TimeInterval = 3600
  public static let workdayRange = 4...7

  public let status: PaceStatus
  public let expectedPercent: Double?
  public let ratio: Double?
  public let projectedExhaustion: Date?

  public init(status: PaceStatus, expectedPercent: Double?, ratio: Double?, projectedExhaustion: Date?) {
    self.status = status
    self.expectedPercent = expectedPercent
    self.ratio = ratio
    self.projectedExhaustion = projectedExhaustion
  }

  public static func estimate(
    window: QuotaWindow, samples: [UsageSample] = [], workdays: Int = workdayRange.upperBound,
    calendar: Calendar = Format.calendar, now: Date
  ) -> PaceEstimate {
    if window.usedPercent >= 100 {
      return PaceEstimate(status: .exhausted, expectedPercent: nil, ratio: nil, projectedExhaustion: now)
    }
    guard let resetsAt = window.resetsAt, let duration = window.duration, duration > 0, resetsAt > now else {
      return PaceEstimate(status: .unknown, expectedPercent: nil, ratio: nil, projectedExhaustion: nil)
    }
    let start = resetsAt.addingTimeInterval(-duration)
    let expected = expectedPercent(start: start, resetsAt: resetsAt, workdays: workdays, calendar: calendar, now: now)
    let projection = projectedExhaustion(window: window, start: start, resetsAt: resetsAt, samples: samples, now: now)
    guard expected >= minimumElapsedPercent else {
      return PaceEstimate(status: .unknown, expectedPercent: expected, ratio: nil, projectedExhaustion: projection)
    }
    let ratio = window.usedPercent / expected
    let status: PaceStatus = ratio > aheadRatio ? .ahead : ratio < behindRatio ? .behind : .onTrack
    return PaceEstimate(status: status, expectedPercent: expected, ratio: ratio, projectedExhaustion: projection)
  }

  /// Windows longer than a day expect usage only on the configured workdays, so a weekly window that opened over the
  /// weekend is not ahead of pace by Monday morning.
  static func expectedPercent(start: Date, resetsAt: Date, workdays: Int, calendar: Calendar, now: Date) -> Double {
    let duration = resetsAt.timeIntervalSince(start)
    let linear = min(max(now.timeIntervalSince(start) / duration, 0), 1) * 100
    guard workdays < workdayRange.upperBound, duration > 86400 else { return linear }
    let total = workdaySeconds(from: start, to: resetsAt, workdays: workdays, calendar: calendar)
    guard total > 0 else { return linear }
    let elapsed = workdaySeconds(from: start, to: min(now, resetsAt), workdays: workdays, calendar: calendar)
    return min(max(elapsed / total, 0), 1) * 100
  }

  static func workdaySeconds(from start: Date, to end: Date, workdays: Int, calendar: Calendar) -> TimeInterval {
    var total: TimeInterval = 0
    var cursor = start
    while cursor < end {
      let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor))!
      let segmentEnd = min(nextDay, end)
      if isWorkday(cursor, workdays: workdays, calendar: calendar) { total += segmentEnd.timeIntervalSince(cursor) }
      cursor = segmentEnd
    }
    return total
  }

  static func isWorkday(_ date: Date, workdays: Int, calendar: Calendar) -> Bool {
    let mondayBased = (calendar.component(.weekday, from: date) + 5) % 7
    return mondayBased < workdays
  }

  static func projectedExhaustion(
    window: QuotaWindow, start: Date, resetsAt: Date, samples: [UsageSample], now: Date
  ) -> Date? {
    let recent = samples.filter { $0.timestamp >= now.addingTimeInterval(-slopeWindow) && $0.timestamp <= now }
    var rate: Double?
    if let first = recent.first, let last = recent.last, last.timestamp > first.timestamp,
      last.usedPercent > first.usedPercent
    {
      rate = (last.usedPercent - first.usedPercent) / last.timestamp.timeIntervalSince(first.timestamp)
    } else if window.usedPercent > 0, now > start {
      rate = window.usedPercent / now.timeIntervalSince(start)
    }
    guard let rate, rate > 0 else { return nil }
    let projected = now.addingTimeInterval((100 - window.usedPercent) / rate)
    return projected < resetsAt ? projected : nil
  }

  public func summary(now: Date) -> String {
    switch status {
    case .exhausted: "Limit reached"
    case .unknown:
      projectedExhaustion.map { "Early in window; at this rate hits 100% \(Format.resetClock($0, now: now))" }
        ?? "Early in window"
    default:
      projectedExhaustion.map {
        "\(status.title) (expected \(Format.percent(expectedPercent ?? 0))); "
          + "hits 100% \(Format.resetClock($0, now: now))"
      }
        ?? "\(status.title) (expected \(Format.percent(expectedPercent ?? 0))); lasts until reset"
    }
  }

  public func comparison(now: Date) -> String {
    if status == .exhausted { return "Limit reached" }
    var parts = [status.title]
    if let expectedPercent {
      parts.append("expected \(Format.percent(expectedPercent))")
    }
    if let ratio {
      parts.append("\(ratio.formatted(.number.precision(.fractionLength(1))))×")
    }
    if let projectedExhaustion {
      parts.append("hits 100% in \(Format.countdown(to: projectedExhaustion, now: now))")
    } else if expectedPercent != nil {
      parts.append("lasts to reset")
    }
    return parts.joined(separator: " · ")
  }
}
