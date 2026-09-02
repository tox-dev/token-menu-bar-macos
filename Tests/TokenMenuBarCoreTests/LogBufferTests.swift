import Foundation
import Testing
import TokenMenuBarCore

@Test func logBufferKeepsEntriesAndLevels() {
  let log = makeLog()
  log.log("hello")
  log.logWarning("careful")
  log.logError("bad")
  log.logDebug("hidden")
  log.debugEnabled = true
  log.logDebug("shown")
  #expect(log.snapshot.map(\.message) == ["hello", "careful", "bad", "shown"])
  #expect(log.snapshot.map(\.level) == [.info, .warning, .error, .debug])
  #expect(log.tail(1).map(\.message) == ["shown"])
  #expect(log.text.contains("[error] bad"))
  #expect(log.snapshot[0].line.hasPrefix("[2026-08-29"))
  #expect(log.snapshot[0].id != log.snapshot[1].id)
  #expect(LogLevel.debug < .info && LogLevel.info < .error)
  log.clear()
  #expect(log.snapshot.isEmpty)
}

@Test func logBufferCapsCapacity() {
  let log = makeLog()
  for index in 0..<(LogBuffer.capacity + 10) { log.log("line \(index)") }
  #expect(log.snapshot.count == LogBuffer.capacity)
  #expect(log.snapshot.first?.message == "line 10")
}

@Test func logBufferPersistsAndPrunesOnLoad() throws {
  let url = temporaryDirectory().appendingPathComponent("logs/app.log")
  let old = LogEntry(
    timestamp: fixedNow.addingTimeInterval(-LogBuffer.retention - 10), level: .info, message: "ancient")
  let recent = LogEntry(timestamp: fixedNow.addingTimeInterval(-10), level: .info, message: "recent")
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data((old.line + "\n" + recent.line + "\n").utf8).write(to: url)

  let log = LogBuffer(fileURL: url, clock: testClock)
  #expect(log.snapshot.map(\.message) == ["recent"])
  // Loading drops what aged out, so the file no longer carries it either.
  #expect(try !String(contentsOf: url, encoding: .utf8).contains("ancient"))

  log.log("new")
  log.flush()
  #expect(LogBuffer(fileURL: url, clock: testClock).snapshot.map(\.message) == ["recent", "new"])
  // Appending leaves what was already there alone rather than rewriting the file.
  #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix(recent.line))
}

@Test func logBufferKeepsLinesItCannotParse() throws {
  let url = temporaryDirectory().appendingPathComponent("logs/app.log")
  let recent = LogEntry(timestamp: fixedNow.addingTimeInterval(-10), level: .info, message: "recent")
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data((recent.line + "\ncrash: not a log line\n[2026-08-29 19:00:00.000] no level here\n").utf8).write(to: url)

  // A malformed line is what the bug report is about, so it survives the round trip whole.
  let messages = LogBuffer(fileURL: url, clock: testClock).snapshot.map(\.message)
  #expect(messages == ["recent", "crash: not a log line", "no level here"])
}

@Test(arguments: [
  "2024-02-29 12:34:56.789",
  "2026-04-30 12:34:56.789",
  "2026-08-29 12:34:56.789",
])
func logBufferParsesStoredUtcTimestamps(timestamp: String) throws {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let expected = try #require(formatter.date(from: timestamp.replacingOccurrences(of: " ", with: "T") + "Z"))
  let url = temporaryDirectory().appendingPathComponent("app.log")
  try Data("[\(timestamp)] [info] retained\n".utf8).write(to: url)

  let entry = try #require(
    LogBuffer(fileURL: url, clock: .fixed(expected.addingTimeInterval(60))).snapshot.first)

  #expect(entry.timestamp == expected)
}

