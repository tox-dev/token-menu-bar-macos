import Foundation

public struct ModelPrice: Sendable, Equatable {
  public let input: Double
  public let output: Double
  public let cacheWrite: Double
  public let cacheRead: Double

  public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
    self.input = input
    self.output = output
    self.cacheWrite = cacheWrite
    self.cacheRead = cacheRead
  }
}

public enum ClaudePricing {
  public static let perMillion: [String: ModelPrice] = [
    "opus": ModelPrice(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5),
    "sonnet": ModelPrice(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3),
    "haiku": ModelPrice(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1),
    "fable": ModelPrice(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5),
    "mythos": ModelPrice(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5),
  ]

  public static func price(for model: String) -> ModelPrice? {
    let lowered = model.lowercased()
    return perMillion.first { lowered.contains($0.key) }?.value
  }

  public static func cost(_ usage: TokenUsage, model: String) -> Double {
    guard let price = price(for: model) else { return 0 }
    return
      (Double(usage.input) * price.input + Double(usage.output) * price.output + Double(usage.cacheWrite)
      * price.cacheWrite
      + Double(usage.cacheRead) * price.cacheRead) / 1_000_000
  }
}

public struct TokenUsage: Sendable, Equatable, Hashable, Codable {
  public var input: Int
  public var output: Int
  public var cacheWrite: Int
  public var cacheRead: Int

  public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
    self.input = input
    self.output = output
    self.cacheWrite = cacheWrite
    self.cacheRead = cacheRead
  }

  public var total: Int {
    input + output + cacheWrite + cacheRead
  }

  public static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
    lhs.input += rhs.input
    lhs.output += rhs.output
    lhs.cacheWrite += rhs.cacheWrite
    lhs.cacheRead += rhs.cacheRead
  }
}

public struct TranscriptMessage: Sendable, Equatable, Hashable {
  public let id: String
  public let timestamp: Date
  public let session: String
  public let model: String
  public let usage: TokenUsage
  public let toolCalls: Int

  public init(id: String, timestamp: Date, session: String, model: String, usage: TokenUsage, toolCalls: Int) {
    self.id = id
    self.timestamp = timestamp
    self.session = session
    self.model = model
    self.usage = usage
    self.toolCalls = toolCalls
  }

  public var cost: Double {
    ClaudePricing.cost(usage, model: model)
  }
}

public struct LocalUsage: Sendable, Equatable, Hashable, Codable {
  public let windowTokens: Int
  public let windowCost: Double
  public let costPerHour: Double
  public let todayTokens: Int
  public let todayCost: Double
  public let todayMessages: Int

  public init(
    windowTokens: Int, windowCost: Double, costPerHour: Double, todayTokens: Int, todayCost: Double, todayMessages: Int
  ) {
    self.windowTokens = windowTokens
    self.windowCost = windowCost
    self.costPerHour = costPerHour
    self.todayTokens = todayTokens
    self.todayCost = todayCost
    self.todayMessages = todayMessages
  }
}

public struct ClaudeTranscriptSnapshot: Sendable {
  fileprivate let days: [String: DayAggregate]
  fileprivate let recent: [String: RecentAggregate]

  fileprivate init(state: ClaudeTranscriptState) {
    days = state.days
    recent = state.recent
  }

  public var messageCount: Int {
    days.values.reduce(0) { $0 + $1.messages }
  }

  public func analytics(now: Date) -> ProviderAnalytics? {
    guard messageCount > 0 else { return nil }
    var points: [AnalyticsPoint] = []
    for (day, aggregate) in days {
      for (model, usage) in aggregate.models {
        points.append(AnalyticsPoint(day: day, metric: .inputTokens, series: model, value: Double(usage.input)))
        points.append(AnalyticsPoint(day: day, metric: .outputTokens, series: model, value: Double(usage.output)))
        points.append(
          AnalyticsPoint(day: day, metric: .cachedInputTokens, series: model, value: Double(usage.cacheRead)))
        points.append(
          AnalyticsPoint(day: day, metric: .cacheWriteTokens, series: model, value: Double(usage.cacheWrite)))
        points.append(
          AnalyticsPoint(day: day, metric: .costUSD, series: model, value: ClaudePricing.cost(usage, model: model)))
      }
      points.append(AnalyticsPoint(day: day, metric: .messages, series: "messages", value: Double(aggregate.messages)))
      points.append(
        AnalyticsPoint(day: day, metric: .sessions, series: "sessions", value: Double(aggregate.sessions.count)))
      points.append(
        AnalyticsPoint(day: day, metric: .toolCalls, series: "tool calls", value: Double(aggregate.toolCalls)))
    }
    return ProviderAnalytics(
      provider: .claude,
      points: points.sorted { ($0.day, $0.metric.rawValue, $0.series) < ($1.day, $1.metric.rawValue, $1.series) },
      fetchedAt: now)
  }

