import AppKit
import ObjectiveC
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func chartSelectionRendersSquareAndDiamondPoints() throws {
  let environment = try makeEnvironment(populate: false)
  let presenter = environment.historyPresenter
  let selected = fixedNow.addingTimeInterval(-60)
  let model = HistoryChartModel(
    series: [
      HistorySeries(
        id: .analytics(provider: .claude, series: "square"), label: "Square",
        points: [SeriesPoint(date: selected, value: 30)], style: HistoryStyleSlot(index: 8)),
      HistorySeries(
        id: .analytics(provider: .codex, series: "diamond"), label: "Diamond",
        points: [SeriesPoint(date: selected, value: 70)], style: HistoryStyleSlot(index: 16)),
    ], domain: selected.addingTimeInterval(-60)...selected.addingTimeInterval(60), yMax: 100)
  let chart = UsageChart(data: model, presenter: presenter, stacked: false, timeZone: .current)
  let unselected = renderedChart(chart)

  presenter.selectedDate = selected

  #expect(try #require(renderedChart(chart)) != #require(unselected))
}

@Test @MainActor func legendHoverDoesNotRedrawTheChartMarks() throws {
  let environment = try makeEnvironment(populate: false)
  let presenter = environment.historyPresenter
  let model = HistoryChartModel(
    series: [
      HistorySeries(
        key: WindowKey(provider: .claude, windowID: "session"), label: "Session",
        points: [
          SeriesPoint(date: fixedNow.addingTimeInterval(-60), value: 30),
          SeriesPoint(date: fixedNow, value: 40),
        ]),
      HistorySeries(
        key: WindowKey(provider: .codex, windowID: "weekly"), label: "Weekly",
        points: [
          SeriesPoint(date: fixedNow.addingTimeInterval(-60), value: 60),
          SeriesPoint(date: fixedNow, value: 70),
        ]),
    ], domain: fixedNow.addingTimeInterval(-60)...fixedNow, yMax: 100)
  let chart = UsageChart(data: model, presenter: presenter, stacked: false, timeZone: .current)
  let before = try #require(renderedChart(chart))

  presenter.setHovered(model.series[0].id)

  #expect(try #require(renderedChart(chart)) == before)
}

@Test @MainActor func chartHandlesKeyboardEventsThroughTheResponderChain() async throws {
  let environment = try makeEnvironment(populate: false)
  let presenter = environment.historyPresenter
  try await environment.history.record(sampleSnapshot(.claude), now: fixedNow.addingTimeInterval(-60))
  try await environment.history.record(sampleSnapshot(.claude, percent: 40), now: fixedNow)
  presenter.reload()
  await presenter.waitForLoad()
  let model = try #require(presenter.state.data)
  let hosting = host(
    UsageChart(data: model, presenter: presenter, stacked: false, timeZone: .current), width: 500, height: 300)
  let window = try #require(hosting.window)
  window.makeKey()
  window.recalculateKeyViewLoop()
  #expect(window.makeFirstResponder(hosting))

  await pressUntilHandled(.rightArrow, keyCode: 124, window: window) { presenter.selectedDate != nil }
  #expect(presenter.selectedDate == model.timeline.first)
  window.sendEvent(chartCoverageKeyEvent(.rightArrow, keyCode: 124, window: window))
  #expect(presenter.selectedDate == model.timeline.last)
  window.sendEvent(chartCoverageKeyEvent(.leftArrow, keyCode: 123, window: window))
  #expect(presenter.selectedDate == model.timeline.first)
  window.sendEvent(chartCoverageKeyEvent(.escape, keyCode: 53, window: window))
  #expect(presenter.selectedDate == nil)

}

