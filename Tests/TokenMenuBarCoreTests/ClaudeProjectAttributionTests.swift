import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

private let recent = fixedNow.addingTimeInterval(-3600)

private func transcriptLine(id: String, cost: Double, cwd: String? = nil) -> String {
  let cwdField = cwd.map { #""cwd":"\#($0)","# } ?? ""
  return #"{"type":"assistant","uuid":"u-\#(id)","requestId":"r-\#(id)","sessionId":"s1",\#(cwdField)"#
    + #""timestamp":"\#(ISODate.string(recent))","costUSD":\#(cost),"message":{"id":"\#(id)","#
    + #""model":"claude-opus-5","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":10,"#
    + #""output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
}

private func projectsRoot(_ transcripts: [String: [String]]) throws -> URL {
  let root = temporaryDirectory().appendingPathComponent("projects")
  for (directory, lines) in transcripts {
    let folder = root.appendingPathComponent(directory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n").write(
      to: folder.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
  }
  return root
}

private func byProject(_ analytics: ProviderAnalytics, _ metric: AnalyticsMetric) -> [String: Double] {
  Dictionary(uniqueKeysWithValues: analytics.points.filter { $0.metric == metric }.map { ($0.series, $0.value) })
}

@Test func transcriptReaderAttributesCostAndMessagesToProjects() async throws {
  let root = try projectsRoot([
    "-Users-me-repo-alpha": [transcriptLine(id: "m1", cost: 1.25), transcriptLine(id: "m2", cost: 0.75)],
    "-Users-me-beta": [transcriptLine(id: "m3", cost: 2, cwd: "/Users/me/beta-tool")],
  ])
  let reader = ClaudeTranscriptReader(root: root)

  let analytics = try #require(await reader.refresh(now: fixedNow).analytics(now: fixedNow))

  #expect(byProject(analytics, .projectCost) == ["directory:-Users-me-repo-alpha": 2, "/Users/me/beta-tool": 2])
  #expect(byProject(analytics, .projectMessages) == ["directory:-Users-me-repo-alpha": 2, "/Users/me/beta-tool": 1])
  #expect(analytics.total(.projectCost) == analytics.total(.costUSD))
  #expect(
    analytics.points.filter { $0.metric == .projectCost }.map(\.day) == [
      DayStamp.string(recent), DayStamp.string(recent),
    ])
}

@Test func transcriptReaderReadsCheckpointsWrittenBeforeProjectsExisted() async throws {
  let root = try projectsRoot(["-Users-me-repo": [transcriptLine(id: "m1", cost: 1)]])
  let stateURL = temporaryDirectory().appendingPathComponent("offsets.json")
  let first = ClaudeTranscriptReader(root: root, stateURL: stateURL, checkpointInterval: 0)
  #expect(await first.refresh(now: fixedNow).messageCount == 1)
  while (await first.workload).checkpoints == 0 { await Task.yield() }

  var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
  var days = try #require(json["days"] as? [String: [String: Any]])
  #expect(days.values.allSatisfy { $0["projects"] != nil })
  for key in days.keys { days[key]?["projects"] = nil }
  json["days"] = days
  json["projectIdentityVersion"] = nil
  try JSONSerialization.data(withJSONObject: json).write(to: stateURL)

  let resumed = ClaudeTranscriptReader(root: root, stateURL: stateURL)
  let snapshot = await resumed.refresh(now: fixedNow)
  #expect(snapshot.messageCount == 1)
  #expect(snapshot.analytics(now: fixedNow)?.total(.costUSD) == 1)
  #expect(snapshot.analytics(now: fixedNow)?.points.contains { $0.metric == .projectCost } == true)
}

@Test func projectIdentityMigrationReplacesLegacyAttributionWithoutDoubleCounting() async throws {
  let root = try projectsRoot([
    "-Users-me-repo": [transcriptLine(id: "m1", cost: 1), transcriptLine(id: "m2", cost: 2)]
  ])
  let stateURL = temporaryDirectory().appendingPathComponent("offsets.json")
  let reader = ClaudeTranscriptReader(root: root, stateURL: stateURL, checkpointInterval: 0)
  _ = await reader.refresh(now: fixedNow)
  while (await reader.workload).checkpoints == 0 { await Task.yield() }
  var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
  var days = try #require(json["days"] as? [String: [String: Any]])
  for key in days.keys {
    let projects = try #require(days[key]?["projects"] as? [String: Any])
    days[key]?["projects"] = ["repo": try #require(projects.values.first)]
  }
  json["days"] = days
  json["projectIdentityVersion"] = nil
  try JSONSerialization.data(withJSONObject: json).write(to: stateURL)
  let resumed = ClaudeTranscriptReader(root: root, stateURL: stateURL)
  let analytics = try #require(await resumed.refresh(now: fixedNow).analytics(now: fixedNow))
  #expect(byProject(analytics, .projectCost) == ["directory:-Users-me-repo": 3])
  #expect(analytics.total(.messages) == 2)
}

@Test func transcriptReaderResumesAnIdentityCheckpointWithoutSeparateProjectDeduplication() async throws {
  let root = try projectsRoot(["repo": [transcriptLine(id: "m1", cost: 1)]])
  let stateURL = temporaryDirectory().appendingPathComponent("offsets.json")
  let reader = ClaudeTranscriptReader(root: root, stateURL: stateURL, checkpointInterval: 0)
  _ = await reader.refresh(now: fixedNow)
  while (await reader.workload).checkpoints == 0 { await Task.yield() }
  var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
  json["projectSeenByDay"] = nil
  try JSONSerialization.data(withJSONObject: json).write(to: stateURL)
  let resumed = ClaudeTranscriptReader(root: root, stateURL: stateURL)
  let analytics = try #require(await resumed.refresh(now: fixedNow).analytics(now: fixedNow))
  #expect(analytics.total(.projectMessages) == 1)
}

@Test(arguments: ["-Users-me-repo", "-private-tmp", "plain", "-"])
func projectIdentityPreservesAmbiguousEncodedDirectoryNames(encoded: String) {
  #expect(ClaudeTranscriptReader.projectName(encodedDirectory: encoded) == "directory:" + encoded)
}

@Test func projectNameFallsBackToTheFileOutsideAProjectDirectory() {
  let root = URL(fileURLWithPath: "/tmp/projects")
  #expect(
    ClaudeTranscriptReader.projectName(transcript: root.appendingPathComponent("loose.jsonl"), root: root) == "loose")
  #expect(
    ClaudeTranscriptReader.projectName(
      transcript: root.appendingPathComponent("-Users-me-repo/nested/b.jsonl"), root: root)
      == "directory:-Users-me-repo")
}