@Test(arguments: [
  "202x-08-29 12:34:56.789",
  "0000-08-29 12:34:56.789",
  "2025-02-29 12:34:56.789",
  "2026-04-31 12:34:56.789",
  "2026-13-29 12:34:56.789",
])
func logBufferFallsBackForInvalidStoredTimestamps(timestamp: String) throws {
  let url = temporaryDirectory().appendingPathComponent("app.log")
  try Data("[\(timestamp)] [info] retained\n".utf8).write(to: url)
  let now = Date(timeIntervalSince1970: 1_788_030_000)

  let entry = try #require(LogBuffer(fileURL: url, clock: .fixed(now)).snapshot.first)

  #expect(entry.timestamp == now.addingTimeInterval(-LogBuffer.retention))
}

@Test func logBufferSanitizesAValidStoredLine() throws {
  let url = temporaryDirectory().appendingPathComponent("app.log")
  try Data("[2026-08-29 19:00:00.000] [warning] access_token=secret\n".utf8).write(to: url)

  let entry = try #require(LogBuffer(fileURL: url, clock: testClock).snapshot.first)

  #expect(entry.message == "access_token=<redacted>")
}

@Test func logBufferPrunesHourlyWhileAppending() {
  let box = DateBox(fixedNow)
  let log = LogBuffer(fileURL: nil, clock: box.clock)
  log.log("first")
  box.date = fixedNow.addingTimeInterval(LogBuffer.retention + 7200)
  log.log("second")
  #expect(log.snapshot.map(\.message) == ["second"])
}

@Test func logBufferDoesNotBuildDisabledDetailedMessages() {
  let log = makeLog()
  var evaluations = 0
  log.logDebug(
    {
      evaluations += 1
      return "debug"
    }())
  log.detailed(
    {
      evaluations += 1
      return tabDiagnostic()
    }())
  #expect(evaluations == 0)
  #expect(log.snapshot.isEmpty)

  log.debugEnabled = true
  log.logDebug(
    {
      evaluations += 1
      return "debug"
    }())
  log.detailed(
    {
      evaluations += 1
      return tabDiagnostic()
    }())
  #expect(evaluations == 2)
  #expect(log.snapshot.map(\.level) == [.debug, .debug])
}

@Test func diagnosticEventsKeepCategoryAndFields() {
  let log = makeLog()
  log.record(tabDiagnostic(), level: .info)
  let entry = log.snapshot[0]
  #expect(entry.category == .tabs)
  #expect(entry.message == "tab.measurement source=History active=Settings filedUnder=History size=832x700")
  #expect(entry.line.contains("[info] [tabs] tab.measurement"))
}

@Test func diagnosticFactoriesReportRealStateChangesAndSkippedWork() throws {
  let unchanged = StatusDiagnostic.retierIfChanged(
    trigger: "fit", buttonFrame: nil, oldTier: 1, newTier: 1, visible: true, popoverVisible: false,
    fits: true, layoutContext: nil)
  #expect(unchanged == nil)
  let changed = try #require(
    StatusDiagnostic.retierIfChanged(
      trigger: "fit", buttonFrame: nil, oldTier: 1, newTier: 2, visible: true, popoverVisible: false,
      fits: false, layoutContext: "closed"))
  #expect(changed.action == .retier)
  #expect(changed.oldTier == 1)
  #expect(changed.newTier == 2)

  let skipped = RefreshDiagnostic.skipped(
    cycleID: "cycle", trigger: "scheduled", provider: .codex, usagePolicy: "due",
    analyticsPolicy: "due", reason: .retryBackoff)
  #expect(skipped.outcome == .skipped)
  #expect(skipped.skipReason == .retryBackoff)
  #expect(DiagnosticEvent.refresh(skipped).message.contains("skipReason=retry-backoff"))
}

