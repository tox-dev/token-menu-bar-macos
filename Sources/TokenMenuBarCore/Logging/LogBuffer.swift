import Foundation
import OSLog

public enum LogLevel: String, CaseIterable, Codable, Sendable, Comparable {
  case debug
  case info
  case warning
  case error

  public var title: String {
    switch self {
    case .debug: "Debug"
    case .info: "Info"
    case .warning: "Warn"
    case .error: "Error"
    }
  }

  public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
    lhs.order < rhs.order
  }

  private var order: Int {
    switch self {
    case .debug: 0
    case .info: 1
    case .warning: 2
    case .error: 3
    }
  }
}

public struct LogEntry: Sendable, Hashable, Identifiable {
  public static let maximumLineBytes = 2_048

  public let timestamp: Date
  public let level: LogLevel
  public let category: LogCategory
  public let message: String
  public let line: String
  public let sequenceID: UInt64

  public init(timestamp: Date, level: LogLevel, category: LogCategory = .app, message: String) {
    let safe = LogSanitizer.message(message)
    self.init(
      timestamp: timestamp,
      level: level,
      category: category,
      message: safe,
      line: Self.render(timestamp: timestamp, level: level, category: category, message: safe),
      sequenceID: LogSequence.next())
  }

  public var id: UInt64 { sequenceID }

  static func parse(_ text: String, after previous: Date) -> LogEntry {
    guard let timestamp = storedTimestamp(text) else {
      return LogEntry(timestamp: previous, level: .info, message: text)
    }
    let close = text.index(text.startIndex, offsetBy: 24)
    let afterTimestamp = text[text.index(after: close)...].drop { $0 == " " }
    guard afterTimestamp.hasPrefix("["), let levelClose = afterTimestamp.firstIndex(of: "]"),
      let level = LogLevel(
        rawValue: String(afterTimestamp[afterTimestamp.index(after: afterTimestamp.startIndex)..<levelClose]))
    else { return LogEntry(timestamp: timestamp, level: .info, message: String(afterTimestamp)) }
    let afterLevel = afterTimestamp[afterTimestamp.index(after: levelClose)...].drop { $0 == " " }
    guard afterLevel.hasPrefix("["), let categoryClose = afterLevel.firstIndex(of: "]"),
      let category = LogCategory(
        rawValue: String(afterLevel[afterLevel.index(after: afterLevel.startIndex)..<categoryClose]))
    else { return stored(timestamp: timestamp, level: level, category: .app, message: String(afterLevel), line: text) }
    let message = afterLevel[afterLevel.index(after: categoryClose)...].drop { $0 == " " }
    return stored(timestamp: timestamp, level: level, category: category, message: String(message), line: text)
  }

  private static func storedTimestamp(_ text: String) -> Date? {
    var text = text
    return text.withUTF8 { storedTimestamp($0) }
  }

  private static func storedTimestamp(_ bytes: UnsafeBufferPointer<UInt8>) -> Date? {
    guard bytes.count >= 25,
      bytes[0] == 0x5B, bytes[5] == 0x2D, bytes[8] == 0x2D, bytes[11] == 0x20,
      bytes[14] == 0x3A, bytes[17] == 0x3A, bytes[20] == 0x2E, bytes[24] == 0x5D
    else { return nil }

    func decimal(_ offset: Int, _ count: Int) -> Int? {
      var value = 0
      for index in offset..<(offset + count) {
        let byte = bytes[index]
        guard byte >= 0x30, byte <= 0x39 else { return nil }
        value = value * 10 + Int(byte - 0x30)
      }
      return value
    }

    guard let year = decimal(1, 4), let month = decimal(6, 2), let day = decimal(9, 2),
      let hour = decimal(12, 2), let minute = decimal(15, 2), let second = decimal(18, 2),
      let millisecond = decimal(21, 3),
      (1...9999).contains(year), (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute),
      (0...59).contains(second), day >= 1, day <= daysInMonth(month, year: year)
    else { return nil }

    let adjustedYear = year - (month <= 2 ? 1 : 0)
    let era = adjustedYear / 400
    let yearOfEra = adjustedYear - era * 400
    let adjustedMonth = month + (month > 2 ? -3 : 9)
    let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    let daysSinceEpoch = era * 146_097 + dayOfEra - 719_468
    let seconds = daysSinceEpoch * 86_400 + hour * 3_600 + minute * 60 + second
    return Date(timeIntervalSince1970: Double(seconds) + Double(millisecond) / 1_000)
  }

