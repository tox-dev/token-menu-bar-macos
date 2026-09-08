import AppKit
import SwiftUI
import TokenMenuBarCore

extension PersistentTabContainer {
  convenience init(
    environment: UIEnvironment, selection: PopoverTab,
    chooseHistoryExportURL: @escaping @MainActor () async -> URL?,
    onMeasure: @escaping @MainActor (PopoverMeasurement) -> Void,
    preferredContentSize: @escaping @MainActor (PopoverTab) -> CGSize?
  ) {
    // Zero-sized hosts trigger narrow-width layout passes before the first popover frame.
    self.init(
      frame: CGRect(
        x: 0, y: 0, width: PopoverGeometry.stableTabWidth,
        height: PopoverGeometry.preferredHeight(for: selection)
          - PopoverGeometry.tabBarHeight - PopoverGeometry.footerHeight))
    self.preferredContentSize = preferredContentSize
    for tab in PopoverTab.allCases {
      let host = TabHostingView(
        rootView: AnyView(
          PersistentTabRoot(
            environment: environment,
            tab: tab,
            mountsSettingsIncrementally: false,
            chooseHistoryExportURL: chooseHistoryExportURL,
            onMeasure: onMeasure)))
      host.sizingOptions = []
      install(host, for: tab)
    }
    select(selection)
    environment.tabContainer = self
  }
}

@MainActor
private final class TabHostingView: NSHostingView<AnyView> {
  // Every tab has controls; querying SwiftUI's focus graph here recursively visits the nested hosts on macOS 14.
  override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class PersistentTabContainer: NSView {
  private(set) var selectionGeneration = 0
  private var slots: [PopoverTab: PersistentTabSlot] = [:]
  private var selected = PopoverTab.usage
  private var prewarmed: Set<PopoverTab> = []
  private var prewarmQueue: [PopoverTab] = []
  private var prewarmScheduled = false
  private var presentationScheduled = false
  private var presentedGeneration: Int?
  private var defersViewportLayout = false
  var preferredContentSize: @MainActor (PopoverTab) -> CGSize? = { _ in nil }

  func install(_ host: NSHostingView<AnyView>, for tab: PopoverTab) {
    wantsLayer = true
    let slot = PersistentTabSlot(host: host, frame: bounds)
    addSubview(slot)
    slots[tab] = slot
  }

  func select(_ tab: PopoverTab) {
    guard let slot = slots[tab], selected != tab || !slot.isActive else { return }
    selected = tab
    selectionGeneration += 1
    prewarmed.insert(tab)
    for (candidate, slot) in slots { slot.setActive(candidate == tab) }
    needsLayout = true
    schedulePrewarm()
  }

  func present(_ tab: PopoverTab) {
    select(tab)
    layoutSubtreeIfNeeded()
    displayIfNeeded()
    presentedGeneration = selectionGeneration
  }

  func refresh(_ tab: PopoverTab) {
    guard tab != selected else { return }
    prewarmed.remove(tab)
    if prewarmScheduled {
      if !prewarmQueue.contains(tab) { prewarmQueue.append(tab) }
    } else {
      schedulePrewarm()
    }
  }

  func resizeViewport(_ resize: () -> Void) {
    defersViewportLayout = true
    resize()
    defersViewportLayout = false
    needsLayout = true
  }

  func schedulePresentation(_ onPresent: @escaping @MainActor (PopoverTab) -> Void) {
    guard !presentationScheduled, presentedGeneration != selectionGeneration else { return }
    presentationScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      presentationScheduled = false
      guard presentedGeneration != selectionGeneration else { return }
      present(selected)
      onPresent(selected)
    }
  }

  override func layout() {
    super.layout()
    if !defersViewportLayout, let slot = slots[selected], slot.frame != bounds { slot.frame = bounds }
    schedulePrewarm()
  }

  func schedulePrewarm() {
    guard !prewarmScheduled, !bounds.isEmpty else { return }
    prewarmQueue = [.settings, .history, .usage].filter {
      $0 != selected && slots[$0] != nil
        && (!prewarmed.contains($0) || slots[$0]?.frame.size != viewportSize(for: $0))
    }
    guard !prewarmQueue.isEmpty else { return }
    prewarmScheduled = true
    DispatchQueue.main.async { [weak self] in self?.prewarmNext() }
  }

  private func prewarmNext() {
    guard let tab = prewarmQueue.first, let slot = slots[tab] else {
      prewarmScheduled = false
      schedulePrewarm()
      return
    }
    prewarmQueue.removeFirst()
    prewarmed.insert(tab)
    slot.prewarm(in: CGRect(origin: bounds.origin, size: viewportSize(for: tab)))
    DispatchQueue.main.async { [weak self] in self?.prewarmNext() }
  }

  private func viewportSize(for tab: PopoverTab) -> CGSize {
    guard let content = preferredContentSize(tab) else { return bounds.size }
    return CGSize(
      width: content.width,
      height: max(content.height - PopoverGeometry.tabBarHeight - PopoverGeometry.footerHeight, 0))
  }
}

@MainActor
final class PersistentTabSlot: NSView {
  private let host: NSHostingView<AnyView>
  private(set) var isActive = false

  init(host: NSHostingView<AnyView>, frame: CGRect) {
    self.host = host
    super.init(frame: frame)
    wantsLayer = true
    host.frame = bounds
    host.autoresizingMask = [.width, .height]
    addSubview(host)
    isHidden = true
    setAccessibilityHidden(true)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
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
    autoreleasepool {
      if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
      }
    }
    isHidden = true
    alphaValue = 1
  }
}

private struct PersistentTabRoot: View {
  @Bindable var environment: UIEnvironment
  let tab: PopoverTab
  let mountsSettingsIncrementally: Bool
  let chooseHistoryExportURL: @MainActor () async -> URL?
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
