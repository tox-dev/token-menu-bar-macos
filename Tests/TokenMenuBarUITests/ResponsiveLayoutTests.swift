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

@Test @MainActor func modelUsageDoesNotCreateNativeProgressFilters() throws {
  let list = WindowSelectionList(environment: try makeEnvironment())
  let row = try #require(list.groups.first?.rows.first)
  let hosting = host(list.modelRow(row), width: 880, height: 100)
  #expect(tooltipAnchors(in: hosting).contains { $0.tooltipContent.title == "Usage and recency" })
  #expect(progressIndicators(in: hosting).isEmpty)
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

@Test(arguments: [false, true]) @MainActor
func modelListOnlyObservesChangesToModelData(snapshotChanged: Bool) throws {
  let environment = try makeEnvironment()
  let invalidated = OSAllocatedUnfairLock(initialState: false)
  withObservationTracking {
    _ = WindowSelectionList(environment: environment).groups
  } onChange: {
    invalidated.withLock { $0 = true }
  }

  environment.state.update(.claude) {
    $0.isRefreshing = true
    if snapshotChanged { $0.snapshot = nil }
  }

  #expect(invalidated.withLock { $0 } == snapshotChanged)
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

@MainActor private func tooltipAnchors(in root: NSView) -> [TooltipTrackingView] {
  root.subviews.flatMap { view in
    (view as? TooltipTrackingView).map { [$0] } ?? tooltipAnchors(in: view)
  }
}

@MainActor private func progressIndicators(in root: NSView) -> [NSProgressIndicator] {
  root.subviews.flatMap { view in
    (view as? NSProgressIndicator).map { [$0] } ?? progressIndicators(in: view)
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
  hosting.sizingOptions = [.intrinsicContentSize]
  hosting.frame = CGRect(x: 0, y: 0, width: width, height: 1)
  hosting.layoutSubtreeIfNeeded()
  return hosting.fittingSize
}
