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

public struct HistoryPruneResult: Sendable, Equatable {
  public let samples: Int
  public let analytics: Int

  public init(samples: Int, analytics: Int) {
    self.samples = samples
    self.analytics = analytics
  }

  public var total: Int { samples + analytics }
}

private struct AnalyticsStorageKey: Hashable {
  let day: String
  let metric: AnalyticsMetric
  let series: String
}

private struct SampleBucket: Hashable {
  let key: WindowKey
  let start: Date
}

private struct OffsetSegment {
  let start: Date
  let end: Date
  let includesEnd: Bool
  let offset: TimeInterval
}

public actor UsageHistoryStore {
  public static let defaultRetentionDays = 60
  public static let retention: TimeInterval = TimeInterval(defaultRetentionDays) * 86400
  public static let sampleInterval: TimeInterval = 300
  static let changeThreshold: Double = 5

  let database: SQLiteDatabase
  private var lastRecorded: [WindowKey: UsageSample] = [:]
  private var lastPrune: Date?
  public private(set) var retentionDays: Int
  public nonisolated let location: URL?

  public init(url: URL?, retentionDays: Int = defaultRetentionDays) throws {
    location = url
    self.retentionDays = min(max(retentionDays, 7), 365)
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
    try database.execute(
      """
      CREATE TABLE IF NOT EXISTS analytics_accounts (
        provider TEXT PRIMARY KEY, fingerprint TEXT NOT NULL
      )
      """
    )
    try database.execute("CREATE INDEX IF NOT EXISTS samples_ts ON samples (ts)")
    try database.execute(
      "CREATE INDEX IF NOT EXISTS analytics_metric_day_provider ON analytics (metric, day, provider)")
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
    var pending: [(key: WindowKey, sample: UsageSample, row: [SQLiteValue])] = []
    for window in snapshot.windows {
      let key = WindowKey(snapshot.provider, window)
      let sample = UsageSample(timestamp: now, key: key, usedPercent: window.usedPercent, resetsAt: window.resetsAt)
      guard Self.shouldRecord(sample, after: lastRecorded[key]) else { continue }
      pending.append(
        (
          key, sample,
          [
            .real(now.timeIntervalSince1970), .text(key.storageKey), .text(window.label), .real(window.usedPercent),
            SQLiteValue(window.resetsAt),
          ]
        ))
    }
    try database.withTransaction {
      try database.executeMany(
        "INSERT OR REPLACE INTO samples (ts, key, label, used, resets_at) VALUES (?, ?, ?, ?, ?)",
        pending.map(\.row))
    }
    for item in pending { lastRecorded[item.key] = item.sample }
    try pruneIfNeeded(now: now)
    return pending.count
  }

  public func seed(_ snapshots: [(ProviderSnapshot, Date)]) throws {
    try database.withTransaction {
      try database.executeMany(
        "INSERT OR REPLACE INTO samples (ts, key, label, used, resets_at) VALUES (?, ?, ?, ?, ?)",
        snapshots.flatMap { snapshot, stamp in
          snapshot.windows.map { window in
            [
              SQLiteValue.real(stamp.timeIntervalSince1970), .text(WindowKey(snapshot.provider, window).storageKey),
              .text(window.label), .real(window.usedPercent), SQLiteValue(window.resetsAt),
            ]
          }
        })
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
    let cutoff = analyticsCutoffDay(now: analytics.fetchedAt)
    var totals: [AnalyticsStorageKey: Double] = [:]
    for point in analytics.points where point.day >= cutoff {
      totals[AnalyticsStorageKey(day: point.day, metric: point.metric, series: point.series), default: 0] += point.value
    }
    let points = totals.map { key, value in
      AnalyticsPoint(day: key.day, metric: key.metric, series: key.series, value: value)
    }
    try database.withTransaction {
      if let fingerprint = analytics.accountFingerprint {
        let stored = try database.query(
          "SELECT fingerprint FROM analytics_accounts WHERE provider = ?", [.text(analytics.provider.rawValue)]
        ) { $0.text(0) }.first
        if let stored, stored != fingerprint {
          try database.execute("DELETE FROM analytics WHERE provider = ?", [.text(analytics.provider.rawValue)])
        }
        try database.execute(
          "INSERT OR REPLACE INTO analytics_accounts (provider, fingerprint) VALUES (?, ?)",
          [.text(analytics.provider.rawValue), .text(fingerprint)])
      }
      for scope in analytics.coveredScopes where !scope.metrics.isEmpty {
        let start = max(scope.startDay, cutoff)
        guard start <= scope.endDay else { continue }
        let metrics = scope.metrics.sorted { $0.rawValue < $1.rawValue }
        let placeholders = Array(repeating: "?", count: metrics.count).joined(separator: ",")
        try database.execute(
          "DELETE FROM analytics WHERE provider = ? AND metric IN (\(placeholders)) AND day >= ? AND day <= ?",
          [.text(analytics.provider.rawValue)] + metrics.map { .text($0.rawValue) }
            + [.text(start), .text(scope.endDay)])
      }
      try database.executeMany(
        "INSERT OR REPLACE INTO analytics (provider, day, metric, series, value) VALUES (?, ?, ?, ?, ?)",
        points.map { point in
          [
            SQLiteValue.text(analytics.provider.rawValue), .text(point.day), .text(point.metric.rawValue),
            .text(point.series), .real(point.value),
          ]
        })
      try database.execute("DELETE FROM analytics WHERE day < ?", [.text(cutoff)])
    }
    return points.count
  }

  /// - Parameter rollup: when given, the database returns the newest row of each `(key, bucket)` rather than every
  ///   row, which is what the chart keeps anyway. A sixty-day range is around 150 000 rows and a few thousand
  ///   buckets, so this is the difference between holding the table in memory and holding what is drawn.
  /// - Parameter timeZone: the calendar used for bucket boundaries. Queries split at offset changes so database
  ///   reduction stays small without assigning rows to the wrong local bucket.
  public func samples(
    keys: [WindowKey]? = nil, from start: Date, to end: Date, rollup: TimeInterval? = nil,
    timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!, includesEnd: Bool = true
  ) async throws -> [UsageSample] {
    try await withTaskCancellationHandler {
      if keys?.isEmpty == true { return [] }
      guard let rollup, rollup > 0 else {
        return try querySamples(keys: keys, from: start, to: end, includesEnd: includesEnd)
      }
      let samples = try Self.offsetSegments(
        from: start, to: end, timeZone: timeZone, includesEnd: includesEnd
      ).flatMap { segment in
        try querySamples(
          keys: keys, from: segment.start, to: segment.end, includesEnd: segment.includesEnd, rollup: rollup,
          timeZoneOffset: segment.offset)
      }
      return Self.collapse(samples, rollup: rollup, timeZone: timeZone)
    } onCancel: {
      database.interrupt()
    }
  }

  private func querySamples(
    keys: [WindowKey]?, from start: Date, to end: Date, includesEnd: Bool, rollup: TimeInterval? = nil,
    timeZoneOffset: TimeInterval = 0
  ) throws -> [UsageSample] {
    var sql = "SELECT ts, key, used, resets_at FROM samples WHERE ts >= ? AND ts \(includesEnd ? "<=" : "<") ?"
    var parameters: [SQLiteValue] = [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)]
    if let keys {
      sql += " AND key IN (\(Array(repeating: "?", count: keys.count).joined(separator: ",")))"
      parameters += keys.map { .text($0.storageKey) }
    }
    if let rollup, rollup > 0 {
      sql =
        "SELECT ts, key, used, resets_at FROM (SELECT ts, key, used, resets_at, ROW_NUMBER() OVER "
        + "(PARTITION BY key, CAST((ts + ?) / ? AS INTEGER) ORDER BY ts DESC) AS rank FROM (\(sql))) WHERE rank = 1"
      parameters = [.real(timeZoneOffset), .real(rollup)] + parameters
    }
    sql += " ORDER BY ts ASC"
    return try database.query(sql, parameters) { row -> UsageSample? in
      WindowKey(storageKey: row.text(1)).map {
        UsageSample(timestamp: row.date(0)!, key: $0, usedPercent: row.double(2)!, resetsAt: row.date(3))
      }
    }.compactMap { $0 }
  }

  public func lastUsageDates(
    keys: [WindowKey], from start: Date, to end: Date
  ) async throws -> [WindowKey: Date] {
    try await withTaskCancellationHandler {
      let keys = keys.uniqued()
      guard !keys.isEmpty else { return [:] }
      let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
      let parameters: [SQLiteValue] =
        [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)]
        + keys.map { .text($0.storageKey) }
      let rows = try database.query(
        """
        WITH chronological AS (
          SELECT ts, key, used, resets_at,
            LAG(ts) OVER (PARTITION BY key ORDER BY ts) AS previous_ts,
            LAG(used) OVER (PARTITION BY key ORDER BY ts) AS previous_used,
            LAG(resets_at) OVER (PARTITION BY key ORDER BY ts) AS previous_resets_at
          FROM samples
          WHERE ts >= ? AND ts <= ? AND key IN (\(placeholders))
        )
        SELECT key, MAX(ts)
        FROM chronological
        WHERE used > 0 AND (
          previous_ts IS NULL OR resets_at IS NOT previous_resets_at OR used > previous_used
        )
        GROUP BY key
        """,
        parameters
      ) { row -> (WindowKey, Date)? in
        guard let key = WindowKey(storageKey: row.text(0)), let date = row.date(1) else { return nil }
        return (key, date)
      }.compactMap { $0 }
      return Dictionary(uniqueKeysWithValues: rows)
    } onCancel: {
      database.interrupt()
    }
  }

  public func recentSamples(key: WindowKey, since: Date) async throws -> [UsageSample] {
    try await samples(keys: [key], from: since, to: .distantFuture)
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

  public func analytics(
    metric: AnalyticsMetric, providers: [ProviderID], from start: String, to end: String
  ) throws -> [HistoryAnalyticsRow] {
    try analytics(metric: metric, providers: providers, from: start, end: end, includesEnd: true)
  }

  public func analytics(
    metric: AnalyticsMetric, providers: [ProviderID], from start: String, before end: String
  ) throws -> [HistoryAnalyticsRow] {
    try analytics(metric: metric, providers: providers, from: start, end: end, includesEnd: false)
  }

  private func analytics(
    metric: AnalyticsMetric, providers: [ProviderID], from start: String, end: String, includesEnd: Bool
  ) throws -> [HistoryAnalyticsRow] {
    guard !providers.isEmpty else { return [] }
    let placeholders = Array(repeating: "?", count: providers.count).joined(separator: ",")
    let parameters: [SQLiteValue] =
      [.text(metric.rawValue), .text(start), .text(end)] + providers.map { .text($0.rawValue) }
    return try database.query(
      "SELECT provider, day, series, value FROM analytics WHERE metric = ? AND day >= ? "
        + "AND day \(includesEnd ? "<=" : "<") ? "
        + "AND provider IN (\(placeholders)) ORDER BY day ASC, provider ASC, series ASC",
      parameters
    ) { row -> HistoryAnalyticsRow? in
      guard let provider = ProviderID(rawValue: row.text(0)) else { return nil }
      return HistoryAnalyticsRow(
        provider: provider,
        point: AnalyticsPoint(day: row.text(1), metric: metric, series: row.text(2), value: row.double(3)!))
    }.compactMap { $0 }
  }

  public func summaries() throws -> [WindowSummary] {
    // Grouping the whole table walks every row. The primary key is (key, ts), so the inner query seeks the last row
    // of each key group and the join reads only those.
    let sql =
      "SELECT s.key, s.label, s.ts, s.used FROM samples s "
      + "JOIN (SELECT key, MAX(ts) AS last_ts FROM samples GROUP BY key) latest "
      + "ON s.key = latest.key AND s.ts = latest.last_ts ORDER BY s.key"
    return try database.query(sql) {
      row -> WindowSummary? in
      WindowKey(storageKey: row.text(0)).map {
        WindowSummary(key: $0, label: row.text(1), lastSeen: row.date(2)!, lastPercent: row.double(3)!)
      }
    }.compactMap { $0 }
  }

  public func earliestSample(keys: [WindowKey]? = nil) throws -> Date? {
    guard let keys else { return try database.query("SELECT MIN(ts) FROM samples") { $0.date(0) }.first! }
    guard !keys.isEmpty else { return nil }
    let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
    return try database.query(
      "SELECT MIN(ts) FROM samples WHERE key IN (\(placeholders))", keys.map { .text($0.storageKey) }
    ) { $0.date(0) }.first!
  }

  public func earliestAnalytics(metric: AnalyticsMetric, providers: [ProviderID]) throws -> Date? {
    guard !providers.isEmpty else { return nil }
    let placeholders = Array(repeating: "?", count: providers.count).joined(separator: ",")
    let parameters = [SQLiteValue.text(metric.rawValue)] + providers.map { .text($0.rawValue) }
    let day = try database.query(
      "SELECT MIN(day) FROM analytics WHERE metric = ? AND provider IN (\(placeholders))", parameters
    ) { row in row.text(0) }.first
    return day.flatMap(DayStamp.date)
  }

  public func stats() throws -> HistoryStats {
    let counts = try database.query("SELECT COUNT(*), MIN(ts), MAX(ts) FROM samples") {
      ($0.int(0), $0.date(1), $0.date(2))
    }.first!
    let analyticsCount = try database.query("SELECT COUNT(*) FROM analytics") { $0.int(0) }.first!
    return HistoryStats(sampleCount: counts.0, analyticsCount: analyticsCount, oldest: counts.1, newest: counts.2)
  }

  /// Writes the whole table to `url` a chunk at a time. Building it in memory first meant one string per row plus a
  /// joined copy of the lot, which over a full retention window is tens of megabytes.
  public func exportCSV(to url: URL) async throws {
    try await withTaskCancellationHandler {
      try writeCSV(
        to: url,
        header: "kind,timestamp,key,label,used_percent,resets_at,provider,day,metric,series,value\n"
      ) { write in
        try database.forEachRow("SELECT ts, key, label, used, resets_at FROM samples ORDER BY ts ASC, key ASC") { row in
          try write(
            [
              "sample", ISODate.string(row.date(0)!), row.text(1), row.text(2), String(format: "%.2f", row.double(3)!),
              row.date(4).map(ISODate.string) ?? "", "", "", "", "", "",
            ])
        }
        try database.forEachRow(
          "SELECT provider, day, metric, series, value FROM analytics "
            + "ORDER BY day ASC, provider ASC, metric ASC, series ASC"
        ) { row in
          try write(
            [
              "analytics", "", "", "", "", "", row.text(0), row.text(1), row.text(2), row.text(3),
              String(format: "%.4f", row.double(4)!),
            ])
        }
      }
    } onCancel: {
      database.interrupt()
    }
  }

  public func exportCSV(
    to url: URL, metric: HistoryMetric, from start: Date, to end: Date, keys: [WindowKey]? = nil,
    providers: [ProviderID]? = nil, includesEnd: Bool = true
  ) async throws {
    try await withTaskCancellationHandler {
      switch metric {
      case .windowUsagePercent:
        try exportSamplesCSV(to: url, from: start, to: end, keys: keys, includesEnd: includesEnd)
      case .analytics(let analyticsMetric):
        let exclusiveEnd = DayStamp.string(end.addingTimeInterval(Rollup.day.seconds))
        try exportAnalyticsCSV(
          to: url, metric: analyticsMetric, providers: providers ?? metric.suppliers, from: DayStamp.string(start),
          before: exclusiveEnd)
      }
    } onCancel: {
      database.interrupt()
    }
  }

  @discardableResult
  public func clear() throws -> Int {
    let removed = try database.withTransaction {
      try database.execute("DELETE FROM samples")
      let samples = database.changes
      try database.execute("DELETE FROM analytics")
      try database.execute("DELETE FROM analytics_accounts")
      return samples
    }
    lastRecorded.removeAll()
    return removed
  }

  public func setRetentionDays(_ days: Int) {
    let clamped = min(max(days, 7), 365)
    guard clamped != retentionDays else { return }
    retentionDays = clamped
    lastPrune = nil
  }

  @discardableResult
  public func setRetentionDays(_ days: Int, now: Date) async throws -> HistoryPruneResult {
    try await withTaskCancellationHandler {
      try applyRetentionDays(days, now: now)
    } onCancel: {
      database.interrupt()
    }
  }

  private func applyRetentionDays(_ days: Int, now: Date) throws -> HistoryPruneResult {
    let clamped = min(max(days, 7), 365)
    let cutoff = now.addingTimeInterval(-TimeInterval(clamped) * 86400)
    let analyticsCutoff = Self.analyticsCutoffDay(now: now, retentionDays: clamped)
    let result = try database.withTransaction {
      try database.execute("DELETE FROM samples WHERE ts < ?", [.real(cutoff.timeIntervalSince1970)])
      let samples = database.changes
      try database.execute("DELETE FROM analytics WHERE day < ?", [.text(analyticsCutoff)])
      return HistoryPruneResult(samples: samples, analytics: database.changes)
    }
    retentionDays = clamped
    lastRecorded = lastRecorded.filter { $0.value.timestamp >= cutoff }
    lastPrune = now
    return result
  }

  func pruneIfNeeded(now: Date) throws {
    if let lastPrune, now.timeIntervalSince(lastPrune) < 3600 { return }
    _ = try applyRetentionDays(retentionDays, now: now)
  }

  private func analyticsCutoffDay(now: Date) -> String {
    Self.analyticsCutoffDay(now: now, retentionDays: retentionDays)
  }

  private static func analyticsCutoffDay(now: Date, retentionDays: Int) -> String {
    DayStamp.string(now.addingTimeInterval(-TimeInterval(max(retentionDays - 1, 0)) * 86400))
  }

  private static func offsetSegments(
    from start: Date, to end: Date, timeZone: TimeZone, includesEnd: Bool
  ) -> [OffsetSegment] {
    var segments: [OffsetSegment] = []
    var cursor = start
    while let transition = timeZone.nextDaylightSavingTimeTransition(after: cursor), transition < end {
      segments.append(
        OffsetSegment(
          start: cursor, end: transition, includesEnd: false,
          offset: TimeInterval(timeZone.secondsFromGMT(for: cursor))))
      cursor = transition
    }
    segments.append(
      OffsetSegment(
        start: cursor, end: end, includesEnd: includesEnd,
        offset: TimeInterval(timeZone.secondsFromGMT(for: cursor))))
    return segments
  }

  private static func collapse(_ samples: [UsageSample], rollup: TimeInterval, timeZone: TimeZone) -> [UsageSample] {
    var latest: [SampleBucket: UsageSample] = [:]
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    for sample in samples {
      let start: Date
      if rollup == Rollup.minute.seconds {
        start = calendar.dateInterval(of: .minute, for: sample.timestamp)!.start
      } else if rollup == Rollup.hour.seconds {
        start = calendar.dateInterval(of: .hour, for: sample.timestamp)!.start
      } else if rollup == Rollup.day.seconds {
        start = calendar.startOfDay(for: sample.timestamp)
      } else {
        let offset = TimeInterval(timeZone.secondsFromGMT(for: sample.timestamp))
        let local = sample.timestamp.timeIntervalSince1970 + offset
        start = Date(timeIntervalSince1970: (local / rollup).rounded(.down) * rollup - offset)
      }
      let bucket = SampleBucket(key: sample.key, start: start)
      if let existing = latest[bucket], existing.timestamp > sample.timestamp { continue }
      latest[bucket] = sample
    }
    return latest.values.sorted { ($0.timestamp, $0.key.storageKey) < ($1.timestamp, $1.key.storageKey) }
  }

  private func exportSamplesCSV(
    to url: URL, from start: Date, to end: Date, keys: [WindowKey]?, includesEnd: Bool
  ) throws {
    var sql = "SELECT ts, key, label, used, resets_at FROM samples WHERE ts >= ? AND ts \(includesEnd ? "<=" : "<") ?"
    var parameters: [SQLiteValue] = [.real(start.timeIntervalSince1970), .real(end.timeIntervalSince1970)]
    if let keys {
      if keys.isEmpty {
        try writeCSV(to: url, header: "timestamp,key,label,used_percent,resets_at\n") { _ in }
        return
      }
      sql += " AND key IN (\(Array(repeating: "?", count: keys.count).joined(separator: ",")))"
      parameters += keys.map { .text($0.storageKey) }
    }
    sql += " ORDER BY ts ASC"
    try writeCSV(to: url, header: "timestamp,key,label,used_percent,resets_at\n") { write in
      try database.forEachRow(sql, parameters) { row in
        try write(
          [
            ISODate.string(row.date(0)!), row.text(1), row.text(2), String(format: "%.2f", row.double(3)!),
            row.date(4).map(ISODate.string) ?? "",
          ])
      }
    }
  }

  private func exportAnalyticsCSV(
    to url: URL, metric: AnalyticsMetric, providers: [ProviderID], from start: String, before end: String
  ) throws {
    let placeholders = Array(repeating: "?", count: providers.count).joined(separator: ",")
    let parameters: [SQLiteValue] =
      [.text(metric.rawValue), .text(start), .text(end)] + providers.map { .text($0.rawValue) }
    try writeCSV(to: url, header: "provider,day,metric,series,value\n") { write in
      try database.forEachRow(
        "SELECT provider, day, metric, series, value FROM analytics WHERE metric = ? AND day >= ? AND day < ? "
          + "AND provider IN (\(placeholders)) ORDER BY day ASC, provider ASC, series ASC",
        parameters
      ) { row in
        try write(
          [
            row.text(0), row.text(1), row.text(2), row.text(3), String(format: "%.4f", row.double(4)!),
          ])
      }
    }
  }

  private func writeCSV(
    to url: URL, header: String, rows: (_ write: ([String]) throws -> Void) throws -> Void
  ) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var buffer = header
    try rows { fields in
      buffer += fields.map(Self.csvField).joined(separator: ",") + "\n"
      if buffer.utf8.count >= 256 * 1024 {
        try handle.write(contentsOf: Data(buffer.utf8))
        buffer = ""
      }
    }
    try handle.write(contentsOf: Data(buffer.utf8))
  }

  private static func csvField(_ field: String) -> String {
    guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
    return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
  }
}
