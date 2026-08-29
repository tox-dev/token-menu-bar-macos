import Foundation

public struct UsageSample: Sendable, Hashable, Codable {
  public let timestamp: Date
  public let key: WindowKey
  public let usedPercent: Double
  public let resetsAt: Date?

  public init(timestamp: Date, key: WindowKey, usedPercent: Double, resetsAt: Date?) {
    self.timestamp = timestamp
    self.key = key
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
  }
}

public struct WindowSummary: Sendable, Hashable, Identifiable {
  public let key: WindowKey
  public let label: String
  public let lastSeen: Date
  public let lastPercent: Double

  public var id: WindowKey { key }
}

public struct HistoryStats: Sendable, Equatable {
  public let sampleCount: Int
  public let analyticsCount: Int
  public let oldest: Date?
  public let newest: Date?
}

public actor UsageHistoryStore {
  public static let retention: TimeInterval = 60 * 86400
  public static let sampleInterval: TimeInterval = 300
  public static let changeThreshold: Double = 5

  let database: SQLiteDatabase
  private var lastRecorded: [WindowKey: UsageSample] = [:]
  private var lastPrune: Date?
  public nonisolated let location: URL?

  public init(url: URL?) throws {
    location = url
    if let url {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    database = try SQLiteDatabase(path: url?.path ?? ":memory:")
    try database.execute("PRAGMA journal_mode = WAL")
    try database.execute(
      """
      CREATE TABLE IF NOT EXISTS samples (
        ts REAL NOT NULL, key TEXT NOT NULL, label TEXT NOT NULL, used REAL NOT NULL, resets_at REAL,
        PRIMARY KEY (key, ts)
      )
      """
    )
    try database.execute(
      """
      CREATE TABLE IF NOT EXISTS analytics (
        provider TEXT NOT NULL, day TEXT NOT NULL, metric TEXT NOT NULL, series TEXT NOT NULL, value REAL NOT NULL,
        PRIMARY KEY (provider, day, metric, series)
      )
      """
    )
    try database.execute("CREATE INDEX IF NOT EXISTS samples_ts ON samples (ts)")
    let latest = try database.query(
      "SELECT key, MAX(ts), used, resets_at FROM samples GROUP BY key"
    ) { row -> UsageSample? in
      WindowKey(storageKey: row.text(0)).map {
        UsageSample(timestamp: row.date(1)!, key: $0, usedPercent: row.double(2)!, resetsAt: row.date(3))
      }
    }
    for sample in latest.compactMap({ $0 }) { lastRecorded[sample.key] = sample }
  }

  @discardableResult
  public func record(_ snapshot: ProviderSnapshot, now: Date) throws -> Int {
    var written = 0
    for window in snapshot.windows {
      let key = WindowKey(snapshot.provider, window)
      let sample = UsageSample(timestamp: now, key: key, usedPercent: window.usedPercent, resetsAt: window.resetsAt)
      guard Self.shouldRecord(sample, after: lastRecorded[key]) else { continue }
      try database.execute(
        "INSERT OR REPLACE INTO samples (ts, key, label, used, resets_at) VALUES (?, ?, ?, ?, ?)",
        [
          .real(now.timeIntervalSince1970), .text(key.storageKey), .text(window.label), .real(window.usedPercent),
          SQLiteValue(window.resetsAt),
        ]
      )
      lastRecorded[key] = sample
      written += 1
    }
    try pruneIfNeeded(now: now)
    return written
  }

  public func seed(_ snapshots: [(ProviderSnapshot, Date)]) throws {
    try database.execute("BEGIN")
    defer { try? database.execute("COMMIT") }
    for (snapshot, stamp) in snapshots {
      for window in snapshot.windows {
        try database.execute(
          "INSERT OR REPLACE INTO samples (ts, key, label, used, resets_at) VALUES (?, ?, ?, ?, ?)",
          [
            .real(stamp.timeIntervalSince1970), .text(WindowKey(snapshot.provider, window).storageKey),
            .text(window.label), .real(window.usedPercent), SQLiteValue(window.resetsAt),
          ]
        )
      }
    }
  }

  static func shouldRecord(_ sample: UsageSample, after previous: UsageSample?) -> Bool {
    guard let previous else { return true }
    if sample.timestamp.timeIntervalSince(previous.timestamp) >= sampleInterval { return true }
    if sample.resetsAt != previous.resetsAt { return true }
    return abs(sample.usedPercent - previous.usedPercent) >= changeThreshold
  }

  @discardableResult
  public func record(_ analytics: ProviderAnalytics) throws -> Int {
    try database.execute("BEGIN")
    defer { try? database.execute("COMMIT") }
    for point in analytics.points {
      try database.execute(
        "INSERT OR REPLACE INTO analytics (provider, day, metric, series, value) VALUES (?, ?, ?, ?, ?)",
        [
          .text(analytics.provider.rawValue), .text(point.day), .text(point.metric.rawValue), .text(point.series),
          .real(point.value),
        ]
      )
    }
    return analytics.points.count
  }

  public func samples(keys: [WindowKey]? = nil, from start: Date, to end: Date) throws -> [UsageSample] {
    var sql = "SELECT ts, key, used, resets_at FROM samples WHERE ts >= ? AND ts <= ?"
    var parameters: [SQLiteValue] = [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)]
    if let keys {
      sql += " AND key IN (\(Array(repeating: "?", count: keys.count).joined(separator: ",")))"
      parameters += keys.map { .text($0.storageKey) }
    }
    sql += " ORDER BY ts ASC"
    return try database.query(sql, parameters) { row -> UsageSample? in
      WindowKey(storageKey: row.text(1)).map {
        UsageSample(timestamp: row.date(0)!, key: $0, usedPercent: row.double(2)!, resetsAt: row.date(3))
      }
    }.compactMap { $0 }
  }

  public func recentSamples(key: WindowKey, since: Date) throws -> [UsageSample] {
    try samples(keys: [key], from: since, to: .distantFuture)
  }

  public func analytics(provider: ProviderID, from start: String, to end: String) throws -> [AnalyticsPoint] {
    try database.query(
      "SELECT day, metric, series, value FROM analytics WHERE provider = ? AND day >= ? AND day <= ? ORDER BY day ASC",
      [.text(provider.rawValue), .text(start), .text(end)]
    ) { row -> AnalyticsPoint? in
      AnalyticsMetric(rawValue: row.text(1)).map {
        AnalyticsPoint(day: row.text(0), metric: $0, series: row.text(2), value: row.double(3)!)
      }
    }.compactMap { $0 }
  }

  public func summaries() throws -> [WindowSummary] {
    try database.query("SELECT key, label, MAX(ts), used FROM samples GROUP BY key ORDER BY key") {
      row -> WindowSummary? in
      WindowKey(storageKey: row.text(0)).map {
        WindowSummary(key: $0, label: row.text(1), lastSeen: row.date(2)!, lastPercent: row.double(3)!)
      }
    }.compactMap { $0 }
  }

  public func earliestSample() throws -> Date? {
    try database.query("SELECT MIN(ts) FROM samples") { $0.date(0) }.first ?? nil
  }

  public func stats() throws -> HistoryStats {
    let counts = try database.query("SELECT COUNT(*), MIN(ts), MAX(ts) FROM samples") {
      ($0.int(0), $0.date(1), $0.date(2))
    }.first!
    let analyticsCount = try database.query("SELECT COUNT(*) FROM analytics") { $0.int(0) }.first!
    return HistoryStats(sampleCount: counts.0, analyticsCount: analyticsCount, oldest: counts.1, newest: counts.2)
  }

  public func exportCSV() throws -> String {
    let rows = try database.query("SELECT ts, key, label, used, resets_at FROM samples ORDER BY ts ASC") { row in
      [
        ISODate.string(row.date(0)!), row.text(1), row.text(2),
        row.double(3)!.formatted(.number.precision(.fractionLength(2))),
        row.date(4).map(ISODate.string) ?? "",
      ].map { $0.contains(",") ? "\"\($0)\"" : $0 }.joined(separator: ",")
    }
    return (["timestamp,key,label,used_percent,resets_at"] + rows).joined(separator: "\n") + "\n"
  }

  @discardableResult
  public func clear() throws -> Int {
    try database.execute("DELETE FROM samples")
    let removed = database.changes
    try database.execute("DELETE FROM analytics")
    lastRecorded.removeAll()
    return removed
  }

  func pruneIfNeeded(now: Date) throws {
    if let lastPrune, now.timeIntervalSince(lastPrune) < 3600 { return }
    let cutoff = now.addingTimeInterval(-Self.retention)
    try database.execute("DELETE FROM samples WHERE ts < ?", [.real(cutoff.timeIntervalSince1970)])
    try database.execute("DELETE FROM analytics WHERE day < ?", [.text(DayStamp.string(cutoff))])
    lastPrune = now
  }
}
