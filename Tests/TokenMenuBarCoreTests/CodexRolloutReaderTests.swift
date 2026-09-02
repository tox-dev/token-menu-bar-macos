import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func rolloutReaderPicksLastRateLimitsInNewestFile() async throws {
  let root = temporaryDirectory()
  let older = root.appendingPathComponent("2026/08/28")
  let newer = root.appendingPathComponent("2026/08/29")
  try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
  let oldFile = older.appendingPathComponent("rollout-old.jsonl")
  try (rolloutLine(primary: 1) + "\n").write(to: oldFile, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: oldFile.path)
  let newFile = newer.appendingPathComponent("rollout-new.jsonl")
  try
    ([
      #"{"type":"other"}"#, rolloutLine(primary: 12), "not json {\"rate_limits\"",
      rolloutLine(primary: 55, secondary: nil),
    ].joined(separator: "\n") + "\n").write(to: newFile, atomically: true, encoding: .utf8)
  try "ignored".write(to: newer.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
  let reading = try #require(await CodexRolloutReader(sessionsRoot: root).latest(now: fixedNow))
  #expect(reading.rateLimit.primaryWindow?.usedPercent == 55)
  #expect(reading.rateLimit.primaryWindow?.limitWindowSeconds == 18000)
  #expect(reading.rateLimit.primaryWindow?.resetAt == 1_788_205_600)
  #expect(reading.rateLimit.secondaryWindow == nil)
  #expect(reading.rateLimit.limitReached == false)
  #expect(reading.planType == "pro")
  #expect(reading.credits?.balance == "9.5")
  #expect(reading.observedAt == ISODate.parse("2026-08-29T10:00:00.000Z"))
}

@Test func rolloutReaderFallsThroughToOlderFilesAndHandlesMissingRoot() async throws {
  let root = temporaryDirectory()
  let dir = root.appendingPathComponent("a")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let empty = dir.appendingPathComponent("rollout-empty.jsonl")
  try "{\"type\":\"nothing\"}\n".write(to: empty, atomically: true, encoding: .utf8)
  let withData = dir.appendingPathComponent("rollout-data.jsonl")
  try (rolloutLine(primary: 7) + "\n").write(to: withData, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: withData.path)
  #expect(
    await CodexRolloutReader(sessionsRoot: root).latest(now: fixedNow)?.rateLimit.primaryWindow?.usedPercent == 7)
  #expect(
    await CodexRolloutReader(sessionsRoot: root.appendingPathComponent("missing")).latest(now: fixedNow) == nil)
  #expect(await CodexRolloutReader(sessionsRoot: temporaryDirectory()).latest(now: fixedNow) == nil)
}

@Test func rolloutReaderLimitsFileCount() async throws {
  let root = temporaryDirectory()
  for index in 0..<(CodexRolloutReader.maxFiles + 3) {
    let file = root.appendingPathComponent("rollout-\(index).jsonl")
    try "{}\n".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: file.path)
  }
  let newest = await CodexRolloutReader(sessionsRoot: root).newestRollouts()
  #expect(newest.count == CodexRolloutReader.maxFiles)
  #expect(newest.first?.lastPathComponent == "rollout-\(CodexRolloutReader.maxFiles + 2).jsonl")
}

