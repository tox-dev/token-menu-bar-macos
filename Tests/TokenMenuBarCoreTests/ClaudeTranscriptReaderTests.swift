import Foundation
import Testing

@testable import TokenMenuBarCore

private func line(
  id: String, request: String = "req", at: Date, model: String = "claude-opus-5", session: String = "s1",
  input: Int = 10,
  output: Int = 20, cacheWrite: Int = 30, cacheRead: Int = 40, tools: Int = 1
) -> String {
  let content = (0..<tools).map { _ in #"{"type":"tool_use","name":"Bash"}"# } + [#"{"type":"text","text":"hi"}"#]
  return #"{"type":"assistant","uuid":"u-\#(id)","requestId":"\#(request)","sessionId":"\#(session)","#
    + #""timestamp":"\#(ISODate.string(at))","message":{"id":"\#(id)","model":"\#(model)","#
    + #""content":[\#(content.joined(separator: ","))],"usage":{"input_tokens":\#(input),"#
    + #""output_tokens":\#(output),"cache_creation_input_tokens":\#(cacheWrite),"#
    + #""cache_read_input_tokens":\#(cacheRead)}}}"#
}

private func transcriptRoot() throws -> URL {
  let root = temporaryDirectory().appendingPathComponent("projects/-Users-me-repo")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

@Test func transcriptReaderParsesIncrementallyAndDedupes() async throws {
  let root = try transcriptRoot()
  let file = root.appendingPathComponent("session.jsonl")
  let first = line(id: "m1", at: fixedNow.addingTimeInterval(-3600))
  try
    (first + "\n" + line(id: "m1", at: fixedNow.addingTimeInterval(-3600)) + "\n" + #"{"type":"user","message":{}}"#
    + "\n").write(to: file, atomically: true, encoding: .utf8)
  let reader = ClaudeTranscriptReader(root: root.deletingLastPathComponent())
  var messages = await reader.refresh(now: fixedNow)
  #expect(messages.count == 1)
  #expect(messages[0].usage == TokenUsage(input: 10, output: 20, cacheWrite: 30, cacheRead: 40))
  #expect(messages[0].usage.total == 100)
  #expect(messages[0].toolCalls == 1)
  #expect(messages[0].session == "s1")
  let handle = try FileHandle(forWritingTo: file)
  try handle.seekToEnd()
  try handle.write(
    contentsOf: Data((line(id: "m2", at: fixedNow.addingTimeInterval(-60), tools: 0) + "\n" + "partial").utf8))
  try handle.close()
  messages = await reader.refresh(now: fixedNow)
  #expect(messages.map(\.id) == ["m1:req", "m2:req"])
  messages = await reader.refresh(now: fixedNow)
  #expect(messages.count == 2)
  let ancient = line(id: "old", at: fixedNow.addingTimeInterval(-90 * 86400))
  try (ancient + "\n").write(to: root.appendingPathComponent("old.jsonl"), atomically: true, encoding: .utf8)
  messages = await reader.refresh(now: fixedNow)
  #expect(messages.count == 2)
  #expect(await ClaudeTranscriptReader(root: root.appendingPathComponent("missing")).refresh(now: fixedNow).isEmpty)
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

@Test func pricingCoversKnownFamilies() {
  let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheWrite: 1_000_000, cacheRead: 1_000_000)
  #expect(ClaudePricing.cost(usage, model: "claude-opus-5") == 15 + 75 + 18.75 + 1.5)
  #expect(ClaudePricing.cost(usage, model: "claude-haiku-4-5-20251001") == 1 + 5 + 1.25 + 0.1)
  #expect(ClaudePricing.cost(usage, model: "claude-sonnet-4-6") == 3 + 15 + 3.75 + 0.3)
  #expect(ClaudePricing.cost(usage, model: "claude-fable-5") == ClaudePricing.cost(usage, model: "claude-mythos-5"))
  #expect(ClaudePricing.cost(usage, model: "gpt-5") == 0)
  #expect(ClaudePricing.price(for: "unknown") == nil)
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
  let analytics = ClaudeTranscriptReader.analytics(messages, now: fixedNow)!
  let today = DayStamp.string(fixedNow)
  #expect(analytics.provider == .claude)
  #expect(
    analytics.points.first { $0.day == today && $0.metric == .inputTokens && $0.series == "claude-opus-5" }?.value == 2)
  #expect(analytics.points.first { $0.day == today && $0.metric == .cacheWriteTokens }?.value == 3)
  #expect(analytics.points.first { $0.day == today && $0.metric == .messages }?.value == 2)
  #expect(analytics.points.first { $0.day == today && $0.metric == .sessions }?.value == 2)
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
  #expect(usage.windowCost == 150)
  #expect(usage.costPerHour == 75)
  #expect(usage.todayTokens == 3_000_000)
  #expect(usage.todayMessages == 3)
  #expect(usage.todayCost == 225)
  let noReset = ClaudeTranscriptReader.localUsage(
    messages, windowResetsAt: nil, windowDuration: 5 * 3600, now: fixedNow, calendar: calendar)!
  #expect(noReset.windowTokens == 2_000_000)
  let quiet = ClaudeTranscriptReader.localUsage(
    [messages[3]], windowResetsAt: nil, windowDuration: 5 * 3600, now: fixedNow, calendar: calendar)!
  #expect(quiet.windowTokens == 0)
  #expect(quiet.costPerHour == 0)
  #expect(ClaudeTranscriptReader.localUsage([], windowResetsAt: nil, windowDuration: 1, now: fixedNow) == nil)
}
