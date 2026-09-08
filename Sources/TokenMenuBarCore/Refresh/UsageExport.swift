import Foundation

/// The snapshot set as scripts read it: `--usage-json` prints it and `Settings.writeUsageFile` keeps a copy next to
/// the widget snapshot after every refresh cycle.
public struct UsageExport: Codable, Sendable, Equatable {
  public static let fileName = "usage.json"

  public struct Window: Codable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(id: String, label: String, usedPercent: Double, resetsAt: Date?) {
      self.id = id
      self.label = label
      self.usedPercent = usedPercent
      self.resetsAt = resetsAt
    }
  }

  public struct Provider: Codable, Sendable, Equatable {
    public let id: ProviderID
    public let plan: String?
    public let fetchedAt: Date
    public let windows: [Window]

    public init(id: ProviderID, plan: String?, fetchedAt: Date, windows: [Window]) {
      self.id = id
      self.plan = plan
      self.fetchedAt = fetchedAt
      self.windows = windows
    }
  }

  public let providers: [Provider]

  public init(snapshots: [ProviderID: ProviderSnapshot]) {
    providers = snapshots.keys.sorted().map { id in
      let snapshot = snapshots[id]!
      return Provider(
        id: id, plan: snapshot.identity?.planName, fetchedAt: snapshot.fetchedAt,
        windows: snapshot.windows.map {
          Window(id: $0.id, label: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
        })
    }
  }

  public func json() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  public func write(to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try json().write(to: url, options: .atomic)
  }
}
