import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore

@testable import TokenMenuBarUI

@Test @MainActor func rootViewHostsEveryTab() async throws {
  let environment = try makeEnvironment()
  var measured: [String] = []
  var selected: [String] = []
  for tab in PopoverTab.allCases {
    environment.settings.lastTab = tab
    let view = RootView(
      environment: environment, onMeasure: { name, _ in measured.append(name) }, onTabChange: { selected.append($0) })
    let hosting = host(view)
    #expect(hosting.fittingSize.width >= PopoverGeometry.minimumWidth)
    try await Task.sleep(for: .milliseconds(50))
    view.select(.history)
  }
  #expect(selected == ["History", "History", "History"])
  #expect(environment.settings.lastTab == .history)
  environment.tick()
  #expect(environment.now == fixedNow)
  await environment.loadRecentSamples()
  #expect(environment.samples.count == 6)
  #expect(environment.cards.count == 2)
}

@Test @MainActor func tabPickerRoundTrips() {
  var selection = PopoverTab.usage
  let binding = Binding(get: { selection }, set: { selection = $0 })
  _ = host(TabPicker(selection: binding), width: 300, height: 40)
  let coordinator = TabPicker.Coordinator(selection: binding)
  let control = NSSegmentedControl(
    labels: PopoverTab.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
  control.selectedSegment = 2
  coordinator.changed(control)
  #expect(selection == .settings)
  control.selectedSegment = -1
  coordinator.changed(control)
  #expect(selection == .usage)
  #expect(TabPicker.tooltip(.history).contains("analytics"))
  #expect(TabPicker.tooltip(.usage).contains("limits"))
  #expect(TabPicker.tooltip(.settings).contains("Menu bar"))
}

@Test @MainActor func usageTabRendersCardsAndEmptyStates() throws {
  let environment = try makeEnvironment()
  _ = host(UsageTab(environment: environment))
  environment.settings.enabledProviders = []
  environment.state.remove(.claude)
  environment.state.remove(.codex)
  _ = host(UsageTab(environment: environment))
  let empty = try makeEnvironment(populate: false)
  empty.state.update(.claude) {
    $0.availability = .authenticationRequired
    $0.credentialState = .missing("none")
  }
  empty.state.update(.codex) { $0.availability = .networkUnavailable }
  _ = host(UsageTab(environment: empty))
  let card = ProviderCardView(card: empty.cards[0], environment: empty)
  #expect(card.icon(for: .authenticationRequired) == "person.crop.circle.badge.exclamationmark")
  #expect(card.icon(for: .networkUnavailable) == "wifi.slash")
  #expect(card.icon(for: .disabled) == "pause.circle")
  #expect(card.icon(for: .loading) == "hourglass")
  #expect(card.icon(for: .current) == "chart.bar")
}

@Test @MainActor func windowRowsSpendAndCreditsRender() {
  let snapshot = sampleSnapshot(.claude)
  let card = UsagePresenter.card(
    provider: .claude, state: ProviderState(snapshot: snapshot, availability: .current), samples: [:], now: fixedNow)
  for row in card.rows {
    let view = WindowRowView(row: row, now: fixedNow)
    _ = host(view, width: 400, height: 120)
  }
  let ahead = WindowRow(
    key: card.rows[0].key, window: card.rows[0].window,
    pace: PaceEstimate(status: .ahead, expectedPercent: 10, ratio: 3, projectedExhaustion: nil), countdown: "1h",
    resetClock: "x")
  #expect(WindowRowView(row: ahead, now: fixedNow).paceColor == .orange)
  let behind = WindowRow(
    key: card.rows[0].key, window: card.rows[0].window,
    pace: PaceEstimate(status: .behind, expectedPercent: 10, ratio: 0.1, projectedExhaustion: nil), countdown: "1h",
    resetClock: "x")
  #expect(WindowRowView(row: behind, now: fixedNow).paceColor == .secondary)
  #expect(WindowRowView(row: card.rows[0], now: fixedNow).paceColor == .orange)
  let onTrack = WindowRow(
    key: card.rows[0].key, window: card.rows[0].window,
    pace: PaceEstimate(status: .onTrack, expectedPercent: 30, ratio: 1, projectedExhaustion: nil), countdown: "1h",
    resetClock: "x")
  #expect(WindowRowView(row: onTrack, now: fixedNow).paceColor == .green)
  _ = host(SpendView(spend: snapshot.spend!, provider: .claude, now: fixedNow), width: 400, height: 200)
  _ = host(
    SpendView(spend: SpendControl(enabled: false, disabledReason: "off"), provider: .codex, now: fixedNow), width: 400,
    height: 200)
  _ = host(CreditsView(credits: snapshot.credits, resetCredits: snapshot.resetCredits), width: 400, height: 200)
  _ = host(CreditsView(credits: nil, resetCredits: nil), width: 400, height: 200)
  _ = host(LocalUsageView(usage: snapshot.localUsage!), width: 400, height: 200)
  #expect(LocalUsageView.money(3.456) == "$3.46")
  #expect(LocalUsageView.money(42.4) == "$42")
}

@Test @MainActor func historyTabRendersStatesAndInteractions() async throws {
  let environment = try makeEnvironment()
  let history = environment.history
  let earlier = fixedNow.addingTimeInterval(-3600)
  try await history.record(
    ProviderSnapshot(
      provider: .claude,
      windows: [
        QuotaWindow(
          id: "session", label: "Session", group: .session, usedPercent: 10,
          resetsAt: fixedNow.addingTimeInterval(3600), duration: 18000)
      ], fetchedAt: earlier), now: earlier)
  try await history.record(sampleSnapshot(.claude), now: fixedNow.addingTimeInterval(-60))
  try await history.record(
    ProviderAnalytics(
      provider: .codex, points: [AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .turns, series: "m", value: 3)],
      fetchedAt: fixedNow))
  _ = host(HistoryTab(environment: environment), width: 700, height: 800)
  let presenter = environment.historyPresenter
  presenter.reload()
  await presenter.waitForLoad()
  _ = host(HistoryTab(environment: environment), width: 700, height: 800)
  environment.settings.historyRange = .custom
  environment.settings.historyStacked = true
  environment.settings.historyRollup = .day
  _ = host(HistoryTab(environment: environment), width: 700, height: 800)
  let data = presenter.state.data!
  let chart = UsageChart(data: data, presenter: presenter, stacked: false, timeZone: .current)
  #expect(chart.opacity(data.series[0].key) == 1)
  presenter.hoveredKey = data.series[0].key
  #expect(chart.opacity(WindowKey(provider: .codex, windowID: "x")) == 0.18)
  #expect(UsageChart.color(index: 9) == UsageChart.palette[1])
  #expect(
    UsageChart.axisFormat(for: fixedNow...fixedNow.addingTimeInterval(3600))
      != UsageChart.axisFormat(for: fixedNow...fixedNow.addingTimeInterval(5 * 86400)))
  presenter.select(x: fixedNow)
  _ = host(UsageChart(data: data, presenter: presenter, stacked: true, timeZone: .current), width: 400, height: 240)
  _ = host(HistoryInspector(environment: environment), width: 240, height: 300)
  environment.settings.historyHiddenKeys = [data.series[0].key]
  _ = host(HistoryInspector(environment: environment), width: 240, height: 300)
  presenter.reload()
  await presenter.waitForLoad()
  _ = host(
    AnalyticsSectionsView(provider: .codex, sections: presenter.analytics[.codex]!, environment: environment),
    width: 500, height: 300)
  try await history.breakDatabase()
  presenter.reload()
  await presenter.waitForLoad()
  _ = host(HistoryTab(environment: environment), width: 700, height: 800)
}

