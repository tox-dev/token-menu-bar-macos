import AppKit
import Observation
import SwiftUI
import Testing
import TokenMenuBarTestSupport
import os

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func modelSelectionExplainsTheSharedDisplayScope() throws {
  let environment = try makeEnvironment()
  let hosting = host(WindowSelectionList(environment: environment), width: 880, height: 1800)
  let tooltip = try #require(tooltipAnchors(in: hosting).first { $0.tooltipContent.title == "Model selection" })

  #expect(
    tooltip.tooltipContent.body.first?.text
      == "Shows Current session in the menu bar, Usage and History. "
      + "Unchecking hides it without deleting stored history. Recheck the model here to show it again.")
}

@Test(arguments: [PopoverTab.usage, .history]) @MainActor
func tabSelectionDoesNotInvalidateRetainedContent(tab: PopoverTab) throws {
  let environment = try makeEnvironment()
  environment.state.popoverVisible = true
  environment.settings.lastTab = tab
  let invalidated = OSAllocatedUnfairLock(initialState: false)
  withObservationTracking {
    switch tab {
    case .usage: _ = UsageTab(environment: environment).body
    case .history: _ = HistoryTab(environment: environment).body
    case .settings: break
    }
  } onChange: {
    invalidated.withLock { $0 = true }
  }

  environment.settings.lastTab = .settings

  #expect(!invalidated.withLock { $0 })
}

@Test @MainActor func usageRowsReflowAt548Points() throws {
  let card = UsagePresenter.card(
    provider: .claude, state: ProviderState(snapshot: sampleSnapshot(.claude), availability: .current), samples: [:],
    now: fixedNow)
  let row = try #require(card.rows.first)
  let wide = fittingSize(WindowRowView(row: row, now: fixedNow), width: 852)
  let narrow = fittingSize(WindowRowView(row: row, now: fixedNow), width: 548)
  #expect(narrow.width <= 548)
  #expect(narrow.height > wide.height)
}

@Test @MainActor func modelRowsReflowAt548PointsAndAccessibilityText() throws {
  let environment = try makeEnvironment()
  let list = WindowSelectionList(environment: environment)
  let row = try #require(list.groups.first { $0.provider == .claude }?.rows.first)
  let wide = fittingSize(list.modelRow(row), width: 852)
  let narrow = fittingSize(list.modelRow(row), width: 548)
  let accessible = fittingSize(
    list.modelRow(row).environment(\.dynamicTypeSize, .accessibility1), width: 548)
  #expect(narrow.width <= 548)
  #expect(narrow.height > wide.height)
  #expect(accessible.height >= narrow.height)
}

@Test @MainActor func settingsRendersAt548PointsWithAccessibilityText() throws {
  let environment = try makeEnvironment()
  environment.settings.statusFormat = .custom
  let view = SettingsTab(environment: environment, mountsIncrementally: false).environment(
    \.dynamicTypeSize, .accessibility1)
  #expect(inkFraction(view, width: 548, height: 1800) > 0)
}

@Test @MainActor func historyReservesTheChartViewportWhileLoadingButNotWhenEmpty() async throws {
  let environment = try makeEnvironment(populate: false)
  let hosting = host(HistoryTab(environment: environment), width: 880, height: 900)
  let loadingHeight = hosting.fittingSize.height
  #expect(environment.historyPresenter.state == .loading)
  #expect(loadingHeight >= PopoverGeometry.historyChartHeight + 100)

  environment.state.popoverVisible = true
  environment.settings.lastTab = .history
  await mainActorTurn()
  await environment.historyPresenter.waitForLoad()
  hosting.layoutSubtreeIfNeeded()

  #expect(environment.historyPresenter.state.data?.isEmpty == true)
  #expect(hosting.fittingSize.height < loadingHeight - 200)
}

@Test(arguments: [3, 30], [700.0, 880.0]) @MainActor
func historyChartUsesTheHeightBesideItsLegend(modelCount: Int, width: Double) async throws {
  let environment = try makeEnvironment()
  let snapshot = ProviderSnapshot(
    provider: .claude,
    windows: (0..<modelCount).map {
      QuotaWindow(
        id: "model-\($0)", label: "Synthetic model \($0)", group: .other, usedPercent: Double($0 + 1), resetsAt: nil)
    }, fetchedAt: fixedNow)
  environment.state.update(.claude) { $0.snapshot = snapshot }
  try await environment.history.record(snapshot, now: fixedNow.addingTimeInterval(-60))
  environment.settings.selectedWindows = snapshot.windows.map { WindowKey(.claude, $0) }
  environment.settings.hasCustomSelection = true
  environment.settings.lastTab = .history
  environment.state.popoverVisible = true
  let hosting = host(HistoryTab(environment: environment), width: width, height: 2000)
  await mainActorTurn()
  await environment.historyPresenter.waitForLoad()
  hosting.layoutSubtreeIfNeeded()
  let anchors = tooltipAnchors(in: hosting)
  let chart = try #require(anchors.first { $0.tooltipContent.title == "History chart" })
  let rows = anchors.filter {
    $0.tooltipContent.body.first?.text.hasPrefix("Shows the value at the selected date.") == true
  }
  #expect(rows.count == modelCount)
  let legend = rows.reduce(CGRect.null) { $0.union(hosting.convert($1.bounds, from: $1)) }
  let chartFrame = hosting.convert(chart.bounds, from: chart)
  if width >= 880 {
    #expect(chartFrame.height >= max(PopoverGeometry.historyChartHeight, legend.height))
    #expect(chartFrame.height <= max(PopoverGeometry.historyChartHeight, legend.height + 100))
  } else {
    #expect(chartFrame.height == PopoverGeometry.historyChartHeight)
  }
}

@MainActor private func tooltipAnchors(in root: NSView) -> [TooltipTrackingView] {
  root.subviews.flatMap { view in
    (view as? TooltipTrackingView).map { [$0] } ?? tooltipAnchors(in: view)
  }
}

@Test @MainActor func historyResetSelectionKeepsTheLegendHeightAndExposesItsDeadline() async throws {
  let environment = try makeEnvironment()
  for (offset, percent) in [(-3600.0, 80.0), (-600.0, 5.0)] {
    let date = fixedNow.addingTimeInterval(offset)
    try await environment.history.record(
      ProviderSnapshot(
        provider: .claude,
        windows: [
          QuotaWindow(
            id: "session", label: "Session", group: .session, usedPercent: percent,
            resetsAt: date.addingTimeInterval(3600), duration: 18000)
        ], fetchedAt: date), now: date)
  }
  let presenter = environment.historyPresenter
  presenter.reload()
  await presenter.waitForLoad()
  let series = try #require(presenter.state.data?.series.first)
  let reset = try #require(series.points.first { $0.isReset })
  let hosting = host(HistoryInspector(environment: environment), width: 220, height: 500)
  await mainActorTurn()
  let initialHeight = hosting.fittingSize.height

  presenter.select(x: reset.date)
  await mainActorTurn()
  hosting.layoutSubtreeIfNeeded()

  #expect(abs(hosting.fittingSize.height - initialHeight) < 0.5)
  let deadline = try #require(presenter.resetDescription(for: series))
  let tooltip = try #require(tooltipAnchors(in: hosting).first { $0.tooltipContent.title == series.label })
  #expect(tooltip.tooltipContent.accessibilityHint.contains(deadline))
}

@MainActor private func fittingSize<Content: View>(_ view: Content, width: CGFloat) -> CGSize {
  prepareTestApp()
  let hosting = NSHostingView(
    rootView: view.frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
  hosting.layoutSubtreeIfNeeded()
  return hosting.fittingSize
}
