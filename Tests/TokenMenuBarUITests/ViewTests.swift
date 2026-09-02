import Accessibility
import AppKit
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func rootViewHostsEveryTab() async throws {
  let environment = try makeEnvironment()
  environment.log.debugEnabled = true
  var measured: [PopoverTab] = []
  var selected: [PopoverTab] = []
  for tab in PopoverTab.allCases {
    environment.settings.lastTab = tab
    let view = RootView(
      environment: environment, onMeasure: { measured.append($0.tab) }, onTabChange: { selected.append($0) })
    let hosting = host(view)
    #expect(hosting.frame.width == 520)
    await waitUntil { measured.contains(tab) }
    view.select(.history)
  }
  #expect(selected == [.history, .history])
  #expect(environment.settings.lastTab == .history)
  environment.tick()
  #expect(environment.now == fixedNow)
  // The cards are the only reader, so nothing is fetched while the popover is closed.
  await environment.loadRecentSamples()
  #expect(environment.samples.isEmpty)
  environment.state.popoverVisible = true
  environment.settings.lastTab = .usage
  await environment.loadRecentSamples()
  #expect(environment.samples.count == 6)
  #expect(environment.cards.count == 2)
  #expect(environment.log.text.contains("tab.transition from="))
}

@Test @MainActor func rootTabsKeepOneFrameAcrossSwitches() async throws {
  let environment = try makeEnvironment()
  let root = RootView(environment: environment, onMeasure: { _ in }, onTabChange: { _ in })
  let hosting = host(root, width: 880, height: 900)
  await mainActorTurn()
  await mainActorTurn()
  hosting.layoutSubtreeIfNeeded()
  let controls: [NSSegmentedControl] = findViews(in: hosting)
  let tabControl = try #require(controls.first { $0.accessibilityLabel() == "Popover tabs" })
  #expect(controls.count { $0.accessibilityLabel() == "Popover tabs" } == 1)
  let frame = tabControl.frame

  for tab in PopoverTab.allCases + PopoverTab.allCases {
    root.select(tab)
    hosting.layoutSubtreeIfNeeded()
    #expect(tabControl.frame == frame)
  }
}

@Test @MainActor func rootViewAdvancesUsageDeadlinesOnlyWhileThePopoverIsOpen() async throws {
  let cases: [(popoverVisible: Bool, tab: PopoverTab, advances: Bool)] = [
    (false, .usage, false), (true, .history, false), (true, .settings, false), (true, .usage, true),
  ]
  for item in cases {
    let clock = SteppableClock()
    let environment = try makeEnvironment(clock: Clock(now: { clock.reading }, sleep: { try await clock.sleep($0) }))
    environment.state.popoverVisible = item.popoverVisible
    environment.settings.lastTab = item.tab
    let hosting = host(
      RootView(environment: environment, onMeasure: { _ in }, onTabChange: { _ in }))
    #expect(hosting.frame.width == 520)
    if item.popoverVisible {
      await waitUntil { environment.samples.count == 6 }
    }
    let initialDeadlineNow = environment.usageDeadlineNow
    let initialNow = environment.now

    let later = fixedNow.addingTimeInterval(600)
    clock.reading = later
    if item.advances {
      await waitUntil { environment.usageDeadlineNow == later }
    } else {
      await mainActorTurn()
    }
    #expect(environment.usageDeadlineNow == (item.advances ? later : initialDeadlineNow))
    #expect(environment.now == initialNow)
  }
}

@Test @MainActor func rootViewStopsTheUsageClockWhenSleepFails() async throws {
  let sleeper = ThrowingSleeper()
  let environment = try makeEnvironment(
    clock: Clock(now: { fixedNow }, sleep: { try await sleeper.sleep($0) }))
  environment.state.popoverVisible = true
  environment.settings.lastTab = .usage
  let initialDeadlineNow = environment.usageDeadlineNow

  let hosting = host(RootView(environment: environment, onMeasure: { _ in }, onTabChange: { _ in }))

  #expect(hosting.frame.width == 520)
  await waitUntil { sleeper.calls > 0 }
  #expect(sleeper.calls == 1)
  #expect(environment.usageDeadlineNow == initialDeadlineNow)
}

final class SteppableClock: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = fixedNow
  private let changes: AsyncStream<Date>
  private let continuation: AsyncStream<Date>.Continuation

  init() {
    (changes, continuation) = AsyncStream.makeStream()
  }

  var reading: Date {
    get { lock.withLock { stored } }
    set {
      lock.withLock { stored = newValue }
      continuation.yield(newValue)
    }
  }

  func sleep(_ interval: TimeInterval) async throws {
    let deadline = reading.addingTimeInterval(interval)
    for await date in changes {
      try Task.checkCancellation()
      if date >= deadline { return }
    }
    throw CancellationError()
  }
}

final class ThrowingSleeper: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCalls = 0

  var calls: Int { lock.withLock { storedCalls } }

  func sleep(_ interval: TimeInterval) async throws {
    lock.withLock { storedCalls += 1 }
    throw TestError()
  }
}

