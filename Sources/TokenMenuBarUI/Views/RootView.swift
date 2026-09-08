import AppKit
import SwiftUI
import TokenMenuBarCore

public struct RootView: View {
  @Bindable var environment: UIEnvironment
  public let onMeasure: (PopoverMeasurement) -> Void
  public let onTabChange: ((PopoverTab) -> Void)?
  public let chooseHistoryExportURL: @MainActor () async -> URL?
  let preferredContentSize: @MainActor (PopoverTab) -> CGSize?

  public init(
    environment: UIEnvironment, onMeasure: @escaping (PopoverMeasurement) -> Void,
    onTabChange: ((PopoverTab) -> Void)? = nil,
    preferredContentSize: @escaping @MainActor (PopoverTab) -> CGSize? = { _ in nil },
    chooseHistoryExportURL: @escaping @MainActor () async -> URL? = { nil }
  ) {
    self.environment = environment
    self.onMeasure = onMeasure
    self.onTabChange = onTabChange
    self.chooseHistoryExportURL = chooseHistoryExportURL
    self.preferredContentSize = preferredContentSize
  }

  public var body: some View {
    RootSurface(root: self)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  func makeNativeView() -> NSView {
    // A native parent avoids nested SwiftUI focus-graph traversal during window attachment.
    RootSurfaceView(root: self)
  }

  fileprivate func makeTabContainer() -> PersistentTabContainer {
    PersistentTabContainer(
      environment: environment, selection: environment.settings.lastTab,
      chooseHistoryExportURL: chooseHistoryExportURL, onMeasure: measured,
      preferredContentSize: preferredContentSize)
  }

  fileprivate var header: some View {
    tabBar
      .font(.body)
      .background(UsageClockDriver(environment: environment))
      .task(id: usageSampleSchedule) { await prepareUsage(usageSampleSchedule) }
      .onChange(of: environment.settings.lastTab) { _, tab in
        environment.tabContainer?.select(tab)
        environment.tabContainer?.schedulePresentation(environment.completeTabTransition)
      }
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

  private var usageSampleSchedule: UsageSampleSchedule {
    UsageSampleSchedule(
      visible: environment.state.popoverVisible && environment.settings.lastTab == .usage,
      revision: environment.state.sampleRevision)
  }

  private func prepareUsage(_ schedule: UsageSampleSchedule) async {
    guard schedule.visible else { return }
    await environment.prepareUsage()
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
    environment.tabContainer?.schedulePrewarm()
  }

  func select(_ tab: PopoverTab) {
    let previous = environment.settings.lastTab
    guard tab != previous else { return }
    let event = NSApp.currentEvent
    let inputTimestamp = event.flatMap { event in
      [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp].contains(event.type) ? event.timestamp : nil
    }
    environment.beginTabTransition(to: tab, inputTimestamp: inputTimestamp)
    let selectedAt = ProcessInfo.processInfo.systemUptime
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      environment.settings.lastTab = tab
      // Keep both tab hosts at their cached sizes while AppKit resizes the viewport.
      if let container = environment.tabContainer {
        container.resizeViewport { onTabChange?(tab) }
      } else {
        onTabChange?(tab)
      }
      let selectionStarted = ProcessInfo.processInfo.systemUptime
      environment.tabContainer?.select(tab)
      environment.log.logDebug(
        "tab.content-selected tab=\(tab.rawValue) durationMs=\((ProcessInfo.processInfo.systemUptime - selectionStarted) * 1_000)",
        category: .tabs)
    }
    environment.log.logDebug(
      "tab.viewport-applied tab=\(tab.rawValue) durationMs=\((ProcessInfo.processInfo.systemUptime - selectedAt) * 1_000)",
      category: .tabs)
    if let container = environment.tabContainer {
      container.present(tab)
      container.superview?.layoutSubtreeIfNeeded()
      container.superview?.displayIfNeeded()
      environment.completeTabTransition(to: tab)
    }
  }
}

private struct RootSurface: NSViewRepresentable {
  let root: RootView