  public func localUsage(
    windowResetsAt: Date?, windowDuration: TimeInterval, now: Date, calendar: Calendar = .current
  ) -> LocalUsage? {
    guard messageCount > 0 else { return nil }
    let windowStart = (windowResetsAt ?? now).addingTimeInterval(-windowDuration)
    let todayStart = calendar.startOfDay(for: now)
    var windowTokens = 0
    var windowCost = 0.0
    var windowFirst: Date?
    var todayTokens = 0
    var todayCost = 0.0
    var todayMessages = 0
    for aggregate in recent.values {
      let first = aggregate.firstTimestamp!
      let last = aggregate.lastTimestamp!
      if first >= windowStart, last <= now {
        windowTokens += aggregate.tokens
        windowCost += aggregate.cost
        windowFirst = min(windowFirst ?? first, first)
      } else if last >= windowStart, first <= now {
        for event in aggregate.events!
        where event.timestamp >= windowStart && event.timestamp <= now {
          windowTokens += event.tokens
          windowCost += event.cost
          windowFirst = min(windowFirst ?? event.timestamp, event.timestamp)
        }
      }
      if first >= todayStart, last <= now {
        todayTokens += aggregate.tokens
        todayCost += aggregate.cost
        todayMessages += aggregate.messages
      } else if last >= todayStart, first <= now {
        for event in aggregate.events!
        where event.timestamp >= todayStart && event.timestamp <= now {
          todayTokens += event.tokens
          todayCost += event.cost
          todayMessages += event.messages
        }
      }
    }
    let elapsedHours = max(now.timeIntervalSince(windowFirst ?? now) / 3600, 1.0 / 60)
    return LocalUsage(
      windowTokens: windowTokens,
      windowCost: windowCost,
      costPerHour: windowFirst == nil ? 0 : windowCost / elapsedHours,
      todayTokens: todayTokens,
      todayCost: todayCost,
      todayMessages: todayMessages)
  }
}

fileprivate struct ClaudeTranscriptState: Codable, Sendable {
  var offsets: [String: TranscriptOffset] = [:]
  var seenByDay: [String: Set<String>] = [:]
  var days: [String: DayAggregate] = [:]
  var recent: [String: RecentAggregate] = [:]

  @discardableResult
  mutating func ingest(_ message: TranscriptMessage) -> Bool {
    let day = DayStamp.string(message.timestamp)
    guard seenByDay[day, default: []].insert(message.id).inserted else { return false }
    var aggregate = days[day] ?? DayAggregate()
    aggregate.models[message.model, default: TokenUsage()] += message.usage
    aggregate.messages += 1
    aggregate.sessions.insert(message.session)
    aggregate.toolCalls += message.toolCalls
    days[day] = aggregate
    let minute = floor(message.timestamp.timeIntervalSince1970 / 60) * 60
    let key = String(Int64(minute))
    recent[key, default: RecentAggregate(timestamp: Date(timeIntervalSince1970: minute))].append(
      RecentEvent(timestamp: message.timestamp, tokens: message.usage.total, cost: message.cost, messages: 1))
    return true
  }

  mutating func prune(now: Date, retentionDays: Int) -> Bool {
    let retainedDay = DayStamp.string(now.addingTimeInterval(-Double(retentionDays) * 86400))
    let recentCutoff = now.addingTimeInterval(-26 * 3600)
    let oldDays = days.count
    let oldRecent = recent.count
    days = days.filter { $0.key >= retainedDay }
    seenByDay = seenByDay.filter { $0.key >= retainedDay }
    var compacted: [String: RecentAggregate] = [:]
    for aggregate in recent.values where (aggregate.lastTimestamp ?? aggregate.timestamp) >= recentCutoff {
      let minute = floor(aggregate.timestamp.timeIntervalSince1970 / 60) * 60
      let key = String(Int64(minute))
      compacted[key, default: RecentAggregate(timestamp: Date(timeIntervalSince1970: minute))].merge(aggregate)
    }
    let recentChanged = compacted != recent
    recent = compacted
    return days.count != oldDays || recent.count != oldRecent || recentChanged
  }
}

fileprivate struct TranscriptOffset: Codable, Sendable {
  var bytes: Int
  var scanGeneration: UInt64

  init(bytes: Int, scanGeneration: UInt64) {
    self.bytes = bytes
    self.scanGeneration = scanGeneration
  }

  init(from decoder: any Decoder) throws {
    if let legacy = try? decoder.singleValueContainer().decode(Int.self) {
      self.init(bytes: legacy, scanGeneration: 0)
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      bytes: try container.decode(Int.self, forKey: .bytes),
      scanGeneration: try container.decode(UInt64.self, forKey: .scanGeneration))
  }
}

