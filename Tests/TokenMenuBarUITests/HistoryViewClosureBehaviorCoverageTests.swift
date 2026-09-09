import AppKit
import SwiftUI
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test(arguments: [false, true]) @MainActor func initialHistoryUsesTheCheckedModels(custom: Bool) async throws {
  let settings = makeSettings()
  let session = QuotaWindow(id: "session", label: "Session", group: .session, usedPercent: 20, resetsAt: nil)
  let review = QuotaWindow(id: "code_review", label: "Code review", group: .other, usedPercent: 30, resetsAt: nil)
  let snapshot = ProviderSnapshot(provider: .codex, windows: [session, review], fetchedAt: fixedNow)
  settings.hasCustomSelection = custom
  settings.selectedWindows = [WindowKey(.codex, review)]
  let state = AppState()
  state.update(.codex) { $0.snapshot = snapshot }
  let history = try UsageHistoryStore(url: nil)
  try await history.record(snapshot, now: fixedNow.addingTimeInterval(-60))
  let environment = UIEnvironment(
    state: state, settings: settings, history: history, log: makeLog(), appInfo: testAppInfo, clock: testClock)

  environment.historyPresenter.reload()
  await environment.historyPresenter.waitForLoad()

  #expect(
    environment.historyPresenter.state.data?.series.map(\.id) == [.window(WindowKey(.codex, custom ? review : session))]
  )
}

@Test @MainActor func historyTabPagesUsingItsArrowButtons() async throws {
  let environment = try makeEnvironment(populate: false)
  let presenter = environment.historyPresenter
  environment.settings.historyRange = .custom
  presenter.customStart = fixedNow.addingTimeInterval(-7200)
  presenter.customEnd = fixedNow.addingTimeInterval(-3600)
  presenter.followNow = false
  presenter.reload()
  await presenter.waitForLoad()
  let buttons: [NativeIconButton] = historyViewValues(in: HistoryTab(environment: environment).body)
  let next = try #require(buttons.first { $0.accessibilityLabel == "Next period" })
  let previous = try #require(buttons.first { $0.accessibilityLabel == "Previous period" })

  next.action()
  await presenter.waitForLoad()
  #expect(presenter.followNow)
  previous.action()
  await presenter.waitForLoad()
  #expect(!presenter.followNow)
}

@Test @MainActor func historyTabChangesMetricThroughItsPicker() async throws {
  let environment = try makeEnvironment(populate: false)
  let presenter = environment.historyPresenter
  presenter.reload()
  await presenter.waitForLoad()
  let bindings: [Binding<HistoryMetric>] = historyViewValues(in: HistoryTab(environment: environment).body)

  bindings.first?.wrappedValue = .analytics(.turns)
  await presenter.waitForLoad()

  #expect(presenter.selectedMetric == .analytics(.turns))
}

@Test @MainActor func historyDateSummaryOpensTheCustomRange() async throws {
  let environment = try makeEnvironment()
  let presenter = environment.historyPresenter
  let label =
    presenter.currentViewport.lowerBound.formatted(date: .abbreviated, time: .omitted)
    + " – " + presenter.currentViewport.upperBound.formatted(date: .abbreviated, time: .omitted)
  let buttons: [NativeActionButton<Text>] = historyViewValues(in: HistoryTab(environment: environment).body)
  try #require(buttons.first { $0.label == Text(label) }).action()
  #expect(presenter.period == .range(.custom) && !presenter.followNow)
  await presenter.waitForLoad()
}

@Test @MainActor func demoExitButtonRequestsLiveMode() throws {
  let environment = try makeEnvironment()
  environment.isDemo = true
  var requested: Bool?
  environment.actions.setDemoMode = { requested = $0 }
  let buttons: [NativeActionButton<Text>] = historyViewValues(in: DisableDemoButton(environment: environment).body)
  try #require(buttons.first).action()
  #expect(requested == false)
}

@Test @MainActor func historyBindingsAndLegendHoverDispatchToThePresenter() async throws {
  let environment = try makeEnvironment()
  let presenter = environment.historyPresenter
  let snapshot = sampleSnapshot(.claude)
  environment.state.update(.claude) { $0.snapshot = snapshot }
  try await environment.history.record(snapshot, now: fixedNow)
  presenter.reload()
  await presenter.waitForLoad()
  let series = try #require(presenter.state.data?.series.first)
  let tab = HistoryTab(environment: environment)
  let start = fixedNow.addingTimeInterval(-7200)
  let end = fixedNow.addingTimeInterval(-3600)

  tab.stackedBinding.wrappedValue = true
  tab.startBinding.wrappedValue = start
  await presenter.waitForLoad()
  tab.endBinding.wrappedValue = end
  await presenter.waitForLoad()

  #expect(environment.settings.historyStacked)
  #expect(presenter.customStart == start)
  #expect(presenter.customEnd == end)

  let inspector = HistoryInspector(environment: environment)
  inspector.useUTCBinding.wrappedValue = true
  inspector.visibilityBinding(for: series.id).wrappedValue.toggle()
  HistoryLegendHoverAction(presenter: presenter, seriesID: series.id)(true)

  #expect(environment.settings.historyUseUTC)
  #expect(!presenter.isVisible(series.id))
  #expect(presenter.hoveredSeriesID == series.id)

  HistoryLegendHoverAction(presenter: presenter, seriesID: series.id)(false)
  #expect(presenter.hoveredSeriesID == nil)
}

