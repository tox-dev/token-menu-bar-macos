import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

@Test(arguments: [true, false])
func transcriptReaderRewindsWhenAFileIsTruncated(relaunch: Bool) async throws {
  let root = try transcriptRoot()
  let file = root.appendingPathComponent("session.jsonl")
  try (line(id: "first-long-identifier", at: fixedNow.addingTimeInterval(-60)) + "\n").write(
    to: file, atomically: true, encoding: .utf8)
  let stateURL = root.deletingLastPathComponent().appendingPathComponent("offsets.json")
  let reader = ClaudeTranscriptReader(root: root.deletingLastPathComponent(), stateURL: stateURL, checkpointInterval: 0)
  #expect(await reader.refresh(now: fixedNow).messageCount == 1)
  while (await reader.workload).checkpoints == 0 { await Task.yield() }
  try (line(id: "next", at: fixedNow) + "\n").write(to: file, atomically: true, encoding: .utf8)
  let resumed = relaunch ? ClaudeTranscriptReader(root: root.deletingLastPathComponent(), stateURL: stateURL) : reader
  #expect(await resumed.refresh(now: fixedNow.addingTimeInterval(1)).messageCount == 2)
}

@Test func transcriptReaderParsesIncrementallyAndDedupes() async throws {
  let root = try transcriptRoot()
  let file = root.appendingPathComponent("session.jsonl")
  let first = line(id: "m1", at: fixedNow.addingTimeInterval(-3600))
  try
    (first + "\n" + line(id: "m1", at: fixedNow.addingTimeInterval(-3600)) + "\n" + #"{"type":"user","message":{}}"#
    + "\n").write(to: file, atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(root: root.deletingLastPathComponent())
  var snapshot = await reader.refresh(now: fixedNow)
  #expect(snapshot.messageCount == 1)
  #expect(snapshot.localUsage(windowResetsAt: nil, windowDuration: 7200, now: fixedNow)?.windowTokens == 100)
  let handle = try FileHandle(forWritingTo: file)
  try handle.seekToEnd()
  try handle.write(
    contentsOf: Data((line(id: "m2", at: fixedNow.addingTimeInterval(-60), tools: 0) + "\n" + "partial").utf8))
  try handle.close()
  snapshot = await reader.refresh(now: fixedNow)
  #expect(snapshot.messageCount == 2)
  #expect(snapshot.analytics(now: fixedNow)?.points.first { $0.metric == .messages }?.value == 2)
  snapshot = await reader.refresh(now: fixedNow)
  #expect(snapshot.messageCount == 2)
  let ancient = line(id: "old", at: fixedNow.addingTimeInterval(-90 * 86400))
  try (ancient + "\n").write(to: root.appendingPathComponent("old.jsonl"), atomically: true, encoding: .utf8)
  snapshot = await reader.refresh(now: fixedNow)
  #expect(snapshot.messageCount == 2)
  #expect(
    await ClaudeTranscriptReader(root: root.appendingPathComponent("missing")).refresh(now: fixedNow).messageCount == 0)
}

@Test func transcriptReaderResumesWhereTheLastRunStopped() async throws {
  let root = try transcriptRoot()
  let file = root.appendingPathComponent("session.jsonl")
  let state = root.deletingLastPathComponent().appendingPathComponent("offsets.json")
  try (line(id: "m1", at: fixedNow.addingTimeInterval(-3600)) + "\n").write(
    to: file, atomically: true, encoding: .utf8)
  let first = ClaudeTranscriptReader(root: root.deletingLastPathComponent(), stateURL: state)
  #expect(await first.refresh(now: fixedNow).messageCount == 1)

  let resumed = ClaudeTranscriptReader(root: root.deletingLastPathComponent(), stateURL: state)
  #expect(await resumed.refresh(now: fixedNow).messageCount == 1)
  let handle = try FileHandle(forWritingTo: file)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((line(id: "m2", at: fixedNow.addingTimeInterval(-60)) + "\n").utf8))
  try handle.close()
  #expect(await resumed.refresh(now: fixedNow).messageCount == 2)
  #expect(
    await resumed.refresh(now: fixedNow).localUsage(windowResetsAt: nil, windowDuration: 7200, now: fixedNow)?
      .windowTokens == 200)

  // Without a state file every reader starts from the beginning.
  let cold = ClaudeTranscriptReader(root: root.deletingLastPathComponent())
  #expect(await cold.refresh(now: fixedNow).messageCount == 2)
}