fileprivate struct DayAggregate: Codable, Sendable {
  var models: [String: TokenUsage] = [:]
  var messages = 0
  var sessions: Set<String> = []
  var toolCalls = 0
}

fileprivate struct RecentAggregate: Codable, Sendable, Equatable {
  let timestamp: Date
  var tokens = 0
  var cost = 0.0
  var messages = 0
  var firstTimestamp: Date?
  var lastTimestamp: Date?
  var events: [RecentEvent]?

  mutating func append(_ event: RecentEvent) {
    tokens += event.tokens
    cost += event.cost
    messages += event.messages
    firstTimestamp = min(firstTimestamp ?? event.timestamp, event.timestamp)
    lastTimestamp = max(lastTimestamp ?? event.timestamp, event.timestamp)
    if events == nil { events = [] }
    events?.append(event)
  }

  mutating func merge(_ aggregate: RecentAggregate) {
    tokens += aggregate.tokens
    cost += aggregate.cost
    messages += aggregate.messages
    let first = aggregate.firstTimestamp ?? aggregate.timestamp
    let last = aggregate.lastTimestamp ?? aggregate.timestamp
    firstTimestamp = min(firstTimestamp ?? first, first)
    lastTimestamp = max(lastTimestamp ?? last, last)
    if events == nil { events = [] }
    events?.append(contentsOf: aggregate.events ?? [aggregate.legacyEvent])
  }

  var legacyEvent: RecentEvent {
    RecentEvent(timestamp: timestamp, tokens: tokens, cost: cost, messages: messages)
  }
}

fileprivate struct RecentEvent: Codable, Sendable, Equatable {
  let timestamp: Date
  let tokens: Int
  let cost: Double
  let messages: Int
}

private struct TranscriptFile: Sendable, Equatable {
  let url: URL
  let size: Int
  let modified: Date
}

private struct TranscriptIngestResult {
  let changed: Bool
  let bytesRead: Int
  let succeeded: Bool
  let complete: Bool

  static let unchanged = TranscriptIngestResult(changed: false, bytesRead: 0, succeeded: true, complete: true)
  static let failed = TranscriptIngestResult(changed: false, bytesRead: 0, succeeded: false, complete: true)
}

private struct PartialTranscriptRead {
  var committedOffset: Int
  var cursor: Int
  var pending = Data()
  var oversized = false
}

private struct TranscriptScan {
  let enumerator: FileManager.DirectoryEnumerator
  let cutoff: Date
  let referenceNow: Date
  let generation: UInt64
  var hotFiles: [TranscriptFile] = []
  var currentFile: TranscriptFile?
}

public struct ClaudeTranscriptWorkload: Sendable, Equatable {
  public fileprivate(set) var scansStarted = 0
  public fileprivate(set) var scansCompleted = 0
  public fileprivate(set) var treeEntriesExamined = 0
  public fileprivate(set) var statChecks = 0
  public fileprivate(set) var filesOpened = 0
  public fileprivate(set) var bytesRead = 0
  public fileprivate(set) var largestSliceBytesRead = 0
  public fileprivate(set) var largestSliceEntriesExamined = 0
  public fileprivate(set) var checkpointAttempts = 0
  public fileprivate(set) var checkpoints = 0
  public fileprivate(set) var checkpointBytesWritten = 0
  public fileprivate(set) var lastCheckpointBytes = 0
  public fileprivate(set) var retainedPartialFiles = 0
  public fileprivate(set) var retainedPartialBytes = 0
  public fileprivate(set) var largestRetainedPartialBytes = 0

  public init() {}
}

