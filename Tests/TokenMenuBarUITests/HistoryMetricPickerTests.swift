import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore

@testable import TokenMenuBarUI

@Test(arguments: [HistoryMetric.windowUsagePercent, .analytics(.inputTokens), .analytics(.costUSD), .analytics(.turns)])
@MainActor func historyMetricMenuSelectsThroughItsNativeAction(metric: HistoryMetric) throws {
  let metrics = [HistoryMetric.windowUsagePercent, .analytics(.inputTokens), .analytics(.costUSD), .analytics(.turns)]
  var selected = HistoryMetric.windowUsagePercent
  let hosting = host(
    HistoryMetricPicker(metrics: metrics, selection: Binding(get: { selected }, set: { selected = $0 })))
  let control = try #require(metricControl(in: hosting))
  control.selectItem(withTag: try #require(metrics.firstIndex(of: metric)))
  #expect(control.selectedItem?.title == metric.title)
  #expect(control.sendAction(control.action, to: control.target))
  #expect(selected == metric)
}

@Test @MainActor func historyMetricMenuKeepsItsGroupsAndAccessibilityNames() throws {
  let metrics = [
    HistoryMetric.windowUsagePercent, .analytics(.inputTokens), .analytics(.costUSD), .analytics(.turns),
    .analytics(.projectCost),
  ]
  let hosting = host(HistoryMetricPicker(metrics: metrics, selection: .constant(.windowUsagePercent)))
  let control = try #require(metricControl(in: hosting))
  let items = try #require(control.menu).items
  #expect(items.filter(\.isSectionHeader).map(\.title) == HistoryMetricGroup.allCases.map(\.rawValue))
  #expect(items.filter { !$0.isSectionHeader }.map(\.title) == metrics.map(\.title))
  #expect(control.accessibilityLabel() == "Metric")
  #expect(control.accessibilityIdentifier() == "history-metric")
  #expect(control.fittingSize.width > 50 && control.fittingSize.height > 10)
}

@Test @MainActor func historyMetricMenuDoesNotSelectASectionHeading() throws {
  var selected = HistoryMetric.analytics(.turns)
  let hosting = host(
    HistoryMetricPicker(
      metrics: [.windowUsagePercent, .analytics(.turns)],
      selection: Binding(get: { selected }, set: { selected = $0 })))
  let control = try #require(metricControl(in: hosting))
  let header: NSMenuItem = try #require(control.menu?.items.first)
  #expect(header.isSectionHeader)
  control.select(header)
  #expect(control.sendAction(control.action, to: control.target))
  #expect(selected == .analytics(.turns))
}

@Test @MainActor func historyMetricMenuKeepsItsNativeLabelWithRichHelp() throws {
  let hosting = host(
    HistoryMetricPicker(metrics: [.windowUsagePercent], selection: .constant(.windowUsagePercent))
      .frame(minWidth: 250, idealWidth: 320, alignment: .leading)
      .accessibilityIdentifier("history-metric")
      .richHelp(TooltipContent(title: "History metric", body: "Chooses the data to load and draw.")))
  #expect(try #require(metricControl(in: hosting)).accessibilityLabel() == "Metric")
}

@Test(arguments: [false, true]) @MainActor func historyMetricMenuHonorsEnabledState(enabled: Bool) throws {
  let hosting = host(
    HistoryMetricPicker(metrics: [.windowUsagePercent], selection: .constant(.windowUsagePercent)).disabled(!enabled))
  #expect(try #require(metricControl(in: hosting)).isEnabled == enabled)
}

@Test @MainActor func historyMetricMenuReusesItsControlWhenAvailableDataChanges() throws {
  let hosting = host(HistoryMetricPicker(metrics: [.windowUsagePercent], selection: .constant(.windowUsagePercent)))
  let control = try #require(metricControl(in: hosting))
  hosting.rootView = HistoryMetricPicker(metrics: [.analytics(.turns)], selection: .constant(.analytics(.turns)))
  hosting.layoutSubtreeIfNeeded()
  #expect(metricControl(in: hosting) === control)
  #expect(control.selectedItem?.title == HistoryMetric.analytics(.turns).title)
  #expect(control.menu?.items.filter { !$0.isSectionHeader }.count == 1)
}

@Test @MainActor func historyMetricMenuWithoutDataCannotChangeTheSelection() throws {
  var selected = HistoryMetric.windowUsagePercent
  let hosting = host(
    HistoryMetricPicker(metrics: [], selection: Binding(get: { selected }, set: { selected = $0 })))
  let control = try #require(metricControl(in: hosting))
  #expect(!control.isEnabled)
  control.sendAction(control.action, to: control.target)
  #expect(selected == .windowUsagePercent)
}

@Test @MainActor func historyMetricMenuClearsAnUnavailableSelection() throws {
  let hosting = host(HistoryMetricPicker(metrics: [.windowUsagePercent], selection: .constant(.analytics(.turns))))
  #expect(try #require(metricControl(in: hosting)).selectedItem == nil)
}

@MainActor private func metricControl(in root: NSView) -> NSPopUpButton? {
  (root as? NSPopUpButton) ?? root.subviews.lazy.compactMap { metricControl(in: $0) }.first
}