@Test func rolloutReaderCachesSuccessAndFailureUntilExpiry() async throws {
  let root = temporaryDirectory()
  let file = root.appendingPathComponent("rollout-current.jsonl")
  try (rolloutLine(primary: 7) + "\n").write(to: file, atomically: true, encoding: .utf8)
  let reader = CodexRolloutReader(sessionsRoot: root, cacheInterval: 300)
  #expect(await reader.latest(now: fixedNow)?.rateLimit.primaryWindow?.usedPercent == 7)

  try (rolloutLine(primary: 42) + "\n").write(to: file, atomically: true, encoding: .utf8)
  #expect(
    await reader.latest(now: fixedNow.addingTimeInterval(60))?.rateLimit.primaryWindow?.usedPercent == 42)
  #expect((await reader.workload).treesScanned == 1)
  #expect(
    await reader.latest(now: fixedNow.addingTimeInterval(301))?.rateLimit.primaryWindow?.usedPercent == 42)

  let emptyRoot = temporaryDirectory()
  let empty = CodexRolloutReader(sessionsRoot: emptyRoot, cacheInterval: 300)
  #expect(await empty.latest(now: fixedNow) == nil)
  let added = emptyRoot.appendingPathComponent("rollout-added.jsonl")
  try (rolloutLine(primary: 9) + "\n").write(to: added, atomically: true, encoding: .utf8)
  #expect(await empty.latest(now: fixedNow.addingTimeInterval(60)) == nil)
  #expect((await empty.workload).treesScanned == 1)
  #expect(await empty.latest(now: fixedNow.addingTimeInterval(301)) != nil)
}

@Test func rolloutReaderBoundsEachReverseReadSlice() async throws {
  let root = temporaryDirectory()
  let file = root.appendingPathComponent("rollout-current.jsonl")
  try (rolloutLine(primary: 7) + "\n" + String(repeating: "x", count: 4_096) + "\n").write(
    to: file, atomically: true, encoding: .utf8)
  let reader = CodexRolloutReader(sessionsRoot: root, workByteBudget: 128)
  #expect(await reader.latest(now: fixedNow) == nil)
  let reading = await waitForRolloutReading(reader)
  #expect(reading?.rateLimit.primaryWindow?.usedPercent == 7)
  #expect((await reader.workload).largestSliceBytesRead <= 128)
}

@Test func rolloutReaderBoundsTreeEnumerationSlices() async throws {
  let root = temporaryDirectory()
  for index in 0..<300 {
    try "{}\n".write(
      to: root.appendingPathComponent("rollout-\(index).jsonl"), atomically: true, encoding: .utf8)
  }
  let reader = CodexRolloutReader(sessionsRoot: root, workEntryBudget: 4)
  _ = await reader.latest(now: fixedNow)
  await waitForRolloutSearch(reader)
  let workload = await reader.workload
  #expect(workload.largestTreeSliceEntries <= 4)
  #expect(workload.treeEntriesExamined == 300)
}

@Test func rolloutReaderStopsAfterAFileShrinksDuringARead() async throws {
  let root = temporaryDirectory()
  let file = root.appendingPathComponent("rollout-current.jsonl")
  try String(repeating: "x", count: 1_048_576).write(to: file, atomically: true, encoding: .utf8)
  let reader = CodexRolloutReader(sessionsRoot: root, workByteBudget: 1)
  _ = await reader.latest(now: fixedNow)
  try Data().write(to: file, options: .atomic)
  await waitForRolloutSearch(reader)
  #expect((await reader.workload).searchesCompleted == 1)
}

@Test func rolloutReaderSkipsOversizedNonRateLimitLines() async throws {
  let root = temporaryDirectory()
  let file = root.appendingPathComponent("rollout-current.jsonl")
  let oversized = String(repeating: "x", count: CodexRolloutReader.maximumLineBytes + 1)
  try (rolloutLine(primary: 7) + "\n" + oversized + "\n").write(to: file, atomically: true, encoding: .utf8)
  let reader = CodexRolloutReader(sessionsRoot: root)
  _ = await reader.latest(now: fixedNow)
  #expect(await waitForRolloutReading(reader)?.rateLimit.primaryWindow?.usedPercent == 7)
}

@Test func rolloutReaderSkipsJsonlDirectories() async throws {
  let root = temporaryDirectory()
  let valid = root.appendingPathComponent("rollout-valid.jsonl")
  try (rolloutLine(primary: 7) + "\n").write(to: valid, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.modificationDate: fixedNow.addingTimeInterval(-60)], ofItemAtPath: valid.path)
  let invalid = root.appendingPathComponent("rollout-broken.jsonl")
  try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
  try FileManager.default.setAttributes([.modificationDate: fixedNow], ofItemAtPath: invalid.path)

  #expect(
    await CodexRolloutReader(sessionsRoot: root).latest(now: fixedNow)?.rateLimit.primaryWindow?.usedPercent == 7)
}