  private static func daysInMonth(_ month: Int, year: Int) -> Int {
    switch month {
    case 2: year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100)) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  private static func stored(
    timestamp: Date, level: LogLevel, category: LogCategory, message: String, line: String
  ) -> LogEntry {
    let safe = LogSanitizer.message(message)
    return LogEntry(
      timestamp: timestamp,
      level: level,
      category: category,
      message: safe,
      line: safe == message ? line : render(timestamp: timestamp, level: level, category: category, message: safe),
      sequenceID: LogSequence.next())
  }

  private static func render(timestamp: Date, level: LogLevel, category: LogCategory, message: String) -> String {
    let prefix = "[\(LogBuffer.timestampFormat.string(from: timestamp))] [\(level.rawValue)]"
    return category == .app ? "\(prefix) \(message)" : "\(prefix) [\(category.rawValue)] \(message)"
  }

  func assigningSequenceID(_ sequenceID: UInt64) -> LogEntry {
    LogEntry(
      timestamp: timestamp,
      level: level,
      category: category,
      message: message,
      line: line,
      sequenceID: sequenceID)
  }

  private init(
    timestamp: Date,
    level: LogLevel,
    category: LogCategory,
    message: String,
    line: String,
    sequenceID: UInt64
  ) {
    self.timestamp = timestamp
    self.level = level
    self.category = category
    self.message = message
    self.line = line
    self.sequenceID = sequenceID
  }
}

private enum LogSequence {
  static let lock = NSLock()
  nonisolated(unsafe) static var value: UInt64 = 0

  static func next() -> UInt64 {
    lock.withLock {
      value += 1
      return value
    }
  }
}

public final class LogSubscription: @unchecked Sendable {
  private let lock = NSLock()
  private var cancellation: (@Sendable () -> Void)?

  init(cancellation: @escaping @Sendable () -> Void) {
    self.cancellation = cancellation
  }

  public func cancel() {
    let action = lock.withLock {
      defer { cancellation = nil }
      return cancellation
    }
    action?()
  }

  deinit {
    cancel()
  }
}

public final class LogBuffer: @unchecked Sendable {
  public static let capacity = 500
  public static let retention: TimeInterval = 7 * 86_400
  public static let flushInterval: TimeInterval = 5
  public static let fileByteLimit = 1_048_576
  public static let retainedFileCount = 3
  public static let pendingCapacity = capacity * 2
  public static let retainedEntryLimit = 100_000

  private static let notificationInterval: TimeInterval = 0.05