@Test @MainActor func chartPointerActionsMapThePlotToTheVisibleDomain() async throws {
  struct PointerValue {
    let location: CGPoint
  }

  let environment = try makeEnvironment(populate: false)
  let presenter = environment.historyPresenter
  try await environment.history.record(sampleSnapshot(.claude), now: fixedNow)
  presenter.reload()
  await presenter.waitForLoad()
  let data = try #require(presenter.state.data)
  let chart = UsageChart(data: data, presenter: presenter, stacked: false, timeZone: .current)
  let plot = CGRect(x: 10, y: 20, width: 100, height: 50)

  ChartDragAction(chart: chart, plot: plot, location: \PointerValue.location)(
    PointerValue(location: CGPoint(x: 60, y: 30)))
  let midpoint = data.domain.lowerBound.addingTimeInterval(
    data.domain.upperBound.timeIntervalSince(data.domain.lowerBound) / 2)
  #expect(
    presenter.selectedDate
      == ChartPipeline.nearestDate(in: data, to: midpoint))

  ChartHoverAction(chart: chart, plot: plot)(.ended)
  #expect(presenter.selectedDate == nil)
  chart.pick(CGPoint(x: 10, y: 20), in: CGRect(x: 10, y: 20, width: 0, height: 50))
  #expect(presenter.selectedDate == nil)
}

@Test @MainActor func historyTabRetryRecoversAnInitialFailure() async throws {
  let environment = try makeEnvironment(populate: false)
  let presenter = environment.historyPresenter
  try await environment.history.breakDatabase()
  presenter.reload()
  await presenter.waitForLoad()
  guard case .failed = presenter.state else {
    Issue.record("expected failed history load")
    return
  }
  try await historyClosureRestoreSamples(in: environment.history)
  let buttons: [NativeActionButton<Text>] = historyViewValues(in: HistoryTab(environment: environment).body)

  try #require(buttons.last).action()
  await presenter.waitForLoad()

  #expect(presenter.state.data?.isEmpty == true)
}

@Test @MainActor func historyTabRetryClearsARefreshError() async throws {
  let environment = try makeEnvironment(populate: false)
  let presenter = environment.historyPresenter
  presenter.reload()
  await presenter.waitForLoad()
  try await environment.history.breakDatabase()
  presenter.reload()
  await presenter.waitForLoad()
  guard case .loaded(_, false, .some) = presenter.state else {
    Issue.record("expected loaded history with refresh error")
    return
  }
  try await historyClosureRestoreSamples(in: environment.history)
  let buttons: [NativeActionButton<Text>] = historyViewValues(in: HistoryTab(environment: environment).body)

  try #require(buttons.last).action()
  await presenter.waitForLoad()

  guard case .loaded(_, false, nil) = presenter.state else {
    Issue.record("expected recovered history")
    return
  }
}

@Test @MainActor func persistentTabsExposeOnlyTheSelectedHostToAccessibility() {
  let container = PersistentTabContainer()
  #expect(container.accessibilityChildren()?.isEmpty == true)
  let usage = NSHostingView(rootView: AnyView(Text("Usage")))
  let history = NSHostingView(rootView: AnyView(Text("History")))
  container.install(usage, for: .usage)
  container.install(history, for: .history)

  container.select(.history)

  let selected = container.accessibilityChildren() as? [PersistentTabSlot]
  #expect(selected?.count == 1)
  #expect(selected?.first?.accessibilityChildren()?.first as? NSView === history)
  let inactive = usage.superview as? PersistentTabSlot
  #expect(inactive?.accessibilityChildren()?.isEmpty == true)
}

@Test @MainActor func tabSwitchRetainsInactiveHostsOutsideTheLayoutTree() throws {
  let container = PersistentTabContainer(frame: CGRect(x: 0, y: 0, width: 880, height: 500))
  let usage = NSHostingView(rootView: AnyView(Text("Usage")))
  let history = NSHostingView(rootView: AnyView(Text("History")))
  container.install(usage, for: .usage)
  container.install(history, for: .history)
  container.present(.usage)
  let usageSlot = try #require(usage.superview)

  container.present(.history)

  #expect(usageSlot.superview == nil)
  #expect(container.subviews == [history.superview!])

  container.present(.usage)

  #expect(container.subviews == [usageSlot])
  #expect(usage.superview === usageSlot)
  #expect(history.superview?.superview == nil)
}