@Test func undiscoveredProviderMissesRequireDetailedLogging() {
  let log = makeLog()
  let event = DiagnosticEvent.refresh(
    RefreshDiagnostic.skipped(
      cycleID: "discovery", trigger: "scheduled", provider: .copilot, usagePolicy: "due",
      analyticsPolicy: "due", reason: .notDiscovered))

  log.detailed(event)
  #expect(log.snapshot.isEmpty)

  log.debugEnabled = true
  log.detailed(event)
  #expect(log.snapshot.map(\.level) == [.debug])
  #expect(log.snapshot[0].message.contains("provider=copilot"))
  #expect(log.snapshot[0].message.contains("skipReason=not-discovered"))
}

@Test func explicitProviderFailuresRemainVisibleWithoutDetailedLogging() {
  let log = makeLog()

  log.logError("refresh provider=codex outcome=authenticationRequired error=Sign in required", category: .refresh)

  #expect(log.snapshot.map(\.level) == [.error])
  #expect(log.snapshot.map(\.category) == [.refresh])
  #expect(log.snapshot[0].message.contains("provider=codex"))
}

@Test func diagnosticCategoriesExposeReadableTitles() {
  #expect(
    LogCategory.allCases.map(\.title) == [
      "App", "Geometry", "Network", "Persistence", "Refresh", "Status item", "Tabs",
    ])
}

@Test func panelPostResizeFactoryCapturesTheResultingWindowState() {
  let result = DiagnosticRect(x: 10, y: 20, width: 832, height: 700)
  let event = PanelDiagnostic.postResize(
    trigger: "backing-window",
    tab: "Settings",
    anchor: DiagnosticRect(x: 100, y: 900, width: 24, height: 22),
    screenID: "main",
    screenFrame: DiagnosticRect(x: 0, y: 0, width: 1_440, height: 900),
    maximum: DiagnosticSize(width: 832, height: 760),
    proposed: DiagnosticSize(width: 832, height: 720),
    clamped: DiagnosticSize(width: 832, height: 700),
    resultFrame: result,
    appActive: true,
    windowKey: true,
    windowMain: false,
    frontmostBundleID: "dev.tox.token-menu-bar")

  #expect(event.action == .resize)
  #expect(event.resultFrame == result)
  #expect(DiagnosticEvent.panel(event).message.contains("result=\"\(result)\""))
}

@Test func logFilterMatchesLevelsCategoriesAndSearch() {
  let log = makeLog()
  log.logInfo("opened panel", category: .geometry)
  log.logWarning("Codex delayed", category: .refresh)
  log.logError("Claude failed", category: .refresh)
  let filter = LogFilter(search: "CODEX", levels: [.warning, .error], categories: [.refresh])
  #expect(log.filtered(filter).map(\.message) == ["Codex delayed"])
  #expect(log.filtered(LogFilter(levels: [])).isEmpty)
}

@Test func logBufferSanitizesMessagesBeforeKeepingThem() {
  let log = makeLog()
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  log.logWarning(
    "Bearer abc access_token=xyz user@example.com \(home)/private https://example.com/path?key=value\nnext")
  let entry = log.snapshot[0]
  #expect(entry.message.contains("Bearer <redacted>"))
  #expect(entry.message.contains("access_token=<redacted>"))
  #expect(entry.message.contains("<redacted-email>"))
  #expect(entry.message.contains("~/private"))
  #expect(entry.message.contains("https://example.com/path?<redacted>"))
  #expect(entry.message.contains("\\nnext"))
  #expect(!entry.message.contains("abc"))
  #expect(!entry.message.contains("xyz"))
  #expect(!entry.message.contains(home))
}