@Test @MainActor func tabPickerRoundTripsWithoutTooltips() throws {
  var selection = PopoverTab.usage
  let binding = Binding(get: { selection }, set: { selection = $0 })
  let hosting = host(TabPicker(selection: binding), width: 300, height: 40)
  #expect(inkFraction(TabPicker(selection: binding), width: 300, height: 40) > 0)
  let hostedControl = try #require(firstSubview(NSSegmentedControl.self, in: hosting))
  #expect(hostedControl.toolTip == nil)
  for segment in PopoverTab.allCases.indices {
    #expect(hostedControl.toolTip(forSegment: segment) == nil)
  }
  let coordinator = TabPicker.Coordinator(selection: binding)
  let control = NSSegmentedControl(
    labels: PopoverTab.allCases.map(\.rawValue), trackingMode: .selectOne, target: nil, action: nil)
  control.selectedSegment = 2
  coordinator.changed(control)
  #expect(selection == .settings)
  control.selectedSegment = -1
  coordinator.changed(control)
  #expect(selection == .usage)
}

@Test @MainActor func nativeSegmentedControlRoundTripsThroughAppKit() throws {
  var selection = "Stable"
  let binding = Binding(get: { selection }, set: { selection = $0 })
  let hosting = host(
    NativeSegmentedControl(
      [(value: "Stable", label: "Stable"), (value: "Usage", label: "Usage")],
      selection: binding,
      accessibilityLabel: "Order",
      accessibilityIdentifier: "model-order"),
    width: 180,
    height: 40)
  let hostedControl = try #require(firstSubview(NSSegmentedControl.self, in: hosting))

  #expect(hostedControl.accessibilityLabel() == "Order")
  #expect(hostedControl.accessibilityIdentifier() == "model-order")
  #expect(hostedControl.selectedSegment == 0)
  #expect((0..<hostedControl.segmentCount).compactMap { hostedControl.label(forSegment: $0) } == ["Stable", "Usage"])
  #expect(hostedControl.intrinsicContentSize.width > 100)

  let coordinator = NativeSegmentedControl<String>.Coordinator(
    selection: binding,
    values: ["Stable", "Usage"])
  hostedControl.selectedSegment = 1
  coordinator.changed(hostedControl)
  #expect(selection == "Usage")
  hostedControl.selectedSegment = -1
  coordinator.changed(hostedControl)
  #expect(selection == "Usage")
}

@MainActor
private func firstSubview<View: NSView>(_ type: View.Type, in root: NSView) -> View? {
  var pending = [root]
  while let view = pending.popLast() {
    if let match = view as? View { return match }
    pending.append(contentsOf: view.subviews)
  }
  return nil
}

