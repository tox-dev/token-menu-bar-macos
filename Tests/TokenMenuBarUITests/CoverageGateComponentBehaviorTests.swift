import AppKit
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func coverageGateSegmentedControlClearsAnUnavailableSelection() throws {
  var selection = "Missing"
  let control = NativeSegmentedControl(
    [(value: "Stable", label: "Stable"), (value: "Usage", label: "Usage")],
    selection: Binding(get: { selection }, set: { selection = $0 }),
    accessibilityLabel: "Order")
  let hosting = host(control, width: 180, height: 40)
  let segmented: NSSegmentedControl = try #require(coverageGateView(in: hosting))

  #expect(segmented.selectedSegment == -1)
}

@Test @MainActor func coverageGateEmptyWrappingStackHasNoIntrinsicContent() {
  let hosting = NSHostingView(rootView: WrappingHStack { EmptyView() })
  hosting.layoutSubtreeIfNeeded()

  #expect(hosting.fittingSize == .zero)
}

@Test @MainActor func coverageGateChipButtonsAndContextActionCopyTheValue() {
  var copied: [String] = []
  let chip = ChipView(chip: Chip(text: "Max"), onCopy: { copied.append($0) })
  chip.primaryAction()
  chip.copyAction()

  #expect(copied == ["Max", "Max"])
}

@Test @MainActor func coverageGateFullLogSearchButtonFocusesTheField() async throws {
  let hosting = host(FullLogView(log: makeLog()), width: 620, height: 260)
  let window = try #require(hosting.window)
  let event = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f",
      isARepeat: false, keyCode: 3))
  #expect(window.performKeyEquivalent(with: event))
  await Task.yield()

  #expect(hosting.window?.firstResponder is NSTextView)
}

@Test @MainActor func coverageGateProviderHeaderButtonsRefreshAndOpenSetup() throws {
  let environment = try makeEnvironment(populate: false)
  environment.settings.setProvider(.claude, enabled: true)
  environment.state.update(.claude) {
    $0.snapshot = sampleSnapshot(.claude)
    $0.availability = .authenticationRequired
  }
  environment.refreshUsagePresentation()
  let card = try #require(environment.cards.first { $0.provider == .claude })
  var refreshed: [ProviderID] = []
  var opened: [ProviderID?] = []
  environment.actions.showProviders = { opened.append($0) }
  let view = ProviderCardView(
    card: card, environment: environment, onRefreshProvider: { refreshed.append($0) })
  let buttons = coverageGateNativeIconButtons(in: view.body)

  try #require(buttons.first { $0.accessibilityLabel == "Refresh Claude" }).action()
  try #require(buttons.first { $0.accessibilityLabel == "Set up Claude" }).action()

  #expect(refreshed == [.claude])
  #expect(opened == [.claude])
}

@Test @MainActor func coverageGateUnselectedInactiveWindowRendersInBothLayouts() {
  let window = QuotaWindow(
    id: "inactive", label: "Inactive model", group: .other, usedPercent: 0, resetsAt: nil, isActive: false)
  let row = WindowRow(
    key: WindowKey(.claude, window), window: window,
    pace: PaceEstimate(status: .unknown, expectedPercent: nil, ratio: nil, projectedExhaustion: nil),
    countdown: "", resetClock: "", isSelected: false)
  let wide = WindowRowView(row: row, now: fixedNow)
  let narrow = wide.environment(\.dynamicTypeSize, .accessibility1)

  #expect(inkFraction(wide, width: 852, height: 90) > 0)
  #expect(inkFraction(narrow, width: 548, height: 150) > 0)
  #expect(wide.accessibilityValue.contains("not shown in the menu bar"))
}

@MainActor
private func coverageGateView<Wanted: NSView>(in root: NSView) -> Wanted? {
  coverageGateViews(in: root).compactMap { $0 as? Wanted }.first
}

@MainActor
private func coverageGateViews(in root: NSView) -> [NSView] {
  [root] + root.subviews.flatMap(coverageGateViews)
}

@MainActor
private func coverageGateNativeIconButtons(in value: Any, depth: Int = 0) -> [NativeIconButton] {
  if let button = value as? NativeIconButton { return [button] }
  guard depth < 48 else { return [] }
  return Mirror(reflecting: value).children.flatMap {
    coverageGateNativeIconButtons(in: $0.value, depth: depth + 1)
  }
}