@Test(arguments: [
  (#"warning HTTP 500: {"access_token":"sk-secret"}"#, "sk-secret"),
  ("request body={\n  \"access_token\": \"sk-secret\"\n}", "sk-secret"),
  ("Authorization: Basic dXNlcjpwYXNz", "dXNlcjpwYXNz"),
  (#"{\"client_secret\":\"private-value\"}"#, "private-value"),
])
func logSanitizerRedactsStructuredAndMultilineSecrets(message: String, secret: String) {
  let sanitized = LogSanitizer.message(message)
  #expect(sanitized.contains("<redacted>"))
  #expect(!sanitized.contains(secret))
}

@Test func logExportRedactsEachMultilineReportFieldWithoutRemovingLaterLines() {
  let report = "first body=private\nsecond access_token: secret\nthird visible"
  let sanitized = LogSanitizer.redact(report)
  #expect(sanitized == "first body=<redacted>\nsecond access_token=<redacted>\nthird visible")
}

@Test func logEntryBoundsUTF8LinesWithoutBreakingCharacters() {
  let entry = LogEntry(timestamp: fixedNow, level: .info, message: String(repeating: "é", count: 2_000))
  #expect(entry.line.utf8.count <= LogEntry.maximumLineBytes)
  #expect(entry.message.hasSuffix("…"))
  #expect(!entry.message.contains("�"))
}

@Test func logExportAddsAHeaderAndHonorsFilters() {
  let log = makeLog()
  log.logInfo("visible", category: .app)
  log.logError("hidden", category: .network)
  let header = LogExportHeader(
    appName: "Token Menu Bar", sourceVersion: "1.2.3", build: "7", distribution: "Direct",
    osVersion: "26.0")
  let export = log.export(filter: LogFilter(levels: [.info]), header: header)
  #expect(export.hasPrefix("Token Menu Bar 1.2.3 (7) Direct\nmacOS 26.0\n\n"))
  #expect(export.contains("visible"))
  #expect(!export.contains("hidden"))
}

@Test func logExportSanitizesHeaderFieldsWithoutChangingEntryIdentity() {
  let log = makeLog()
  log.log("visible")
  let sequenceID = log.snapshot[0].sequenceID
  let header = LogExportHeader(
    appName: "user@example.com", sourceVersion: "1", build: "7", distribution: "Direct",
    osVersion: "26")

  let export = log.export(header: header)

  #expect(export.contains("<redacted-email>"))
  #expect(log.snapshot[0].sequenceID == sequenceID)
  #expect(export.contains(log.snapshot[0].line))
}

@Test func logExportHeaderUsesTheRuntimeDistribution() {
  let header = LogExportHeader(
    app: AppInfo(
      name: "Token Menu Bar", version: "1", build: "7", bundleIdentifier: "dev.tox.token-menu-bar",
      distribution: .homebrew, repository: AppInfo.repositoryURL),
    osVersion: "15")
  #expect(header.distribution == "Homebrew")
}

@Test func logBufferRotatesFilesWithinTheConfiguredBound() throws {
  let url = temporaryDirectory().appendingPathComponent("logs/app.log")
  let log = LogBuffer(fileURL: url, clock: testClock, maximumFileBytes: 150, maximumFileCount: 3)
  for index in 0..<12 { log.log("line-\(index)-" + String(repeating: "x", count: 30)) }
  log.flush()

  let urls = [url, URL(fileURLWithPath: "\(url.path).1"), URL(fileURLWithPath: "\(url.path).2")]
  #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
  #expect(!FileManager.default.fileExists(atPath: "\(url.path).3"))
  for file in urls {
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let size = try #require(attributes[.size] as? NSNumber)
    #expect(size.intValue <= 150)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }
  let restored = LogBuffer(fileURL: url, clock: testClock, maximumFileBytes: 150, maximumFileCount: 3)
  #expect(restored.snapshot.last?.message.hasPrefix("line-11-") == true)
  #expect(restored.snapshot.first?.message.hasPrefix("line-0-") == false)
}

@Test func logBufferSubscriptionsCoalesceAndDeliverTheLatestSnapshot() async {
  let log = makeLog()
  var snapshots = log.snapshots().makeAsyncIterator()
  #expect(await snapshots.next()?.isEmpty == true)
  log.log("first")
  log.log("second")
  var update: [LogEntry] = []
  while update.last?.message != "second" { update = await snapshots.next() ?? [] }
  #expect(update.map(\.message) == ["first", "second"])
}

@Test func logBufferSubscriptionStopsAfterCancellation() async throws {
  let log = makeLog()
  let counter = InvocationCounter()
  let subscription = log.subscribe { Task { await counter.increment() } }
  log.log("first")
  await counter.wait(for: 1)
  #expect(await counter.value == 1)

  subscription.cancel()
  let barrier = InvocationCounter()
  let barrierSubscription = log.subscribe { Task { await barrier.increment() } }
  log.log("second")
  await barrier.wait(for: 1)
  #expect(await counter.value == 1)
  barrierSubscription.cancel()
}

@Test func persistedDiagnosticRetainsItsCategory() {
  let url = temporaryDirectory().appendingPathComponent("logs/app.log")
  let log = LogBuffer(fileURL: url, clock: testClock)
  log.record(tabDiagnostic(), level: .info)
  log.flush()

  let restored = LogBuffer(fileURL: url, clock: testClock)

  #expect(restored.snapshot.map(\.category) == [.tabs])
  #expect(
    restored.snapshot.map(\.message) == [
      "tab.measurement source=History active=Settings filedUnder=History size=832x700"
    ])
}

@Test func logBufferRewritesTheLiveTailWhenPendingStorageReachesItsBound() async {
  let url = temporaryDirectory().appendingPathComponent("logs/app.log")
  let log = LogBuffer(fileURL: url, clock: testClock, maximumFileBytes: 100_000, maximumFileCount: 2)
  for index in 0...LogBuffer.pendingCapacity { log.log("pending-\(index)") }

  log.flush()
  let retained = await log.retainedSnapshot()

  #expect(retained.count == LogBuffer.capacity)
  #expect(retained.first?.message == "pending-501")
  #expect(retained.last?.message == "pending-1000")
}

@Test func logBufferFitsARecordIntoAOneByteFile() throws {
  let url = temporaryDirectory().appendingPathComponent("logs/app.log")
  let log = LogBuffer(fileURL: url, clock: testClock, maximumFileBytes: 1, maximumFileCount: 1)
  log.log("value")

  log.flush()

  #expect(try Data(contentsOf: url) == Data("\n".utf8))
}

@Test func logBufferDoesNotSplitUTF8WhenFittingAFileRecord() throws {
  let url = temporaryDirectory().appendingPathComponent("logs/app.log")
  let entry = LogEntry(timestamp: fixedNow, level: .info, message: "é")
  let log = LogBuffer(
    fileURL: url, clock: testClock, maximumFileBytes: entry.line.utf8.count, maximumFileCount: 1)
  log.log("é")

  log.flush()
  let data = try Data(contentsOf: url)

  #expect(String(data: data, encoding: .utf8) != nil)
  #expect(data.count <= entry.line.utf8.count)
  #expect(!String(decoding: data, as: UTF8.self).contains("é"))
}

@Test func logBufferRetriesAnInitializationRewriteAfterPermissionsRecover() throws {
  let directory = temporaryDirectory().appendingPathComponent("logs")
  let url = directory.appendingPathComponent("app.log")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try Data("partial\n".utf8).write(to: url)
  try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
  defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

  let log = LogBuffer(fileURL: url, clock: testClock, maximumFileBytes: 4, maximumFileCount: 1)
  #expect(FileManager.default.fileExists(atPath: url.path))

  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  log.log("recovered")
  log.flush()

  #expect(try !String(contentsOf: url, encoding: .utf8).contains("partial"))
}

@Test func logBufferRetriesClearAfterPermissionsRecover() throws {
  let directory = temporaryDirectory().appendingPathComponent("logs")
  let url = directory.appendingPathComponent("app.log")
  let log = LogBuffer(fileURL: url, clock: testClock)
  log.log("stored")
  log.flush()
  try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
  defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

  log.clear()
  #expect(FileManager.default.fileExists(atPath: url.path))

  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  log.flush()

  #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func logBufferBoundsRequeuedEntriesWhenWritesAndLoggingOverlap() async throws {
  let directory = temporaryDirectory().appendingPathComponent("logs")
  let url = directory.appendingPathComponent("app.log")
  let longMessage = String(repeating: "x", count: 256)
  let seedBytes = LogEntry(timestamp: fixedNow, level: .info, message: "seed").line.utf8.count + 1
  let entryBytes = LogEntry(timestamp: fixedNow, level: .info, message: longMessage).line.utf8.count + 1
  let fileLimit = seedBytes + entryBytes * LogBuffer.pendingCapacity - 1
  let log = LogBuffer(
    fileURL: url, clock: testClock, maximumFileBytes: fileLimit, maximumFileCount: 2)
  log.log("seed")
  log.flush()
  for _ in 0..<LogBuffer.pendingCapacity { log.log(longMessage) }
  try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
  defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

  let flushing = Task.detached { log.flush() }
  while true {
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    if size > seedBytes { break }
    await Task.yield()
  }
  log.log("concurrent")
  await flushing.value

  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  log.flush()
  let retained = await log.retainedSnapshot()

  #expect(retained.count == LogBuffer.capacity)
  #expect(retained.last?.message == "concurrent")
}

@Test func logBufferRequeuesAWriteAfterTheStoragePathRecovers() throws {
  let parent = temporaryDirectory().appendingPathComponent("blocked")
  try Data("not a directory".utf8).write(to: parent)
  let url = parent.appendingPathComponent("app.log")
  let log = LogBuffer(fileURL: url, clock: testClock)
  log.log("survives")
  log.flush()

  try FileManager.default.removeItem(at: parent)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
  log.flush()

  #expect(try String(contentsOf: url, encoding: .utf8).contains("survives"))
}

@Test func logBufferBoundsStartupReadsToTheNewestFileTail() throws {
  let url = temporaryDirectory().appendingPathComponent("logs/app.log")
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  let lines = (0..<2_000).map { "malformed-\($0)" }.joined(separator: "\n") + "\n"
  try Data(lines.utf8).write(to: url)

  let log = LogBuffer(fileURL: url, clock: testClock, maximumFileBytes: 512, maximumFileCount: 1)

  #expect(log.snapshot.count <= LogBuffer.capacity)
  #expect(log.snapshot.last?.message == "malformed-1999")
}

@Test func retainedSnapshotLoadsRotatedLinesBeyondTheLiveCapacity() async {
  let url = temporaryDirectory().appendingPathComponent("logs/app.log")
  let log = LogBuffer(fileURL: url, clock: testClock, maximumFileBytes: 4_096, maximumFileCount: 20)
  for index in 0..<700 { log.log("retained-\(index)") }
  log.flush()

  let retained = await log.retainedSnapshot()

  #expect(log.snapshot.count == LogBuffer.capacity)
  #expect(retained.count == 700)
  #expect(retained.first?.message == "retained-0")
  #expect(retained.last?.message == "retained-699")
  #expect(retained.suffix(log.snapshot.count).map(\.sequenceID) == log.snapshot.map(\.sequenceID))
}

@Test func duplicateLogLinesReceiveDistinctSequenceIDs() {
  let log = makeLog()

  log.log("same")
  log.log("same")

  #expect(Set(log.snapshot.map(\.sequenceID)).count == 2)
}

private func tabDiagnostic() -> DiagnosticEvent {
  .tab(
    TabDiagnostic(
      action: .measurement, sourceTab: "History", activeTab: "Settings", filedUnderTab: "History",
      size: DiagnosticSize(width: 832, height: 700)))
}

private actor InvocationCounter {
  private(set) var value = 0
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func increment() {
    value += 1
    let ready = waiters.filter { value >= $0.0 }
    waiters.removeAll { value >= $0.0 }
    for (_, waiter) in ready { waiter.resume() }
  }

  func wait(for expected: Int) async {
    guard value < expected else { return }
    await withCheckedContinuation { waiters.append((expected, $0)) }
  }
}