@Test(arguments: [false, true]) @MainActor
func tabPresentationCoalescesCallbacksAndSkipsCompletedDraws(presentSynchronously: Bool) async {
  let container = PersistentTabContainer(frame: CGRect(x: 0, y: 0, width: 880, height: 500))
  container.install(NSHostingView(rootView: AnyView(Text("Usage"))), for: .usage)
  container.select(.usage)
  var presented: [PopoverTab] = []
  container.schedulePresentation { presented.append($0) }
  container.schedulePresentation { presented.append($0) }
  if presentSynchronously { container.present(.usage) }

  await mainActorTurn()
  await mainActorTurn()
  container.schedulePresentation { presented.append($0) }
  await mainActorTurn()

  #expect(presented == (presentSynchronously ? [] : [.usage]))
}

@Test @MainActor func queuedTabPresentationUsesTheLatestSelection() async {
  let container = PersistentTabContainer(frame: CGRect(x: 0, y: 0, width: 880, height: 500))
  for tab in [PopoverTab.usage, .settings] {
    container.install(NSHostingView(rootView: AnyView(Text(tab.rawValue))), for: tab)
  }
  container.select(.usage)
  var presented: [PopoverTab] = []
  container.schedulePresentation { presented.append($0) }
  container.select(.settings)

  await mainActorTurn()

  #expect(presented == [.settings])
}

@Test @MainActor func queuedPresentationDoesNotRetainItsContainer() async {
  var container: PersistentTabContainer? = PersistentTabContainer()
  weak var retained: PersistentTabContainer?
  retained = container
  var presented: [PopoverTab] = []
  container?.schedulePresentation { presented.append($0) }
  container = nil

  await mainActorTurn()

  #expect(retained == nil && presented.isEmpty)
}

@Test @MainActor func resizingTheSelectedTabKeepsHiddenHostsAtTheirCachedSize() throws {
  let container = PersistentTabContainer(frame: CGRect(x: 0, y: 0, width: 880, height: 500))
  let usage = NSHostingView(rootView: AnyView(Text("Usage")))
  let history = NSHostingView(rootView: AnyView(Text("History")))
  usage.sizingOptions = []
  history.sizingOptions = []
  container.install(usage, for: .usage)
  container.install(history, for: .history)
  container.present(.history)
  container.present(.usage)
  let cachedFrame = try #require(history.superview).frame

  container.setFrameSize(CGSize(width: 880, height: 800))
  container.layoutSubtreeIfNeeded()

  #expect(history.superview?.frame == cachedFrame)
  #expect(usage.superview?.frame == container.bounds)
}

@Test @MainActor func openingSettingsPrewarmsUsageBeforeItsFirstClick() async {
  let container = PersistentTabContainer(frame: CGRect(x: 0, y: 0, width: 880, height: 500))
  let usage = NSHostingView(rootView: AnyView(Text("Usage")))
  usage.sizingOptions = []
  container.install(usage, for: .usage)
  container.install(NSHostingView(rootView: AnyView(Text("History"))), for: .history)
  container.install(NSHostingView(rootView: AnyView(Text("Settings"))), for: .settings)
  container.present(.settings)

  await mainActorTurn()
  await mainActorTurn()

  #expect(usage.frame.size == container.bounds.size)
  #expect(usage.superview?.isHidden == true)
}

@Test func popoverMeasurementPreferenceKeepsTheNewestMeasurement() {
  let usage = PopoverMeasurement(tab: .usage, size: CGSize(width: 320, height: 400))
  let history = PopoverMeasurement(tab: .history, size: CGSize(width: 520, height: 700))
  var value: PopoverMeasurement? = usage

  PopoverMeasurementKey.reduce(value: &value) { history }
  #expect(value == history)
  PopoverMeasurementKey.reduce(value: &value) { nil }
  #expect(value == history)
}

private func historyViewValues<Value>(in value: Any, depth: Int = 0) -> [Value] {
  if let match = value as? Value { return [match] }
  guard depth < 96 else { return [] }
  return Mirror(reflecting: value).children.flatMap { historyViewValues(in: $0.value, depth: depth + 1) }
}

private func historyClosureRestoreSamples(in history: UsageHistoryStore) async throws {
  try await history.database.execute(
    """
    CREATE TABLE samples (
      ts REAL NOT NULL, key TEXT NOT NULL, label TEXT NOT NULL, used REAL NOT NULL, resets_at REAL,
      PRIMARY KEY (key, ts)
    )
    """)
}
