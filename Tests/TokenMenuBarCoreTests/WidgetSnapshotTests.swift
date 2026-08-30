import Foundation
import Testing
import TokenMenuBarCore

@Test func widgetSnapshotBuildsRowsFromSelection() {
  let snapshot = DemoData.snapshot(.claude, now: fixedNow)
  let keys = [
    WindowKey(provider: .claude, windowID: "session"), WindowKey(provider: .claude, windowID: "missing"),
    WindowKey(provider: .codex, windowID: "weekly"),
  ]
  let widget = WidgetSnapshot.build(
    snapshots: [.claude: snapshot], availability: [.codex: .authenticationRequired], selectedKeys: keys, now: fixedNow)
  #expect(widget.rows.map(\.key) == [keys[0]])
  #expect(widget.rows[0].providerName == "Claude")
  #expect(widget.rows[0].label == "Current session")
  #expect(widget.rows[0].percentText == Format.percent(snapshot.windows[0].usedPercent))
  #expect(widget.rows[0].resetText(now: fixedNow) == Format.countdown(to: snapshot.windows[0].resetsAt, now: fixedNow))
  #expect(widget.attention)
  #expect(widget.updatedAt == fixedNow)
  #expect(widget.isStale)
  #expect(!WidgetSnapshot.placeholder.isStale)
  #expect(WidgetSnapshot.placeholder.rows.count == 3)
  #expect(widget.rows[0].id == keys[0])
}

@Test func widgetStoreRoundTripsAndResolvesSharedURL() throws {
  let root = temporaryDirectory()
  let store = WidgetSnapshotStore(url: root.appendingPathComponent("nested/widget.json"))
  #expect(store.read() == nil)
  let snapshot = WidgetSnapshot.build(
    snapshots: [.claude: DemoData.snapshot(.claude, now: fixedNow)], availability: [:],
    selectedKeys: [WindowKey(provider: .claude, windowID: "session")], now: fixedNow)
  try store.write(snapshot)
  #expect(store.read()?.rows == snapshot.rows)
  #expect(store.read()?.updatedAt == fixedNow)
  try Data("{".utf8).write(to: store.url)
  #expect(store.read() == nil)
  let shared = WidgetSnapshotStore.sharedURL(
    containerURL: { URL(fileURLWithPath: "/container/\($0)") }, fallbackDirectory: root)
  #expect(shared.path == "/container/\(WidgetSnapshot.appGroup)/widget.json")
  let fallback = WidgetSnapshotStore.sharedURL(containerURL: { _ in nil }, fallbackDirectory: root)
  #expect(fallback == root.appendingPathComponent("widget.json"))
  #expect(WidgetSnapshot.appGroup(info: nil) == WidgetSnapshot.appGroup)
  #expect(WidgetSnapshot.appGroup(info: ["TokenMenuBarAppGroup": "$(APP_GROUP_ID)"]) == WidgetSnapshot.appGroup)
  #expect(WidgetSnapshot.appGroup(info: ["TokenMenuBarAppGroup": ""]) == WidgetSnapshot.appGroup)
  #expect(WidgetSnapshot.appGroup(info: ["TokenMenuBarAppGroup": "TEAM.dev.tox"]) == "TEAM.dev.tox")
  let unwritable = WidgetSnapshotStore(url: URL(fileURLWithPath: "/dev/null/widget.json"))
  #expect(throws: (any Error).self) { try unwritable.write(snapshot) }
}