@Test @MainActor func usageTabRendersCardsAndEmptyStates() throws {
  let environment = try makeEnvironment()
  #expect(inkFraction(UsageTab(environment: environment)) > 0)
  environment.settings.enabledProviders = []
  environment.state.remove(.claude)
  environment.state.remove(.codex)
  environment.refreshUsagePresentation()
  #expect(inkFraction(UsageTab(environment: environment)) > 0)
  let empty = try makeEnvironment(populate: false)
  empty.state.update(.claude) {
    $0.availability = .authenticationRequired
    $0.credentialState = .expired(fixedNow)
  }
  empty.state.update(.codex) { $0.availability = .networkUnavailable }
  empty.refreshUsagePresentation()
  #expect(empty.cards.isEmpty)
  #expect(inkFraction(UsageTab(environment: empty)) > 0)
  let authenticated = try makeEnvironment(populate: false)
  authenticated.state.update(.claude) {
    $0.availability = .current
    $0.credentialState = .valid(expiresAt: nil)
  }
  authenticated.refreshUsagePresentation()
  #expect(authenticated.cards.map(\.provider) == [.claude])
  #expect(inkFraction(UsageTab(environment: authenticated)) > 0)
  let stale = try makeEnvironment(populate: false)
  stale.state.update(.claude) {
    $0.snapshot = sampleSnapshot(.claude)
    $0.availability = .stale
    $0.lastError = "network down"
  }
  stale.refreshUsagePresentation()
  #expect(inkFraction(UsageTab(environment: stale)) > 0)
  let card = ProviderCardView(card: try #require(stale.cards.first), environment: stale)
  #expect(card.icon(for: .authenticationRequired) == "person.crop.circle.badge.exclamationmark")
  #expect(card.icon(for: .networkUnavailable) == "wifi.slash")
  #expect(card.icon(for: .disabled) == "pause.circle")
  #expect(card.icon(for: .loading) == "hourglass")
  #expect(card.icon(for: .current) == "chart.bar")
}

@Test @MainActor func usageDemoControlDisablesDemoMode() throws {
  let environment = try makeEnvironment(populate: false)
  environment.isDemo = true
  var values: [Bool] = []
  environment.actions.setDemoMode = { values.append($0) }
  let buttons = findNativeTextButtons(in: UsageTab(environment: environment).body)

  for button in buttons { button.action() }

  #expect(values == [false])
}

@Test @MainActor func providerCardRefreshRoutesItsProvider() throws {
  let environment = try makeEnvironment()
  var refreshed: [ProviderID] = []
  let card = ProviderCardView(
    card: try #require(environment.cards.first { $0.provider == .codex }), environment: environment,
    onRefreshProvider: { refreshed.append($0) })
  card.refresh()
  #expect(refreshed == [.codex])
}

@Test @MainActor func providerRecoveryCardRoutesToSettings() throws {
  let environment = try makeEnvironment(populate: false)
  environment.state.update(.claude) {
    $0.snapshot = sampleSnapshot(.claude)
    $0.availability = .authenticationRequired
    $0.credentialState = .expired(fixedNow)
  }
  environment.refreshUsagePresentation()
  var opened: [ProviderID?] = []
  environment.actions.showProviders = { opened.append($0) }
  let card = ProviderCardView(card: try #require(environment.cards.first), environment: environment)
  card.showProviders()
  #expect(opened == [.claude])
}

@Test @MainActor func usageTabUsesTheProviderRefreshAction() throws {
  let environment = try makeEnvironment()
  var refreshed: [ProviderID] = []
  environment.actions.refreshProvider = { refreshed.append($0) }
  UsageTab(environment: environment).onRefreshProvider(.codex)
  #expect(refreshed == [.codex])
}

@Test @MainActor func usageIdentityChipRoutesBothCopyControls() {
  var copied: [String] = []
  let chip = UsageIdentityChip(chip: Chip(text: "Max"), provider: .claude, onCopy: { copied.append($0) })
  chip.primaryAction()
  chip.copyAction()
  #expect(copied == ["Max", "Max"])
}

@Test @MainActor func usageIdentityChipKeepsExplanatoryHelp() {
  let chip = UsageIdentityChip(chip: Chip(text: "Max"), provider: .claude, onCopy: { _ in })
  #expect(chip.primaryHelp.accessibilityHint.contains("Claude plan"))
  #expect(chip.copyHelp.accessibilityHint == "Copy Max. Copies this value to the clipboard.")
}

@Test @MainActor func windowRowsSpendAndCreditsRender() {
  let snapshot = sampleSnapshot(.claude)
  let card = UsagePresenter.card(
    provider: .claude, state: ProviderState(snapshot: snapshot, availability: .current), samples: [:], now: fixedNow)
  for row in card.rows {
    let view = WindowRowView(row: row, now: fixedNow)
    #expect(inkFraction(view, width: 820, height: 50) > 0)
  }
  let ahead = WindowRow(
    key: card.rows[0].key, window: card.rows[0].window,
    pace: PaceEstimate(status: .ahead, expectedPercent: 10, ratio: 3, projectedExhaustion: nil), countdown: "1h",
    resetClock: "x")
  #expect(WindowRowView(row: ahead, now: fixedNow).paceColor == .primary)
  let behind = WindowRow(
    key: card.rows[0].key, window: card.rows[0].window,
    pace: PaceEstimate(status: .behind, expectedPercent: 10, ratio: 0.1, projectedExhaustion: nil), countdown: "1h",
    resetClock: "x")
  #expect(WindowRowView(row: behind, now: fixedNow).paceColor == .primary)
  #expect(WindowRowView(row: card.rows[0], now: fixedNow).paceColor == .primary)
  let onTrack = WindowRow(
    key: card.rows[0].key, window: card.rows[0].window,
    pace: PaceEstimate(status: .onTrack, expectedPercent: 30, ratio: 1, projectedExhaustion: nil), countdown: "1h",
    resetClock: "x")
  // Pace text remains readable; only the marker and bar carry the state colour.
  #expect(WindowRowView(row: onTrack, now: fixedNow).paceColor == .primary)
  #expect(inkFraction(SpendView(spend: snapshot.spend!, provider: .claude, now: fixedNow), width: 400, height: 200) > 0)
  #expect(
    inkFraction(
      SpendView(spend: SpendControl(enabled: false, disabledReason: "off"), provider: .codex, now: fixedNow),
      width: 400,
      height: 200) > 0)
  #expect(
    inkFraction(CreditsView(credits: snapshot.credits, resetCredits: snapshot.resetCredits), width: 400, height: 200)
      > 0)
  #expect(inkFraction(CreditsView(credits: nil, resetCredits: nil), width: 400, height: 200) == 0)
  #expect(inkFraction(LocalUsageView(usage: snapshot.localUsage!), width: 400, height: 200) > 0)
  #expect(LocalUsageView.money(3.456) == "$3.46")
  #expect(LocalUsageView.money(42.4) == "$42")
}

@Test @MainActor func usageEnvironmentStoresPresentationAndAdvancesLeafClock() throws {
  let environment = try makeEnvironment()
  let presentation = environment.usagePresentation
  #expect(presentation.cards.count == 2)
  #expect(environment.nextUsageDeadline() == fixedNow.addingTimeInterval(1))
  #expect(environment.advanceUsageDeadlines(to: fixedNow.addingTimeInterval(1)))
  #expect(environment.usageDeadlineNow == fixedNow.addingTimeInterval(1))
  #expect(environment.usagePresentation == presentation)
  environment.state.remove(.codex)
  environment.refreshUsagePresentation()
  #expect(environment.usagePresentation.cards.map(\.provider) == [.claude])
}

