import SwiftUI
import TokenMenuBarCore
import WidgetKit

// WidgetKit hands these entry points a context that no test can construct outside an extension host, so this file
// holds the calls alone and the coverage gate caps its size instead.
extension UsageTimelineProvider: TimelineProvider {
  public func placeholder(in context: Context) -> UsageEntry {
    placeholderEntry()
  }

  public func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
    completion(entry())
  }

  public func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
    completion(timeline())
  }
}

public struct UsageWidget: Widget {
  public static let kind = "dev.tox.token-menu-bar.usage"

  public init() {}

  public var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: UsageTimelineProvider(store: UsageTimelineProvider.defaultStore())) {
      UsageWidgetEntryView(entry: $0)
    }
    .configurationDisplayName("Plan usage")
    .description("Claude, Codex and other plan windows with reset countdowns.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}