@Test @MainActor func settingsTabRendersAndMutates() throws {
  let environment = try makeEnvironment()
  var changes = 0
  environment.actions.settingsChanged = { changes += 1 }
  environment.settings.statusFormat = .custom
  environment.settings.customTemplate = "{label} {pct}"
  _ = host(SettingsTab(environment: environment), width: 520, height: 1200)
  environment.launchAtLoginStatus = .enabled
  environment.canCheckForUpdates = false
  environment.isSandboxed = false
  _ = host(SettingsTab(environment: environment), width: 520, height: 1200)
  let list = WindowSelectionList(environment: environment)
  #expect(list.rows.count == 6)
  let key = WindowKey(provider: .claude, windowID: "session")
  list.toggle(key, on: false)
  #expect(!environment.settings.selectedWindows.contains(key))
  list.toggle(key, on: true)
  list.toggle(key, on: true)
  #expect(environment.settings.selectedWindows.contains(key))
  environment.settings.selectedWindows = [key]
  list.toggle(key, on: false)
  #expect(environment.settings.selectedWindows == [key])
  list.setLabel(key, "S")
  #expect(environment.settings.shortLabels[key] == "S")
  list.setLabel(key, "")
  #expect(environment.settings.shortLabels[key] == nil)
  #expect(changes == 6)
  _ = host(WindowSelectionList(environment: environment), width: 400, height: 300)
  let empty = try makeEnvironment(populate: false)
  _ = host(WindowSelectionList(environment: empty), width: 400, height: 100)
  _ = host(StatusPreview(model: statusModel()), width: 300, height: 40)
  _ = host(LogSection(environment: environment), width: 400, height: 300)
}

