import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func transcriptSnapshotFiltersTodayAtASecondOffsetDayBoundary() async throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 30))
  let now = calendar.startOfDay(for: fixedNow).addingTimeInterval(3600)
  let todayStart = calendar.startOfDay(for: now)
  let root = temporaryDirectory()
  try
    ([
      coverageClaudeLine(id: "before", at: todayStart.addingTimeInterval(-1), input: 1),
      coverageClaudeLine(id: "after", at: todayStart.addingTimeInterval(1), input: 2),
    ].joined(separator: "\n") + "\n").write(
      to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)

  let snapshot = await ClaudeTranscriptReader(root: root).refresh(now: now)
  let usage = try #require(
    snapshot.localUsage(windowResetsAt: nil, windowDuration: 7200, now: now, calendar: calendar))
  #expect(usage.windowTokens == 3)
  #expect(usage.todayTokens == 2)
  #expect(usage.todayMessages == 1)
}

@Test func transcriptReaderMigratesLegacyRecentUsage() async throws {
  let root = temporaryDirectory()
  let stateURL = root.appendingPathComponent("state.json")
  try coverageClaudeState(recent: (fixedNow.addingTimeInterval(-60), 17, 2.5, 1)).write(to: stateURL)

  let snapshot = await ClaudeTranscriptReader(root: root, stateURL: stateURL).refresh(now: fixedNow)
  let usage = try #require(snapshot.localUsage(windowResetsAt: nil, windowDuration: 3600, now: fixedNow))
  #expect(usage.windowTokens == 17)
  #expect(usage.windowCost == 2.5)
  #expect(usage.todayMessages == 1)
}

@Test func transcriptReaderRemovesOffsetsForMissingFiles() async throws {
  let root = temporaryDirectory()
  let stateURL = root.appendingPathComponent("state.json")
  try coverageClaudeState(offsets: [root.appendingPathComponent("gone.jsonl").path: 10]).write(to: stateURL)

  let reader = ClaudeTranscriptReader(root: root, stateURL: stateURL)
  _ = await reader.refresh(now: fixedNow)
  #expect((await reader.workload).checkpoints == 1)

  let reopened = ClaudeTranscriptReader(root: root, stateURL: stateURL)
  _ = await reopened.refresh(now: fixedNow)
  #expect((await reopened.workload).checkpoints == 0)
}

@Test func transcriptReaderRecoversFromAnOffsetBeyondEndOfFile() async throws {
  let root = temporaryDirectory()
  let file = root.appendingPathComponent("session.jsonl")
  let stateURL = root.appendingPathComponent("state.json")
  try Data().write(to: file)
  let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
  let canonicalFile = try #require(enumerator.nextObject() as? URL)
  try coverageClaudeState(offsets: [canonicalFile.path: 100]).write(to: stateURL)
  let reader = ClaudeTranscriptReader(
    root: root, stateURL: stateURL, fileScanInterval: 300, checkpointInterval: 0)
  #expect(await reader.refresh(now: fixedNow).messageCount == 0)
  #expect((await reader.workload).filesOpened == 0)
  let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
  let offsets = try #require(stored["offsets"] as? [String: Any])
  let offset = try #require(offsets[canonicalFile.path] as? [String: Any])
  #expect((offset["bytes"] as? NSNumber)?.intValue == 0)

  let handle = try FileHandle(forWritingTo: file)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((coverageClaudeLine(id: "after-reset", at: fixedNow, input: 4) + "\n").utf8))
  try handle.close()
  #expect(await reader.refresh(now: fixedNow.addingTimeInterval(60)).messageCount == 1)
}

@Test func transcriptReaderResumesAfterAnOversizedUnterminatedLine() async throws {
  let root = temporaryDirectory()
  let file = root.appendingPathComponent("session.jsonl")
  let record = coverageClaudeLine(id: "valid", at: fixedNow, input: 5)
  try String(repeating: "x", count: record.utf8.count + 1).write(
    to: file, atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(
    root: root, fileScanInterval: 300, maximumLineBytes: record.utf8.count,
    maximumRetainedPartialBytes: record.utf8.count)
  #expect(await reader.refresh(now: fixedNow).messageCount == 0)

  let handle = try FileHandle(forWritingTo: file)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data(("\n" + record + "\n").utf8))
  try handle.close()
  #expect(await reader.refresh(now: fixedNow.addingTimeInterval(60)).messageCount == 1)
}

@Test func transcriptReaderEvictsTheLargestOtherPartialLine() async throws {
  let root = temporaryDirectory()
  for name in ["a", "b", "c"] {
    try "data".write(
      to: root.appendingPathComponent("\(name).jsonl"), atomically: true, encoding: .utf8)
  }
  let reader = ClaudeTranscriptReader(
    root: root, maximumLineBytes: 8, maximumRetainedPartialBytes: 8)
  _ = await reader.refresh(now: fixedNow)
  let workload = await reader.workload
  #expect(workload.retainedPartialFiles == 2)
  #expect(workload.retainedPartialBytes == 8)
}