@Test @MainActor func inspectorIsolatesTheFocusedSeriesFromAKeyboardEvent() async throws {
  let environment = try makeEnvironment(populate: false)
  try await environment.history.record(sampleSnapshot(.claude), now: fixedNow.addingTimeInterval(-60))
  try await environment.history.record(sampleSnapshot(.codex), now: fixedNow.addingTimeInterval(-60))
  let presenter = environment.historyPresenter
  presenter.reload()
  await presenter.waitForLoad()
  let seriesCount = try #require(presenter.state.data?.series.count)
  #expect(seriesCount > 1)
  let hosting = host(HistoryInspector(environment: environment), width: 320, height: 400)
  let window = try #require(hosting.window)
  window.makeKey()
  window.recalculateKeyViewLoop()
  #expect(window.makeFirstResponder(hosting))

  for _ in 0..<(seriesCount * 2 + 2) where environment.settings.historyHiddenKeys.isEmpty {
    window.sendEvent(chartCoverageKeyEvent(.tab, keyCode: 48, window: window))
    await mainActorTurn()
    window.sendEvent(chartCoverageKeyEvent("i", keyCode: 34, window: window))
    await mainActorTurn()
  }

  #expect(environment.settings.historyHiddenKeys.count == seriesCount - 1)
}

@Test @MainActor func historyTabDefaultExportPresentsTheSavePanel() throws {
  let environment = try makeEnvironment(populate: false)
  let export = try #require(chartCoverageButtons(in: HistoryTab(environment: environment).body).first)
  let original = try #require(class_getInstanceMethod(NSSavePanel.self, #selector(NSSavePanel.runModal)))
  let replacement = try #require(
    class_getInstanceMethod(NSSavePanel.self, #selector(NSSavePanel.chartCoverageRunModal)))
  method_exchangeImplementations(original, replacement)
  defer { method_exchangeImplementations(replacement, original) }
  ChartCoverageSavePanelObservation.wasPresented = false

  export.action()

  #expect(ChartCoverageSavePanelObservation.wasPresented)
}

@MainActor
private func pressUntilHandled(
  _ key: KeyEquivalent, keyCode: UInt16, window: NSWindow, handled: () -> Bool
) async {
  for _ in 0..<4 where !handled() {
    window.sendEvent(chartCoverageKeyEvent(key, keyCode: keyCode, window: window))
    await mainActorTurn()
    if !handled() { window.sendEvent(chartCoverageKeyEvent(.tab, keyCode: 48, window: window)) }
  }
}

@MainActor
private func chartCoverageKeyEvent(_ key: KeyEquivalent, keyCode: UInt16, window: NSWindow) -> NSEvent {
  chartCoverageKeyEvent(String(key.character), keyCode: keyCode, window: window)
}

@MainActor
private func chartCoverageKeyEvent(_ characters: String, keyCode: UInt16, window: NSWindow) -> NSEvent {
  NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}

@MainActor
private func renderedChart(_ chart: UsageChart) -> Data? {
  renderedView(host(chart, width: 500, height: 300))
}

@MainActor
private func renderedView(_ view: NSView) -> Data? {
  guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
  view.cacheDisplay(in: view.bounds, to: representation)
  return representation.representation(using: .png, properties: [:])
}

@MainActor
private func chartCoverageView<Wanted: NSView>(in root: NSView) -> Wanted? {
  if let match = root as? Wanted { return match }
  return root.subviews.lazy.compactMap { chartCoverageView(in: $0) }.first
}

private func chartCoverageButtons(in value: Any, depth: Int = 0) -> [NativeActionButton<Text>] {
  if let button = value as? NativeActionButton<Text> { return [button] }
  guard depth < 48 else { return [] }
  return Mirror(reflecting: value).children.flatMap { chartCoverageButtons(in: $0.value, depth: depth + 1) }
}

@MainActor private enum ChartCoverageSavePanelObservation {
  static var wasPresented = false
}

extension NSSavePanel {
  @objc fileprivate func chartCoverageRunModal() -> NSApplication.ModalResponse {
    ChartCoverageSavePanelObservation.wasPresented = true
    return .cancel
  }
}
