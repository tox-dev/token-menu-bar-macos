import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore
import TokenMenuBarWidgets
import WidgetKit

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

@Test func timelineProviderDefaultClockUsesTheCurrentDate() {
  let before = Date()

  let entry = UsageTimelineProvider(store: temporaryStore()).placeholderEntry()

  #expect(entry.date >= before)
  #expect(entry.date <= Date())
}

private let fixedNow = Date(timeIntervalSince1970: 1_788_030_000)

private func temporaryStore() -> WidgetSnapshotStore {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-widget-\(UUID().uuidString)")
  return WidgetSnapshotStore(url: root.appendingPathComponent("widget.json"))
}

@Test(arguments: [WidgetFamily.systemSmall, .systemMedium, .systemLarge])
@MainActor func widgetViewsRenderEveryFamily(family: WidgetFamily) {
  let view = UsageWidgetView(entry: populatedEntry, family: family)
  #expect(view.rows.count == min(view.rowLimit, 3))
  #expect(inkFraction(view, width: 300, height: 300) > 0)
}

@MainActor
private func inkFraction<Content: View>(_ view: Content, width: CGFloat, height: CGFloat) -> Double {
  let hosting = host(view, width: width, height: height)
  guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 0 }
  hosting.cacheDisplay(in: hosting.bounds, to: rep)
  guard let image = rep.cgImage, image.width > 0, image.height > 0 else { return 0 }
  var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
  let context = CGContext(
    data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  return Double(stride(from: 3, to: pixels.count, by: 4).count { pixels[$0] > 8 }) / Double(image.width * image.height)
}

private let populatedEntry = UsageEntry(
  date: fixedNow,
  snapshot: WidgetSnapshot(rows: WidgetSnapshot.placeholder.rows, attention: true, updatedAt: fixedNow))

@Test @MainActor func widgetViewsHostEntryAndRows() {
  let entry = populatedEntry
  #expect(UsageWidgetView(entry: entry, family: .systemLarge).rowLimit == 8)
  let empty = UsageWidgetView(
    entry: UsageEntry(date: fixedNow, snapshot: WidgetSnapshot(rows: [], attention: false, updatedAt: fixedNow)),
    family: .systemSmall)
  #expect(inkFraction(empty, width: 160, height: 160) > 0)
  #expect(inkFraction(UsageWidgetEntryView(entry: entry), width: 300, height: 300) > 0)
  let row = WidgetRowView(row: WidgetSnapshot.placeholder.rows[0], now: fixedNow, compact: false)
  #expect(inkFraction(row, width: 300, height: 60) > 0)
  #expect(row.color != Color.clear)
  #expect(UsageWidget.kind.hasPrefix("dev.tox"))
  _ = UsageWidget().body
}

@Test @MainActor func widgetViewRendersTheUnavailableInstruction() {
  let entry = UsageEntry(date: fixedNow, snapshot: .unavailable)

  #expect(inkFraction(UsageWidgetView(entry: entry, family: .systemSmall), width: 160, height: 160) > 0)
}

@MainActor
private var hostingWindows: [NSWindow] = []

@MainActor
private func host<Content: View>(_ view: Content, width: CGFloat, height: CGFloat) -> NSHostingView<Content> {
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
