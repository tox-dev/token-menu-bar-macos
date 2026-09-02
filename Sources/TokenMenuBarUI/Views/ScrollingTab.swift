import AppKit
import SwiftUI
import TokenMenuBarCore

public struct ScrollingTab<Content: View>: View {
  let tab: PopoverTab
  let content: Content
  let measurementHeight: CGFloat?
  @State private var measuredSize = CGSize.zero

  public init(tab: PopoverTab, measurementHeight: CGFloat? = nil, @ViewBuilder content: () -> Content) {
    self.tab = tab
    self.measurementHeight = measurementHeight
    self.content = content()
  }

  public var body: some View {
    ScrollView(.vertical) {
      content
        .padding(PopoverGeometry.contentPadding)
        .background(ScrollerStyler())
        .modifier(ContentMeasurement(tab: tab, fixedHeight: measurementHeight, measuredSize: $measuredSize))
    }
    .frame(minHeight: 200)
  }
}

private struct ContentMeasurement: ViewModifier {
  let tab: PopoverTab
  let fixedHeight: CGFloat?
  @Binding var measuredSize: CGSize

  func body(content: Content) -> some View {
    if let fixedHeight {
      content.preference(
        key: PopoverMeasurementKey.self,
        value: PopoverMeasurement(
          tab: tab,
          size: CGSize(width: PopoverGeometry.stableTabWidth, height: fixedHeight)))
    } else {
      content
        .onGeometryChange(for: CGSize.self) { proxy in
          proxy.size
        } action: { size in
          measuredSize = size
        }
        .preference(
          key: PopoverMeasurementKey.self,
          value: measuredSize == .zero ? nil : PopoverMeasurement(tab: tab, size: measuredSize))
    }
  }
}

public struct PopoverMeasurementKey: PreferenceKey {
  public static let defaultValue: PopoverMeasurement? = nil

  public static func reduce(value: inout PopoverMeasurement?, nextValue: () -> PopoverMeasurement?) {
    value = nextValue() ?? value
  }
}
