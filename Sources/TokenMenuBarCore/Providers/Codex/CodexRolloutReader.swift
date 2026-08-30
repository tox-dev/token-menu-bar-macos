import Foundation

public struct CodexRolloutReader: Sendable {
  static let maxFiles = 8

  public let sessionsRoot: URL

  public init(sessionsRoot: URL) {
    self.sessionsRoot = sessionsRoot
  }

  struct Reading: Sendable, Equatable {
    let rateLimit: CodexAPI.RateLimit
    let planType: String?
    let credits: CodexAPI.Credits?
    let observedAt: Date?
  }

  func latest() -> Reading? {
    for url in newestRollouts() {
      guard let data = FileManager.default.contents(atPath: url.path) else { continue }
      let text = String(decoding: data, as: UTF8.self)
      for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
        if let reading = Self.parse(line: String(line)) { return reading }
      }
    }
    return nil
  }

  func newestRollouts() -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: sessionsRoot, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
    else { return [] }
    var candidates: [(URL, Date)] = []
    for case let url as URL in enumerator
    where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
      let modified =
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
      candidates.append((url, modified))
    }
    return candidates.sorted { $0.1 > $1.1 }.prefix(Self.maxFiles).map(\.0)
  }

  static func parse(line: String) -> Reading? {
    guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), let limits = findRateLimits(json)
    else { return nil }
    func window(_ value: JSONValue?) -> CodexAPI.Window? {
      guard let value, let used = value["used_percent"]?.doubleValue else { return nil }
      let minutes = value["window_minutes"]?.doubleValue
      return CodexAPI.Window(
        usedPercent: used,
        limitWindowSeconds: minutes.map { $0 * 60 } ?? value["limit_window_seconds"]?.doubleValue,
        resetAfterSeconds: value["resets_in_seconds"]?.doubleValue,
        resetAt: value["resets_at"]?.doubleValue ?? value["reset_at"]?.doubleValue
      )
    }
    let credits = limits["credits"].flatMap { value -> CodexAPI.Credits? in
      guard let data = try? JSONEncoder().encode(value) else { return nil }
      return try? JSONDecoder().decode(CodexAPI.Credits.self, from: data)
    }
    let observed = json["timestamp"]?.stringValue.flatMap { ISODate.parse($0) }
    return Reading(
      rateLimit: CodexAPI.RateLimit(
        allowed: nil,
        limitReached: limits["rate_limit_reached_type"].map { !$0.isNull },
        primaryWindow: window(limits["primary"]),
        secondaryWindow: window(limits["secondary"])
      ),
      planType: limits["plan_type"]?.stringValue,
      credits: credits,
      observedAt: observed
    )
  }

  static func findRateLimits(_ value: JSONValue) -> JSONValue? {
    switch value {
    case .object(let dict):
      if let limits = dict["rate_limits"], limits.objectValue != nil { return limits }
      for child in dict.values { if let found = findRateLimits(child) { return found } }
      return nil
    case .array(let items):
      for item in items { if let found = findRateLimits(item) { return found } }
      return nil
    default:
      return nil
    }
  }
}