@Test func transcriptReaderPersistsExpandedRetentionAcrossLaunches() async throws {
  let root = try transcriptRoot()
  let file = root.appendingPathComponent("session.jsonl")
  let state = root.deletingLastPathComponent().appendingPathComponent("offsets.json")
  try (line(id: "m1", at: fixedNow.addingTimeInterval(-90 * 86400)) + "\n").write(
    to: file, atomically: true, encoding: .utf8)
  let first = ClaudeTranscriptReader(root: root.deletingLastPathComponent(), stateURL: state)
  #expect(await first.refresh(now: fixedNow, retentionDays: 365).messageCount == 1)
  #expect((await first.workload).bytesRead > 0)

  let resumed = ClaudeTranscriptReader(root: root.deletingLastPathComponent(), stateURL: state)
  #expect(await resumed.refresh(now: fixedNow, retentionDays: 365).messageCount == 1)
  #expect((await resumed.workload).bytesRead == 0)
}

@Test func transcriptReaderAppliesAndExpandsConfiguredRetention() async throws {
  let root = try transcriptRoot()
  let file = root.appendingPathComponent("retention.jsonl")
  try
    ([
      line(id: "recent", at: fixedNow.addingTimeInterval(-5 * 86400)),
      line(id: "month", at: fixedNow.addingTimeInterval(-30 * 86400)),
      line(id: "quarter", at: fixedNow.addingTimeInterval(-90 * 86400)),
    ].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.modificationDate: fixedNow], ofItemAtPath: file.path)
  let reader = ClaudeTranscriptReader(root: root.deletingLastPathComponent())

  #expect(await reader.refresh(now: fixedNow, retentionDays: 60).messageCount == 2)
  #expect(await reader.refresh(now: fixedNow, retentionDays: 7).messageCount == 1)
  #expect(await reader.refresh(now: fixedNow, retentionDays: 365).messageCount == 3)
}

@Test func transcriptReaderLoadsLegacyIntegerOffsets() async throws {
  let root = try transcriptRoot()
  let file = root.appendingPathComponent("session.jsonl")
  let transcript = line(id: "already-read", at: fixedNow) + "\n"
  try transcript.write(to: file, atomically: true, encoding: .utf8)
  let stateURL = root.deletingLastPathComponent().appendingPathComponent("legacy-state.json")
  let enumerator = try #require(
    FileManager.default.enumerator(at: root.deletingLastPathComponent(), includingPropertiesForKeys: nil))
  let enumeratedPath = try #require(
    (enumerator.allObjects as? [URL])?.first { $0.lastPathComponent == file.lastPathComponent }
  ).path
  let state: [String: Any] = [
    "offsets": [enumeratedPath: transcript.utf8.count],
    "seenByDay": [String: [String]](),
    "days": [String: Any](),
    "recent": [String: Any](),
  ]
  try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
  let reader = ClaudeTranscriptReader(root: root.deletingLastPathComponent(), stateURL: stateURL)
  #expect(await reader.refresh(now: fixedNow).messageCount == 1)
}

@Test func transcriptReaderIndexesTheTreePeriodicallyButTailsKnownFiles() async throws {
  let root = try transcriptRoot()
  let first = root.appendingPathComponent("first.jsonl")
  try (line(id: "m1", at: fixedNow) + "\n").write(to: first, atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(
    root: root.deletingLastPathComponent(), fileScanInterval: 300)
  #expect(await reader.refresh(now: fixedNow).messageCount == 1)

  let handle = try FileHandle(forWritingTo: first)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((line(id: "m2", at: fixedNow) + "\n").utf8))
  try handle.close()
  let second = root.appendingPathComponent("second.jsonl")
  try (line(id: "m3", at: fixedNow) + "\n").write(to: second, atomically: true, encoding: .utf8)

  #expect(await reader.refresh(now: fixedNow.addingTimeInterval(60)).messageCount == 2)
  #expect(await reader.refresh(now: fixedNow.addingTimeInterval(301)).messageCount == 3)
}

@Test func transcriptReaderBoundsTheFilesTailedBetweenTreeScans() async throws {
  let root = try transcriptRoot()
  for index in 0...ClaudeTranscriptReader.maxIndexedFiles {
    let file = root.appendingPathComponent("session-\(index).jsonl")
    try (line(id: "m\(index)", at: fixedNow) + "\n").write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.modificationDate: fixedNow.addingTimeInterval(Double(index - ClaudeTranscriptReader.maxIndexedFiles))],
      ofItemAtPath: file.path)
  }
  let reader = ClaudeTranscriptReader(root: root.deletingLastPathComponent(), fileScanInterval: 300)
  _ = await reader.refresh(now: fixedNow)
  await waitForTranscriptScan(reader)
  #expect(await reader.refresh(now: fixedNow).messageCount == ClaudeTranscriptReader.maxIndexedFiles + 1)

  for (index, id) in [(0, "excluded"), (ClaudeTranscriptReader.maxIndexedFiles, "indexed")] {
    let handle = try FileHandle(forWritingTo: root.appendingPathComponent("session-\(index).jsonl"))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line(id: id, at: fixedNow) + "\n").utf8))
    try handle.close()
  }
  #expect(await reader.refresh(now: fixedNow.addingTimeInterval(60)).messageCount == 66)
  #expect(await reader.refresh(now: fixedNow.addingTimeInterval(301)).messageCount == 67)
}

