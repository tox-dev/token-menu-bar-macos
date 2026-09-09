import AppKit
import SwiftUI

struct NativeDatePicker: NSViewRepresentable {
  @Binding var selection: Date
  let includesTime: Bool
  let timeZone: TimeZone
  let label: String
  let identifier: String

  func makeNSView(context: Context) -> NSDatePicker {
    let picker = NSDatePicker()
    picker.datePickerStyle = .textFieldAndStepper
    picker.isBezeled = true
    picker.drawsBackground = true
    picker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    picker.target = context.coordinator
    picker.action = #selector(Coordinator.change(_:))
    return picker
  }

  func updateNSView(_ picker: NSDatePicker, context: Context) {
    context.coordinator.selection = $selection
    picker.datePickerElements = includesTime ? [.yearMonthDay, .hourMinute] : [.yearMonthDay]
    picker.calendar = context.environment.calendar
    picker.timeZone = timeZone
    picker.isEnabled = context.environment.isEnabled
    picker.setAccessibilityLabel(label)
    picker.setAccessibilityIdentifier(identifier)
    if picker.dateValue != selection { picker.dateValue = selection }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSDatePicker, context: Context) -> CGSize? {
    nsView.fittingSize
  }

  func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

  @MainActor final class Coordinator: NSObject {
    var selection: Binding<Date>

    init(selection: Binding<Date>) { self.selection = selection }

    @objc func change(_ picker: NSDatePicker) { selection.wrappedValue = picker.dateValue }
  }
}