@Test @MainActor func logTextViewUpdatesInPlace() {
  let entries = [
    LogEntry(timestamp: fixedNow, level: .info, message: "one"),
    LogEntry(timestamp: fixedNow, level: .error, message: "two"),
  ]
  let hosting = host(LogTextView(entries: entries, height: 100), width: 300, height: 120)
  let scroll = hosting.subviews.compactMap { $0 as? NSScrollView }.first ?? findScrollView(hosting)!
  let textView = scroll.documentView as! NSTextView
  #expect(textView.string.contains("[error] two"))
  hosting.rootView = LogTextView(entries: entries, height: 100)
  hosting.layoutSubtreeIfNeeded()
  hosting.rootView = LogTextView(entries: [], height: 100)
  hosting.layoutSubtreeIfNeeded()
  #expect(textView.string.isEmpty)
}

@MainActor
func findScrollView(_ view: NSView) -> NSScrollView? {
  for subview in view.subviews {
    if let scroll = subview as? NSScrollView { return scroll }
    if let found = findScrollView(subview) { return found }
  }
  return nil
}

@Test @MainActor func componentsRender() {
  _ = host(Banner("see https://example.com/docs now", tone: .info), width: 300, height: 60)
  _ = host(Banner("plain"), width: 300, height: 60)
  let attributed = LinkifiedText.attributed("a https://x.y/z) b")
  #expect(attributed.runs.contains { $0.link != nil })
  var copied: [String] = []
  var opened: [URL] = []
  let chip = ChipView(
    chip: Chip(text: "Max", link: URL(string: "https://claude.ai")!), onCopy: { copied.append($0) },
    onOpen: { opened.append($0) })
  _ = host(chip, width: 200, height: 40)
  _ = host(
    ChipView(chip: Chip(text: "plain"), onCopy: { copied.append($0) }, onOpen: { opened.append($0) }), width: 200,
    height: 40)
  _ = host(UsageBar(percent: 150, color: .red), width: 200, height: 10)
  _ = host(MetricCell(title: "t", value: "v", help: "h"), width: 200, height: 40)
  _ = host(WrappingHStack { ForEach(0..<12, id: \.self) { Text("chip \($0)").padding(4) } }, width: 200, height: 200)
  let layout = WrappingHStack()
  #expect(layout.horizontalSpacing == 6)
  var size = CGSize.zero
  SizeKey.reduce(value: &size) { CGSize(width: 1, height: 2) }
  SizeKey.reduce(value: &size) { .zero }
  #expect(size == CGSize(width: 1, height: 2))
  _ = host(Color.red.frame(width: 10, height: 10).measureSize { _ in }, width: 20, height: 20)
  _ = host(ScrollingTab { Text("x") }, width: 200, height: 200)
  #expect(Color(HSBColor(hue: 0.3, saturation: 0.5, brightness: 0.5)) != Color.clear)
  _ = host(Text("help").hoverHelp { Text("tip") }, width: 100, height: 40)
  let plain = NSView(frame: .zero)
  ScrollerStyler.apply(from: plain)
  let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
  let inner = NSView(frame: .zero)
  scroll.documentView = inner
  ScrollerStyler.apply(from: inner)
  #expect(scroll.scrollerStyle == .overlay)
  _ = host(ScrollerStyler(), width: 10, height: 10)
}
