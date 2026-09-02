import Foundation

public struct WidgetRow: Codable, Sendable, Hashable, Identifiable {
  public let key: WindowKey
  public let providerName: String
  public let label: String
  public let usedPercent: Double
  public let resetsAt: Date?

  public init(key: WindowKey, providerName: String, label: String, usedPercent: Double, resetsAt: Date?) {
    self.key = key
    self.providerName = providerName
    self.label = label
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
  }

  public var id: WindowKey { key }

  public var percentText: String {
    Format.percent(usedPercent)
  }

  public func resetText(now: Date) -> String {
    Format.countdown(to: resetsAt, now: now)
  }
}

public struct WidgetSnapshot: Codable, Sendable, Hashable {
  public static let appGroup = "group.dev.tox.token-menu-bar"
  public static let appGroupInfoKey = "TokenMenuBarAppGroup"
  public static let fileName = "widget.json"

  public static func appGroup(info: [String: Any]?) -> String {
    guard let configured = info?[appGroupInfoKey] as? String, !configured.isEmpty, !configured.hasPrefix("$(") else {
      return appGroup
    }
    return configured
  }

  public let rows: [WidgetRow]
  public let attention: Bool
  public let updatedAt: Date

  public init(rows: [WidgetRow], attention: Bool, updatedAt: Date) {
    self.rows = rows
    self.attention = attention
    self.updatedAt = updatedAt
  }

  /// Shown until the app writes its first snapshot. Empty on purpose: `placeholder` carries sample percentages
  /// and would otherwise read as the viewer's own quota.
  public static let unavailable = WidgetSnapshot(rows: [], attention: false, updatedAt: .distantPast)

  public static let placeholder = WidgetSnapshot(
    rows: [
      WidgetRow(
        key: WindowKey(provider: .claude, windowID: "session"), providerName: "Claude", label: "Current session",
        usedPercent: 36, resetsAt: Date().addingTimeInterval(4 * 3600)),
      WidgetRow(
        key: WindowKey(provider: .claude, windowID: "weekly"), providerName: "Claude", label: "All models",
        usedPercent: 61, resetsAt: Date().addingTimeInterval(3 * 86400)),
      WidgetRow(
        key: WindowKey(provider: .codex, windowID: "weekly"), providerName: "Codex", label: "Weekly", usedPercent: 76,
        resetsAt: Date().addingTimeInterval(6 * 86400)),
    ], attention: false, updatedAt: Date())

  public static func build(
    snapshots: [ProviderID: ProviderSnapshot], availability: [ProviderID: QuotaAvailability],
    selectedKeys: [WindowKey], now: Date
  ) -> WidgetSnapshot {
    let rows = selectedKeys.compactMap { key -> WidgetRow? in
      guard let snapshot = snapshots[key.provider], let window = snapshot.window(key.windowID) else { return nil }
      return WidgetRow(
        key: key, providerName: key.provider.displayName, label: window.label, usedPercent: window.usedPercent,
        resetsAt: window.resetsAt)
    }
    return WidgetSnapshot(
      rows: rows, attention: availability.values.contains(.authenticationRequired), updatedAt: now)
  }

  public var hasData: Bool {
    updatedAt != .distantPast
  }

  public var isStale: Bool {
    Date().timeIntervalSince(updatedAt) > 3600
  }
}

public struct WidgetSnapshotStore: Sendable {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public static func sharedURL(
    containerURL: (String) -> URL?, fallbackDirectory: URL, appGroup: String = WidgetSnapshot.appGroup
  ) -> URL {
    (containerURL(appGroup) ?? fallbackDirectory).appendingPathComponent(WidgetSnapshot.fileName)
  }

  public func write(_ snapshot: WidgetSnapshot) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    try encoder.encode(snapshot).write(to: url, options: .atomic)
  }

  public func read() -> WidgetSnapshot? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return try? decoder.decode(WidgetSnapshot.self, from: data)
  }
}