@Test @MainActor func usageEnvironmentRefreshesVisibleUsageWhenProviderStateChanges() async throws {
  let environment = try makeEnvironment()
  environment.state.popoverVisible = true
  environment.settings.lastTab = .usage

  environment.state.update(.codex) {
    $0.snapshot = sampleSnapshot(.codex, percent: 12)
  }

  await waitUntil {
    environment.cards.first { $0.provider == .codex }?.rows.first?.window.usedPercent == 12
  }
  #expect(environment.cards.first { $0.provider == .codex }?.rows.first?.window.usedPercent == 12)
}

@Test @MainActor func usageTabStaysWithinTheDenseContentBudget() async throws {
  let environment = try makeEnvironment()
  var measured: [PopoverMeasurement] = []
  let hosting = host(
    RootView(environment: environment, onMeasure: { measured.append($0) }, onTabChange: { _ in }), width: 880,
    height: 1200)
  #expect(hosting.frame.width == 880)
  await waitUntil { measured.contains { $0.tab == .usage } }
  let usageHeight = try #require(measured.last { $0.tab == .usage }?.size.height)
  #expect(usageHeight <= 1100)
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
  #expect(inkFraction(HistoryTab(environment: environment), width: 700, height: 800) > 0)
  let presenter = environment.historyPresenter
  presenter.reload()
  await presenter.waitForLoad()
  #expect(inkFraction(HistoryTab(environment: environment), width: 700, height: 800) > 0)
  environment.settings.historyRange = .custom
  environment.settings.historyStacked = true
  environment.settings.historyRollup = .day
  #expect(inkFraction(HistoryTab(environment: environment), width: 700, height: 800) > 0)
  let data = presenter.state.data!
  let chart = UsageChart(data: data, presenter: presenter, stacked: false, timeZone: .current)
  #expect(UsageChart.color(index: 9) == UsageChart.palette[1])
  #expect(
    UsageChart.axisFormat(for: fixedNow...fixedNow.addingTimeInterval(3600))
      != UsageChart.axisFormat(for: fixedNow...fixedNow.addingTimeInterval(5 * 86400)))
  presenter.select(x: fixedNow)
  #expect(
    inkFraction(
      UsageChart(data: data, presenter: presenter, stacked: true, timeZone: .current), width: 400, height: 240) > 0)
  #expect(inkFraction(HistoryInspector(environment: environment), width: 240, height: 300) > 0)
  environment.settings.historyHiddenKeys = [data.series[0].key]
  #expect(inkFraction(HistoryInspector(environment: environment), width: 240, height: 300) > 0)
  presenter.setMetric(.analytics(.turns))
  await presenter.waitForLoad()
  let analytics = try #require(presenter.state.data)
  #expect(analytics.metric == .analytics(.turns))
  #expect(analytics.series.map(\.summaryValue) == [3])
  #expect(
    inkFraction(
      UsageChart(data: analytics, presenter: presenter, stacked: false, timeZone: presenter.chartTimeZone), width: 500,
      height: 240) > 0)
  #expect(
    inkFraction(
      UsageChart(data: analytics, presenter: presenter, stacked: true, timeZone: presenter.chartTimeZone), width: 500,
      height: 240) > 0)
  #expect(
    inkFraction(
      Rectangle().fill(UsageChart.barStyle(HistoryStyleSlot(index: 8))), width: 40, height: 20) > 0)
  #expect(
    inkFraction(
      HistoryLegendSwatch(style: HistoryStyleSlot(index: 16), markKind: .line), width: 18, height: 10) > 0)
  chart.pick(CGPoint(x: -1, y: -1), in: CGRect(x: 0, y: 0, width: 100, height: 100))
  #expect(presenter.selectedDate == nil)
  try await history.breakDatabase()
  presenter.reload()
  await presenter.waitForLoad()
  await presenter.exportCSV(to: try uiTemporaryDirectory().appendingPathComponent("failed-history.csv")).value
  #expect(inkFraction(HistoryTab(environment: environment), width: 700, height: 800) > 0)
}

@Test @MainActor func historyTabRendersAnInitialFailure() async throws {
  let environment = try makeEnvironment(populate: false)
  try await environment.history.breakDatabase()
  environment.historyPresenter.reload()
  await environment.historyPresenter.waitForLoad()

  #expect(inkFraction(HistoryTab(environment: environment), width: 700, height: 800) > 0)
}

