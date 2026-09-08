import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

private func cachedSnapshot(_ provider: ProviderID, plan: String?) -> ProviderSnapshot {
  ProviderSnapshot(
    provider: provider,
    identity: plan.map { ProviderIdentity(planName: $0) },
    windows: [
      QuotaWindow(
        id: "session", label: "Current session", group: .session, usedPercent: 36,
        resetsAt: fixedNow.addingTimeInterval(3600), duration: 18000),
      QuotaWindow(id: "weekly", label: "Weekly", group: .weekly, usedPercent: 61, resetsAt: nil, duration: nil),
    ],
    fetchedAt: fixedNow)
}

private let cachedSnapshots: [ProviderID: ProviderSnapshot] = [
  .claude: cachedSnapshot(.claude, plan: "Max 20x"), .codex: cachedSnapshot(.codex, plan: nil),
]

@Test(
  arguments: [
    (["app", "--usage-json"], ExportInvocation.usageJSON),
    (["--usage-json", "--export-icon", "/tmp/a"], .usageJSON),
    (["--export-menubar", "/tmp/a"], .files(.menuBar, directory: URL(fileURLWithPath: "/tmp/a"))),
  ])
func exportInvocationParsesTheUsageFlagWithoutADirectory(arguments: [String], invocation: ExportInvocation) {
  #expect(ExportInvocation.parse(arguments) == invocation)
}

@Test(arguments: [["app"], ["app", "--export-popover"], []])
func exportInvocationNeedsAKnownFlag(arguments: [String]) {
  #expect(ExportInvocation.parse(arguments) == nil)
}

@Test func exportInvocationsNameTheirFailure() {
  #expect(ExportInvocation.usageJSON.failureMessage == "usage export failed")
  #expect(
    ExportInvocation.files(.popover, directory: URL(fileURLWithPath: "/tmp/a")).failureMessage
      == "popover export failed")
}

@Test func usageJSONCommandPrintsTheCachedSnapshotSet() throws {
  let cache = SnapshotCache(url: temporaryDirectory().appendingPathComponent("snapshots.json"))
  try cache.store(cachedSnapshots)

  let output = try UsageExportCommand.output(cache: cache)

  let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  let providers = try #require(json["providers"] as? [[String: Any]])
  #expect(providers.map { $0["id"] as? String } == ["claude", "codex"])
  #expect(providers[0]["plan"] as? String == "Max 20x")
  #expect(providers[1]["plan"] == nil)
  #expect(providers.map { $0["fetchedAt"] as? String } == ["2026-08-29T19:00:00Z", "2026-08-29T19:00:00Z"])
  let windows = try #require(providers[0]["windows"] as? [[String: Any]])
  #expect(windows.map { $0["id"] as? String } == ["session", "weekly"])
  #expect(windows.map { $0["label"] as? String } == ["Current session", "Weekly"])
  #expect(windows.map { $0["usedPercent"] as? Double } == [36, 61])
  #expect(windows[0]["resetsAt"] as? String == "2026-08-29T20:00:00Z")
  #expect(windows[1]["resetsAt"] == nil)
  #expect(output.hasSuffix("}"))
}

@Test(arguments: [URL?.none, temporaryDirectory().appendingPathComponent("missing.json")])
func usageJSONCommandFailsWithoutACache(url: URL?) {
  #expect(throws: UsageExportCommand.NoCachedUsage()) {
    try UsageExportCommand.output(cache: SnapshotCache(url: url))
  }
  #expect(UsageExportCommand.NoCachedUsage().description.contains("no cached usage"))
}

@Test func usageExportRoundTripsThroughItsFile() throws {
  let url = temporaryDirectory().appendingPathComponent("nested/usage.json")
  let export = UsageExport(snapshots: cachedSnapshots)
  try export.write(to: url)
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  #expect(try decoder.decode(UsageExport.self, from: Data(contentsOf: url)) == export)
  #expect(export.providers.map(\.windows.count) == [2, 2])
}

@Test func snapshotPersistenceWritesTheUsageFileOnlyWhenAsked() async throws {
  let root = temporaryDirectory()
  let usageURL = root.appendingPathComponent(UsageExport.fileName)
  let persistence = SnapshotPersistence(
    cache: SnapshotCache(url: root.appendingPathComponent("snapshots.json")), usageFileURL: usageURL)

  await persistence.submitSnapshots(cachedSnapshots)
  await persistence.flush()
  #expect(!FileManager.default.fileExists(atPath: usageURL.path))

  await persistence.submitSnapshots(cachedSnapshots, writesUsageFile: true)
  await persistence.flush()
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  #expect(
    try decoder.decode(UsageExport.self, from: Data(contentsOf: usageURL)) == UsageExport(snapshots: cachedSnapshots))

  await persistence.submitSnapshots(cachedSnapshots, writesUsageFile: true)
  await persistence.flush()
  let workload = await persistence.workload
  #expect(workload.usageFileWrites == 1)
  #expect(workload.cacheWrites == 1)
}

@Test func snapshotPersistenceSkipsTheUsageFileWithoutALocation() async throws {
  let persistence = SnapshotPersistence(cache: SnapshotCache(url: nil))
  await persistence.submitSnapshots(cachedSnapshots, writesUsageFile: true)
  await persistence.flush()
  #expect((await persistence.workload).usageFileWrites == 0)
}

@Test func snapshotPersistenceReportsUsageFileWriteFailures() async throws {
  let blocker = temporaryDirectory().appendingPathComponent("blocker")
  try Data().write(to: blocker)
  let failures = UsageFileFailureRecorder()
  let persistence = SnapshotPersistence(
    cache: SnapshotCache(url: nil), usageFileURL: blocker.appendingPathComponent("usage.json")
  ) { await failures.record($0) }
  await persistence.submitSnapshots(cachedSnapshots, writesUsageFile: true)
  await persistence.flush()
  let recorded = await failures.values
  #expect(recorded.count == 1)
  #expect(recorded.first?.message.hasPrefix("usage file write failed: ") == true)
  #expect((await persistence.workload).usageFileWrites == 0)
}

@Test @MainActor func settingsPersistTheUsageFileAndFirstRunChoices() {
  let defaults = testDefaults()
  let settings = Settings(defaults: defaults)
  #expect(!settings.writeUsageFile)
  #expect(!settings.firstRunCardDismissed)
  settings.writeUsageFile = true
  settings.firstRunCardDismissed = true
  let reloaded = Settings(defaults: defaults)
  #expect(reloaded.writeUsageFile)
  #expect(reloaded.firstRunCardDismissed)
  reloaded.resetToDefaults()
  #expect(!reloaded.writeUsageFile)
  #expect(!reloaded.firstRunCardDismissed)
}

private actor UsageFileFailureRecorder {
  private(set) var values: [SnapshotPersistenceFailure] = []

  func record(_ failure: SnapshotPersistenceFailure) {
    values.append(failure)
  }
}
