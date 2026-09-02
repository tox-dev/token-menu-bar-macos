import AppKit
import SwiftUI
import TokenMenuBarCore

public struct RootView: View {
  @Bindable var environment: UIEnvironment
  public let onMeasure: (PopoverMeasurement) -> Void
  public let onTabChange: ((PopoverTab) -> Void)?
  public let chooseHistoryExportURL: @MainActor () -> URL?

  public init(
    environment: UIEnvironment, onMeasure: @escaping (PopoverMeasurement) -> Void,
    onTabChange: ((PopoverTab) -> Void)? = nil,
    chooseHistoryExportURL: @escaping @MainActor () -> URL? = { nil }
  ) {
    self.environment = environment
    self.onMeasure = onMeasure
    self.onTabChange = onTabChange
    self.chooseHistoryExportURL = chooseHistoryExportURL
  }

  public var body: some View {
    VStack(spacing: 0) {
      tabBar
      PersistentTabContent(
        environment: environment,
        selection: environment.settings.lastTab,
        chooseHistoryExportURL: chooseHistoryExportURL,
        onMeasure: measured,
        onPresent: environment.completeTabTransition
      )
      .preference(key: SettingsContentReadyKey.self, value: true)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      PopoverFooter(environment: environment)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("popover-surface")
    .panelSurface(.content)
    .font(.body)
    .task(id: usageClockSchedule) { await advanceUsageClock(usageClockSchedule) }
    .task(id: usageSampleSchedule) { await prepareUsage(usageSampleSchedule) }
  }

  private var tabBar: some View {
    HStack(spacing: 0) {
      Spacer(minLength: 0)
      TabPicker(selection: Binding(get: { environment.settings.lastTab }, set: { select($0) }))
        .fixedSize()
      Spacer(minLength: 0)
    }
    .frame(height: PopoverGeometry.tabBarHeight)
    .panelSurface(.content)
  }

  private var usageClockSchedule: UsageClockSchedule {
    let visible = environment.state.popoverVisible && environment.settings.lastTab == .usage
    return UsageClockSchedule(
      visible: visible,
      deadline: visible ? environment.nextUsageDeadline() : nil)
  }

  private var usageSampleSchedule: UsageSampleSchedule {
    UsageSampleSchedule(
      visible: environment.state.popoverVisible && environment.settings.lastTab == .usage,
      revision: environment.state.sampleRevision)
  }

  private func prepareUsage(_ schedule: UsageSampleSchedule) async {
    guard schedule.visible else { return }
    await environment.prepareUsage()
  }

  private func advanceUsageClock(_ schedule: UsageClockSchedule) async {
    guard schedule.visible, let deadline = schedule.deadline else { return }
    do {
      try await environment.clock.sleep(max(deadline.timeIntervalSince(environment.clock.now()), 0))
    } catch {
      return
    }
    guard !Task.isCancelled, environment.state.popoverVisible else { return }
    environment.advanceUsageDeadlines(to: environment.clock.now())
  }

  func measured(_ measurement: PopoverMeasurement) {
    guard measurement.size != .zero else { return }
    let measurement = PopoverMeasurement(
      tab: measurement.tab,
      size: CGSize(
        width: measurement.size.width,
        height: measurement.size.height + PopoverGeometry.tabBarHeight + PopoverGeometry.footerHeight))
    environment.log.detailed(
      .tab(
        TabDiagnostic(
          action: .measurement,
          sourceTab: measurement.tab.rawValue,
          activeTab: environment.settings.lastTab.rawValue,
          filedUnderTab: measurement.tab.rawValue,
          size: DiagnosticSize(measurement.size),
          chromeHeight: PopoverGeometry.tabBarHeight + PopoverGeometry.footerHeight)))
    DiagnosticSignposts.tabs.withInterval("Tab measurement") { onMeasure(measurement) }
  }

  func select(_ tab: PopoverTab) {
    let previous = environment.settings.lastTab
    guard tab != previous else { return }
    environment.beginTabTransition(to: tab)
    environment.log.detailed(
      .tab(
        TabDiagnostic(
          action: .transition,
          from: previous.rawValue,
          to: tab.rawValue,
          activeTab: previous.rawValue)))
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      environment.settings.lastTab = tab
      onTabChange?(tab)
    }
  }
}

private struct UsageClockSchedule: Equatable {
  let visible: Bool
  let deadline: Date?
}

private struct UsageSampleSchedule: Equatable {
  let visible: Bool
  let revision: UInt64
}
