import AppKit
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

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

@Test @MainActor func historyBindingsAndLegendHoverDispatchToThePresenter() async throws {
  let environment = try makeEnvironment(populate: false)
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
  let inactive = container.subviews.compactMap { $0 as? PersistentTabSlot }.first { !$0.isActive }
  #expect(inactive?.accessibilityChildren()?.isEmpty == true)
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
