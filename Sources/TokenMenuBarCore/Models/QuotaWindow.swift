import Foundation

public enum WindowGroup: String, Codable, Sendable, Hashable, Comparable {
  case session
  case weekly
  case monthly
  case other

  private var order: Int {
    switch self {
    case .session: 0
    case .weekly: 1
    case .monthly: 2
    case .other: 3
    }
  }

  public static func < (lhs: WindowGroup, rhs: WindowGroup) -> Bool {
    lhs.order < rhs.order
  }
}

public enum Severity: String, Codable, Sendable, Hashable {
  case normal
  case warning
  case critical

  public init(raw: String?) {
    switch raw?.lowercased() {
    case "warning", "elevated", "high": self = .warning
    case "critical", "exhausted", "limit_reached": self = .critical
    default: self = .normal
    }
  }

  public init(percent: Double) {
    self = percent >= 90 ? .critical : percent >= 75 ? .warning : .normal
  }
}

public struct QuotaWindow: Codable, Sendable, Hashable, Identifiable {
  public let id: String
  public let label: String
  public let group: WindowGroup
  public let usedPercent: Double
  public let resetsAt: Date?
  public let duration: TimeInterval?
  public let severity: Severity
  public let isActive: Bool
  public let scope: String?
  public let resetPrecision: ResetPrecision
  /// Text the card shows under the label instead of the window id, such as which pools an aggregate combines.
  public let detail: String?

  public init(
    id: String,
    label: String,
    group: WindowGroup,
    usedPercent: Double,
    resetsAt: Date?,
    duration: TimeInterval? = nil,
    severity: Severity? = nil,
    isActive: Bool = true,
    scope: String? = nil,
    resetPrecision: ResetPrecision = .instant,
    detail: String? = nil
  ) {
    self.id = id
    self.label = label
    self.group = group
    self.usedPercent = min(max(usedPercent, 0), 100)
    self.resetsAt = resetsAt
    self.duration = duration
    self.severity = severity ?? Severity(percent: usedPercent)
    self.isActive = isActive
    self.scope = scope
    self.resetPrecision = resetPrecision
    self.detail = detail
  }

  // Snapshots cached before the precision existed decode as instants.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      label: try container.decode(String.self, forKey: .label),
      group: try container.decode(WindowGroup.self, forKey: .group),
      usedPercent: try container.decode(Double.self, forKey: .usedPercent),
      resetsAt: try container.decodeIfPresent(Date.self, forKey: .resetsAt),
      duration: try container.decodeIfPresent(TimeInterval.self, forKey: .duration),
      severity: try container.decode(Severity.self, forKey: .severity),
      isActive: try container.decode(Bool.self, forKey: .isActive),
      scope: try container.decodeIfPresent(String.self, forKey: .scope),
      resetPrecision: try container.decodeIfPresent(ResetPrecision.self, forKey: .resetPrecision) ?? .instant,
      detail: try container.decodeIfPresent(String.self, forKey: .detail))
  }

  public func withDetail(_ detail: String?) -> QuotaWindow {
    QuotaWindow(
      id: id, label: label, group: group, usedPercent: usedPercent, resetsAt: resetsAt, duration: duration,
      severity: severity, isActive: isActive, scope: scope, resetPrecision: resetPrecision, detail: detail)
  }

  public var remainingPercent: Double {
    100 - usedPercent
  }

  public func windowStart(now: Date) -> Date? {
    guard let resetsAt, let duration else { return nil }
    return resetsAt.addingTimeInterval(-duration)
  }

  public func hasReset(since previous: QuotaWindow) -> Bool {
    guard let old = previous.resetsAt, let new = resetsAt else { return usedPercent < previous.usedPercent - 1 }
    return new > old
  }
}

public struct WindowKey: Codable, Sendable, Hashable, Comparable {
  public let provider: ProviderID
  public let windowID: String

  public init(provider: ProviderID, windowID: String) {
    self.provider = provider
    self.windowID = windowID
  }

  public init(_ provider: ProviderID, _ window: QuotaWindow) {
    self.init(provider: provider, windowID: window.id)
  }

  public var storageKey: String {
    "\(provider.rawValue):\(windowID)"
  }

  public init?(storageKey: String) {
    guard let colon = storageKey.firstIndex(of: ":"), let provider = ProviderID(rawValue: String(storageKey[..<colon]))
    else { return nil }
    self.init(provider: provider, windowID: String(storageKey[storageKey.index(after: colon)...]))
  }

  public static func < (lhs: WindowKey, rhs: WindowKey) -> Bool {
    (lhs.provider, lhs.windowID) < (rhs.provider, rhs.windowID)
  }
}