@Test @MainActor func historyInspectorRendersSelectedResetMetadata() async throws {
  let environment = try makeEnvironment(populate: false)
  let earlier = fixedNow.addingTimeInterval(-3600)
  let later = fixedNow.addingTimeInterval(-600)
  let snapshot: (Double, Date) -> ProviderSnapshot = { percent, date in
    ProviderSnapshot(
      provider: .claude,
      windows: [
        QuotaWindow(
          id: "session", label: "Session", group: .session, usedPercent: percent,
          resetsAt: date.addingTimeInterval(3600), duration: 18000)
      ], fetchedAt: date)
  }
  try await environment.history.record(snapshot(80, earlier), now: earlier)
  try await environment.history.record(snapshot(5, later), now: later)
  let presenter = environment.historyPresenter
  presenter.reload()
  await presenter.waitForLoad()
  let series = try #require(presenter.state.data?.series.first)
  let reset = try #require(series.points.first { $0.isReset })
  presenter.select(x: reset.date)

  #expect(inkFraction(HistoryInspector(environment: environment), width: 260, height: 300) > 0)
}

@Test @MainActor func historyInspectorKeepsEveryLegendRowReadableDuringHover() async throws {
  let environment = try makeEnvironment(populate: false)
  try await environment.history.record(sampleSnapshot(.claude), now: fixedNow.addingTimeInterval(-60))
  try await environment.history.record(sampleSnapshot(.codex), now: fixedNow.addingTimeInterval(-60))
  let presenter = environment.historyPresenter
  presenter.reload()
  await presenter.waitForLoad()
  let first = try #require(presenter.state.data?.series.first?.id)
  let inspector = HistoryInspector(environment: environment)
  let normal = opaqueInkFraction(inspector, width: 300, height: 300)

  presenter.setHovered(first)
  let hovered = opaqueInkFraction(inspector, width: 300, height: 300)

  #expect(hovered >= normal * 0.9)
}

@Test @MainActor func historyChartBuildsAccessibleLineAndBarDescriptors() throws {
  let environment = try makeEnvironment(populate: false)
  let presenter = environment.historyPresenter
  let resetDate = fixedNow.addingTimeInterval(60)
  let line = HistoryChartModel(
    metric: .analytics(.surfaceUsagePercent),
    series: [
      HistorySeries(
        id: .analytics(provider: .codex, series: "cli"), label: "CLI",
        points: [
          SeriesPoint(date: fixedNow, value: 10),
          SeriesPoint(date: resetDate, value: 20, segment: 1, isReset: true),
          SeriesPoint(
            date: resetDate.addingTimeInterval(60), value: 30, resetsAt: resetDate, segment: 1, isReset: true),
        ])
    ], domain: fixedNow...resetDate.addingTimeInterval(60), yMax: 100, summaryText: "CLI usage")
  let lineDescriptor = try #require(
    findChartDescriptor(
      in: UsageChart(data: line, presenter: presenter, stacked: false, timeZone: TimeZone(secondsFromGMT: 0)!).body))

  #expect(lineDescriptor.title == "Usage by surface history")
  #expect(lineDescriptor.series.map(\.name) == ["CLI"])
  #expect(lineDescriptor.series.flatMap(\.dataPoints).compactMap(\.label).count == 2)
  let xAxis = try #require(lineDescriptor.xAxis as? AXNumericDataAxisDescriptor)
  #expect(!xAxis.valueDescriptionProvider(fixedNow.timeIntervalSinceReferenceDate).isEmpty)
  #expect(lineDescriptor.yAxis?.valueDescriptionProvider(25) == "25%")

  let units: [(HistoryMetric, String)] = [
    (.analytics(.costUSD), "$2.50"), (.analytics(.inputTokens), "2.5K"), (.analytics(.turns), "2.5K"),
  ]
  for (metric, expected) in units {
    let model = HistoryChartModel(
      metric: metric,
      series: [
        HistorySeries(
          id: .analytics(provider: metric.suppliers[0], series: "total"), label: "Total",
          points: [SeriesPoint(date: fixedNow, value: 2500)])
      ], domain: fixedNow...fixedNow.addingTimeInterval(86400), yMax: 3000)
    let descriptor = try #require(
      findChartDescriptor(
        in: UsageChart(data: model, presenter: presenter, stacked: false, timeZone: TimeZone(secondsFromGMT: 0)!)
          .body))
    #expect(descriptor.series.count == 1)
    #expect(!descriptor.series[0].isContinuous)
    #expect(descriptor.yAxis?.valueDescriptionProvider(metric.unit == .usd ? 2.5 : 2500) == expected)
  }
}

@Test @MainActor func historyTabExportsTheSelectedPeriodToTheChosenURL() async throws {
  let environment = try makeEnvironment(populate: false)
  let outside = fixedNow.addingTimeInterval(-8 * 86400)
  let current = fixedNow.addingTimeInterval(-60)
  try await environment.history.record(sampleSnapshot(.claude), now: outside)
  try await environment.history.record(sampleSnapshot(.claude), now: current)
  let presenter = environment.historyPresenter
  presenter.setRange(.week)
  presenter.reload()
  await presenter.waitForLoad()
  let directory = try uiTemporaryDirectory()
  let url = directory.appendingPathComponent("selected-history.csv")
  let tab = HistoryTab(environment: environment, chooseExportURL: { url })
  let export = try #require(findNativeTextButtons(in: tab.body).first)

  export.action()
  await waitUntil { ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains("claude:session") }

  let text = try String(contentsOf: url, encoding: .utf8)
  #expect(text.hasPrefix("timestamp,key,label,used_percent,resets_at"))
  #expect(text.contains(ISODate.string(current)))
  #expect(!text.contains(ISODate.string(outside)))
}

