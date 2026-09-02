import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func claudeReaderCancelsThrottledBackgroundScan() async throws {
  let root = try backgroundScanRoot(prefix: "session")
  let reader = ClaudeTranscriptReader(root: root, workEntryBudget: 1, backgroundWorkDelay: 0.05)
  _ = await reader.refresh(now: fixedNow)
  #expect((await reader.workload).treeEntriesExamined == 1)

  await reader.cancelBackgroundWork()
  try await ContinuousClock().sleep(for: .milliseconds(100))
  let workload = await reader.workload
  #expect(workload.treeEntriesExamined == 1)
  #expect(workload.scansCompleted == 0)
}

@Test func rolloutReaderCancelsThrottledBackgroundScan() async throws {
  let root = try backgroundScanRoot(prefix: "rollout")
  let reader = CodexRolloutReader(sessionsRoot: root, workEntryBudget: 1, backgroundWorkDelay: 0.05)
  _ = await reader.latest(now: fixedNow)
  #expect((await reader.workload).treeEntriesExamined == 1)

  await reader.cancelBackgroundWork()
  try await ContinuousClock().sleep(for: .milliseconds(100))
  let workload = await reader.workload
  #expect(workload.treeEntriesExamined == 1)
  #expect(workload.searchesCompleted == 0)
}

@Test func claudeReaderCompletesASmallInitialScanBeforeThrottling() async throws {
  let root = temporaryDirectory()
  try (backgroundClaudeLine + "\n").write(
    to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(root: root, backgroundWorkDelay: 60)

  #expect(await reader.refresh(now: fixedNow).messageCount == 1)
  #expect((await reader.workload).scansCompleted == 1)
}

@Test func rolloutReaderCompletesASmallInitialScanBeforeThrottling() async throws {
  let root = temporaryDirectory()
  try (backgroundRolloutLine + "\n").write(
    to: root.appendingPathComponent("rollout-current.jsonl"), atomically: true, encoding: .utf8)
  let reader = CodexRolloutReader(sessionsRoot: root, backgroundWorkDelay: 60)

  #expect(await reader.latest(now: fixedNow)?.rateLimit.primaryWindow?.usedPercent == 7)
  #expect((await reader.workload).searchesCompleted == 1)
}

@Test func claudeBackgroundTaskStopsAfterForegroundCompletion() async throws {
  let reader = ClaudeTranscriptReader(
    root: try backgroundScanRoot(prefix: "session"), workEntryBudget: 1, backgroundWorkDelay: 0.05)
  repeat {
    _ = await reader.refresh(now: fixedNow)
  } while (await reader.workload).scansCompleted == 0

  try await ContinuousClock().sleep(for: .milliseconds(100))
  #expect((await reader.workload).scansCompleted == 1)
}

@Test func rolloutBackgroundTaskStopsAfterForegroundCompletion() async throws {
  let reader = CodexRolloutReader(
    sessionsRoot: try backgroundScanRoot(prefix: "rollout"), workEntryBudget: 1, backgroundWorkDelay: 0.05)
  repeat {
    _ = await reader.latest(now: fixedNow)
  } while (await reader.workload).searchesCompleted == 0

  try await ContinuousClock().sleep(for: .milliseconds(100))
  #expect((await reader.workload).searchesCompleted == 1)
}

@Test func newestRolloutsPacesLargeTreeScans() async throws {
  let reader = CodexRolloutReader(
    sessionsRoot: try backgroundScanRoot(prefix: "rollout"), workEntryBudget: 1, backgroundWorkDelay: 0.001)

  #expect(await reader.newestRollouts().count == CodexRolloutReader.maxFiles)
  #expect((await reader.workload).largestTreeSliceEntries == 1)
}

@Test func replacingClaudeProviderReleasesItsThrottledReader() async throws {
  var reader: ClaudeTranscriptReader? = ClaudeTranscriptReader(
    root: try backgroundScanRoot(prefix: "session"), workEntryBudget: 1, backgroundWorkDelay: 60)
  weak let retainedReader: ClaudeTranscriptReader? = reader
  var provider: ClaudeProvider? = ClaudeProvider(
    credentials: MemoryClaudeStore(validClaude), localAccountURL: nil, transcripts: reader,
    client: APIClient(transport: StubTransport(), log: makeLog(), clock: testClock), log: makeLog(),
    allowRefresh: { false })
  _ = await reader?.refresh(now: fixedNow)
  #expect(provider != nil)
  reader = nil

  provider = ClaudeProvider(
    credentials: MemoryClaudeStore(validClaude), localAccountURL: nil, transcripts: nil,
    client: APIClient(transport: StubTransport(), log: makeLog(), clock: testClock), log: makeLog(),
    allowRefresh: { false })
  #expect(retainedReader == nil)
  _ = provider
}

@Test func replacingCodexProviderReleasesItsThrottledReader() async throws {
  var reader: CodexRolloutReader? = CodexRolloutReader(
    sessionsRoot: try backgroundScanRoot(prefix: "rollout"), workEntryBudget: 1, backgroundWorkDelay: 60)
  weak let retainedReader: CodexRolloutReader? = reader
  var provider: CodexProvider? = CodexProvider(
    auth: MemoryCodexStore(validCodex), rollouts: reader,
    client: APIClient(transport: StubTransport(), log: makeLog(), clock: testClock), log: makeLog(),
    allowRefresh: { false })
  _ = await reader?.latest(now: fixedNow)
  #expect(provider != nil)
  reader = nil

  provider = CodexProvider(
    auth: MemoryCodexStore(validCodex), rollouts: nil,
    client: APIClient(transport: StubTransport(), log: makeLog(), clock: testClock), log: makeLog(),
    allowRefresh: { false })
  #expect(retainedReader == nil)
  _ = provider
}

private func backgroundScanRoot(prefix: String) throws -> URL {
  let root = temporaryDirectory()
  for index in 0..<20 {
    try Data().write(to: root.appendingPathComponent("\(prefix)-\(index).jsonl"))
  }
  return root
}

private let backgroundClaudeLine =
  #"{"type":"assistant","uuid":"uuid","requestId":"request","sessionId":"session","#
  + #""timestamp":"2026-08-29T10:00:00Z","message":{"id":"message","model":"claude-haiku-4-5","#
  + #""content":[],"usage":{"input_tokens":1,"output_tokens":0}}}"#

private let backgroundRolloutLine =
  #"{"timestamp":"2026-08-29T10:00:00Z","rate_limits":{"primary":{"used_percent":7,"window_minutes":300}}}"#
