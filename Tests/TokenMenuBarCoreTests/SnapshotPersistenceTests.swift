import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func snapshotPersistenceLoadsCacheOnceAndReportsMalformedData() async throws {
  let root = temporaryDirectory()
  let cache = SnapshotCache(url: root.appendingPathComponent("snapshots.json"))
  try cache.store([.claude: DemoData.snapshot(.claude, now: fixedNow)])
  let persistence = SnapshotPersistence(cache: cache)
  async let first = persistence.loadSnapshots()
  async let second = persistence.loadSnapshots()
  let loaded = await [first, second]
  #expect(loaded.allSatisfy { $0[.claude]?.source == .cache })
  #expect((await persistence.workload).cacheLoads == 1)

  let malformed = SnapshotCache(url: root.appendingPathComponent("malformed.json"))
  try Data("{".utf8).write(to: malformed.url!)
  let failures = PersistenceFailureRecorder()
  let broken = SnapshotPersistence(cache: malformed) { await failures.record($0) }
  #expect(await broken.loadSnapshots().isEmpty)
  #expect(await failures.values.count == 1)
}

@Test func snapshotPersistenceCoalescesCacheWritesToTheLatestValue() async throws {
  let cache = SnapshotCache(url: temporaryDirectory().appendingPathComponent("snapshots.json"))
  let persistence = SnapshotPersistence(cache: cache)
  await withTaskGroup(of: Void.self) { group in
    for percent in 0..<100 {
      group.addTask {
        let snapshot = DemoData.snapshot(.claude, now: fixedNow.addingTimeInterval(Double(percent)))
        await persistence.submitSnapshots([.claude: snapshot])
      }
    }
  }
  let latest = DemoData.snapshot(.codex, now: fixedNow.addingTimeInterval(1_000))
  await persistence.submitSnapshots([.codex: latest])
  await persistence.flush()
  #expect(cache.load()[.codex]?.fetchedAt == latest.fetchedAt)
  let workload = await persistence.workload
  #expect(workload.cacheSubmissions == 101)
  #expect(workload.coalescedCacheSubmissions > 0)
  #expect(workload.cacheWrites < workload.cacheSubmissions)
}

@Test @MainActor func snapshotPersistenceReloadsWidgetsOncePerWrittenValue() async throws {
  let store = WidgetSnapshotStore(url: temporaryDirectory().appendingPathComponent("widget.json"))
  let reloads = WidgetReloadRecorder()
  let failures = PersistenceFailureRecorder()
  let persistence = SnapshotPersistence(cache: SnapshotCache(url: nil), widgetStore: store) { failure in
    await failures.record(failure)
  } reloadWidgets: {
    reloads.count += 1
  }
  await persistence.submitWidget(.placeholder)
  await persistence.flush()
  let stored = try #require(store.read())
  #expect(stored.rows.map(\.key) == WidgetSnapshot.placeholder.rows.map(\.key))
  #expect(stored.rows.map(\.usedPercent) == WidgetSnapshot.placeholder.rows.map(\.usedPercent))
  #expect(stored.attention == WidgetSnapshot.placeholder.attention)
  #expect(reloads.count == 1)
  await persistence.submitWidget(.placeholder)
  await persistence.flush()
  #expect(reloads.count == 1)
  let workload = await persistence.workload
  #expect(workload.widgetWrites == 1)
  #expect(workload.widgetReloads == 1)
  #expect(await failures.values.isEmpty)
}

@Test func snapshotPersistenceReportsWriteFailures() async {
  let failures = PersistenceFailureRecorder()
  let persistence = SnapshotPersistence(
    cache: SnapshotCache(url: URL(fileURLWithPath: "/dev/null/snapshots.json")),
    widgetStore: WidgetSnapshotStore(url: URL(fileURLWithPath: "/dev/null/widget.json"))
  ) { await failures.record($0) }
  await persistence.submitSnapshots([.claude: DemoData.snapshot(.claude, now: fixedNow)])
  await persistence.submitWidget(.placeholder)
  await persistence.flush()
  let values = await failures.values
  #expect(values.contains { if case .cacheWrite = $0 { true } else { false } })
  #expect(values.contains { if case .widgetWrite = $0 { true } else { false } })
}

private actor PersistenceFailureRecorder {
  private(set) var values: [SnapshotPersistenceFailure] = []

  func record(_ failure: SnapshotPersistenceFailure) {
    values.append(failure)
  }
}

@MainActor
private final class WidgetReloadRecorder {
  var count = 0
}