@Test func transcriptReaderIgnoresJsonlDirectories() async throws {
  let root = try transcriptRoot()
  try FileManager.default.createDirectory(
    at: root.appendingPathComponent("broken.jsonl"), withIntermediateDirectories: true)
  try (line(id: "m1", at: fixedNow) + "\n").write(
    to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

  let snapshot = await ClaudeTranscriptReader(root: root.deletingLastPathComponent()).refresh(now: fixedNow)
  #expect(snapshot.messageCount == 1)
}

@Test func emptyTranscriptSnapshotHasNoDerivedUsage() async {
  let snapshot = await ClaudeTranscriptReader(root: temporaryDirectory()).refresh(now: fixedNow)
  #expect(snapshot.analytics(now: fixedNow) == nil)
  #expect(snapshot.localUsage(windowResetsAt: nil, windowDuration: 3600, now: fixedNow) == nil)
}

@Test func transcriptReaderCompletesASplitRecordAfterAppend() async throws {
  let root = try transcriptRoot()
  let file = root.appendingPathComponent("session.jsonl")
  let record = line(id: "split", at: fixedNow)
  let split = record.index(record.startIndex, offsetBy: record.count / 2)
  try String(record[..<split]).write(to: file, atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(root: root.deletingLastPathComponent())
  #expect(await reader.refresh(now: fixedNow).messageCount == 0)

  let handle = try FileHandle(forWritingTo: file)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((String(record[split...]) + "\n").utf8))
  try handle.close()
  #expect(await reader.refresh(now: fixedNow).messageCount == 1)
}

@Test func transcriptReaderResetsItsCursorAfterTruncation() async throws {
  let root = try transcriptRoot()
  let file = root.appendingPathComponent("session.jsonl")
  try (line(id: "first-long-id", at: fixedNow) + "\n").write(to: file, atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(root: root.deletingLastPathComponent())
  #expect(await reader.refresh(now: fixedNow).messageCount == 1)
  try (line(id: "b", at: fixedNow) + "\n").write(to: file, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.modificationDate: fixedNow.addingTimeInterval(1)], ofItemAtPath: file.path)
  #expect(await reader.refresh(now: fixedNow.addingTimeInterval(60)).messageCount == 2)
}

@Test func transcriptReaderKeepsExactUsageAtAMinuteBoundary() async throws {
  let root = try transcriptRoot()
  try
    ([
      line(id: "before", at: fixedNow.addingTimeInterval(-50)), line(id: "after", at: fixedNow.addingTimeInterval(-20)),
    ]
    .joined(separator: "\n") + "\n").write(
      to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
  let snapshot = await ClaudeTranscriptReader(root: root.deletingLastPathComponent()).refresh(now: fixedNow)
  #expect(snapshot.localUsage(windowResetsAt: nil, windowDuration: 30, now: fixedNow)?.windowTokens == 100)
}

@Test func transcriptReaderFinishesAColdTreeOutsideTheProviderPoll() async throws {
  let root = try transcriptRoot()
  for index in 0..<300 {
    try (line(id: "m\(index)", at: fixedNow) + "\n").write(
      to: root.appendingPathComponent("session-\(index).jsonl"), atomically: true, encoding: .utf8)
  }
  let reader = ClaudeTranscriptReader(
    root: root.deletingLastPathComponent(), workByteBudget: 1024, workEntryBudget: 4, backgroundWorkDelay: 0.001)
  _ = await reader.refresh(now: fixedNow)
  await waitForTranscriptScan(reader)
  #expect(await reader.refresh(now: fixedNow).messageCount == 300)
  let workload = await reader.workload
  #expect(workload.largestSliceBytesRead <= 1024)
  #expect(workload.largestSliceEntriesExamined <= 4)
}

@Test func transcriptReaderResumesBackgroundWorkAfterAForegroundScanFinishes() async throws {
  let root = try transcriptRoot()
  try (line(id: "m1", at: fixedNow) + "\n").write(
    to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(
    root: root.deletingLastPathComponent(), workEntryBudget: 1, backgroundWorkDelay: 0.1,
    powerState: { PowerState(lowPowerMode: false, thermalPressure: false) })

  _ = await reader.refresh(now: fixedNow)
  #expect((await reader.workload).scansCompleted == 0)
  for _ in 0..<10 where (await reader.workload).scansCompleted == 0 {
    _ = await reader.refresh(now: fixedNow)
  }
  #expect((await reader.workload).scansCompleted == 1)

  let next = fixedNow.addingTimeInterval(ClaudeTranscriptReader.defaultFileScanInterval)
  _ = await reader.refresh(now: next)
  await waitForTranscriptScan(reader, count: 2)

  #expect((await reader.workload).scansCompleted == 2)
  #expect(await reader.refresh(now: next).messageCount == 1)
}

@Test func transcriptReaderDoesNotReopenUnchangedFiles() async throws {
  let root = try transcriptRoot()
  try (line(id: "m1", at: fixedNow) + "\n").write(
    to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(root: root.deletingLastPathComponent(), fileScanInterval: 300)
  _ = await reader.refresh(now: fixedNow)
  await waitForTranscriptScan(reader)
  let first = await reader.workload
  _ = await reader.refresh(now: fixedNow.addingTimeInterval(60))
  let second = await reader.workload
  #expect(second.filesOpened == first.filesOpened)
  #expect(second.bytesRead == first.bytesRead)
}

@Test func transcriptReaderCheckpointIsSmallerThanTheTranscript() async throws {
  let root = try transcriptRoot()
  let stateURL = root.deletingLastPathComponent().appendingPathComponent("state.json")
  let transcript = (0..<1_000).map { line(id: "m\($0)", at: fixedNow) }.joined(separator: "\n") + "\n"
  try transcript.write(to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(
    root: root.deletingLastPathComponent(), stateURL: stateURL, workTimeBudget: 2)
  #expect(await reader.refresh(now: fixedNow).messageCount == 1_000)
  let workload = await reader.workload
  #expect(workload.checkpoints == 1)
  #expect(workload.lastCheckpointBytes > 0)
  #expect(workload.lastCheckpointBytes < transcript.utf8.count)
}

@Test func transcriptReaderBacksOffAfterCheckpointFailure() async throws {
  let root = try transcriptRoot()
  let parent = root.deletingLastPathComponent().appendingPathComponent("file")
  try Data().write(to: parent)
  try (line(id: "m1", at: fixedNow) + "\n").write(
    to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(
    root: root.deletingLastPathComponent(), stateURL: parent.appendingPathComponent("state.json"),
    maximumCheckpointBytes: 1)
  _ = await reader.refresh(now: fixedNow)
  #expect((await reader.workload).checkpointAttempts == 1)
  _ = await reader.refresh(now: fixedNow.addingTimeInterval(0.5))
  #expect((await reader.workload).checkpointAttempts == 1)
  _ = await reader.refresh(now: fixedNow.addingTimeInterval(61))
  #expect((await reader.workload).checkpointAttempts == 2)
}

@Test func transcriptReaderBoundsUnterminatedColdTails() async throws {
  let root = try transcriptRoot()
  for index in 0..<200 {
    try String(repeating: "x", count: 1_024).write(
      to: root.appendingPathComponent("session-\(index).jsonl"), atomically: true, encoding: .utf8)
  }
  let reader = ClaudeTranscriptReader(
    root: root.deletingLastPathComponent(), workByteBudget: 4_096, workEntryBudget: 8)
  _ = await reader.refresh(now: fixedNow)
  await waitForTranscriptScan(reader)
  let workload = await reader.workload
  #expect(workload.retainedPartialFiles <= ClaudeTranscriptReader.maxIndexedFiles)
  #expect(workload.retainedPartialBytes <= ClaudeTranscriptReader.maxIndexedFiles * 1_024)
}

@Test(arguments: [64 * 1024, ClaudeTranscriptReader.defaultWorkByteBudget])
func transcriptReaderReleasesCompletedLineStorageBeforeRetainingATail(byteBudget: Int) async throws {
  let root = try transcriptRoot()
  let complete = String(repeating: "x", count: 1_048_576)
  try (complete + "\nnext").write(
    to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(
    root: root.deletingLastPathComponent(), workByteBudget: byteBudget, maximumLineBytes: complete.utf8.count + 1)
  _ = await reader.refresh(now: fixedNow)
  await waitForTranscriptScan(reader)
  let workload = await reader.workload
  #expect(workload.retainedPartialFiles == 1)
  #expect(workload.retainedPartialBytes == 4)
}

@Test func transcriptReaderStopsAfterAFileShrinksDuringARead() async throws {
  let root = try transcriptRoot()
  let file = root.appendingPathComponent("session.jsonl")
  try String(repeating: "x", count: 1_048_576).write(to: file, atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(root: root.deletingLastPathComponent(), workByteBudget: 1)
  _ = await reader.refresh(now: fixedNow)
  try Data().write(to: file, options: .atomic)
  await waitForTranscriptScan(reader)
  #expect((await reader.workload).scansCompleted == 1)
}

@Test func transcriptReaderRestartsFromZeroAfterSeekFailure() async throws {
  let root = try transcriptRoot()
  let file = root.appendingPathComponent("session.jsonl")
  let state = root.deletingLastPathComponent().appendingPathComponent("offsets.json")
  try (line(id: "m1", at: fixedNow) + "\n").write(to: file, atomically: true, encoding: .utf8)
  #expect(
    await ClaudeTranscriptReader(root: root.deletingLastPathComponent(), stateURL: state).refresh(now: fixedNow)
      .messageCount == 1)
  let handle = try FileHandle(forWritingTo: file)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((line(id: "m2", at: fixedNow) + "\n").utf8))
  try handle.close()

  let seek = FailingFirstTranscriptSeek()
  let resumed = ClaudeTranscriptReader(
    root: root.deletingLastPathComponent(), stateURL: state, backgroundWorkDelay: 60, seek: seek.call)
  #expect(await resumed.refresh(now: fixedNow).messageCount == 1)
  #expect(await resumed.refresh(now: fixedNow).messageCount == 2)
  #expect(seek.callCount == 2)
}

@Test func transcriptReaderIgnoresDirectoriesBeforeChoosingHotFiles() async throws {
  let root = try transcriptRoot()
  for index in 0...ClaudeTranscriptReader.maxIndexedFiles {
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("fake-\(index).jsonl"), withIntermediateDirectories: true)
  }
  try (line(id: "m1", at: fixedNow) + "\n").write(
    to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
  #expect(await ClaudeTranscriptReader(root: root.deletingLastPathComponent()).refresh(now: fixedNow).messageCount == 1)
}

@Test func transcriptReaderBreaksEqualModificationDatesByPath() async throws {
  let root = try transcriptRoot()
  for index in 0...ClaudeTranscriptReader.maxIndexedFiles {
    let file = root.appendingPathComponent(String(format: "session-%03d.jsonl", index))
    try (line(id: "m\(index)", at: fixedNow) + "\n").write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: fixedNow], ofItemAtPath: file.path)
  }
  let reader = ClaudeTranscriptReader(root: root.deletingLastPathComponent(), fileScanInterval: 300)
  _ = await reader.refresh(now: fixedNow)
  await waitForTranscriptScan(reader)
  #expect(await reader.refresh(now: fixedNow).messageCount == ClaudeTranscriptReader.maxIndexedFiles + 1)
  for (index, id) in [(0, "indexed"), (ClaudeTranscriptReader.maxIndexedFiles, "excluded")] {
    let file = root.appendingPathComponent(String(format: "session-%03d.jsonl", index))
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line(id: id, at: fixedNow) + "\n").utf8))
    try handle.close()
  }
  #expect(await reader.refresh(now: fixedNow.addingTimeInterval(60)).messageCount == 66)
}

private func waitForTranscriptScan(_ reader: ClaudeTranscriptReader, count: Int = 1) async {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(30))
  while clock.now < deadline {
    if (await reader.workload).scansCompleted >= count { return }
    await Task.yield()
  }
  Issue.record("Transcript scan did not finish")
}