  static let timestampFormat: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
  }()

  private let lock = NSLock()
  private let clock: Clock
  private let fileURL: URL?
  private let maximumFileBytes: Int
  private let maximumFileCount: Int
  private let ioQueue = DispatchQueue(label: "dev.tox.token-menu-bar.log-file", qos: .utility)
  private let notificationQueue = DispatchQueue(label: "dev.tox.token-menu-bar.log-observers", qos: .utility)
  private var entries: [LogEntry] = []
  private var unwritten: [LogEntry] = []
  private var observers: [UUID: @Sendable ([LogEntry]) -> Void] = [:]
  private var lastPrune: Date?
  private var flushScheduled = false
  private var notificationScheduled = false
  private var rewriteOnFlush = false
  private var _debugEnabled = false

  public init(
    fileURL: URL?,
    clock: Clock = .system,
    maximumFileBytes: Int = LogBuffer.fileByteLimit,
    maximumFileCount: Int = LogBuffer.retainedFileCount
  ) {
    self.fileURL = fileURL
    self.clock = clock
    self.maximumFileBytes = max(maximumFileBytes, 1)
    self.maximumFileCount = max(maximumFileCount, 1)
    guard let fileURL else { return }
    let now = clock.now()
    let stored = Self.load(
      fileURL: fileURL,
      count: self.maximumFileCount,
      after: now.addingTimeInterval(-Self.retention),
      maximumFileBytes: self.maximumFileBytes,
      maximumEntries: Self.retainedEntryLimit)
    entries = Array(stored.entries.suffix(Self.capacity))
    lastPrune = now
    guard stored.droppedEntries else { return }
    let loaded = stored.entries
    ioQueue.sync {
      do {
        try rewriteStorage(loaded)
      } catch {
        SystemLogSink.persistenceError(error)
        lock.withLock { rewriteOnFlush = true }
      }
    }
  }

  public var debugEnabled: Bool {
    get { lock.withLock { _debugEnabled } }
    set { lock.withLock { _debugEnabled = newValue } }
  }

  public var snapshot: [LogEntry] {
    lock.withLock { entries }
  }

  public var text: String {
    LogExport.text(entries: snapshot)
  }

  public func log(_ message: @autoclosure () -> String) {
    append(.info, category: .app, message())
  }

  public func logInfo(_ message: @autoclosure () -> String, category: LogCategory = .app) {
    append(.info, category: category, message())
  }

  public func logWarning(_ message: @autoclosure () -> String, category: LogCategory = .app) {
    append(.warning, category: category, message())
  }

  public func logError(_ message: @autoclosure () -> String, category: LogCategory = .app) {
    append(.error, category: category, message())
  }

  public func logDebug(_ message: @autoclosure () -> String, category: LogCategory = .app) {
    guard debugEnabled else { return }
    append(.debug, category: category, message())
  }

  public func detailed(_ event: @autoclosure () -> DiagnosticEvent) {
    guard debugEnabled else { return }
    record(event(), level: .debug)
  }

  public func record(_ event: DiagnosticEvent, level: LogLevel) {
    SystemLogSink.record(event, level: level)
    append(level, category: event.category, event.message, writeSystemLog: false)
  }

  public func tail(_ count: Int) -> [LogEntry] {
    lock.withLock { Array(entries.suffix(max(count, 0))) }
  }

  public func filtered(_ filter: LogFilter) -> [LogEntry] {
    filter.entries(from: snapshot)
  }

  public func export(filter: LogFilter = LogFilter(), header: LogExportHeader? = nil) -> String {
    LogExport.text(entries: filtered(filter), header: header)
  }

  public func subscribe(_ observer: @escaping @Sendable () -> Void) -> LogSubscription {
    let id = UUID()
    lock.withLock { observers[id] = { _ in observer() } }
    return LogSubscription { [weak self] in self?.removeObserver(id) }
  }

  public func snapshots() -> AsyncStream<[LogEntry]> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let id = UUID()
      let subscription = lock.withLock {
        observers[id] = { continuation.yield($0) }
        continuation.yield(entries)
        return LogSubscription { [weak self] in self?.removeObserver(id) }
      }
      continuation.onTermination = { _ in subscription.cancel() }
    }
  }

  public func retainedSnapshot() async -> [LogEntry] {
    guard let fileURL else { return snapshot }
    return await withCheckedContinuation { continuation in
      ioQueue.async { [self] in
        flushPending()
        let result = Self.load(
          fileURL: fileURL,
          count: maximumFileCount,
          after: clock.now().addingTimeInterval(-Self.retention),
          maximumFileBytes: maximumFileBytes,
          maximumEntries: Self.retainedEntryLimit)
        continuation.resume(returning: Self.align(result.entries, with: snapshot))
      }
    }
  }

  public func flush() {
    ioQueue.sync { flushPending() }
  }

  public func clear() {
    lock.withLock {
      entries.removeAll(keepingCapacity: true)
      unwritten.removeAll(keepingCapacity: true)
      flushScheduled = false
      rewriteOnFlush = false
    }
    let failure = ioQueue.sync {
      do {
        try clearStorage()
        return false
      } catch {
        SystemLogSink.persistenceError(error)
        return true
      }
    }
    if failure { requeue(.rewrite([])) }
    scheduleObserverNotification()
  }

  private func append(
    _ level: LogLevel, category: LogCategory, _ message: String, writeSystemLog: Bool = true
  ) {
    let result = lock.withLock {
      let now = clock.now()
      let entry = LogEntry(timestamp: now, level: level, category: category, message: message)
      entries.append(entry)
      if fileURL != nil {
        unwritten.append(entry)
        if unwritten.count > Self.pendingCapacity {
          unwritten.removeFirst(unwritten.count - Self.pendingCapacity)
          rewriteOnFlush = true
        }
      }
      if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
      rewriteOnFlush = prune(now: now) || rewriteOnFlush
      guard fileURL != nil, !flushScheduled else { return (false, entry.message) }
      flushScheduled = true
      return (true, entry.message)
    }
    if writeSystemLog { SystemLogSink.record(result.1, level: level, category: category) }
    if result.0 {
      ioQueue.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in self?.flushPending() }
    }
    scheduleObserverNotification()
  }

  private func prune(now: Date) -> Bool {
    guard lastPrune.map({ now.timeIntervalSince($0) >= 3_600 }) ?? true else { return false }
    let count = entries.count
    entries.removeAll { $0.timestamp < now.addingTimeInterval(-Self.retention) }
    lastPrune = now
    return entries.count != count
  }

  private func flushPending() {
    let work: FlushWork? = lock.withLock {
      flushScheduled = false
      if rewriteOnFlush {
        rewriteOnFlush = false
        unwritten.removeAll(keepingCapacity: true)
        return FlushWork.rewrite(entries)
      }
      guard !unwritten.isEmpty else { return nil }
      defer { unwritten.removeAll(keepingCapacity: true) }
      return FlushWork.append(unwritten)
    }
    guard let work else { return }
    do {
      switch work {
      case .append(let pending): try appendToStorage(pending)
      case .rewrite(let replacement): try rewriteStorage(replacement)
      }
    } catch {
      SystemLogSink.persistenceError(error)
      requeue(work)
    }
  }

  private func requeue(_ work: FlushWork) {
    let shouldRetry = lock.withLock {
      switch work {
      case .append(let pending):
        unwritten.insert(contentsOf: pending, at: 0)
        if unwritten.count > Self.pendingCapacity {
          unwritten.removeFirst(unwritten.count - Self.pendingCapacity)
          rewriteOnFlush = true
        }
      case .rewrite:
        rewriteOnFlush = true
      }
      guard fileURL != nil, !flushScheduled else { return false }
      flushScheduled = true
      return true
    }
    guard shouldRetry else { return }
    ioQueue.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in self?.flushPending() }
  }

  private func scheduleObserverNotification() {
    let shouldNotify = lock.withLock {
      guard !observers.isEmpty, !notificationScheduled else { return false }
      notificationScheduled = true
      return true
    }
    guard shouldNotify else { return }
    notificationQueue.asyncAfter(deadline: .now() + Self.notificationInterval) { [weak self] in
      self?.notifyObservers()
    }
  }

  private func notifyObservers() {
    let (callbacks, snapshot) = lock.withLock {
      notificationScheduled = false
      return (Array(observers.values), entries)
    }
    for callback in callbacks { callback(snapshot) }
  }

  private func removeObserver(_ id: UUID) {
    _ = lock.withLock { observers.removeValue(forKey: id) }
  }

  private func appendToStorage(_ pending: [LogEntry]) throws {
    guard let fileURL, !pending.isEmpty else { return }
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var size = Self.fileSize(fileURL)
    var handle = try Self.open(fileURL)
    defer { try? handle.close() }
    for entry in pending {
      let data = Self.fileData(entry, maximumBytes: maximumFileBytes)
      if size > 0, size + data.count > maximumFileBytes {
        try handle.close()
        try rotateStorage(fileURL)
        handle = try Self.open(fileURL)
        size = 0
      }
      try handle.write(contentsOf: data)
      size += data.count
    }
  }

  private func rewriteStorage(_ replacement: [LogEntry]) throws {
    try clearStorage()
    try appendToStorage(replacement)
  }

  private func rotateStorage(_ fileURL: URL) throws {
    if maximumFileCount == 1 {
      if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
      return
    }
    for index in stride(from: maximumFileCount - 1, through: 1, by: -1) {
      let source = index == 1 ? fileURL : Self.archive(fileURL, index: index - 1)
      let destination = Self.archive(fileURL, index: index)
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      if FileManager.default.fileExists(atPath: source.path) {
        try FileManager.default.moveItem(at: source, to: destination)
      }
    }
  }

  private func clearStorage() throws {
    guard let fileURL else { return }
    for index in 0..<maximumFileCount {
      let url = index == 0 ? fileURL : Self.archive(fileURL, index: index)
      if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
  }

  private static func load(
    fileURL: URL,
    count: Int,
    after cutoff: Date,
    maximumFileBytes: Int,
    maximumEntries: Int
  ) -> LoadResult {
    var previous = cutoff
    var loaded: [LogEntry] = []
    var droppedEntries = false
    var text = ""
    let urls = stride(from: count - 1, through: 0, by: -1).map {
      $0 == 0 ? fileURL : archive(fileURL, index: $0)
    }
    for url in urls {
      guard let contents = try? boundedContents(of: url, maximumBytes: maximumFileBytes) else { continue }
      droppedEntries = contents.truncated || droppedEntries
      text += contents.text + "\n"
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    droppedEntries = lines.count > maximumEntries || droppedEntries
    for line in lines.suffix(maximumEntries) {
      let entry = LogEntry.parse(String(line), after: previous)
      previous = entry.timestamp
      if entry.timestamp >= cutoff {
        loaded.append(entry)
      } else {
        droppedEntries = true
      }
    }
    return LoadResult(entries: loaded, droppedEntries: droppedEntries)
  }

  private static func align(_ retained: [LogEntry], with live: [LogEntry]) -> [LogEntry] {
    guard !retained.isEmpty, !live.isEmpty else { return retained }
    var aligned = retained
    var retainedIndex = retained.index(before: retained.endIndex)
    var liveIndex = live.index(before: live.endIndex)
    while retained[retainedIndex].line == live[liveIndex].line {
      aligned[retainedIndex] = retained[retainedIndex].assigningSequenceID(live[liveIndex].sequenceID)
      guard retainedIndex != retained.startIndex, liveIndex != live.startIndex else { break }
      retained.formIndex(before: &retainedIndex)
      live.formIndex(before: &liveIndex)
    }
    return aligned
  }

  private static func boundedContents(of url: URL, maximumBytes: Int) throws -> BoundedContents {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    let limit = UInt64(max(maximumBytes, 1))
    let offset = size > limit ? size - limit : 0
    try handle.seek(toOffset: offset)
    let data = handle.readData(ofLength: Int(size - offset))
    var text = String(decoding: data, as: UTF8.self)
    if offset > 0 {
      guard let newline = text.firstIndex(of: "\n") else { return BoundedContents(text: "", truncated: true) }
      text.removeSubrange(...newline)
    }
    return BoundedContents(text: text, truncated: offset > 0)
  }

  private static func fileData(_ entry: LogEntry, maximumBytes: Int) -> Data {
    let data = Data((entry.line + "\n").utf8)
    guard data.count > maximumBytes else { return data }
    guard maximumBytes > 1 else { return Data("\n".utf8.prefix(maximumBytes)) }
    var bytes = Array(entry.line.utf8.prefix(maximumBytes - 1))
    while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
    bytes.append(0x0A)
    return Data(bytes)
  }

  private static func open(_ url: URL) throws -> FileHandle {
    if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .atomic) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let handle = try FileHandle(forWritingTo: url)
    _ = try handle.seekToEnd()
    return handle
  }

  private static func fileSize(_ url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.intValue ?? 0
  }

  private static func archive(_ url: URL, index: Int) -> URL {
    URL(fileURLWithPath: "\(url.path).\(index)")
  }

  private enum FlushWork {
    case append([LogEntry])
    case rewrite([LogEntry])
  }

  private struct LoadResult {
    let entries: [LogEntry]
    let droppedEntries: Bool
  }

  private struct BoundedContents {
    let text: String
    let truncated: Bool
  }
}

