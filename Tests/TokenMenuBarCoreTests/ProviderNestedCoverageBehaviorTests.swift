import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func nestedCoverageClaudeMoneyUsesBothDefaults() {
  let money = ClaudeAPI.MoneyDTO(amountMinor: 125, currency: nil, exponent: nil).money(defaultCurrency: "CAD")

  #expect(money == Money(amountMinor: 125, currency: "CAD", exponent: 2))
}

@Test func nestedCoverageClaudeUsageAcceptsANonobjectDocument() throws {
  let response = try decodeClaudeUsage("[]")

  #expect(response.limits.isEmpty)
  #expect(response.windows.isEmpty)
  #expect(response.spend == nil)
}

@Test func nestedCoverageClaudeMultiplierRejectsATierWithoutDigits() {
  #expect(ClaudeMapper.trailingMultiplier(in: "defaultx") == nil)
}

@Test func nestedCoverageClaudeScopedWindowUsesGenericNamesWithoutAScope() throws {
  let response = try decodeClaudeUsage(
    #"{"limits":[{"kind":"weekly_scoped","percent":2,"severity":"warning"}]}"#)

  #expect(ClaudeMapper.windows(response).map(\.id) == ["weekly:scoped"])
  #expect(ClaudeMapper.windows(response).map(\.label) == ["Scoped weekly"])
}

@Test func nestedCoverageClaudeSpendDefaultsDisabledAndReadsAutoReload() throws {
  let response = try decodeClaudeUsage(#"{"spend":{"auto_reload":{"enabled":true}}}"#)
  let spend = try #require(ClaudeMapper.spend(response, now: fixedNow))

  #expect(!spend.enabled)
  #expect(spend.autoReload == true)
}

@Test func nestedCoverageClaudeLimitNoticeUsesALaterResetWhenMissing() throws {
  let response = try decodeClaudeUsage(
    #"{"limits":[{"kind":"session","percent":100,"severity":"critical"}]}"#)

  #expect(ClaudeMapper.notices(response).map(\.text) == ["Current session limit reached; resets later."])
}

@Test func nestedCoverageClaudeProfileFallsBackToItsExpiredCache() async throws {
  let transport = NestedCoverageClaudeTransport()
  let provider = ClaudeProvider(
    credentials: MemoryClaudeStore(validClaude), localAccountURL: nil,
    client: APIClient(transport: transport, log: makeLog(), clock: testClock), log: makeLog(),
    allowRefresh: { false })

  let first = await provider.fetch(now: fixedNow, options: FetchOptions())
  let second = await provider.fetch(
    now: fixedNow.addingTimeInterval(ClaudeProvider.profileCacheInterval), options: FetchOptions())

  #expect(first.outcome.snapshot?.identity?.email == "user@example.com")
  #expect(second.outcome.snapshot?.identity?.email == "user@example.com")
  #expect(second.warnings.isEmpty)
}

@Test func nestedCoverageCodexRetriesAPendingCredentialSave() async {
  let expired = CodexAuth(
    accessToken: makeJWT(.object(["exp": .number(fixedNow.timeIntervalSince1970 - 5)])), refreshToken: "refresh")
  let store = MemoryCodexStore(expired)
  store.saveError = CredentialStoreError.keychain(-1)
  let transport = StubTransport()
  transport.on(path: "/oauth/token", .text(#"{"access_token":"fresh"}"#))
  transport.on(path: "/wham/usage", .json("codex_usage"))
  transport.on(path: "rate-limit-reset-credits", .json("codex_reset_credits"))
  let provider = codexProvider(store, transport: transport, allowRefresh: true)

  let unsaved = await provider.fetch(now: fixedNow, options: FetchOptions())
  store.saveError = nil
  let retried = await provider.fetch(now: fixedNow.addingTimeInterval(1), options: FetchOptions())

  #expect(unsaved.recoveryIssue?.kind == .credentialPersistence)
  #expect(retried.recoveryIssue == nil)
  #expect(store.saved.map(\.accessToken) == ["fresh"])
}

@Test func nestedCoverageCodexResetCreditsDefaultsEveryCount() {
  let summary = CodexAPI.ResetCreditsSummary(
    availableCount: nil, applicableAvailableCount: nil, totalEarnedCount: nil,
    immediateResetPurchaseEligible: nil)

  #expect(CodexMapper.resetCredits(summary) == ResetCredits(available: 0, applicable: 0))
}

@Test func nestedCoverageCodexTokenAnalyticsDefaultsMissingSurfaces() {
  let rows: [JSONValue] = [
    .object([
      "date": .string("2026-08-29"),
      "models": .array([.object(["model": .string("gpt"), "credits": .number(2)])]),
    ])
  ]

  #expect(
    CodexMapper.analytics(.tokenUsage, rows: rows)
      == [AnalyticsPoint(day: "2026-08-29", metric: .modelCredits, series: "gpt", value: 2)])
}

@Test func nestedCoverageCodexSkillAnalyticsDefaultsMissingSkills() {
  #expect(CodexMapper.analytics(.skills, rows: [.object(["date": .string("2026-08-29")])]).isEmpty)
}

@Test func nestedCoverageCodexPluginAnalyticsDefaultsMissingPlugins() {
  #expect(CodexMapper.analytics(.plugins, rows: [.object(["date": .string("2026-08-29")])]).isEmpty)
}

@Test func nestedCoverageCodexPluginAnalyticsSortsNames() {
  let rows: [JSONValue] = [
    .object([
      "date": .string("2026-08-29"),
      "plugin_usage_overviews": .array([
        .object(["plugin_name": .string("zeta"), "invocation_counts": .number(1)]),
        .object(["plugin_name": .string("alpha"), "invocation_counts": .number(2)]),
      ]),
    ])
  ]

  #expect(CodexMapper.analytics(.plugins, rows: rows).map(\.series) == ["alpha", "zeta"])
}

@Test func nestedCoverageCodexCreditEventDefaultsUsageAndID() {
  let rows: [JSONValue] = [.object(["date": .string("2026-08-29")])]
  let event = CodexMapper.creditEvents(rows).first

  #expect(event?.creditsUsed == 0)
  #expect(event?.service == "Codex")
  #expect(event?.id == "2026-08-29-0")
}

@Test func nestedCoverageCodexRefreshBuildsTokensForAnAPIKeyDocument() throws {
  let auth = try #require(CodexAuth(document: .object(["OPENAI_API_KEY": .string("key")])))

  #expect(
    auth.refreshed(accessToken: "fresh", refreshToken: nil, idToken: nil, now: fixedNow).accessToken == "fresh")
}

@Test func nestedCoverageLegacyTranscriptUsesAggregateFallbacksAcrossBoundaries() async throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
  let now = calendar.startOfDay(for: fixedNow).addingTimeInterval(3600)
  let todayStart = calendar.startOfDay(for: now)
  let stateURL = temporaryDirectory().appendingPathComponent("state.json")
  let recent: [String: Any] = [
    "timestamp": todayStart.addingTimeInterval(1).timeIntervalSinceReferenceDate,
    "tokens": 7,
    "cost": 0.5,
    "messages": 1,
    "firstTimestamp": todayStart.addingTimeInterval(-1).timeIntervalSinceReferenceDate,
    "lastTimestamp": now.timeIntervalSinceReferenceDate,
  ]
  try nestedCoverageTranscriptState(now: now, recent: ["minute": recent]).write(to: stateURL)
  let snapshot = await ClaudeTranscriptReader(root: temporaryDirectory(), stateURL: stateURL).refresh(now: now)

  let usage = try #require(
    snapshot.localUsage(windowResetsAt: nil, windowDuration: 1800, now: now, calendar: calendar))
  #expect(usage.windowTokens == 0)
  #expect(usage.todayTokens == 7)
}

@Test func nestedCoverageEmptyRecentTranscriptReportsZeroVelocity() async throws {
  let stateURL = temporaryDirectory().appendingPathComponent("state.json")
  try nestedCoverageTranscriptState(now: fixedNow, recent: [:]).write(to: stateURL)
  let snapshot = await ClaudeTranscriptReader(root: temporaryDirectory(), stateURL: stateURL).refresh(now: fixedNow)

  let usage = try #require(snapshot.localUsage(windowResetsAt: nil, windowDuration: 3600, now: fixedNow))
  #expect(usage.windowTokens == 0)
  #expect(usage.costPerHour == 0)
}

@Test func nestedCoverageConcurrentTranscriptRefreshesShareStateLoading() async throws {
  let stateURL = temporaryDirectory().appendingPathComponent("state.json")
  try nestedCoverageTranscriptState(now: fixedNow, recent: [:]).write(to: stateURL)
  let reader = ClaudeTranscriptReader(root: temporaryDirectory(), stateURL: stateURL)

  async let first = reader.refresh(now: fixedNow)
  async let second = reader.refresh(now: fixedNow)
  let snapshots = await (first, second)

  #expect(snapshots.0.messageCount == 1)
  #expect(snapshots.1.messageCount == 1)
}

@Test func nestedCoverageTranscriptDropsAnIndexedFileThatDisappears() async throws {
  let root = temporaryDirectory()
  let file = root.appendingPathComponent("session.jsonl")
  try (nestedCoverageClaudeLine(id: "first") + "\n").write(to: file, atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(root: root, fileScanInterval: 300)
  #expect(await reader.refresh(now: fixedNow).messageCount == 1)

  try FileManager.default.removeItem(at: file)
  #expect(await reader.refresh(now: fixedNow.addingTimeInterval(1)).messageCount == 1)
}

@Test func nestedCoverageTranscriptRereadsASameSizeReplacement() async throws {
  let root = temporaryDirectory()
  let file = root.appendingPathComponent("session.jsonl")
  try (nestedCoverageClaudeLine(id: "first") + "\n").write(to: file, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.modificationDate: fixedNow], ofItemAtPath: file.path)
  let reader = ClaudeTranscriptReader(root: root, fileScanInterval: 300)
  #expect(await reader.refresh(now: fixedNow).messageCount == 1)

  try (nestedCoverageClaudeLine(id: "other") + "\n").write(to: file, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.modificationDate: fixedNow.addingTimeInterval(1)], ofItemAtPath: file.path)
  #expect(await reader.refresh(now: fixedNow.addingTimeInterval(1)).messageCount == 2)
}

