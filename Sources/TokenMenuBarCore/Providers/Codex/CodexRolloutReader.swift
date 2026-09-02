import Foundation

public struct CodexRolloutWorkload: Sendable, Equatable {
  public fileprivate(set) var treesScanned = 0
  public fileprivate(set) var treeEntriesExamined = 0
  public fileprivate(set) var statChecks = 0
  public fileprivate(set) var filesOpened = 0
  public fileprivate(set) var bytesRead = 0
  public fileprivate(set) var largestSliceBytesRead = 0
  public fileprivate(set) var largestTreeSliceEntries = 0
  public fileprivate(set) var searchesCompleted = 0

  public init() {}
}

private struct RolloutFile: Sendable, Equatable {
  let url: URL
  let size: Int
  let modified: Date
}

private struct RolloutCandidateCache {
  var files: [RolloutFile]
  let expiresAt: Date
}

private struct RolloutSearch {
  let files: [RolloutFile]
  let referenceNow: Date
  var fileIndex = 0
  var current: ReverseRolloutRead?
}

private struct RolloutTreeScan {
  let enumerator: FileManager.DirectoryEnumerator
  let referenceNow: Date
  var candidates: [RolloutFile] = []
}

private struct ReverseRolloutRead {
  let file: RolloutFile
  var cursor: Int
  var reversedLine = Data()
  var oversized = false
}

