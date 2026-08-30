import Foundation
import OSLog

public enum LogLevel: String, Codable, Sendable, Comparable {
  case debug
  case info
  case error

  private var order: Int {
    switch self {
    case .debug: 0
    case .info: 1
    case .error: 2
    }
  }

  public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
    lhs.order < rhs.order
  }
}

public struct LogEntry: Codable, Sendable, Hashable, Identifiable {
  public let timestamp: Date
  public let level: LogLevel
  public let message: String

  public init(timestamp: Date, level: LogLevel, message: String) {
    self.timestamp = timestamp
    self.level = level
    self.message = message
  }

  public var id: String {
    "\(timestamp.timeIntervalSince1970)-\(message.hashValue)"
  }

  public var line: String {
    "\(LogBuffer.timestampFormat.string(from: timestamp)) [\(level.rawValue)] \(message)"
  }
}

public final class LogBuffer: @unchecked Sendable {
  static let timestampFormat: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()

  public static let capacity = 500
  public static let retention: TimeInterval = 7 * 86400

  private let lock = NSLock()
  private var entries: [LogEntry] = []
  private var lastPrune: Date?
  private let fileURL: URL?
  private let clock: Clock
  private let osLog = Logger(subsystem: "dev.tox.token-menu-bar", category: "app")
  public var debugEnabled: Bool {
    get { lock.withLock { _debugEnabled } }
    set { lock.withLock { _debugEnabled = newValue } }
  }
  private var _debugEnabled = false

  public init(fileURL: URL?, clock: Clock = .system) {
    self.fileURL = fileURL
    self.clock = clock
    if let fileURL, let data = try? Data(contentsOf: fileURL),
      let stored = try? JSONDecoder().decode([LogEntry].self, from: data)
    {
      let cutoff = clock.now().addingTimeInterval(-Self.retention)
      entries = stored.filter { $0.timestamp >= cutoff }.suffix(Self.capacity)
      lastPrune = clock.now()
    }
  }

  public func log(_ message: String) {
    append(.info, message)
  }

  public func logError(_ message: String) {
    append(.error, message)
  }

  public func logDebug(_ message: String) {
    guard debugEnabled else { return }
    append(.info, message)
  }

  private func append(_ level: LogLevel, _ message: String) {
    let entry = LogEntry(timestamp: clock.now(), level: level, message: message)
    switch level {
    case .error: osLog.error("\(message, privacy: .public)")
    default: osLog.info("\(message, privacy: .public)")
    }
    lock.withLock {
      entries.append(entry)
      if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
      let now = clock.now()
      if lastPrune.map({ now.timeIntervalSince($0) > 3600 }) ?? true {
        let cutoff = now.addingTimeInterval(-Self.retention)
        entries.removeAll { $0.timestamp < cutoff }
        lastPrune = now
      }
      persist()
    }
  }

  private func persist() {
    guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
    try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: fileURL, options: .atomic)
  }

  public var snapshot: [LogEntry] {
    lock.withLock { entries }
  }

  public func tail(_ count: Int) -> [LogEntry] {
    lock.withLock { Array(entries.suffix(count)) }
  }

  public func clear() {
    lock.withLock {
      entries.removeAll()
      persist()
    }
  }

  public var text: String {
    snapshot.map(\.line).joined(separator: "\n")
  }
}
