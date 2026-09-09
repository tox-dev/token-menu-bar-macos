import AppKit
import SwiftUI
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarUI

@Test(arguments: [false, true]) @MainActor
func datePickerExposesItsNativeIdentityAndTimeFields(includesTime: Bool) throws {
  let timeZone = TimeZone(secondsFromGMT: 3600)!
  let hosting = host(
    NativeDatePicker(
      selection: .constant(fixedNow), includesTime: includesTime, timeZone: timeZone,
      label: "From", identifier: "history-from"))
  let picker = try #require(datePicker(in: hosting))
  #expect(picker.accessibilityIdentifier() == "history-from")
  #expect(picker.accessibilityLabel() == "From")
  #expect(picker.dateValue == fixedNow)
  #expect(picker.timeZone == timeZone)
  #expect(picker.datePickerElements == (includesTime ? [.yearMonthDay, .hourMinute] : [.yearMonthDay]))
  #expect(picker.frame.width >= picker.fittingSize.width)
}

@Test @MainActor func datePickerPropagatesNativeEditsAndReplacesItsBinding() async throws {
  var first = fixedNow
  let hosting = host(
    NativeDatePicker(
      selection: Binding(get: { first }, set: { first = $0 }), includesTime: true, timeZone: .current,
      label: "From", identifier: "history-from"))
  let picker = try #require(datePicker(in: hosting))
  picker.dateValue = fixedNow.addingTimeInterval(-3600)
  #expect(picker.sendAction(picker.action, to: picker.target))
  #expect(first == fixedNow.addingTimeInterval(-3600))

  var second = fixedNow.addingTimeInterval(86400)
  hosting.rootView = NativeDatePicker(
    selection: Binding(get: { second }, set: { second = $0 }), includesTime: false, timeZone: .current,
    label: "To", identifier: "history-to")
  await mainActorTurn()
  hosting.layoutSubtreeIfNeeded()
  #expect(picker.dateValue == second)
  #expect(picker.accessibilityIdentifier() == "history-to")
  picker.dateValue = fixedNow.addingTimeInterval(90000)
  #expect(picker.sendAction(picker.action, to: picker.target))
  #expect(second == fixedNow.addingTimeInterval(90000))
  #expect(first == fixedNow.addingTimeInterval(-3600))
}

@Test @MainActor func datePickerRespectsTheDisabledEnvironment() throws {
  let hosting = host(
    NativeDatePicker(
      selection: .constant(fixedNow), includesTime: false, timeZone: .current,
      label: "To", identifier: "history-to"
    ).disabled(true))
  #expect(try #require(datePicker(in: hosting)).isEnabled == false)
}

@MainActor
private func datePicker(in view: NSView) -> NSDatePicker? {
  if let picker = view as? NSDatePicker { return picker }
  return view.subviews.lazy.compactMap { datePicker(in: $0) }.first
}