@Test func nestedCoverageTranscriptKeepsSkippingAnOversizedTailWithoutANewline() async throws {
  let root = temporaryDirectory()
  let file = root.appendingPathComponent("session.jsonl")
  try "12345".write(to: file, atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(root: root, fileScanInterval: 300, maximumLineBytes: 4)
  #expect(await reader.refresh(now: fixedNow).messageCount == 0)

  let handle = try FileHandle(forWritingTo: file)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data("6789".utf8))
  try handle.close()
  #expect(await reader.refresh(now: fixedNow.addingTimeInterval(1)).messageCount == 0)
  #expect((await reader.workload).retainedPartialFiles == 1)
}

@Test func nestedCoverageTranscriptEvictsDifferentSizedPartialTails() async throws {
  let root = temporaryDirectory()
  for (name, text) in [("a", "1"), ("b", "23"), ("c", "456")] {
    try text.write(to: root.appendingPathComponent("\(name).jsonl"), atomically: true, encoding: .utf8)
  }
  let reader = ClaudeTranscriptReader(root: root, maximumLineBytes: 4, maximumRetainedPartialBytes: 4)

  _ = await reader.refresh(now: fixedNow)
  let workload = await reader.workload
  #expect(workload.retainedPartialFiles == 2)
  #expect(workload.retainedPartialBytes <= 4)
}

