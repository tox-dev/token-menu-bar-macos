import AppKit
import SwiftUI
import TokenMenuBarCore

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
    control.setAccessibilityLabel("Popover tabs")
    let symbols = ["chart.bar.fill", "clock.arrow.circlepath", "gearshape.fill"]
    let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: control.controlSize))
    let widest =
      PopoverTab.allCases.map {
        NSAttributedString(string: $0.rawValue, attributes: [.font: font])
          .size().width
      }.max()!
    for index in PopoverTab.allCases.indices {
      let image = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)
      control.setImage(image?.withSymbolConfiguration(symbolConfiguration), forSegment: index)
      control.setImageScaling(.scaleProportionallyDown, forSegment: index)
      control.setWidth(ceil(widest) + 38, forSegment: index)
    }
    return control
  }

  public func updateNSView(_ control: NSSegmentedControl, context: Context) {
    control.selectedSegment = PopoverTab.allCases.firstIndex(of: selection)!
    context.coordinator.selection = $selection
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator(selection: $selection)
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