private func line(
  id: String, request: String = "req", at: Date, model: String = "claude-opus-5", session: String = "s1",
  input: Int = 10,
  output: Int = 20, cacheWrite: Int = 30, cacheRead: Int = 40, tools: Int = 1, costUSD: Double? = nil
) -> String {
  let content = (0..<tools).map { _ in #"{"type":"tool_use","name":"Bash"}"# } + [#"{"type":"text","text":"hi"}"#]
  let cost = costUSD.map { #""costUSD":\#($0),"# } ?? ""
  return #"{"type":"assistant","uuid":"u-\#(id)","requestId":"\#(request)","sessionId":"\#(session)","#
    + #""timestamp":"\#(ISODate.string(at))",\#(cost)"message":{"id":"\#(id)","model":"\#(model)","#
    + #""content":[\#(content.joined(separator: ","))],"usage":{"input_tokens":\#(input),"#
    + #""output_tokens":\#(output),"cache_creation_input_tokens":\#(cacheWrite),"#
    + #""cache_read_input_tokens":\#(cacheRead)}}}"#
}

private func transcriptRoot() throws -> URL {
  let root = temporaryDirectory().appendingPathComponent("projects/-Users-me-repo")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

private final class FailingFirstTranscriptSeek: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0

  var callCount: Int {
    lock.withLock { calls }
  }

  func call(_ handle: FileHandle, _ offset: UInt64) throws {
    try lock.withLock {
      calls += 1
      if calls == 1 { throw CocoaError(.fileReadUnknown) }
    }
    try handle.seek(toOffset: offset)
  }
}

@Test func transcriptParseRejectsIncompleteRecords() {
  #expect(ClaudeTranscriptReader.parse(line: Data("{".utf8)) == nil)
  #expect(ClaudeTranscriptReader.parse(line: Data(#"{"type":"user","message":{"usage":{}}}"#.utf8)) == nil)
  #expect(
    ClaudeTranscriptReader.parse(line: Data(#"{"type":"assistant","message":{"usage":{},"model":"m"}}"#.utf8)) == nil)
  let minimal = ClaudeTranscriptReader.parse(
    line: Data(
      #"{"type":"assistant","timestamp":"2026-08-29T10:00:00Z","message":{"usage":{},"model":"claude-sonnet-4-6"}}"#
        .utf8))!
  #expect(minimal.id == ":")
  #expect(minimal.usage == TokenUsage())
  #expect(minimal.toolCalls == 0)
  #expect(minimal.cost == 0)
}

private let millionOfEach = TokenUsage(
  input: 1_000_000, output: 1_000_000, cacheWrite: 1_000_000, cacheRead: 1_000_000)

@Test(arguments: [
  ("claude-opus-5", 36.75), ("claude-haiku-4-5-20251001", 7.35), ("claude-sonnet-4-6", 22.05),
  ("Claude-Sonnet-5", 14.7), ("claude-fable-5-1", 72.75),
])
func pricingMatchesTheLongestModelIdPrefix(model: String, cost: Double) {
  #expect(ClaudePricing.cost(millionOfEach, model: model) == cost)
}

@Test(arguments: ["claude-opus-6", "claude-opus-4-1-20250805"])
func pricingFallsBackToTheNewestEntryOfTheSameFamily(model: String) {
  #expect(ClaudePricing.price(for: model) == ClaudePricing.perMillion["claude-opus-5"])
}

@Test(arguments: ["gpt-5", "unknown", "claude-zeta-1", "claude"])
func pricingHasNoEntryOutsideKnownFamilies(model: String) {
  #expect(ClaudePricing.price(for: model) == nil)
  #expect(ClaudePricing.cost(millionOfEach, model: model) == 0)
}

@Test func pricingTreatsMythosLikeFable() {
  #expect(ClaudePricing.price(for: "claude-fable-5") == ClaudePricing.price(for: "claude-mythos-5"))
  #expect(ClaudePricing.price(for: "claude-fable-5-1") == ClaudePricing.price(for: "claude-mythos-5-1"))
}

@Test func transcriptMessagePrefersTheCostClaudeCodeWrote() throws {
  let parsed = try #require(
    ClaudeTranscriptReader.parse(line: Data(line(id: "m", at: fixedNow, model: "claude-zeta-1", costUSD: 0.42).utf8)))
  #expect(parsed.reportedCost == 0.42)
  #expect(parsed.cost == 0.42)
  #expect(!parsed.isCostEstimated)
  let priced = try #require(ClaudeTranscriptReader.parse(line: Data(line(id: "m", at: fixedNow, costUSD: 0.42).utf8)))
  #expect(priced.cost == 0.42)
  let unpriced = try #require(
    ClaudeTranscriptReader.parse(line: Data(line(id: "m", at: fixedNow, model: "claude-zeta-1").utf8)))
  #expect(unpriced.reportedCost == nil)
  #expect(unpriced.cost == 0)
  #expect(unpriced.isCostEstimated)
}

@Test func transcriptReaderWarnsOncePerRunAboutModelsThePricingTableLacks() async throws {
  let root = try transcriptRoot()
  try
    ([
      line(id: "estimated", at: fixedNow, model: "claude-zeta-1"),
      line(id: "reported", at: fixedNow, model: "claude-omega-2", costUSD: 1.5), line(id: "known", at: fixedNow),
    ].joined(separator: "\n") + "\n").write(
      to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(root: root.deletingLastPathComponent())
  let first = await reader.refresh(now: fixedNow)
  #expect(first.unpricedModels == ["claude-zeta-1"])
  #expect(first.pricingWarnings == ["Cost for claude-zeta-1 is estimated; the pricing table has no entry"])
  let costs = first.analytics(now: fixedNow)?.points.filter { $0.metric == .costUSD }
  #expect(costs?.first { $0.series == "claude-omega-2" }?.value == 1.5)
  #expect(costs?.first { $0.series == "claude-zeta-1" }?.value == 0)
  #expect(costs?.first { $0.series == "claude-opus-5" }?.value == 0.000_757_5)
  #expect(first.localUsage(windowResetsAt: nil, windowDuration: 3600, now: fixedNow)?.windowCost == 1.500_757_5)
  let second = await reader.refresh(now: fixedNow.addingTimeInterval(60))
  #expect(second.unpricedModels.isEmpty)
  #expect(second.pricingWarnings.isEmpty)
}

@Test func transcriptReaderRemembersUnpricedModelsAcrossLaunchesButWarnsAgainPerRun() async throws {
  let root = try transcriptRoot()
  let state = root.deletingLastPathComponent().appendingPathComponent("offsets.json")
  try (line(id: "m1", at: fixedNow, model: "claude-zeta-1") + "\n").write(
    to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
  _ = await ClaudeTranscriptReader(root: root.deletingLastPathComponent(), stateURL: state).refresh(now: fixedNow)
  let resumed = ClaudeTranscriptReader(root: root.deletingLastPathComponent(), stateURL: state)
  #expect(await resumed.refresh(now: fixedNow).unpricedModels == ["claude-zeta-1"])
  #expect(await resumed.refresh(now: fixedNow).unpricedModels.isEmpty)
}

@Test func transcriptReaderPricesDaysCheckpointedBeforeCostsWereStored() async throws {
  let root = try transcriptRoot()
  let stateURL = root.deletingLastPathComponent().appendingPathComponent("legacy-state.json")
  let day = DayStamp.string(fixedNow)
  let state: [String: Any] = [
    "offsets": [String: Int](),
    "seenByDay": [day: ["m1"]],
    "days": [
      day: [
        "models": ["claude-opus-5": ["input": 0, "output": 1_000_000, "cacheWrite": 0, "cacheRead": 0]],
        "messages": 1, "sessions": ["s1"], "toolCalls": 0,
      ]
    ],
    "recent": [String: Any](),
  ]
  try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
  let snapshot = await ClaudeTranscriptReader(root: root.deletingLastPathComponent(), stateURL: stateURL).refresh(
    now: fixedNow)
  #expect(snapshot.analytics(now: fixedNow)?.points.first { $0.metric == .costUSD }?.value == 25)
  #expect(snapshot.unpricedModels.isEmpty)
}

@Test func transcriptReaderSkipsFilesOutsideRetentionWithoutStattingThem() async throws {
  let root = try transcriptRoot()
  let old = root.appendingPathComponent("old.jsonl")
  try (line(id: "old", at: fixedNow.addingTimeInterval(-90 * 86400)) + "\n").write(
    to: old, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.modificationDate: fixedNow.addingTimeInterval(-90 * 86400)], ofItemAtPath: old.path)
  try (line(id: "m1", at: fixedNow) + "\n").write(
    to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(root: root.deletingLastPathComponent())
  #expect(await reader.refresh(now: fixedNow).messageCount == 1)
  let workload = await reader.workload
  #expect(workload.scansCompleted == 1)
  #expect(workload.treeEntriesExamined == 3)
  #expect(workload.statChecks == 1)
  #expect(workload.filesOpened == 1)
}

@Test(arguments: throttledPowerStates)
func transcriptReaderSkipsScheduledTreeScansWhilePowerIsConstrained(throttled: PowerState) async throws {
  let root = try transcriptRoot()
  let first = root.appendingPathComponent("first.jsonl")
  try (line(id: "m1", at: fixedNow) + "\n").write(to: first, atomically: true, encoding: .utf8)
  let power = PowerSwitch()
  let reader = ClaudeTranscriptReader(
    root: root.deletingLastPathComponent(), fileScanInterval: 300, powerState: power.read)
  #expect(await reader.refresh(now: fixedNow).messageCount == 1)

  power.current = throttled
  try (line(id: "m2", at: fixedNow) + "\n").write(
    to: root.appendingPathComponent("second.jsonl"), atomically: true, encoding: .utf8)
  let handle = try FileHandle(forWritingTo: first)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((line(id: "m3", at: fixedNow) + "\n").utf8))
  try handle.close()
  #expect(await reader.refresh(now: fixedNow.addingTimeInterval(301)).messageCount == 2)
  #expect((await reader.workload).scansStarted == 1)

  power.current = PowerState(lowPowerMode: false, thermalPressure: false)
  #expect(await reader.refresh(now: fixedNow.addingTimeInterval(302)).messageCount == 3)
  #expect((await reader.workload).scansStarted == 2)
}

@Test func transcriptReaderStillRunsItsFirstScanOnLowPower() async throws {
  let root = try transcriptRoot()
  try (line(id: "m1", at: fixedNow) + "\n").write(
    to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(
    root: root.deletingLastPathComponent(), powerState: { PowerState(lowPowerMode: true, thermalPressure: true) })
  #expect(await reader.refresh(now: fixedNow).messageCount == 1)
  #expect(ClaudeTranscriptReader.defaultFileScanInterval == 15 * 60)
}

@Test func transcriptAnalyticsAggregatesPerDayAndModel() {
  let messages = [
    TranscriptMessage(
      id: "a", timestamp: fixedNow, session: "s1", model: "claude-opus-5",
      usage: TokenUsage(input: 1, output: 2, cacheWrite: 3, cacheRead: 4), toolCalls: 2),
    TranscriptMessage(
      id: "b", timestamp: fixedNow.addingTimeInterval(60), session: "s2", model: "claude-opus-5",
      usage: TokenUsage(input: 1), toolCalls: 0),
    TranscriptMessage(
      id: "c", timestamp: fixedNow.addingTimeInterval(-86400), session: "s1", model: "claude-haiku-4-5",
      usage: TokenUsage(output: 5), toolCalls: 1),
  ]
  let reported = TranscriptMessage(
    id: "d", timestamp: fixedNow.addingTimeInterval(120), session: "s1", model: "claude-opus-5",
    usage: TokenUsage(output: 1_000_000), toolCalls: 0, reportedCost: 3)
  let analytics = ClaudeTranscriptReader.analytics(messages + [reported], now: fixedNow)!
  let today = DayStamp.string(fixedNow)
  #expect(analytics.provider == .claude)
  #expect(
    analytics.points.first { $0.day == today && $0.metric == .inputTokens && $0.series == "claude-opus-5" }?.value == 2)
  #expect(analytics.points.first { $0.day == today && $0.metric == .cacheWriteTokens }?.value == 3)
  #expect(analytics.points.first { $0.day == today && $0.metric == .messages }?.value == 3)
  #expect(analytics.points.first { $0.day == today && $0.metric == .sessions }?.value == 2)
  #expect(
    analytics.points.first { $0.day == today && $0.metric == .costUSD && $0.series == "claude-opus-5" }?.value
      == 3 + ClaudePricing.cost(TokenUsage(input: 2, output: 2, cacheWrite: 3, cacheRead: 4), model: "claude-opus-5"))
  #expect(analytics.points.first { $0.day == today && $0.metric == .toolCalls }?.value == 2)
  #expect(
    analytics.points.first { $0.metric == .costUSD && $0.series == "claude-haiku-4-5" }?.value == 5.0 * 5 / 1_000_000)
  #expect(analytics.points.contains { $0.metric == .outputTokens && $0.series == "claude-haiku-4-5" })
  #expect(ClaudeTranscriptReader.analytics([], now: fixedNow) == nil)
  #expect(AnalyticsMetric.costUSD.unit == "USD")
  #expect(AnalyticsMetric.cacheWriteTokens.unit == "tokens")
  #expect(AnalyticsMetric.toolCalls.title == "Tool calls")
}

@Test func transcriptLocalUsageSummarizesWindowAndToday() {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  let messages = [
    TranscriptMessage(
      id: "a", timestamp: fixedNow.addingTimeInterval(-7200), session: "s", model: "claude-opus-5",
      usage: TokenUsage(output: 1_000_000), toolCalls: 0),
    TranscriptMessage(
      id: "b", timestamp: fixedNow.addingTimeInterval(-3600), session: "s", model: "claude-opus-5",
      usage: TokenUsage(output: 1_000_000), toolCalls: 0),
    TranscriptMessage(
      id: "c", timestamp: fixedNow.addingTimeInterval(-6 * 3600), session: "s", model: "claude-opus-5",
      usage: TokenUsage(output: 1_000_000), toolCalls: 0),
    TranscriptMessage(
      id: "d", timestamp: fixedNow.addingTimeInterval(-40 * 3600), session: "s", model: "claude-opus-5",
      usage: TokenUsage(output: 1), toolCalls: 0),
  ]
  let usage = ClaudeTranscriptReader.localUsage(
    messages, windowResetsAt: fixedNow.addingTimeInterval(2 * 3600), windowDuration: 5 * 3600, now: fixedNow,
    calendar: calendar)!
  #expect(usage.windowTokens == 2_000_000)
  #expect(usage.windowCost == 50)
  #expect(usage.costPerHour == 25)
  #expect(usage.todayTokens == 3_000_000)
  #expect(usage.todayMessages == 3)
  #expect(usage.todayCost == 75)
  let noReset = ClaudeTranscriptReader.localUsage(
    messages, windowResetsAt: nil, windowDuration: 5 * 3600, now: fixedNow, calendar: calendar)!
  #expect(noReset.windowTokens == 2_000_000)
  let quiet = ClaudeTranscriptReader.localUsage(
    [messages[3]], windowResetsAt: nil, windowDuration: 5 * 3600, now: fixedNow, calendar: calendar)!
  #expect(quiet.windowTokens == 0)
  #expect(quiet.costPerHour == 0)
  #expect(ClaudeTranscriptReader.localUsage([], windowResetsAt: nil, windowDuration: 1, now: fixedNow) == nil)
}