@Test func rolloutReaderIgnoresDirectoriesBeforeApplyingItsFileLimit() async throws {
  let root = temporaryDirectory()
  for index in 0...CodexRolloutReader.maxFiles {
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("rollout-fake-\(index).jsonl"), withIntermediateDirectories: true)
  }
  try (rolloutLine(primary: 7) + "\n").write(
    to: root.appendingPathComponent("rollout-valid.jsonl"), atomically: true, encoding: .utf8)
  #expect(
    await CodexRolloutReader(sessionsRoot: root).latest(now: fixedNow)?.rateLimit.primaryWindow?.usedPercent == 7)
}

@Test func rolloutReaderBreaksEqualModificationDatesByPath() async throws {
  let root = temporaryDirectory()
  for name in ["rollout-c.jsonl", "rollout-a.jsonl", "rollout-b.jsonl"] {
    let file = root.appendingPathComponent(name)
    try "{}\n".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: fixedNow], ofItemAtPath: file.path)
  }
  #expect(
    await CodexRolloutReader(sessionsRoot: root).newestRollouts().map(\.lastPathComponent) == [
      "rollout-a.jsonl", "rollout-b.jsonl", "rollout-c.jsonl",
    ])
}

@Test func rolloutParseHandlesNestedAndInvalidShapes() {
  #expect(CodexRolloutReader.parse(line: "{") == nil)
  #expect(CodexRolloutReader.parse(line: #"{"a":[{"rate_limits":"str"}]}"#) == nil)
  let nested = CodexRolloutReader.parse(
    line: #"{"a":[1,{"b":{"rate_limits":{"primary":{"used_percent":3,"limit_window_seconds":18000,"#
      + #""resets_in_seconds":5,"reset_at":9},"rate_limit_reached_type":{"type":"x"}}}}]}"#)!
  #expect(nested.rateLimit.primaryWindow?.limitWindowSeconds == 18000)
  #expect(nested.rateLimit.primaryWindow?.resetAfterSeconds == 5)
  #expect(nested.rateLimit.primaryWindow?.resetAt == 9)
  #expect(nested.rateLimit.limitReached == true)
  #expect(nested.credits == nil)
  #expect(nested.observedAt == nil)
  let noPercent = CodexRolloutReader.parse(line: #"{"rate_limits":{"primary":{"window_minutes":5}}}"#)!
  #expect(noPercent.rateLimit.primaryWindow == nil)
  #expect(CodexRolloutReader.findRateLimits(.string("x")) == nil)
}

private func rolloutLine(
  primary: Double, secondary: Double? = 34, plan: String = "pro", timestamp: String = "2026-08-29T10:00:00.000Z"
) -> String {
  let secondaryText =
    secondary.map { #"{"used_percent":\#($0),"window_minutes":10080,"resets_at":1788544000}"# } ?? "null"
  return #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","#
    + #""rate_limits":{"primary":{"used_percent":\#(primary),"window_minutes":300,"#
    + #""resets_at":1788205600},"secondary":\#(secondaryText),"#
    + #""credits":{"has_credits":true,"unlimited":false,"balance":"9.5"},"#
    + #""plan_type":"\#(plan)","rate_limit_reached_type":null}}}"#
}

private func waitForRolloutReading(_ reader: CodexRolloutReader) async -> CodexRolloutReader.Reading? {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(5))
  while clock.now < deadline {
    if let reading = await reader.latest(now: fixedNow) { return reading }
    await Task.yield()
  }
  Issue.record("Rollout search did not finish")
  return nil
}

private func waitForRolloutSearch(_ reader: CodexRolloutReader) async {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: .seconds(5))
  while clock.now < deadline {
    if (await reader.workload).searchesCompleted > 0 { return }
    await Task.yield()
  }
  Issue.record("Rollout search did not finish")
}
