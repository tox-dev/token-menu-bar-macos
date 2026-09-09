import AppKit
import SwiftUI

struct NativeDatePicker: NSViewRepresentable {
  @Binding var selection: Date
  let includesTime: Bool
  let timeZone: TimeZone
  let label: String
  let identifier: String

  func makeNSView(context: Context) -> DatePickerContainer {
    let picker = NSDatePicker()
    picker.datePickerStyle = .textFieldAndStepper
    picker.isBezeled = true
    picker.drawsBackground = true
    picker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    picker.target = context.coordinator
    picker.action = #selector(Coordinator.change(_:))
    return DatePickerContainer(picker: picker)
  }

  func updateNSView(_ container: DatePickerContainer, context: Context) {
    let picker = container.picker
    context.coordinator.selection = $selection
    picker.datePickerElements = includesTime ? [.yearMonthDay, .hourMinute] : [.yearMonthDay]
    picker.calendar = context.environment.calendar
    picker.timeZone = timeZone
    picker.isEnabled = context.environment.isEnabled
    picker.setAccessibilityLabel(label)
    picker.setAccessibilityIdentifier(identifier)
    if picker.dateValue != selection { picker.dateValue = selection }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: DatePickerContainer, context: Context) -> CGSize? {
    nsView.picker.fittingSize
  }

  func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

  @MainActor final class Coordinator: NSObject {
    var selection: Binding<Date>

    init(selection: Binding<Date>) { self.selection = selection }

    @objc func change(_ picker: NSDatePicker) { selection.wrappedValue = picker.dateValue }
  }
}

final class DatePickerContainer: NSView {
  let picker: NSDatePicker

  init(picker: NSDatePicker) {
    self.picker = picker
    super.init(frame: .zero)
    picker.autoresizingMask = [.width, .height]
    addSubview(picker)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func layout() {
    super.layout()
    if picker.frame != bounds { picker.frame = bounds }
  }
}
