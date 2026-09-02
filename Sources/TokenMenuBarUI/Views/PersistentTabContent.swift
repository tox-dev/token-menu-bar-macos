import AppKit
import SwiftUI
import TokenMenuBarCore

struct PersistentTabContent: NSViewRepresentable {
  @Bindable var environment: UIEnvironment
  let selection: PopoverTab
  let chooseHistoryExportURL: @MainActor () -> URL?
  let onMeasure: @MainActor (PopoverMeasurement) -> Void
  let onPresent: @MainActor (PopoverTab) -> Void

  func makeNSView(context: Context) -> PersistentTabContainer {
    let container = PersistentTabContainer()
    for tab in PopoverTab.allCases {
      let host = NSHostingView(
        rootView: AnyView(
          PersistentTabRoot(
            environment: environment,
            tab: tab,
            mountsSettingsIncrementally: false,
            chooseHistoryExportURL: chooseHistoryExportURL,
            onMeasure: onMeasure)))
      container.install(host, for: tab)
    }
    container.select(selection)
    return container
  }

  func updateNSView(_ container: PersistentTabContainer, context: Context) {
    container.select(selection)
    onPresent(selection)
  }
}

@MainActor
final class PersistentTabContainer: NSView {
  private var slots: [PopoverTab: PersistentTabSlot] = [:]
  private var selected = PopoverTab.usage
  private var prewarmed: Set<PopoverTab> = []
  private var prewarmQueue: [PopoverTab] = []
  private var prewarmScheduled = false

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  override func accessibilityChildren() -> [Any]? {
    slots[selected].map { [$0] } ?? []
  }

  func install(_ host: NSHostingView<AnyView>, for tab: PopoverTab) {
    let slot = PersistentTabSlot(host: host)
    slot.autoresizingMask = [.width, .height]
    addSubview(slot)
    slots[tab] = slot
  }

  func select(_ tab: PopoverTab) {
    guard let slot = slots[tab], selected != tab || !slot.isActive else { return }
    selected = tab
    prewarmed.insert(tab)
    for (candidate, slot) in slots { slot.setActive(candidate == tab) }
    slot.frame = bounds
    slot.layoutSubtreeIfNeeded()
    schedulePrewarm()
  }

  override func layout() {
    super.layout()
    if let slot = slots[selected], slot.frame != bounds { slot.frame = bounds }
    schedulePrewarm()
  }

  private func schedulePrewarm() {
    guard !prewarmScheduled, !bounds.isEmpty else { return }
    prewarmQueue = [.settings, .history].filter { $0 != selected && !prewarmed.contains($0) }
    guard !prewarmQueue.isEmpty else { return }
    prewarmScheduled = true
    DispatchQueue.main.async { [weak self] in self?.prewarmNext() }
  }

  private func prewarmNext() {
    guard let tab = prewarmQueue.first, let slot = slots[tab] else {
      prewarmScheduled = false
      return
    }
    prewarmQueue.removeFirst()
    prewarmed.insert(tab)
    slot.prewarm(in: bounds)
    DispatchQueue.main.async { [weak self] in self?.prewarmNext() }
  }
}

@MainActor
final class PersistentTabSlot: NSView {
  private let host: NSHostingView<AnyView>
  private(set) var isActive = false

  init(host: NSHostingView<AnyView>) {
    self.host = host
    super.init(frame: .zero)
    host.autoresizingMask = [.width, .height]
    addSubview(host)
    isHidden = true
    setAccessibilityHidden(true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func accessibilityChildren() -> [Any]? {
    isActive ? [host] : []
  }

  override func layout() {
    super.layout()
    if host.frame != bounds { host.frame = bounds }
  }

  func setActive(_ active: Bool) {
    guard active != isActive else { return }
    isActive = active
    setAccessibilityHidden(!active)
    isHidden = !active
    alphaValue = 1
  }

  func prewarm(in bounds: CGRect) {
    guard !isActive else { return }
    frame = bounds
    alphaValue = 0
    isHidden = false
    layoutSubtreeIfNeeded()
    isHidden = true
    alphaValue = 1
  }
}

private struct PersistentTabRoot: View {
  @Bindable var environment: UIEnvironment
  let tab: PopoverTab
  let mountsSettingsIncrementally: Bool
  let chooseHistoryExportURL: @MainActor () -> URL?
  let onMeasure: @MainActor (PopoverMeasurement) -> Void

  var body: some View {
    content
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("tab-content-\(tab.rawValue)")
      .onPreferenceChange(PopoverMeasurementKey.self) { measurement in
        guard let measurement, measurement.tab == tab else { return }
        MainActor.assumeIsolated { onMeasure(measurement) }
      }
  }

  @ViewBuilder private var content: some View {
    switch tab {
    case .usage:
      UsageTab(environment: environment)
    case .history:
      HistoryTab(environment: environment, chooseExportURL: chooseHistoryExportURL)
    case .settings:
      SettingsTab(
        environment: environment,
        providerFocusRequest: environment.providerFocusRequest,
        mountsIncrementally: mountsSettingsIncrementally)
    }
  }
}