@Test @MainActor func historyPeriodAndRollupControlsDispatchNativeActions() async throws {
  let environment = try makeEnvironment(populate: false)
  let presenter = environment.historyPresenter
  presenter.reload()
  await presenter.waitForLoad()
  let hosting = host(HistoryTab(environment: environment), width: 900, height: 900)
  let controls: [NSSegmentedControl] = findViews(in: hosting)
  let period = try #require(controls.first { $0.segmentCount == HistoryPeriod.allCases.count })
  let rollup = try #require(controls.first { $0.segmentCount == Rollup.allCases.count })

  period.selectedSegment = 2
  period.sendAction(period.action, to: period.target)
  await waitUntil { presenter.period == .range(.week) }
  rollup.selectedSegment = 1
  rollup.sendAction(rollup.action, to: rollup.target)
  await waitUntil { presenter.effectiveRollup == .hour }

  #expect(environment.settings.historyRange == .week)
  #expect(environment.settings.historyRollup == .hour)
}

private func findChartDescriptor(in value: Any, depth: Int = 0) -> AXChartDescriptor? {
  if let representable = value as? any AXChartDescriptorRepresentable { return representable.makeChartDescriptor() }
  guard depth < 48 else { return nil }
  for child in Mirror(reflecting: value).children {
    if let descriptor = findChartDescriptor(in: child.value, depth: depth + 1) { return descriptor }
  }
  return nil
}

@MainActor private func keyEvent(_ key: KeyEquivalent, keyCode: UInt16, window: NSWindow) -> NSEvent {
  NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
    characters: String(key.character), charactersIgnoringModifiers: String(key.character), isARepeat: false,
    keyCode: keyCode)!
}

private func findNativeTextButtons(in value: Any, depth: Int = 0) -> [NativeActionButton<Text>] {
  if let button = value as? NativeActionButton<Text> { return [button] }
  guard depth < 48 else { return [] }
  return Mirror(reflecting: value).children.flatMap { findNativeTextButtons(in: $0.value, depth: depth + 1) }
}

@MainActor private func findViews<Wanted: NSView>(in root: NSView) -> [Wanted] {
  (root as? Wanted).map { [$0] } ?? root.subviews.flatMap { findViews(in: $0) }
}

private func uiTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "token-menu-bar-ui-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@MainActor private func opaqueInkFraction<Content: View>(
  _ view: Content, width: CGFloat, height: CGFloat
) -> Double {
  let hosting = host(view, width: width, height: height)
  guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 0 }
  hosting.cacheDisplay(in: hosting.bounds, to: rep)
  guard let image = rep.cgImage else { return 0 }
  var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
  let context = CGContext(
    data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
  return Double(stride(from: 3, to: pixels.count, by: 4).count { pixels[$0] > 200 })
    / Double(image.width * image.height)
}

@Test @MainActor func settingsTabRendersAndMutates() throws {
  let environment = try makeEnvironment()
  var changes = 0
  environment.actions.settingsChanged = { changes += 1 }
  environment.settings.statusFormat = .custom
  environment.settings.customTemplate = "{label} {pct}"
  #expect(inkFraction(SettingsTab(environment: environment), width: 520, height: 1200) > 0)
  environment.launchAtLoginStatus = .enabled
  environment.canCheckForUpdates = false
  environment.isSandboxed = false
  #expect(inkFraction(SettingsTab(environment: environment), width: 520, height: 1200) > 0)
  let list = WindowSelectionList(environment: environment)
  #expect(list.rows.count == 6)
  let key = WindowKey(provider: .claude, windowID: "session")
  let window = try #require(list.rows.first { $0.key == key }?.window)
  #expect(list.label(key, window: window).wrappedValue == "CC 5h")
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
  #expect(list.label(key, window: window).wrappedValue == "S")
  list.setLabel(key, "")
  #expect(environment.settings.shortLabels[key] == nil)
  #expect(list.label(key, window: window).wrappedValue == "CC 5h")
  environment.state.update(.claude) { $0.availability = .authenticationRequired }
  #expect(SettingsTab(environment: environment).authenticationHint(.claude) == ProviderID.claude.loginHint)
  environment.settings.setProvider(.claude, enabled: false)
  #expect(SettingsTab(environment: environment).authenticationHint(.claude) == nil)
  #expect(changes == 6)
  #expect(inkFraction(WindowSelectionList(environment: environment), width: 400, height: 300) > 0)
  let empty = try makeEnvironment(populate: false)
  #expect(inkFraction(WindowSelectionList(environment: empty), width: 400, height: 100) > 0)
  #expect(inkFraction(StatusPreview(model: statusModel()), width: 300, height: 40) > 0)
  #expect(inkFraction(LogSection(environment: environment), width: 400, height: 300) > 0)
}