public actor CodexRolloutReader {
  static let maxFiles = 8
  public static let defaultCacheInterval: TimeInterval = 5 * 60
  public static let defaultWorkByteBudget = 2 * 1024 * 1024
  public static let defaultWorkEntryBudget = 256
  public static let defaultWorkTimeBudget: TimeInterval = 0.05
  public static let defaultBackgroundWorkDelay: TimeInterval = 0.01
  static let readChunkSize = 64 * 1024
  static let maximumLineBytes = 1024 * 1024

  public let sessionsRoot: URL
  private let cacheInterval: TimeInterval
  private let workByteBudget: Int
  private let workEntryBudget: Int
  private let workTimeBudget: TimeInterval
  private let backgroundWorkDelay: TimeInterval
  private var cache: Cache?
  private var candidateCache: RolloutCandidateCache?
  private var treeScan: RolloutTreeScan?
  private var search: RolloutSearch?
  private var backgroundTask: Task<Void, Never>?
  public private(set) var workload = CodexRolloutWorkload()

  public init(
    sessionsRoot: URL,
    cacheInterval: TimeInterval = defaultCacheInterval,
    workByteBudget: Int = defaultWorkByteBudget,
    workEntryBudget: Int = defaultWorkEntryBudget,
    workTimeBudget: TimeInterval = defaultWorkTimeBudget,
    backgroundWorkDelay: TimeInterval = defaultBackgroundWorkDelay
  ) {
    self.sessionsRoot = sessionsRoot
    self.cacheInterval = cacheInterval
    self.workByteBudget = max(workByteBudget, 1)
    self.workEntryBudget = max(workEntryBudget, 1)
    self.workTimeBudget = max(workTimeBudget, 0.001)
    self.backgroundWorkDelay = max(backgroundWorkDelay, 0.001)
  }

  deinit { backgroundTask?.cancel() }

  public func cancelBackgroundWork() {
    backgroundTask?.cancel()
    backgroundTask = nil
    treeScan = nil
    search = nil
  }

  struct Reading: Sendable, Equatable {
    let rateLimit: CodexAPI.RateLimit
    let planType: String?
    let credits: CodexAPI.Credits?
    let observedAt: Date?
  }

  func latest(now: Date = Date()) -> Reading? {
    if let cache, cache.expiresAt > now {
      if let refreshed = refreshedFiles(cache.files) {
        if refreshed == cache.files { return cache.reading }
        candidateCache = RolloutCandidateCache(
          files: refreshed, expiresAt: candidateCache!.expiresAt)
        self.cache = nil
        search = RolloutSearch(files: refreshed, referenceNow: now)
      } else {
        self.cache = nil
        candidateCache = nil
        treeScan = nil
        search = nil
      }
    }
    if treeScan == nil, search == nil {
      if let candidateCache, candidateCache.expiresAt > now {
        search = RolloutSearch(files: candidateCache.files, referenceNow: now)
      } else {
        beginTreeScan(now: now)
      }
    }
    runWorkSlice()
    scheduleBackgroundWork()
    return cache?.reading
  }

  private func beginTreeScan(now: Date) {
    let enumerator = FileManager.default.enumerator(
      at: sessionsRoot,
      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles])!
    workload.treesScanned += 1
    treeScan = RolloutTreeScan(enumerator: enumerator, referenceNow: now)
  }

  private func refreshedFiles(_ files: [RolloutFile]) -> [RolloutFile]? {
    var refreshed: [RolloutFile] = []
    refreshed.reserveCapacity(files.count)
    for file in files {
      guard let current = rolloutFile(file.url) else { return nil }
      refreshed.append(current)
    }
    return refreshed.sorted(by: Self.isNewer)
  }

  private func runWorkSlice() {
    let initialBytes = workload.bytesRead
    let initialEntries = workload.treeEntriesExamined
    defer {
      workload.largestSliceBytesRead = max(workload.largestSliceBytesRead, workload.bytesRead - initialBytes)
      workload.largestTreeSliceEntries = max(
        workload.largestTreeSliceEntries, workload.treeEntriesExamined - initialEntries)
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(workTimeBudget))
    advanceTreeScan(deadline: deadline)
    guard clock.now < deadline else { return }
    runSearchSlice(deadline: deadline)
  }

  private func advanceTreeScan(deadline: ContinuousClock.Instant) {
    guard var active = treeScan else { return }
    let clock = ContinuousClock()
    var entriesRemaining = workEntryBudget
    while entriesRemaining > 0, clock.now < deadline {
      guard let url = active.enumerator.nextObject() as? URL else {
        let files = active.candidates
        candidateCache = RolloutCandidateCache(
          files: files, expiresAt: active.referenceNow.addingTimeInterval(cacheInterval))
        treeScan = nil
        search = RolloutSearch(files: files, referenceNow: active.referenceNow)
        return
      }
      workload.treeEntriesExamined += 1
      entriesRemaining -= 1
      guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl", let file = rolloutFile(url)
      else { continue }
      insertCandidate(file, into: &active.candidates)
    }
    treeScan = active
  }

  private func runSearchSlice(deadline: ContinuousClock.Instant) {
    guard var active = search else { return }
    let clock = ContinuousClock()
    var bytesRemaining = workByteBudget
    while active.fileIndex < active.files.count, bytesRemaining > 0, clock.now < deadline {
      var current =
        active.current
        ?? ReverseRolloutRead(
          file: active.files[active.fileIndex], cursor: active.files[active.fileIndex].size)
      guard let handle = try? FileHandle(forReadingFrom: current.file.url) else {
        active.current = nil
        active.fileIndex += 1
        continue
      }
      workload.filesOpened += 1
      defer { try? handle.close() }
      var found: Reading?
      var reachedStaleEOF = false
      while current.cursor > 0, bytesRemaining > 0, clock.now < deadline {
        let count = min(Self.readChunkSize, bytesRemaining, current.cursor)
        let start = current.cursor - count
        let result = Result {
          try handle.seek(toOffset: UInt64(start))
          return try handle.read(upToCount: count)
        }
        guard case .success(let value) = result, let chunk = value, chunk.count == count else {
          reachedStaleEOF = true
          break
        }
        workload.bytesRead += chunk.count
        bytesRemaining -= chunk.count
        current.cursor = start
        for byte in chunk.reversed() {
          if byte == UInt8(ascii: "\n") {
            if !current.oversized, let reading = Self.parse(reversedLine: current.reversedLine) {
              found = reading
              break
            }
            current.reversedLine.removeAll(keepingCapacity: true)
            current.oversized = false
          } else if current.reversedLine.count < Self.maximumLineBytes {
            current.reversedLine.append(byte)
          } else {
            current.oversized = true
          }
        }
        if found != nil { break }
      }
      if let found {
        cache = Cache(
          reading: found, files: active.files, expiresAt: active.referenceNow.addingTimeInterval(cacheInterval))
        workload.searchesCompleted += 1
        search = nil
        return
      }
      if reachedStaleEOF {
        active.current = nil
        active.fileIndex += 1
      } else if current.cursor == 0 {
        if !current.oversized, let reading = Self.parse(reversedLine: current.reversedLine) {
          cache = Cache(
            reading: reading, files: active.files, expiresAt: active.referenceNow.addingTimeInterval(cacheInterval))
          workload.searchesCompleted += 1
          search = nil
          return
        }
        active.current = nil
        active.fileIndex += 1
      } else {
        active.current = current
      }
    }
    if active.fileIndex >= active.files.count {
      cache = Cache(
        reading: nil, files: active.files, expiresAt: active.referenceNow.addingTimeInterval(cacheInterval))
      workload.searchesCompleted += 1
      search = nil
    } else {
      search = active
    }
  }

  private static func parse(reversedLine: Data) -> Reading? {
    guard !reversedLine.isEmpty else { return nil }
    let line = Data(reversedLine.reversed())
    guard line.range(of: Data("\"rate_limits\"".utf8)) != nil else { return nil }
    return parse(line: String(decoding: line, as: UTF8.self))
  }

  private var hasPendingWork: Bool { treeScan != nil || search != nil }

  private func scheduleBackgroundWork() {
    guard hasPendingWork, backgroundTask == nil else { return }
    let delay = backgroundWorkDelay
    backgroundTask = Task(priority: .utility) { [weak self] in
      do {
        try await ContinuousClock().sleep(for: .seconds(delay))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await self?.runBackgroundSlice()
    }
  }

  private func runBackgroundSlice() {
    guard hasPendingWork else {
      backgroundTask = nil
      return
    }
    runWorkSlice()
    guard !Task.isCancelled else { return }
    backgroundTask = nil
    scheduleBackgroundWork()
  }

  func newestRollouts() async -> [URL] {
    backgroundTask?.cancel()
    backgroundTask = nil
    cache = nil
    candidateCache = nil
    treeScan = nil
    search = nil
    beginTreeScan(now: Date())
    while !Task.isCancelled, treeScan != nil {
      runWorkSlice()
      if treeScan != nil {
        try? await ContinuousClock().sleep(for: .seconds(backgroundWorkDelay))
      }
    }
    return candidateCache?.files.map(\.url) ?? []
  }

  private func insertCandidate(_ file: RolloutFile, into candidates: inout [RolloutFile]) {
    if candidates.count < Self.maxFiles {
      candidates.append(file)
      candidates.sort(by: Self.isNewer)
    } else if let oldest = candidates.last, Self.isNewer(file, oldest) {
      candidates[candidates.count - 1] = file
      candidates.sort(by: Self.isNewer)
    }
  }

  private func rolloutFile(_ url: URL) -> RolloutFile? {
    workload.statChecks += 1
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType == .typeRegular
    else { return nil }
    return RolloutFile(
      url: url,
      size: (attributes[.size] as! NSNumber).intValue,
      modified: attributes[.modificationDate] as! Date)
  }

  private static func isNewer(_ lhs: RolloutFile, _ rhs: RolloutFile) -> Bool {
    lhs.modified == rhs.modified ? lhs.url.path < rhs.url.path : lhs.modified > rhs.modified
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
      let data = try! JSONEncoder().encode(value)
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

private struct Cache {
  let reading: CodexRolloutReader.Reading?
  let files: [RolloutFile]
  let expiresAt: Date
}
