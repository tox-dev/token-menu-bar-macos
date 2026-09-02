import AppKit
import SwiftUI
import TokenMenuBarCore

public struct LogSection: View {
  @Bindable var environment: UIEnvironment
  @State private var entries: [LogEntry]
  @State private var level: LogLevel?
  @State private var search = ""

  public init(environment: UIEnvironment) {
    self.environment = environment
    _entries = State(initialValue: environment.log.snapshot)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          actions
          Spacer()
          options
        }
        VStack(alignment: .leading, spacing: 7) {
          actions
          options
        }
      }
      LogViewer(
        entries: displayedEntries, level: $level, search: $search, height: 150, newestFirst: true,
        searchShortcut: false)
    }
    .task {
      for await snapshot in environment.log.snapshots() { entries = snapshot }
    }
  }

  public func setDetailedLogging(_ enabled: Bool) {
    environment.settings.detailedLogging = enabled
    environment.log.debugEnabled = enabled
    environment.actions.settingsChanged()
  }

  func setDemoMode(_ enabled: Bool) {
    environment.actions.setDemoMode(enabled)
  }

  func copyDisplayedEntries() {
    environment.actions.copy(exportedEntries)
  }

  func clear() {
    environment.log.clear()
  }

  func showFullLog() {
    environment.actions.showFullLog()
  }

  var demoModeBinding: Binding<Bool> {
    Binding(get: { environment.isDemo }, set: { setDemoMode($0) })
  }

  var detailedLoggingBinding: Binding<Bool> {
    Binding(get: { environment.settings.detailedLogging }, set: { setDetailedLogging($0) })
  }

  private var displayedEntries: [LogEntry] {
    Array(entries.suffix(200))
  }

  private var actions: some View {
    HStack(spacing: 8) {
      NativeActionButton("Copy", action: copyDisplayedEntries)
        .richHelp(
          TooltipContent(
            title: "Copy log",
            body: "Copies the visible lines after applying the level and search filters. Private values are redacted."))
      NativeActionButton("Clear", intent: .destructive, action: clear)
        .richHelp(
          TooltipContent(
            title: "Clear log",
            body: "Removes the in-memory log and its rotated files. New events continue to be recorded."))
      NativeActionButton("Show Full Log", action: showFullLog)
        .richHelp(
          TooltipContent(
            title: "Show full log", body: "Opens every retained line in a larger searchable window."))
    }
  }

  private var options: some View {
    HStack(spacing: 8) {
      Toggle(
        "Demo data",
        isOn: demoModeBinding
      )
      .toggleStyle(.checkbox)
      .richHelp(
        TooltipContent(
          title: "Demo data",
          body:
            "Replaces providers with generated data in a separate history file. "
            + "Turning it off restores real data after relaunch."
        ))
      Toggle(
        "Detailed logging",
        isOn: detailedLoggingBinding
      )
      .toggleStyle(.checkbox)
      .richHelp(
        TooltipContent(
          title: "Detailed logging",
          body:
            "Records panel geometry, tab measurements, status-item re-tiers, and refresh outcomes. "
            + "Off keeps routine and failure messages only."
        ))
      Text("off by default")
        .font(.caption2)
        .semanticForeground(.secondary)
    }
  }

  private var exportedEntries: String {
    let filter = LogFilter(search: search, levels: Self.selectedLevels(level))
    return LogExport.text(entries: filter.entries(from: displayedEntries.reversed()))
  }

  static func selectedLevels(_ level: LogLevel?) -> Set<LogLevel> {
    if let level { [level] } else { Set(LogLevel.allCases) }
  }
}

public struct FullLogView: View {
  public let log: LogBuffer
  @State private var entries: [LogEntry]
  @State private var level: LogLevel?
  @State private var search = ""

  public init(log: LogBuffer) {
    self.log = log
    _entries = State(initialValue: log.snapshot)
  }

  public var body: some View {
    LogViewer(
      entries: entries, level: $level, search: $search, height: nil, newestFirst: false,
      searchShortcut: true
    )
    .padding(12)
    .task {
      var retained = await log.retainedSnapshot()
      entries = retained
      var previousLive: [LogEntry] = []
      for await snapshot in log.snapshots() {
        if snapshot.isEmpty {
          retained.removeAll(keepingCapacity: true)
          entries.removeAll(keepingCapacity: true)
        } else if previousLive.isEmpty {
          entries = Self.merge(retained: retained, live: snapshot)
        } else {
          let overlap = Self.overlap(previousLive, snapshot)
          if overlap > 0 {
            entries.append(contentsOf: snapshot.dropFirst(overlap))
          } else {
            retained = await log.retainedSnapshot()
            entries = Self.merge(retained: retained, live: snapshot)
          }
        }
        if entries.count > LogBuffer.retainedEntryLimit + LogBuffer.capacity {
          entries.removeFirst(entries.count - LogBuffer.retainedEntryLimit)
        }
        previousLive = snapshot
      }
    }
  }

  static func merge(retained: [LogEntry], live: [LogEntry]) -> [LogEntry] {
    guard !retained.isEmpty else { return live }
    guard !live.isEmpty else { return [] }
    let overlap = overlap(retained, live)
    return retained + Array(live.dropFirst(overlap))
  }

  static func overlap(_ previous: [LogEntry], _ current: [LogEntry]) -> Int {
    guard let first = current.first,
      let start = previous.firstIndex(where: { $0.sequenceID == first.sequenceID })
    else { return 0 }
    let count = min(previous.distance(from: start, to: previous.endIndex), current.count)
    return previous[start...].prefix(count).elementsEqual(
      current.prefix(count),
      by: {
        $0.sequenceID == $1.sequenceID
      }) ? count : 0
  }
}

private struct LogViewer: View {
  let entries: [LogEntry]
  @Binding var level: LogLevel?
  @Binding var search: String
  let height: CGFloat?
  let newestFirst: Bool
  let searchShortcut: Bool
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        NativeSegmentedControl(
          [(value: LogLevel?.none, label: "All")]
            + LogLevel.allCases.map { (value: LogLevel?.some($0), label: $0.title) },
          selection: $level,
          accessibilityLabel: "Log level"
        )
        .fixedSize()
        .richHelp(
          TooltipContent(
            title: "Log level",
            body: "Shows one severity. All keeps debug, information, warning, and error lines visible."))
        TextField("Search log", text: $search, prompt: Text("Search log…"))
          .textFieldStyle(.roundedBorder)
          .focused($searchFocused)
          .accessibilityLabel("Search log")
          .richHelp(
            TooltipContent(
              title: "Search log",
              body: "Filters retained lines as you type without changing or deleting the stored log."))
        if searchShortcut {
          Button("Search Log") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
      }
      .padding(6)
      .background(.quaternary.opacity(0.35))
      Divider()
      LogTextView(entries: filteredEntries, height: height, bordered: false, followsTail: !newestFirst)
        .frame(maxWidth: .infinity, maxHeight: height == nil ? .infinity : nil)
    }
    .background(.background.opacity(0.7))
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(.separator, lineWidth: 1)
    }
  }

  private var filteredEntries: [LogEntry] {
    let filter = LogFilter(search: search, levels: LogSection.selectedLevels(level))
    let result = filter.entries(from: entries)
    return newestFirst ? result.reversed() : result
  }
}
