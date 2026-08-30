import AppKit
import SwiftUI
import Testing
import WidgetKit

@testable import TokenMenuBarCore
@testable import TokenMenuBarWidgets

private let fixedNow = Date(timeIntervalSince1970: 1_788_030_000)

@MainActor
private var hostingWindows: [NSWindow] = []

@MainActor
private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSHostingView<V> {
  let hosting = NSHostingView(rootView: view)
  hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
  let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = hosting
  hosting.layoutSubtreeIfNeeded()
  hosting.displayIfNeeded()
  hostingWindows.append(window)
  return hosting
}

private func temporaryStore() -> WidgetSnapshotStore {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-widget-\(UUID().uuidString)")
  return WidgetSnapshotStore(url: root.appendingPathComponent("widget.json"))
}

@Test func timelineProviderReadsStoreOrPlaceholder() throws {
  let store = temporaryStore()
  let provider = UsageTimelineProvider(store: store, now: { fixedNow })
  // a live timeline must never show the sample percentages
  #expect(provider.entry().snapshot == .unavailable)
  #expect(!provider.entry().snapshot.hasData)
  let snapshot = WidgetSnapshot(
    rows: Array(WidgetSnapshot.placeholder.rows.prefix(1)), attention: true, updatedAt: fixedNow)
  try store.write(snapshot)
  #expect(provider.entry().snapshot.rows.count == 1)
  #expect(provider.entry().date == fixedNow)
  #expect(provider.placeholderEntry().snapshot == .placeholder)
  #expect(WidgetSnapshot.placeholder.hasData)
  let timeline = provider.timeline()
  #expect(timeline.entries.count == 1)
  #expect(timeline.entries[0].snapshot.attention)
  #expect(
    UsageTimelineProvider.defaultStore(
      containerURL: { _ in nil }, fallbackDirectory: store.url.deletingLastPathComponent()
    ).url == store.url)
  #expect(UsageTimelineProvider.defaultStore().url.lastPathComponent == WidgetSnapshot.fileName)
}

@Test @MainActor func widgetViewsHostEveryFamily() {
  let entry = UsageEntry(
    date: fixedNow,
    snapshot: WidgetSnapshot(rows: WidgetSnapshot.placeholder.rows, attention: true, updatedAt: fixedNow))
  for family in [WidgetFamily.systemSmall, .systemMedium, .systemLarge] {
    let view = UsageWidgetView(entry: entry, family: family)
    #expect(view.rows.count == min(view.rowLimit, 3))
    _ = host(view, width: 300, height: 300)
  }
  #expect(UsageWidgetView(entry: entry, family: .systemLarge).rowLimit == 8)
  let empty = UsageWidgetView(
    entry: UsageEntry(date: fixedNow, snapshot: WidgetSnapshot(rows: [], attention: false, updatedAt: fixedNow)),
    family: .systemSmall)
  _ = host(empty, width: 160, height: 160)
  _ = host(UsageWidgetEntryView(entry: entry), width: 300, height: 300)
  let row = WidgetRowView(row: WidgetSnapshot.placeholder.rows[0], now: fixedNow, compact: false)
  _ = host(row, width: 300, height: 60)
  #expect(row.color != Color.clear)
  #expect(UsageWidget.kind.hasPrefix("dev.tox"))
  _ = UsageWidget().body
}