@Test func rolloutReaderRebuildsCandidatesAfterACachedFileDisappears() async throws {
  let root = temporaryDirectory()
  let file = root.appendingPathComponent("rollout-current.jsonl")
  try (coverageRolloutLine(primary: 7) + "\n").write(to: file, atomically: true, encoding: .utf8)
  let reader = CodexRolloutReader(sessionsRoot: root, cacheInterval: 300)
  #expect(await reader.latest(now: fixedNow)?.rateLimit.primaryWindow?.usedPercent == 7)

  try FileManager.default.removeItem(at: file)
  #expect(await reader.latest(now: fixedNow.addingTimeInterval(60)) == nil)
  let workload = await reader.workload
  #expect(workload.treesScanned == 2)
  #expect(workload.searchesCompleted == 2)
}

@Test func rolloutReaderReusesCandidatesAfterTheClockMovesBackward() async throws {
  let root = temporaryDirectory()
  let file = root.appendingPathComponent("rollout-current.jsonl")
  try (coverageRolloutLine(primary: 7) + "\n").write(to: file, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.modificationDate: fixedNow], ofItemAtPath: file.path)
  let reader = CodexRolloutReader(sessionsRoot: root, cacheInterval: 300)
  #expect(await reader.latest(now: fixedNow)?.rateLimit.primaryWindow?.usedPercent == 7)

  try (coverageRolloutLine(primary: 42) + "\n").write(to: file, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.modificationDate: fixedNow.addingTimeInterval(1)], ofItemAtPath: file.path)
  #expect(
    await reader.latest(now: fixedNow.addingTimeInterval(-100))?.rateLimit.primaryWindow?.usedPercent == 42)
  #expect(await reader.latest(now: fixedNow.addingTimeInterval(250))?.rateLimit.primaryWindow?.usedPercent == 42)
  #expect((await reader.workload).treesScanned == 1)
}

@Test func rolloutReaderSkipsAFileThatCannotBeOpened() async throws {
  let root = temporaryDirectory()
  let readable = root.appendingPathComponent("rollout-readable.jsonl")
  try (coverageRolloutLine(primary: 7) + "\n").write(to: readable, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.modificationDate: fixedNow.addingTimeInterval(-1)], ofItemAtPath: readable.path)
  let unreadable = root.appendingPathComponent("rollout-unreadable.jsonl")
  try (coverageRolloutLine(primary: 99) + "\n").write(to: unreadable, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.modificationDate: fixedNow, .posixPermissions: 0o000], ofItemAtPath: unreadable.path)
  defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }

  let reader = CodexRolloutReader(sessionsRoot: root)
  #expect(await reader.latest(now: fixedNow)?.rateLimit.primaryWindow?.usedPercent == 7)
  #expect((await reader.workload).filesOpened == 1)
}

private func coverageClaudeState(
  offsets: [String: Int] = [:], recent: (Date, Int, Double, Int)? = nil
) throws -> Data {
  var days: [String: Any] = [:]
  var seenByDay: [String: Any] = [:]
  var recentByMinute: [String: Any] = [:]
  if let (timestamp, tokens, cost, messages) = recent {
    let day = DayStamp.string(timestamp)
    days[day] = ["models": [:], "messages": messages, "sessions": ["session"], "toolCalls": 0]
    seenByDay[day] = ["message"]
    recentByMinute[String(Int64(timestamp.timeIntervalSince1970 / 60) * 60)] = [
      "timestamp": timestamp.timeIntervalSinceReferenceDate,
      "tokens": tokens,
      "cost": cost,
      "messages": messages,
    ]
  }
  return try JSONSerialization.data(withJSONObject: [
    "offsets": offsets,
    "seenByDay": seenByDay,
    "days": days,
    "recent": recentByMinute,
  ])
}

private func coverageClaudeLine(id: String, at date: Date, input: Int) -> String {
  #"{"type":"assistant","uuid":"u-\#(id)","requestId":"request","sessionId":"session","#
    + #""timestamp":"\#(ISODate.string(date))","message":{"id":"\#(id)","model":"claude-haiku-4-5","#
    + #""content":[],"usage":{"input_tokens":\#(input),"output_tokens":0,"cache_creation_input_tokens":0,"#
    + #""cache_read_input_tokens":0}}}"#
}

private func coverageRolloutLine(primary: Double) -> String {
  #"{"timestamp":"2026-08-29T10:00:00.000Z","rate_limits":{"primary":{"used_percent":\#(primary),"#
    + #""window_minutes":300},"rate_limit_reached_type":null}}"#
}