private enum SystemLogSink {
  static func record(_ message: String, level: LogLevel, category: LogCategory) {
    logger(category).log(level: level.osLogType, "\(message, privacy: .private(mask: .hash))")
  }

  static func record(_ event: DiagnosticEvent, level: LogLevel) {
    let logger = logger(event.category)
    switch event {
    case .panel(let value):
      let anchor = value.anchor?.description ?? "-"
      let screen = value.screenID ?? "-"
      let screenFrame = value.screenFrame?.description ?? "-"
      let result = value.resultFrame?.description ?? "-"
      let frontmost = value.frontmostBundleID ?? "-"
      logger.log(
        level: level.osLogType,
        """
        panel action=\(value.action.rawValue, privacy: .public) \
        trigger=\(value.trigger, privacy: .public) tab=\(value.tab, privacy: .public) \
        anchor=\(anchor, privacy: .public) screen=\(screen, privacy: .public) \
        screenFrame=\(screenFrame, privacy: .public) max=\(value.maximum.description, privacy: .public) \
        proposed=\(value.proposed.description, privacy: .public) \
        clamped=\(value.clamped.description, privacy: .public) result=\(result, privacy: .public) \
        appActive=\(value.appActive, privacy: .public) \
        frontmost=\(frontmost, privacy: .private(mask: .hash))
        """
      )
    case .tab(let value):
      let from = value.from ?? "-"
      let to = value.to ?? "-"
      let source = value.sourceTab ?? "-"
      let filedUnder = value.filedUnderTab ?? "-"
      let size = value.size?.description ?? "-"
      logger.log(
        level: level.osLogType,
        """
        tab action=\(value.action.rawValue, privacy: .public) from=\(from, privacy: .public) \
        to=\(to, privacy: .public) source=\(source, privacy: .public) \
        active=\(value.activeTab, privacy: .public) filedUnder=\(filedUnder, privacy: .public) \
        size=\(size, privacy: .public)
        """
      )
    case .status(let value):
      let frame = value.buttonFrame?.description ?? "-"
      let oldTier = value.oldTier ?? -1
      let newTier = value.newTier ?? -1
      let context = value.layoutContext ?? "-"
      logger.log(
        level: level.osLogType,
        """
        status action=\(value.action.rawValue, privacy: .public) \
        trigger=\(value.trigger, privacy: .public) frame=\(frame, privacy: .public) \
        oldTier=\(oldTier, privacy: .public) newTier=\(newTier, privacy: .public) \
        visible=\(value.visible, privacy: .public) popoverVisible=\(value.popoverVisible, privacy: .public) \
        context=\(context, privacy: .private(mask: .hash))
        """
      )
    case .refresh(let value):
      let skipReason = value.skipReason?.rawValue ?? "-"
      logger.log(
        level: level.osLogType,
        """
        refresh cycle=\(value.cycleID, privacy: .public) trigger=\(value.trigger, privacy: .public) \
        provider=\(value.provider.rawValue, privacy: .public) \
        usagePolicy=\(value.usagePolicy, privacy: .public) \
        analyticsPolicy=\(value.analyticsPolicy, privacy: .public) \
        outcome=\(value.outcome.rawValue, privacy: .public) skipReason=\(skipReason, privacy: .public) \
        durationMs=\(value.durationMilliseconds, privacy: .public) \
        includeAnalytics=\(value.includeAnalytics, privacy: .public) \
        analyticsReturned=\(value.analyticsReturned, privacy: .public) \
        analyticsPoints=\(value.analyticsPointCount, privacy: .public) \
        warnings=\(value.warnings.count, privacy: .public)
        """
      )
    case .request(let value):
      let status = value.status ?? 0
      let domain = value.errorDomain ?? "-"
      let code = value.errorCode ?? 0
      logger.log(
        level: level.osLogType,
        """
        request id=\(value.requestID, privacy: .public) operation=\(value.operation, privacy: .public) \
        method=\(value.method, privacy: .public) status=\(status, privacy: .public) \
        bytes=\(value.byteCount, privacy: .public) \
        durationMs=\(value.durationMilliseconds, privacy: .public) \
        errorDomain=\(domain, privacy: .public) errorCode=\(code, privacy: .public)
        """
      )
    }
  }

