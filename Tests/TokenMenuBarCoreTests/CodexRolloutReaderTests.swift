import Foundation
import Testing

@testable import TokenMenuBarCore

private func rolloutLine(
  primary: Double, secondary: Double? = 34, plan: String = "pro", timestamp: String = "2026-08-29T10:00:00.000Z"
) -> String {
  let secondaryText =
    secondary.map { #"{"used_percent":\#($0),"window_minutes":10080,"resets_at":1788544000}"# } ?? "null"
  return
    #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(primary),"window_minutes":300,"resets_at":1788205600},"secondary":\#(secondaryText),"credits":{"has_credits":true,"unlimited":false,"balance":"9.5"},"plan_type":"\#(plan)","rate_limit_reached_type":null}}}"#
}

@Test func rolloutReaderPicksLastRateLimitsInNewestFile() throws {
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
  let reading = CodexRolloutReader(sessionsRoot: root).latest()!
  #expect(reading.rateLimit.primaryWindow?.usedPercent == 55)
  #expect(reading.rateLimit.primaryWindow?.limitWindowSeconds == 18000)
  #expect(reading.rateLimit.primaryWindow?.resetAt == 1_788_205_600)
  #expect(reading.rateLimit.secondaryWindow == nil)
  #expect(reading.rateLimit.limitReached == false)
  #expect(reading.planType == "pro")
  #expect(reading.credits?.balance == "9.5")
  #expect(reading.observedAt == ISODate.parse("2026-08-29T10:00:00.000Z"))
}

@Test func rolloutReaderFallsThroughToOlderFilesAndHandlesMissingRoot() throws {
  let root = temporaryDirectory()
  let dir = root.appendingPathComponent("a")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let empty = dir.appendingPathComponent("rollout-empty.jsonl")
  try "{\"type\":\"nothing\"}\n".write(to: empty, atomically: true, encoding: .utf8)
  let withData = dir.appendingPathComponent("rollout-data.jsonl")
  try (rolloutLine(primary: 7) + "\n").write(to: withData, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: withData.path)
  #expect(CodexRolloutReader(sessionsRoot: root).latest()?.rateLimit.primaryWindow?.usedPercent == 7)
  #expect(CodexRolloutReader(sessionsRoot: root.appendingPathComponent("missing")).latest() == nil)
  #expect(CodexRolloutReader(sessionsRoot: temporaryDirectory()).latest() == nil)
}

@Test func rolloutReaderLimitsFileCount() throws {
  let root = temporaryDirectory()
  for index in 0..<(CodexRolloutReader.maxFiles + 3) {
    let file = root.appendingPathComponent("rollout-\(index).jsonl")
    try "{}\n".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: file.path)
  }
  let newest = CodexRolloutReader(sessionsRoot: root).newestRollouts()
  #expect(newest.count == CodexRolloutReader.maxFiles)
  #expect(newest.first?.lastPathComponent == "rollout-\(CodexRolloutReader.maxFiles + 2).jsonl")
}

@Test func rolloutParseHandlesNestedAndInvalidShapes() {
  #expect(CodexRolloutReader.parse(line: "{") == nil)
  #expect(CodexRolloutReader.parse(line: #"{"a":[{"rate_limits":"str"}]}"#) == nil)
  let nested = CodexRolloutReader.parse(
    line:
      #"{"a":[1,{"b":{"rate_limits":{"primary":{"used_percent":3,"limit_window_seconds":18000,"resets_in_seconds":5,"reset_at":9},"rate_limit_reached_type":{"type":"x"}}}}]}"#
  )!
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