@Test func transcriptAnalyticsGroupProjectSeriesFromMessagesThatCarryOne() throws {
  func message(_ id: String, cost: Double, project: String? = nil) -> TranscriptMessage {
    TranscriptMessage(
      id: id, timestamp: fixedNow, session: "s", model: "claude-opus-5", usage: TokenUsage(input: 10), toolCalls: 0,
      reportedCost: cost, project: project)
  }
  let analytics = try #require(
    ClaudeTranscriptReader.analytics(
      [message("1", cost: 1, project: "repo"), message("2", cost: 2, project: "repo"), message("3", cost: 4)],
      now: fixedNow))
  #expect(byProject(analytics, .projectCost) == ["repo": 3])
  #expect(byProject(analytics, .projectMessages) == ["repo": 2])
  #expect(analytics.total(.costUSD) == 7)
}

@Test @MainActor func historyPresenterShowsProjectSeriesUnderTheProjectsGroup() async throws {
  let settings = Settings(defaults: testDefaults())
  let history = try UsageHistoryStore(url: nil)
  let presenter = HistoryPresenter(history: history, settings: settings, clock: testClock)
  let day = DayStamp.string(fixedNow)
  try await history.record(
    ProviderAnalytics(
      provider: .claude,
      points: [
        AnalyticsPoint(day: day, metric: .projectCost, series: "alpha", value: 2),
        AnalyticsPoint(day: day, metric: .projectCost, series: "beta-tool", value: 1),
        AnalyticsPoint(day: day, metric: .projectMessages, series: "alpha", value: 3),
      ], fetchedAt: fixedNow))

  presenter.setMetric(.analytics(.projectCost))
  await presenter.waitForLoad()

  let data = try #require(presenter.state.data)
  #expect(data.series.map(\.label) == ["alpha", "beta-tool"])
  #expect(data.summaryText == "\(Format.currency(3)) total")
  #expect(
    HistoryMetric.allCases.filter { $0.group == .projects }
      == [.analytics(.projectCost), .analytics(.projectMessages)])
  #expect(HistoryMetric.analytics(.projectMessages).suppliers == [.claude])
  #expect(HistoryMetric.analytics(.projectMessages).unit == .count)
  #expect(AnalyticsMetric.projectCost.unit == "USD")
  #expect(AnalyticsMetric.projectMessages.title == "Messages by project")
  #expect(AnalyticsMetric.projectCost.title == "Cost by project")
}