  static func persistenceError(_ error: any Error) {
    let value = error as NSError
    persistence.error(
      "log file operation failed domain=\(value.domain, privacy: .public) code=\(value.code, privacy: .public)")
  }

  private static func logger(_ category: LogCategory) -> Logger {
    switch category {
    case .app: app
    case .geometry: geometry
    case .network: network
    case .persistence: persistence
    case .refresh: refresh
    case .status: status
    case .tabs: tabs
    }
  }

  private static let app = Logger(subsystem: SystemLog.subsystem, category: LogCategory.app.rawValue)
  private static let geometry = Logger(subsystem: SystemLog.subsystem, category: LogCategory.geometry.rawValue)
  private static let network = Logger(subsystem: SystemLog.subsystem, category: LogCategory.network.rawValue)
  private static let persistence = Logger(subsystem: SystemLog.subsystem, category: LogCategory.persistence.rawValue)
  private static let refresh = Logger(subsystem: SystemLog.subsystem, category: LogCategory.refresh.rawValue)
  private static let status = Logger(subsystem: SystemLog.subsystem, category: LogCategory.status.rawValue)
  private static let tabs = Logger(subsystem: SystemLog.subsystem, category: LogCategory.tabs.rawValue)
}

extension LogLevel {
  fileprivate var osLogType: OSLogType {
    switch self {
    case .debug: .debug
    case .info: .info
    case .warning: .default
    case .error: .error
    }
  }
}