@Test func nestedCoverageTranscriptEvictsEqualSizedPartialTails() async throws {
  let root = temporaryDirectory()
  for name in ["a", "b", "c", "d"] {
    try "1".write(to: root.appendingPathComponent("\(name).jsonl"), atomically: true, encoding: .utf8)
  }
  let reader = ClaudeTranscriptReader(root: root, maximumLineBytes: 1, maximumRetainedPartialBytes: 3)

  _ = await reader.refresh(now: fixedNow)
  let workload = await reader.workload
  #expect(workload.retainedPartialFiles == 3)
  #expect(workload.retainedPartialBytes == 3)
}

@Test func nestedCoverageTranscriptHandlesAReadFailure() async throws {
  let root = temporaryDirectory()
  try "mock".write(to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
  let failure = NestedCoverageReadFailure()
  let reader = ClaudeTranscriptReader(root: root, readChunk: failure.read)

  let snapshot = await reader.refresh(now: fixedNow)

  #expect(snapshot.messageCount == 0)
  #expect(failure.count == 1)
  #expect((await reader.workload).filesOpened == 1)
}

@Test func nestedCoverageTranscriptCheckpointsAfterCrossingItsByteThreshold() async throws {
  let root = temporaryDirectory()
  let file = root.appendingPathComponent("session.jsonl")
  let stateURL = temporaryDirectory().appendingPathComponent("state.json")
  try (nestedCoverageClaudeLine(id: "first") + "\n").write(to: file, atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(
    root: root, stateURL: stateURL, fileScanInterval: 300, checkpointInterval: 300, maximumCheckpointBytes: 1)
  _ = await reader.refresh(now: fixedNow)

  let handle = try FileHandle(forWritingTo: file)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((nestedCoverageClaudeLine(id: "other") + "\n").utf8))
  try handle.close()
  _ = await reader.refresh(now: fixedNow.addingTimeInterval(1))

  #expect((await reader.workload).checkpoints == 2)
}

@Test func nestedCoverageTranscriptKeepsAnIncompleteIndexedTailAcrossRefreshes() async throws {
  let root = temporaryDirectory()
  let file = root.appendingPathComponent("session.jsonl")
  try Data().write(to: file)
  let reader = ClaudeTranscriptReader(
    root: root, fileScanInterval: 300, workByteBudget: 4, backgroundWorkDelay: 60)
  _ = await reader.refresh(now: fixedNow)

  try (nestedCoverageClaudeLine(id: "later") + "\n").write(to: file, atomically: true, encoding: .utf8)
  _ = await reader.refresh(now: fixedNow.addingTimeInterval(1))
  let snapshot = await reader.refresh(now: fixedNow.addingTimeInterval(2))

  #expect(snapshot.messageCount == 0)
  #expect((await reader.workload).bytesRead == 8)
  #expect((await reader.workload).retainedPartialFiles == 1)
}

@Test func nestedCoverageTranscriptContinuesAnIncompleteColdScanFile() async throws {
  let root = temporaryDirectory()
  try (nestedCoverageClaudeLine(id: "slow") + "\n").write(
    to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(root: root, workByteBudget: 1, backgroundWorkDelay: 60)

  _ = await reader.refresh(now: fixedNow)
  let snapshot = await reader.refresh(now: fixedNow.addingTimeInterval(1))

  #expect(snapshot.messageCount == 0)
  #expect((await reader.workload).bytesRead == 2)
  #expect((await reader.workload).scansCompleted == 0)
}

@Test func nestedCoverageTranscriptSkipsAFileThatCannotBeOpened() async throws {
  let root = temporaryDirectory()
  let file = root.appendingPathComponent("session.jsonl")
  try (nestedCoverageClaudeLine(id: "unreadable") + "\n").write(
    to: file, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
  defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

  let reader = ClaudeTranscriptReader(root: root)
  #expect(await reader.refresh(now: fixedNow).messageCount == 0)
  #expect((await reader.workload).filesOpened == 0)
  #expect((await reader.workload).scansCompleted == 1)
}

@Test func nestedCoverageTranscriptDefersANonurgentCheckpoint() async throws {
  let root = temporaryDirectory()
  let file = root.appendingPathComponent("session.jsonl")
  let stateURL = temporaryDirectory().appendingPathComponent("state.json")
  try (nestedCoverageClaudeLine(id: "first") + "\n").write(to: file, atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(
    root: root, stateURL: stateURL, fileScanInterval: 300, checkpointInterval: 300)
  _ = await reader.refresh(now: fixedNow)

  let handle = try FileHandle(forWritingTo: file)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((nestedCoverageClaudeLine(id: "second") + "\n").utf8))
  try handle.close()
  let snapshot = await reader.refresh(now: fixedNow.addingTimeInterval(1))

  #expect(snapshot.messageCount == 2)
  #expect((await reader.workload).checkpoints == 1)
}

@Test func nestedCoverageTranscriptCoalescesConcurrentCheckpoints() async throws {
  let root = temporaryDirectory()
  let stateURL = temporaryDirectory().appendingPathComponent("state.json")
  let reader = ClaudeTranscriptReader(root: root, stateURL: stateURL, fileScanInterval: 0, workTimeBudget: 2)
  _ = await reader.refresh(now: fixedNow)
  try ((0..<1_000).map { nestedCoverageClaudeLine(id: "message-\($0)") }.joined(separator: "\n") + "\n")
    .write(to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

  async let first = reader.refresh(now: fixedNow.addingTimeInterval(1))
  async let second = reader.refresh(now: fixedNow.addingTimeInterval(1))
  let snapshots = await (first, second)

  #expect(snapshots.0.messageCount == 1_000)
  #expect(snapshots.1.messageCount == 1_000)
  #expect((await reader.workload).checkpointAttempts == 1)
}

@Test func nestedCoverageRolloutResortsRefreshedCandidates() async throws {
  let root = temporaryDirectory()
  let first = root.appendingPathComponent("rollout-first.jsonl")
  let second = root.appendingPathComponent("rollout-second.jsonl")
  try (nestedCoverageRolloutLine(percent: 10) + "\n").write(to: first, atomically: true, encoding: .utf8)
  try (nestedCoverageRolloutLine(percent: 20) + "\n").write(to: second, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.modificationDate: fixedNow], ofItemAtPath: first.path)
  try FileManager.default.setAttributes(
    [.modificationDate: fixedNow.addingTimeInterval(-10)], ofItemAtPath: second.path)
  let reader = CodexRolloutReader(sessionsRoot: root, cacheInterval: 300)
  #expect(await reader.latest(now: fixedNow)?.rateLimit.primaryWindow?.usedPercent == 10)

  try FileManager.default.setAttributes(
    [.modificationDate: fixedNow.addingTimeInterval(10)], ofItemAtPath: second.path)
  #expect(await reader.latest(now: fixedNow.addingTimeInterval(1))?.rateLimit.primaryWindow?.usedPercent == 20)
}

@Test func nestedCoverageCancelledNewestRolloutsReturnNoPartialTree() async throws {
  let root = temporaryDirectory()
  for index in 0..<20 {
    try Data().write(to: root.appendingPathComponent("rollout-\(index).jsonl"))
  }
  let reader = CodexRolloutReader(
    sessionsRoot: root, workEntryBudget: 1, backgroundWorkDelay: 0.05)
  let task = Task { await reader.newestRollouts() }
  while (await reader.workload).treeEntriesExamined == 0 { await Task.yield() }

  task.cancel()
  #expect(await task.value.isEmpty)
}

private func decodeClaudeUsage(_ text: String) throws -> ClaudeAPI.UsageResponse {
  try JSONDecoder().decode(ClaudeAPI.UsageResponse.self, from: Data(text.utf8))
}

private func nestedCoverageTranscriptState(now: Date, recent: [String: Any]) throws -> Data {
  let day = DayStamp.string(now)
  return try JSONSerialization.data(withJSONObject: [
    "offsets": [:],
    "seenByDay": [day: ["message"]],
    "days": [day: ["models": [:], "messages": 1, "sessions": ["session"], "toolCalls": 0]],
    "recent": recent,
  ])
}

private func nestedCoverageClaudeLine(id: String) -> String {
  #"{"type":"assistant","uuid":"uuid-\#(id)","requestId":"request","sessionId":"session","#
    + #""timestamp":"2026-08-29T10:00:00Z","message":{"id":"\#(id)","model":"claude-haiku-4-5","#
    + #""content":[],"usage":{"input_tokens":1,"output_tokens":0}}}"#
}

private func nestedCoverageRolloutLine(percent: Int) -> String {
  #"{"timestamp":"2026-08-29T10:00:00Z","rate_limits":{"primary":{"used_percent":\#(percent),"#
    + #""window_minutes":300}}}"#
}

private final class NestedCoverageReadFailure: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0

  var count: Int { lock.withLock { calls } }

  func read(_ handle: FileHandle, count: Int) throws -> Data? {
    lock.withLock { calls += 1 }
    throw CocoaError(.fileReadUnknown)
  }
}

private final class NestedCoverageClaudeTransport: HTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var profiles = 0

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    if request.url?.path.hasSuffix("/profile") == true {
      let attempt = lock.withLock {
        profiles += 1
        return profiles
      }
      if attempt > 1 { throw URLError(.notConnectedToInternet) }
      return response(Fixtures.data("claude_profile"), for: request)
    }
    return response(Fixtures.data("claude_usage"), for: request)
  }

  private func response(_ data: Data, for request: URLRequest) -> (Data, URLResponse) {
    (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