public actor ClaudeTranscriptReader {
  public static let defaultFileScanInterval: TimeInterval = 5 * 60
  public static let defaultCheckpointInterval: TimeInterval = 5 * 60
  public static let defaultMaximumCheckpointBytes = 1024 * 1024
  public static let defaultWorkByteBudget = 8 * 1024 * 1024
  public static let defaultWorkEntryBudget = 256
  public static let defaultWorkTimeBudget: TimeInterval = 0.05
  public static let defaultBackgroundWorkDelay: TimeInterval = 0.01
  public static let defaultMaximumLineBytes = 16 * 1024 * 1024
  public static let defaultMaximumRetainedPartialBytes = 16 * 1024 * 1024
  static let maxIndexedFiles = 64
  static let readChunkSize = 256 * 1024

  private let root: URL
  private let stateURL: URL?
  private let fileScanInterval: TimeInterval
  private let checkpointInterval: TimeInterval
  private let maximumCheckpointBytes: Int
  private let workByteBudget: Int
  private let workEntryBudget: Int
  private let workTimeBudget: TimeInterval
  private let backgroundWorkDelay: TimeInterval
  private let maximumLineBytes: Int
  private let maximumRetainedPartialBytes: Int
  private let readChunk: @Sendable (FileHandle, Int) throws -> Data?
  private var state = ClaudeTranscriptState()
  private var indexedFiles: [String: TranscriptFile] = [:]
  private var partialReads: [String: PartialTranscriptRead] = [:]
  private var pendingTails: [TranscriptFile] = []
  private var pendingTailIndex = 0
  private var scan: TranscriptScan?
  private var backgroundTask: Task<Void, Never>?
  private var stateLoadTask: Task<ClaudeTranscriptState?, Never>?
  private var nextFileScanAt = Date.distantPast
  private var nextCheckpointAt = Date.distantFuture
  private var nextPruneAt = Date.distantPast
  private var workReferenceNow = Date.distantPast
  private var workCutoff = Date.distantPast
  private var uncheckpointedBytes = 0
  private var stateRevision = 0
  private var checkpointInFlightRevision: Int?
  private var checkpointRetryAt: Date?
  private var stateDirty = false
  private var stateLoaded = false
  private var hasScanned = false
  private var scanGeneration: UInt64 = 0
  private var activeRetentionDays = UsageHistoryStore.defaultRetentionDays
  public private(set) var workload = ClaudeTranscriptWorkload()

  /// - Parameter stateURL: where to keep how far each session file has been read. Without it the first refresh
  ///   after every launch re-reads every session Claude Code wrote in the retention window, which for a heavy user
  ///   is hundreds of megabytes.
  public init(
    root: URL,
    stateURL: URL? = nil,
    fileScanInterval: TimeInterval = defaultFileScanInterval,
    checkpointInterval: TimeInterval = defaultCheckpointInterval,
    maximumCheckpointBytes: Int = defaultMaximumCheckpointBytes,
    workByteBudget: Int = defaultWorkByteBudget,
    workEntryBudget: Int = defaultWorkEntryBudget,
    workTimeBudget: TimeInterval = defaultWorkTimeBudget,
    backgroundWorkDelay: TimeInterval = defaultBackgroundWorkDelay,
    maximumLineBytes: Int = defaultMaximumLineBytes,
    maximumRetainedPartialBytes: Int = defaultMaximumRetainedPartialBytes,
    readChunk: @escaping @Sendable (FileHandle, Int) throws -> Data? = { handle, count in
      try handle.read(upToCount: count)
    }
  ) {
    self.root = root
    self.stateURL = stateURL
    self.fileScanInterval = fileScanInterval
    self.checkpointInterval = checkpointInterval
    self.maximumCheckpointBytes = max(maximumCheckpointBytes, 1)
    self.workByteBudget = max(workByteBudget, 1)
    self.workEntryBudget = max(workEntryBudget, 1)
    self.workTimeBudget = max(workTimeBudget, 0.001)
    self.backgroundWorkDelay = max(backgroundWorkDelay, 0.001)
    self.maximumLineBytes = max(maximumLineBytes, 1)
    self.maximumRetainedPartialBytes = max(maximumRetainedPartialBytes, self.maximumLineBytes)
    self.readChunk = readChunk
  }

  deinit { backgroundTask?.cancel() }

  public func cancelBackgroundWork() {
    backgroundTask?.cancel()
    backgroundTask = nil
    scan = nil
    hasScanned = false
    pendingTails.removeAll(keepingCapacity: true)
    pendingTailIndex = 0
    partialReads.removeAll(keepingCapacity: true)
    recordPartialWorkload()
  }

  private static let usageMarker = Array("\"usage\"".utf8)

  public func refresh(
    now: Date, retentionDays: Int = UsageHistoryStore.defaultRetentionDays
  ) async -> ClaudeTranscriptSnapshot {
    await loadState()
    let retentionDays = min(max(retentionDays, 7), 365)
    if retentionDays != activeRetentionDays {
      if retentionDays > activeRetentionDays {
        state.offsets = state.offsets.mapValues {
          TranscriptOffset(bytes: 0, scanGeneration: $0.scanGeneration)
        }
        markDirty()
      }
      activeRetentionDays = retentionDays
      scan = nil
      hasScanned = false
      pendingTails.removeAll(keepingCapacity: true)
      pendingTailIndex = 0
      nextFileScanAt = .distantPast
      nextPruneAt = .distantPast
    }
    let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
    workReferenceNow = now
    workCutoff = cutoff
    if now >= nextPruneAt {
      if state.prune(now: now, retentionDays: retentionDays) { markDirty() }
      nextPruneAt = nextPruneDate(after: now)
    }
    prepareIndexedTails()
    if scan == nil, !hasScanned || now >= nextFileScanAt { beginScan(cutoff: cutoff, now: now) }
    runWorkSlice()
    await checkpointIfNeeded(now: now)
    scheduleBackgroundWork()
    return ClaudeTranscriptSnapshot(state: state)
  }

  private func loadState() async {
    guard !stateLoaded else { return }
    if stateLoadTask == nil {
      let stateURL = stateURL
      stateLoadTask = Task.detached(priority: .utility) {
        guard let stateURL, let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(ClaudeTranscriptState.self, from: data)
      }
    }
    let stored = await stateLoadTask?.value
    guard !stateLoaded else { return }
    stateLoaded = true
    stateLoadTask = nil
    nextCheckpointAt = .distantPast
    if let stored {
      state = stored
      scanGeneration = stored.offsets.values.map(\.scanGeneration).max() ?? 0
    }
  }

  private func transcriptFile(_ url: URL) -> TranscriptFile? {
    workload.statChecks += 1
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType == .typeRegular
    else { return nil }
    return TranscriptFile(
      url: url,
      size: (attributes[.size] as! NSNumber).intValue,
      modified: attributes[.modificationDate] as! Date)
  }

  private static func isNewer(_ lhs: TranscriptFile, _ rhs: TranscriptFile) -> Bool {
    lhs.modified == rhs.modified ? lhs.url.path < rhs.url.path : lhs.modified > rhs.modified
  }

  private func beginScan(cutoff: Date, now: Date) {
    partialReads.removeAll(keepingCapacity: true)
    recordPartialWorkload()
    let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles])!
    scanGeneration &+= 1
    scan = TranscriptScan(
      enumerator: enumerator, cutoff: cutoff, referenceNow: now, generation: scanGeneration)
    workload.scansStarted += 1
  }

  private func prepareIndexedTails() {
    guard pendingTailIndex >= pendingTails.count else { return }
    pendingTails.removeAll(keepingCapacity: true)
    pendingTailIndex = 0
    for key in indexedFiles.keys.sorted() {
      guard let indexed = indexedFiles[key], let current = transcriptFile(indexed.url) else { continue }
      let partial = partialReads[key]
      guard current != indexed || partial.map({ $0.cursor < current.size }) == true else { continue }
      if current.size < (partial?.cursor ?? state.offsets[key]?.bytes ?? 0)
        || current.size == indexed.size && current.modified != indexed.modified
      {
        state.offsets[key] = TranscriptOffset(bytes: 0, scanGeneration: state.offsets[key]!.scanGeneration)
        partialReads.removeValue(forKey: key)
        markDirty()
      }
      indexedFiles[key] = current
      pendingTails.append(current)
    }
  }

  private var hasPendingWork: Bool {
    pendingTailIndex < pendingTails.count || scan != nil
  }

  private func runWorkSlice() {
    let initialBytes = workload.bytesRead
    let initialEntries = workload.treeEntriesExamined
    defer {
      workload.largestSliceBytesRead = max(workload.largestSliceBytesRead, workload.bytesRead - initialBytes)
      workload.largestSliceEntriesExamined = max(
        workload.largestSliceEntriesExamined, workload.treeEntriesExamined - initialEntries)
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(workTimeBudget))
    var bytesRemaining = workByteBudget
    while pendingTailIndex < pendingTails.count, bytesRemaining > 0, clock.now < deadline {
      let file = pendingTails[pendingTailIndex]
      let result = ingest(
        file, cutoff: workCutoff, byteLimit: bytesRemaining, deadline: deadline, retainsIncompleteTail: true)
      apply(result)
      bytesRemaining -= result.bytesRead
      guard result.complete else { break }
      pendingTailIndex += 1
    }
    if pendingTailIndex >= pendingTails.count {
      pendingTails.removeAll(keepingCapacity: true)
      pendingTailIndex = 0
    }
    guard bytesRemaining > 0, clock.now < deadline, var activeScan = scan else { return }
    var entriesRemaining = workEntryBudget
    while bytesRemaining > 0, entriesRemaining > 0, clock.now < deadline {
      if let file = activeScan.currentFile {
        let retainsIncompleteTail = activeScan.hotFiles.contains { $0.url.path == file.url.path }
        let result = ingest(
          file, cutoff: activeScan.cutoff, byteLimit: bytesRemaining, deadline: deadline,
          retainsIncompleteTail: retainsIncompleteTail)
        apply(result)
        bytesRemaining -= result.bytesRead
        guard result.complete else { break }
        activeScan.currentFile = nil
        continue
      }
      guard let url = activeScan.enumerator.nextObject() as? URL else {
        finishScan(activeScan)
        return
      }
      workload.treeEntriesExamined += 1
      entriesRemaining -= 1
      guard url.pathExtension == "jsonl", let file = transcriptFile(url), file.modified >= activeScan.cutoff else {
        continue
      }
      if state.offsets[file.url.path] != nil {
        state.offsets[file.url.path]?.scanGeneration = activeScan.generation
      }
      let retainsIncompleteTail = insertHotFile(file, into: &activeScan.hotFiles)
      if state.offsets[file.url.path]?.bytes != file.size || partialReads[file.url.path] != nil {
        activeScan.currentFile = file
        let result = ingest(
          file, cutoff: activeScan.cutoff, byteLimit: bytesRemaining, deadline: deadline,
          retainsIncompleteTail: retainsIncompleteTail)
        apply(result)
        bytesRemaining -= result.bytesRead
        guard result.complete else { break }
        activeScan.currentFile = nil
      }
    }
    scan = activeScan
  }

  private func finishScan(_ completed: TranscriptScan) {
    let previousOffsetCount = state.offsets.count
    state.offsets = state.offsets.filter { $0.value.scanGeneration == completed.generation }
    if state.offsets.count != previousOffsetCount {
      markDirty()
    }
    indexedFiles = Dictionary(uniqueKeysWithValues: completed.hotFiles.map { ($0.url.path, $0) })
    scan = nil
    hasScanned = true
    nextFileScanAt = completed.referenceNow.addingTimeInterval(fileScanInterval)
    workload.scansCompleted += 1
    recordPartialWorkload()
  }

  @discardableResult
  private func insertHotFile(_ file: TranscriptFile, into files: inout [TranscriptFile]) -> Bool {
    if files.count < Self.maxIndexedFiles {
      files.append(file)
      files.sort(by: Self.isNewer)
      return true
    } else if let oldest = files.last, Self.isNewer(file, oldest) {
      partialReads.removeValue(forKey: oldest.url.path)
      files[files.count - 1] = file
      files.sort(by: Self.isNewer)
      return true
    }
    partialReads.removeValue(forKey: file.url.path)
    return false
  }

  private func ingest(
    _ file: TranscriptFile, cutoff: Date, byteLimit: Int, deadline: ContinuousClock.Instant,
    retainsIncompleteTail: Bool
  ) -> TranscriptIngestResult {
    let key = file.url.path
    let storedOffset = state.offsets[key]?.bytes ?? 0
    let generation = scan?.generation ?? state.offsets[key]?.scanGeneration ?? scanGeneration
    var partial = partialReads[key] ?? PartialTranscriptRead(committedOffset: storedOffset, cursor: storedOffset)
    if file.size < partial.cursor || file.size < partial.committedOffset {
      partial = PartialTranscriptRead(committedOffset: 0, cursor: 0)
      state.offsets[key] = TranscriptOffset(bytes: 0, scanGeneration: generation)
    }
    guard partial.cursor < file.size else {
      return TranscriptIngestResult(
        changed: partial.committedOffset != storedOffset, bytesRead: 0, succeeded: true, complete: true)
    }
    guard let handle = try? FileHandle(forReadingFrom: file.url) else { return .failed }
    workload.filesOpened += 1
    defer { try? handle.close() }
    try! handle.seek(toOffset: UInt64(partial.cursor))
    let clock = ContinuousClock()
    var bytesRead = 0
    var aggregateChanged = false
    var reachedStaleEOF = false
    while partial.cursor < file.size, bytesRead < byteLimit, clock.now < deadline {
      let count = min(Self.readChunkSize, byteLimit - bytesRead, file.size - partial.cursor)
      let result = Result { try readChunk(handle, count) }
      guard case .success(let value) = result else { return .failed }
      guard let chunk = value, !chunk.isEmpty else {
        reachedStaleEOF = true
        break
      }
      let chunkStart = partial.cursor
      partial.cursor += chunk.count
      bytesRead += chunk.count
      aggregateChanged = consume(chunk, startingAt: chunkStart, cutoff: cutoff, partial: &partial) || aggregateChanged
    }
    state.offsets[key] = TranscriptOffset(bytes: partial.committedOffset, scanGeneration: generation)
    if reachedStaleEOF || (partial.pending.isEmpty && !partial.oversized && partial.cursor >= file.size)
      || (partial.cursor >= file.size && !retainsIncompleteTail)
    {
      partialReads.removeValue(forKey: key)
    } else {
      retainPartial(partial, for: key)
    }
    recordPartialWorkload()
    workload.bytesRead += bytesRead
    return TranscriptIngestResult(
      changed: aggregateChanged || partial.committedOffset != storedOffset,
      bytesRead: bytesRead,
      succeeded: !reachedStaleEOF,
      complete: reachedStaleEOF || partial.cursor >= file.size)
  }

  private func consume(
    _ chunk: Data, startingAt chunkStart: Int, cutoff: Date, partial: inout PartialTranscriptRead
  ) -> Bool {
    var changed = false
    var start = chunk.startIndex
    while start < chunk.endIndex {
      if partial.oversized {
        guard let newline = chunk[start...].firstIndex(of: UInt8(ascii: "\n")) else { return changed }
        partial.oversized = false
        partial.committedOffset = chunkStart + chunk.distance(from: chunk.startIndex, to: newline) + 1
        start = chunk.index(after: newline)
        continue
      }
      guard let newline = chunk[start...].firstIndex(of: UInt8(ascii: "\n")) else {
        let suffix = chunk[start...]
        if partial.pending.count + suffix.count <= maximumLineBytes {
          partial.pending.append(contentsOf: suffix)
        } else {
          partial.pending.removeAll(keepingCapacity: false)
          partial.oversized = true
        }
        return changed
      }
      let segment = chunk[start..<newline]
      if partial.pending.count + segment.count <= maximumLineBytes {
        partial.pending.append(contentsOf: segment)
        if partial.pending.contains(Self.usageMarker), let message = Self.parse(line: partial.pending),
          message.timestamp >= cutoff
        {
          changed = state.ingest(message) || changed
        }
      }
      partial.pending.removeAll(keepingCapacity: false)
      partial.committedOffset = chunkStart + chunk.distance(from: chunk.startIndex, to: newline) + 1
      start = chunk.index(after: newline)
    }
    return changed
  }

  private func apply(_ result: TranscriptIngestResult) {
    guard result.changed else { return }
    markDirty(bytes: result.bytesRead)
  }

  private func markDirty(bytes: Int = 0) {
    stateDirty = true
    stateRevision += 1
    uncheckpointedBytes += bytes
  }

  private func recordPartialWorkload() {
    workload.retainedPartialFiles = partialReads.count
    workload.retainedPartialBytes = partialReads.values.reduce(0) { $0 + $1.pending.count }
    workload.largestRetainedPartialBytes = max(
      workload.largestRetainedPartialBytes, workload.retainedPartialBytes)
  }

  private func retainPartial(_ partial: PartialTranscriptRead, for key: String) {
    partialReads[key] = partial
    var retainedBytes = partialReads.values.reduce(0) { $0 + $1.pending.count }
    while retainedBytes > maximumRetainedPartialBytes {
      let victim = partialReads.keys.filter({ $0 != key }).max(by: {
        let lhs = partialReads[$0]!.pending.count
        let rhs = partialReads[$1]!.pending.count
        return lhs == rhs ? $0 > $1 : lhs < rhs
      })!
      retainedBytes -= partialReads.removeValue(forKey: victim)!.pending.count
    }
    recordPartialWorkload()
  }

  private func checkpointIfNeeded(now: Date) async {
    guard stateDirty else { return }
    if let checkpointRetryAt {
      guard now >= checkpointRetryAt else { return }
    } else {
      guard now >= nextCheckpointAt || uncheckpointedBytes >= maximumCheckpointBytes else { return }
    }
    guard checkpointInFlightRevision == nil else { return }
    guard let stateURL else {
      stateDirty = false
      uncheckpointedBytes = 0
      return
    }
    let revision = stateRevision
    let byteCount = uncheckpointedBytes
    let snapshot = state
    checkpointInFlightRevision = revision
    workload.checkpointAttempts += 1
    let writtenBytes = await Task.detached(priority: .utility) { () -> Int? in
      let data = try! JSONEncoder().encode(snapshot)
      guard
        (try? FileManager.default.createDirectory(
          at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
        (try? data.write(to: stateURL, options: .atomic)) != nil
      else { return nil }
      return data.count
    }.value
    checkpointInFlightRevision = nil
    guard let writtenBytes else {
      checkpointRetryAt = now.addingTimeInterval(max(min(checkpointInterval, 60), 1))
      return
    }
    checkpointRetryAt = nil
    workload.checkpoints += 1
    workload.checkpointBytesWritten += writtenBytes
    workload.lastCheckpointBytes = writtenBytes
    uncheckpointedBytes = max(uncheckpointedBytes - byteCount, 0)
    stateDirty = stateRevision != revision
    nextCheckpointAt = now.addingTimeInterval(checkpointInterval)
  }

  private func scheduleBackgroundWork() {
    guard hasPendingWork, backgroundTask == nil else { return }
    let delay = backgroundWorkDelay
    backgroundTask = Task(priority: .utility) { [weak self] in
      do {
        try await ContinuousClock().sleep(for: .seconds(delay))
        try Task.checkCancellation()
        try await self?.runBackgroundSlice()
      } catch {
        return
      }
    }
  }

  private func runBackgroundSlice() async throws {
    guard hasPendingWork else {
      backgroundTask = nil
      return
    }
    runWorkSlice()
    await checkpointIfNeeded(now: workReferenceNow)
    try Task.checkCancellation()
    backgroundTask = nil
    scheduleBackgroundWork()
  }

  private func nextPruneDate(after now: Date) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
  }

  /// The handful of fields a transcript line contributes. Decoding into this rather than a `JSONValue` tree skips
  /// the assistant's own text, which is nearly all of every line and is thrown away immediately.
  private struct Line: Decodable {
    struct Message: Decodable {
      struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?

        enum CodingKeys: String, CodingKey {
          case inputTokens = "input_tokens"
          case outputTokens = "output_tokens"
          case cacheCreationInputTokens = "cache_creation_input_tokens"
          case cacheReadInputTokens = "cache_read_input_tokens"
        }
      }

      struct Block: Decodable {
        let type: String?
      }

      let id: String?
      let model: String?
      let usage: Usage?
      let content: [Block]?
    }

    let type: String?
    let uuid: String?
    let requestId: String?
    let sessionId: String?
    let timestamp: String?
    let message: Message?
  }

  private static let decoder = JSONDecoder()

  static func parse(line: Data) -> TranscriptMessage? {
    guard let json = try? decoder.decode(Line.self, from: line), json.type == "assistant",
      let message = json.message, let usage = message.usage, let model = message.model,
      let timestamp = ISODate.parse(json.timestamp)
    else { return nil }
    return TranscriptMessage(
      id: "\(message.id ?? json.uuid ?? ""):\(json.requestId ?? "")",
      timestamp: timestamp,
      session: json.sessionId ?? "",
      model: model,
      usage: TokenUsage(
        input: usage.inputTokens ?? 0,
        output: usage.outputTokens ?? 0,
        cacheWrite: usage.cacheCreationInputTokens ?? 0,
        cacheRead: usage.cacheReadInputTokens ?? 0
      ),
      toolCalls: message.content?.count { $0.type == "tool_use" } ?? 0
    )
  }

  public static func analytics(_ messages: [TranscriptMessage], now: Date) -> ProviderAnalytics? {
    guard !messages.isEmpty else { return nil }
    var byDayModel: [String: [String: TokenUsage]] = [:]
    var daily: [String: (messages: Int, sessions: Set<String>, toolCalls: Int, cost: Double)] = [:]
    for message in messages {
      let day = DayStamp.string(message.timestamp)
      byDayModel[day, default: [:]][message.model, default: TokenUsage()] += message.usage
      var entry = daily[day] ?? (0, [], 0, 0)
      entry.messages += 1
      entry.sessions.insert(message.session)
      entry.toolCalls += message.toolCalls
      entry.cost += message.cost
      daily[day] = entry
    }
    var points: [AnalyticsPoint] = []
    for (day, models) in byDayModel {
      for (model, usage) in models {
        points.append(AnalyticsPoint(day: day, metric: .inputTokens, series: model, value: Double(usage.input)))
        points.append(AnalyticsPoint(day: day, metric: .outputTokens, series: model, value: Double(usage.output)))
        points.append(
          AnalyticsPoint(day: day, metric: .cachedInputTokens, series: model, value: Double(usage.cacheRead)))
        points.append(
          AnalyticsPoint(day: day, metric: .cacheWriteTokens, series: model, value: Double(usage.cacheWrite)))
        points.append(
          AnalyticsPoint(day: day, metric: .costUSD, series: model, value: ClaudePricing.cost(usage, model: model)))
      }
    }
    for (day, entry) in daily {
      points.append(AnalyticsPoint(day: day, metric: .messages, series: "messages", value: Double(entry.messages)))
      points.append(
        AnalyticsPoint(day: day, metric: .sessions, series: "sessions", value: Double(entry.sessions.count)))
      points.append(AnalyticsPoint(day: day, metric: .toolCalls, series: "tool calls", value: Double(entry.toolCalls)))
    }
    return ProviderAnalytics(
      provider: .claude,
      points: points.sorted { ($0.day, $0.metric.rawValue, $0.series) < ($1.day, $1.metric.rawValue, $1.series) },
      fetchedAt: now)
  }

  public static func localUsage(
    _ messages: [TranscriptMessage], windowResetsAt: Date?, windowDuration: TimeInterval, now: Date,
    calendar: Calendar = .current
  ) -> LocalUsage? {
    guard !messages.isEmpty else { return nil }
    let windowStart = (windowResetsAt ?? now).addingTimeInterval(-windowDuration)
    let inWindow = messages.filter { $0.timestamp >= windowStart && $0.timestamp <= now }
    let windowTokens = inWindow.reduce(0) { $0 + $1.usage.total }
    let windowCost = inWindow.reduce(0) { $0 + $1.cost }
    let elapsedHours = max(now.timeIntervalSince(inWindow.map(\.timestamp).min() ?? now) / 3600, 1.0 / 60)
    let todayStart = calendar.startOfDay(for: now)
    let today = messages.filter { $0.timestamp >= todayStart }
    return LocalUsage(
      windowTokens: windowTokens,
      windowCost: windowCost,
      costPerHour: inWindow.isEmpty ? 0 : windowCost / elapsedHours,
      todayTokens: today.reduce(0) { $0 + $1.usage.total },
      todayCost: today.reduce(0) { $0 + $1.cost },
      todayMessages: today.count
    )
  }
}
