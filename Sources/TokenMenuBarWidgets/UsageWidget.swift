import SwiftUI
import TokenMenuBarCore
import WidgetKit

public struct UsageEntry: TimelineEntry, Sendable {
  public let date: Date
  public let snapshot: WidgetSnapshot

  public init(date: Date, snapshot: WidgetSnapshot) {
    self.date = date
    self.snapshot = snapshot
  }
}

public struct UsageTimelineProvider: Sendable {
  public static let refreshInterval = WidgetSnapshot.refreshInterval

  public let store: WidgetSnapshotStore
  public let now: @Sendable () -> Date

  public init(store: WidgetSnapshotStore, now: @escaping @Sendable () -> Date = { Date() }) {
    self.store = store
    self.now = now
  }

  public static func defaultStore(
    containerURL: (String) -> URL? = {
      FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
    },
    fallbackDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Token Menu Bar"),
    appGroup: String = WidgetSnapshot.appGroup(info: Bundle.main.infoDictionary)
  ) -> WidgetSnapshotStore {
    WidgetSnapshotStore(
      url: WidgetSnapshotStore.sharedURL(
        containerURL: containerURL, fallbackDirectory: fallbackDirectory, appGroup: appGroup))
  }

  public func placeholderEntry() -> UsageEntry {
    UsageEntry(date: now(), snapshot: .placeholder)
  }

  public func timeline() -> Timeline<UsageEntry> {
    let entry = entry()
    return Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(Self.refreshInterval)))
  }

  public func entry() -> UsageEntry {
    UsageEntry(date: now(), snapshot: store.read() ?? .unavailable)
  }
}

public struct UsageWidgetView: View {
  public let entry: UsageEntry
  public let family: WidgetFamily
  public let increaseContrast: Bool

  public init(entry: UsageEntry, family: WidgetFamily, increaseContrast: Bool = false) {
    self.entry = entry
    self.family = family
    self.increaseContrast = increaseContrast
  }

  public var rows: [WidgetRow] {
    Array(entry.snapshot.rows.prefix(rowLimit))
  }

  public var rowLimit: Int {
    switch family {
    case .systemSmall: 3
    case .systemMedium: 4
    default: 8
    }
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("Token Menu Bar").font(.caption.weight(.semibold))
        Spacer()
        if entry.snapshot.attention {
          Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        }
        if entry.snapshot.hasData {
          Text(entry.snapshot.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
        }
      }
      if rows.isEmpty {
        Text(entry.snapshot.hasData ? "Open Token Menu Bar to pick windows." : "Open Token Menu Bar to start tracking.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      ForEach(rows) { row in
        WidgetRowView(
          row: row, now: entry.date, compact: family == .systemSmall, increaseContrast: increaseContrast,
          display: entry.snapshot.display)
      }
      Spacer(minLength: 0)
    }
    .containerBackground(.background, for: .widget)
  }
}

public struct WidgetRowView: View {
  public let row: WidgetRow
  public let now: Date
  public let compact: Bool
  public let increaseContrast: Bool
  public let display: UsageDisplay

  public init(
    row: WidgetRow, now: Date, compact: Bool, increaseContrast: Bool = false, display: UsageDisplay = .used
  ) {
    self.row = row
    self.now = now
    self.compact = compact
    self.increaseContrast = increaseContrast
    self.display = display
  }

  public var color: Color {
    let hsb = UsageColor.color(percent: row.usedPercent, contrast: UsageContrast(increased: increaseContrast))
    return Color(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        Text(compact ? row.label : "\(row.providerName) \(row.label)").font(.caption).lineLimit(1)
        Spacer()
        Text(row.percentText(display: display)).font(.caption.monospacedDigit().weight(.semibold))
          .foregroundStyle(color)
      }
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.primary.opacity(0.12))
          Capsule().fill(color).frame(width: max(proxy.size.width * row.usedPercent / 100, 3))
          if increaseContrast {
            Capsule().strokeBorder(Color.primary, lineWidth: 1)
          }
        }
      }
      .frame(height: 4)
      if !compact {
        resetText.font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private var resetText: some View {
    if let resetsAt = row.resetsAt, resetsAt > now {
      HStack(spacing: 3) {
        Text("Resets in")
        Text(timerInterval: now...resetsAt, countsDown: true)
      }
    } else {
      Text(row.resetsAt == nil ? "Reset unavailable" : "Reset due")
    }
  }
}

public struct UsageWidgetEntryView: View {
  public let entry: UsageEntry
  @Environment(\.widgetFamily) private var family
  @Environment(\.colorSchemeContrast) private var contrast

  public init(entry: UsageEntry) {
    self.entry = entry
  }

  public var body: some View {
    UsageWidgetView(entry: entry, family: family, increaseContrast: contrast == .increased)
  }
}
