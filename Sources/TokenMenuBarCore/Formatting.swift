import Foundation

public enum Format {
  public static func percent(_ value: Double, decimals: Int = 0) -> String {
    let clamped = min(max(value, 0), 100)
    return clamped.formatted(.number.precision(.fractionLength(decimals))) + "%"
  }

  public static func countdown(to date: Date?, now: Date) -> String {
    guard let date else { return "—" }
    let seconds = date.timeIntervalSince(now)
    guard seconds > 0 else { return "reset due" }
    let minutes = Int(seconds / 60)
    let days = minutes / 1440
    let hours = (minutes % 1440) / 60
    let mins = minutes % 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours) hr \(mins) min" }
    if minutes > 0 { return "\(mins) min" }
    return "< 1 min"
  }

  public static func compactCountdown(to date: Date?, now: Date) -> String {
    guard let date else { return "--" }
    let seconds = date.timeIntervalSince(now)
    guard seconds > 0 else { return "0m" }
    let minutes = Int(seconds / 60)
    let days = minutes / 1440
    let hours = (minutes % 1440) / 60
    let mins = minutes % 60
    if days > 0 { return "\(days)d\(hours)h" }
    if hours > 0 { return "\(hours)h\(String(format: "%02d", mins))m" }
    return "\(mins)m"
  }

  public static func resetClock(_ date: Date?, now: Date, calendar: Calendar = .current) -> String {
    guard let date else { return "—" }
    guard date > now else { return "now" }
    if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
    if date.timeIntervalSince(now) < 6 * 86400 {
      return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
    return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
  }

  public static func compactNumber(_ value: Double) -> String {
    let magnitude = abs(value)
    let (scaled, suffix): (Double, String) =
      switch magnitude {
      case ..<1000: (value, "")
      case ..<1_000_000: (value / 1000, "K")
      case ..<1_000_000_000: (value / 1_000_000, "M")
      default: (value / 1_000_000_000, "B")
      }
    let digits = abs(scaled) < 10 && !suffix.isEmpty ? 1 : 0
    return scaled.formatted(.number.precision(.fractionLength(digits))) + suffix
  }

  public static func duration(_ seconds: TimeInterval) -> String {
    let hours = Int(seconds / 3600)
    if hours >= 24, hours % 24 == 0 { return hours == 24 ? "24h" : "\(hours / 24)d" }
    if hours > 0 { return "\(hours)h" }
    return "\(Int(seconds / 60))m"
  }

  public static func windowLabel(seconds: TimeInterval) -> String {
    switch seconds {
    case 18000: "5-hour"
    case 604_800: "Weekly"
    case 86400: "Daily"
    case 2_592_000, 2_678_400: "Monthly"
    default: duration(seconds)
    }
  }

  public static func humanize(_ key: String) -> String {
    key.split(whereSeparator: { $0 == "_" || $0 == "-" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(
      separator: " ")
  }

  public static func slug(_ text: String) -> String {
    text.lowercased().replacing(try! Regex("[^a-z0-9]+"), with: "-").trimmingCharacters(
      in: CharacterSet(charactersIn: "-"))
  }

  public static func relativeAge(_ date: Date?, now: Date) -> String {
    guard let date else { return "never" }
    let seconds = max(now.timeIntervalSince(date), 0)
    if seconds < 5 { return "just now" }
    if seconds < 60 { return "\(Int(seconds))s ago" }
    if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
    if seconds < 86400 { return "\(Int(seconds / 3600)) hr ago" }
    return "\(Int(seconds / 86400)) d ago"
  }
}
