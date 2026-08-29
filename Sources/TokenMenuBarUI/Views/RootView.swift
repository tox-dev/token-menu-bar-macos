import AppKit
import SwiftUI
import TokenMenuBarCore

public struct RootView: View {
  @Bindable var environment: UIEnvironment
  public let onMeasure: (String, CGSize) -> Void
  public let onTabChange: (String) -> Void
  @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
  @State private var chromeHeight: CGFloat = PopoverGeometry.chromeHeight

  public init(
    environment: UIEnvironment, onMeasure: @escaping (String, CGSize) -> Void, onTabChange: @escaping (String) -> Void
  ) {
    self.environment = environment
    self.onMeasure = onMeasure
    self.onTabChange = onTabChange
  }

  public var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        TabPicker(selection: Binding(get: { environment.settings.lastTab }, set: { select($0) }))
          .padding(.horizontal, 12)
          .padding(.top, 10)
          .padding(.bottom, 6)
        Divider()
      }
      .background(GeometryReader { proxy in Color.clear.preference(key: ChromeSizeKey.self, value: proxy.size) })
      content
    }
    .onPreferenceChange(ChromeSizeKey.self) { size in Task { @MainActor in chromeHeight = size.height } }
    .frame(minWidth: PopoverGeometry.minimumWidth)
    .font(.body)
    .background(.regularMaterial)
    .onReceive(timer) { _ in environment.tick() }
    .task { await environment.loadRecentSamples() }
    .onChange(of: environment.state.lastRefresh) { Task { await environment.loadRecentSamples() } }
    .onPreferenceChange(SizeKey.self) { size in Task { @MainActor in measured(size) } }
  }

  @ViewBuilder private var content: some View {
    switch environment.settings.lastTab {
    case .usage: UsageTab(environment: environment)
    case .history: HistoryTab(environment: environment)
    case .settings: SettingsTab(environment: environment)
    }
  }

  func measured(_ content: CGSize) {
    guard content != .zero else { return }
    onMeasure(
      environment.settings.lastTab.rawValue, CGSize(width: content.width, height: content.height + chromeHeight))
  }

  func select(_ tab: PopoverTab) {
    environment.settings.lastTab = tab
    onTabChange(tab.rawValue)
    if tab == .history { environment.historyPresenter.reload() }
  }
}

public struct ChromeSizeKey: PreferenceKey {
  public static let defaultValue: CGSize = .zero
  public static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
    let next = nextValue()
    if next != .zero { value = next }
  }
}

public struct TabPicker: NSViewRepresentable {
  @Binding var selection: PopoverTab

  public init(selection: Binding<PopoverTab>) {
    _selection = selection
  }

  public func makeNSView(context: Context) -> NSSegmentedControl {
    let control = NSSegmentedControl(
      labels: PopoverTab.allCases.map(\.rawValue), trackingMode: .selectOne, target: context.coordinator,
      action: #selector(Coordinator.changed(_:)))
    control.segmentStyle = .automatic
    let widest =
      PopoverTab.allCases.map {
        NSAttributedString(string: $0.rawValue, attributes: [.font: control.font ?? NSFont.systemFont(ofSize: 12)])
          .size().width
      }.max() ?? 60
    for (index, tab) in PopoverTab.allCases.enumerated() {
      control.setWidth(ceil(widest) + 20, forSegment: index)
      control.setToolTip(Self.tooltip(tab), forSegment: index)
    }
    return control
  }

  public func updateNSView(_ control: NSSegmentedControl, context: Context) {
    control.selectedSegment = PopoverTab.allCases.firstIndex(of: selection) ?? 0
    context.coordinator.selection = $selection
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator(selection: $selection)
  }

  public static func tooltip(_ tab: PopoverTab) -> String {
    switch tab {
    case .usage: "Current limits, credits and pace"
    case .history: "Usage over time and analytics"
    case .settings: "Menu bar, providers, notifications, log"
    }
  }

  @MainActor
  public final class Coordinator: NSObject {
    var selection: Binding<PopoverTab>

    init(selection: Binding<PopoverTab>) {
      self.selection = selection
    }

    @objc func changed(_ sender: NSSegmentedControl) {
      selection.wrappedValue = PopoverTab.allCases[max(sender.selectedSegment, 0)]
    }
  }
}

public struct ScrollerStyler: NSViewRepresentable {
  public init() {}

  public func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async { Self.apply(from: view) }
    return view
  }

  public func updateNSView(_ view: NSView, context: Context) {}

  static func apply(from view: NSView) {
    guard let scrollView = view.enclosingScrollView else { return }
    scrollView.scrollerStyle = .overlay
    scrollView.hasHorizontalScroller = false
    scrollView.flashScrollers()
  }
}

public struct ScrollingTab<Content: View>: View {
  let content: Content

  public init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  public var body: some View {
    ScrollView(.vertical) {
      content.padding(PopoverGeometry.contentPadding).background(ScrollerStyler()).measureSize { _ in }
    }
    .frame(minHeight: 200)
  }
}