@Test @MainActor func windowRowReadsAsOneSentence() {
  let card = UsagePresenter.card(
    provider: .claude, state: ProviderState(snapshot: sampleSnapshot(.claude), availability: .current), samples: [:],
    now: fixedNow)
  let session = WindowRowView(row: card.rows[0], now: fixedNow).accessibilityValue
  #expect(session.hasPrefix("36% used, resets in 4 hr 0 min"))
  #expect(!session.contains("inactive"))
  let inactive = WindowRowView(row: card.rows[2], now: fixedNow).accessibilityValue
  #expect(inactive.contains("inactive"))
  #expect(inactive.contains("no reset scheduled"))
}

@Test @MainActor func spendViewSaysWhenTheLimitIsReached() {
  let reached = SpendControl(
    enabled: true, used: Money(amountMinor: 1000, currency: "USD"), limit: Money(amountMinor: 1000, currency: "USD"),
    percent: 100, limitReached: true)
  let view = SpendView(spend: reached, provider: .codex, now: fixedNow)
  #expect(view.title == "Spend control")
  #expect(SpendView(spend: reached, provider: .claude, now: fixedNow).title == "Usage credits")
  #expect(inkFraction(view, width: 400, height: 200) > 0)
}

@Test @MainActor func chartMarksNameTheirSeriesAndTime() {
  let utc = UsageChart.markLabel("Claude Session", at: fixedNow, timeZone: TimeZone(identifier: "UTC")!)
  #expect(utc.hasPrefix("Claude Session, "))
  #expect(utc != UsageChart.markLabel("Claude Session", at: fixedNow, timeZone: TimeZone(identifier: "Asia/Tokyo")!))
}

@Test @MainActor func chartStylesRemainDistinctAfterThePaletteWraps() {
  let lineIdentities = Set(
    (0..<65).map { index in
      let slot = HistoryStyleSlot(index: index)
      let stroke = UsageChart.stroke(variant: slot.variant)
      return "\(slot.hueIndex):\(stroke.lineWidth):\(stroke.dash):\(stroke.dashPhase)"
    })
  let barIdentities = Set(
    (0..<65).map { index in
      let slot = HistoryStyleSlot(index: index)
      return "\(slot.hueIndex):\(UsageChart.barPattern(variant: slot.variant))"
    })
  #expect(lineIdentities.count == 65)
  #expect(barIdentities.count == 65)
}

@Test @MainActor func chartPointSymbolsUseABoundedRepresentativeSet() {
  let points = (0..<100).map {
    SeriesPoint(date: fixedNow.addingTimeInterval(Double($0) * 60), value: Double($0))
  }
  let symbols = UsageChart.symbolPoints(points)

  #expect(symbols.count == 16)
  #expect(symbols.first == points.first)
  #expect(symbols.last == points.last)
}

@Test @MainActor func chartSelectionBuildsAtMostOneOverlayPointPerVisibleSeries() throws {
  let environment = try makeEnvironment(populate: false)
  let points = (0..<ChartPipeline.maxPoints).map {
    SeriesPoint(date: fixedNow.addingTimeInterval(Double($0) * 60), value: Double($0))
  }
  let series = (0..<20).map { index in
    HistorySeries(
      id: .analytics(provider: .codex, series: "series:\(index)"), label: "Series \(index)", points: points,
      isVisible: index.isMultiple(of: 2), summaryValue: points.last?.value)
  }
  let data = HistoryChartModel(
    metric: .analytics(.surfaceUsagePercent), series: series, domain: points[0].date...points.last!.date, yMax: 400)
  let chart = UsageChart(data: data, presenter: environment.historyPresenter, stacked: false, timeZone: .current)

  let selection = chart.selectionPoints(at: points[200].date)

  #expect(selection.count == 10)
  #expect(Set(selection.map(\.id)) == Set(series.filter(\.isVisible).map(\.id)))
}

@Test @MainActor func tabPickerIsNamedForVoiceOver() {
  var selection = PopoverTab.usage
  let hosting = host(
    TabPicker(selection: Binding(get: { selection }, set: { selection = $0 })), width: 300, height: 40)
  let control: NSSegmentedControl? = findView(hosting)
  #expect(control?.accessibilityLabel() == "Popover tabs")
  #expect(PopoverTab.allCases.indices.allSatisfy { control?.image(forSegment: $0) != nil })
}