  func makeNSView(context: Context) -> RootSurfaceView {
    RootSurfaceView(root: root)
  }

  func updateNSView(_ view: RootSurfaceView, context: Context) {
    view.update(root)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: RootSurfaceView, context: Context) -> CGSize? {
    proposal.replacingUnspecifiedDimensions(
      by: CGSize(width: PopoverGeometry.stableTabWidth, height: PopoverGeometry.minimumHeight))
  }
}

private struct RootHeader: View {
  let root: RootView

  var body: some View { root.header }
}

@MainActor
private final class RootSurfaceView: NSView {
  private let header: NSHostingView<RootHeader>
  private let content: PersistentTabContainer
  private let footer: NSHostingView<AnyView>

  init(root: RootView) {
    header = NSHostingView(rootView: RootHeader(root: root))
    content = root.makeTabContainer()
    footer = NSHostingView(rootView: AnyView(PopoverFooter(environment: root.environment).font(.body)))
    super.init(
      frame: CGRect(
        origin: .zero,
        size: CGSize(
          width: PopoverGeometry.stableTabWidth,
          height: PopoverGeometry.preferredHeight(for: root.environment.settings.lastTab))))
    header.sizingOptions = []
    footer.sizingOptions = []
    addSubview(header)
    addSubview(content)
    addSubview(footer)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityIdentifier("popover-surface")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  func update(_ root: RootView) {
    header.rootView = RootHeader(root: root)
    footer.rootView = AnyView(PopoverFooter(environment: root.environment).font(.body))
    content.select(root.environment.settings.lastTab)
    content.schedulePresentation(root.environment.completeTabTransition)
  }

  override func layout() {
    super.layout()
    content.select(header.rootView.root.environment.settings.lastTab)
    header.frame = CGRect(
      x: bounds.minX, y: bounds.maxY - PopoverGeometry.tabBarHeight,
      width: bounds.width, height: PopoverGeometry.tabBarHeight)
    footer.frame = CGRect(
      x: bounds.minX, y: bounds.minY, width: bounds.width, height: PopoverGeometry.footerHeight)
    content.frame = CGRect(
      x: bounds.minX, y: bounds.minY + PopoverGeometry.footerHeight, width: bounds.width,
      height: max(bounds.height - PopoverGeometry.tabBarHeight - PopoverGeometry.footerHeight, 0))
  }

  override func draw(_ dirtyRect: NSRect) {
    if PanelMaterialAdapter.fill(for: .content) == .windowBackground {
      NSColor.windowBackgroundColor.setFill()
      dirtyRect.fill()
    }
  }

  override func accessibilityHitTest(_ point: NSPoint) -> Any? {
    let target = MainActor.assumeIsolated { () -> NSView? in
      guard let window, let superview else { return nil }
      return hitTest(superview.convert(window.convertPoint(fromScreen: point), from: nil))
    }
    guard let target, target !== self else { return super.accessibilityHitTest(point) }
    return target.accessibilityHitTest(point)
  }
}

private struct UsageClockDriver: View {
  let environment: UIEnvironment

  var body: some View {
    Color.clear.frame(width: 0, height: 0)
      .task(id: schedule) { await advance(schedule) }
  }

  private var schedule: UsageClockSchedule {
    let visible = environment.state.popoverVisible && environment.settings.lastTab == .usage
    return UsageClockSchedule(visible: visible, deadline: visible ? environment.nextUsageDeadline() : nil)
  }

  private func advance(_ schedule: UsageClockSchedule) async {
    guard schedule.visible, let deadline = schedule.deadline else { return }
    do {
      try await environment.clock.sleep(max(deadline.timeIntervalSince(environment.clock.now()), 0))
    } catch {
      return
    }
    guard !Task.isCancelled, environment.state.popoverVisible else { return }
    environment.advanceUsageDeadlines(to: environment.clock.now())
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
