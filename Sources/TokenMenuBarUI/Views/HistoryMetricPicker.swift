import AppKit
import SwiftUI
import TokenMenuBarCore

struct HistoryMetricPicker: NSViewRepresentable {
  let metrics: [HistoryMetric]
  @Binding var selection: HistoryMetric

  func makeNSView(context: Context) -> NSPopUpButton {
    let control = NSPopUpButton(frame: .zero, pullsDown: false)
    control.controlSize = .small
    control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    control.target = context.coordinator
    control.action = #selector(Coordinator.changed(_:))
    control.setAccessibilityLabel("Metric")
    control.setAccessibilityIdentifier("history-metric")
    return control
  }

  func updateNSView(_ control: NSPopUpButton, context: Context) {
    context.coordinator.selection = $selection
    if context.coordinator.metrics != metrics {
      let menu = NSMenu()
      menu.autoenablesItems = false
      for group in HistoryMetricGroup.allCases {
        let entries = metrics.enumerated().filter { $0.element.group == group }
        guard !entries.isEmpty else { continue }
        let header = NSMenuItem.sectionHeader(title: group.rawValue)
        header.tag = -1
        menu.addItem(header)
        for (index, metric) in entries {
          let item = NSMenuItem(title: metric.title, action: nil, keyEquivalent: "")
          item.tag = index
          menu.addItem(item)
        }
      }
      control.menu = menu
      context.coordinator.metrics = metrics
    }
    control.select(metrics.firstIndex(of: selection).flatMap { control.menu?.item(withTag: $0) })
    control.isEnabled = context.environment.isEnabled && !metrics.isEmpty
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
    nsView.fittingSize
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(selection: $selection)
  }

  @MainActor final class Coordinator: NSObject {
    var selection: Binding<HistoryMetric>
    var metrics: [HistoryMetric] = []

    init(selection: Binding<HistoryMetric>) {
      self.selection = selection
    }

    @objc func changed(_ sender: NSPopUpButton) {
      guard let item = sender.selectedItem, !item.isSectionHeader, metrics.indices.contains(item.tag) else { return }
      selection.wrappedValue = metrics[item.tag]
    }
  }
}