@Test @MainActor func logTextViewUpdatesInPlace() {
  let entries = [
    LogEntry(timestamp: fixedNow, level: .info, message: "one"),
    LogEntry(timestamp: fixedNow, level: .error, message: "two"),
  ]
  let hosting = host(LogTextView(entries: entries, height: 100), width: 300, height: 120)
  let scroll: NSScrollView = hosting.subviews.compactMap { $0 as? NSScrollView }.first ?? findView(hosting)!
  let textView = scroll.documentView as! NSTextView
  #expect(textView.string.contains("[error] two"))
  #expect(textView.accessibilityLabel() == "Log")
  #expect(scroll.scrollerStyle == .overlay)
  #expect(textView.font?.pointSize == NSFont.systemFontSize(for: .small))
  textView.setSelectedRange((textView.string as NSString).range(of: "one"))
  let appended = entries + [LogEntry(timestamp: fixedNow, level: .info, message: "three")]
  hosting.rootView = LogTextView(entries: appended, height: 100)
  hosting.layoutSubtreeIfNeeded()
  #expect((textView.string as NSString).substring(with: textView.selectedRange()) == "one")
  let zero = LogEntry(timestamp: fixedNow, level: .warning, message: "zero")
  let current = [zero] + appended
  hosting.rootView = LogTextView(entries: current, height: 100)
  hosting.layoutSubtreeIfNeeded()
  #expect((textView.string as NSString).substring(with: textView.selectedRange()) == "one")
  let changedMiddle = [
    current[0], LogEntry(timestamp: fixedNow, level: .warning, message: "changed"), current[2], current[3],
  ]
  hosting.rootView = LogTextView(entries: changedMiddle, height: 100)
  hosting.layoutSubtreeIfNeeded()
  #expect(textView.string.contains("changed"))
  #expect(!textView.string.contains("] one"))
  hosting.rootView = LogTextView(entries: [], height: 100)
  hosting.layoutSubtreeIfNeeded()
  #expect(textView.string.isEmpty)
}

@Test @MainActor func fullLogMergePreservesRetainedLinesAndAppendsOnlyNewLiveLines() {
  let first = LogEntry(timestamp: fixedNow, level: .info, message: "one")
  let second = LogEntry(timestamp: fixedNow, level: .info, message: "two")
  let third = LogEntry(timestamp: fixedNow, level: .info, message: "three")
  let fourth = LogEntry(timestamp: fixedNow, level: .info, message: "four")
  #expect(FullLogView.merge(retained: [first, second], live: [second, third]) == [first, second, third])
  #expect(
    FullLogView.merge(retained: [first, second, third], live: [second, third, fourth])
      == [first, second, third, fourth])
  #expect(FullLogView.merge(retained: [first], live: []).isEmpty)
}

@MainActor
func findView<Wanted: NSView>(_ view: NSView) -> Wanted? {
  for subview in view.subviews {
    if let match = subview as? Wanted { return match }
    if let found: Wanted = findView(subview) { return found }
  }
  return nil
}

@Test @MainActor func componentsRender() {
  #expect(inkFraction(Banner("see https://example.com/docs now", tone: .info), width: 300, height: 60) > 0)
  #expect(inkFraction(Banner("plain"), width: 300, height: 60) > 0)
  let attributed = LinkifiedText.attributed("a https://x.y/z) b")
  #expect(attributed.runs.contains { $0.link != nil })
  #expect(attributed.runs.compactMap(\.link?.absoluteString) == ["https://x.y/z"])
  #expect(LinkifiedText.attributed("no link, http not a scheme").runs.allSatisfy { $0.link == nil })
  let both = LinkifiedText.attributed("http://a.b and https://c.d/e")
  #expect(both.runs.compactMap(\.link?.absoluteString) == ["http://a.b", "https://c.d/e"])
  var copied: [String] = []
  let chip = ChipView(chip: Chip(text: "Max"), onCopy: { copied.append($0) })
  #expect(inkFraction(chip, width: 200, height: 40) > 0)
  #expect(
    inkFraction(
      ChipView(chip: Chip(text: "plain"), onCopy: { copied.append($0) }), width: 200, height: 40) > 0)
  #expect(inkFraction(UsageBar(percent: 150, color: .red, label: "Session"), width: 200, height: 10) > 0)
  #expect(inkFraction(MetricCell(title: "t", value: "v", help: "h"), width: 200, height: 40) > 0)
  #expect(
    inkFraction(
      WrappingHStack { ForEach(0..<12, id: \.self) { Text("chip \($0)").padding(4) } }, width: 200, height: 200) > 0)
  #expect(WrappingHStack().horizontalSpacing == 6)
  var size = CGSize.zero
  SizeKey.reduce(value: &size) { CGSize(width: 1, height: 2) }
  SizeKey.reduce(value: &size) { .zero }
  #expect(size == CGSize(width: 1, height: 2))
  #expect(inkFraction(Color.red.frame(width: 10, height: 10).measureSize { _ in }, width: 20, height: 20) > 0)
  #expect(inkFraction(ScrollingTab(tab: .usage) { Text("x") }, width: 200, height: 200) > 0)
  #expect(Color(HSBColor(hue: 0.3, saturation: 0.5, brightness: 0.5)) != Color.clear)
  #expect(
    inkFraction(
      Text("help").richHelp(TooltipContent(title: "Help", body: "Explains this control.")),
      width: 100,
      height: 40
    ) > 0
  )
  ScrollerStyler.apply(from: NSView(frame: .zero))
  let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
  let inner = NSView(frame: .zero)
  scroll.documentView = inner
  ScrollerStyler.apply(from: inner)
  #expect(scroll.scrollerStyle == .overlay)
  #expect(scroll.hasVerticalScroller)
  #expect(scroll.autohidesScrollers)
  _ = host(ScrollerStyler(), width: 10, height: 10)
}
