import AppKit
import SwiftUI
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func coverageGateSegmentedControlClearsAnUnavailableSelection() throws {
  var selection = "Missing"
  let control = NativeSegmentedControl(
    [(value: "Stable", label: "Stable"), (value: "Usage", label: "Usage")],
    selection: Binding(get: { selection }, set: { selection = $0 }),
    accessibilityLabel: "Order")
  let hostingFixture = NativeHosting(control, width: 180, height: 40)
  defer { hostingFixture.close() }
  let hosting = hostingFixture.view
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
  let hostingFixture = NativeHosting(FullLogView(log: makeLog()), width: 620, height: 260)
  defer { hostingFixture.close() }
  let hosting = hostingFixture.view
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

@Test @MainActor func coverageGateProviderHeaderButtonsSignInAndOpenSetup() throws {
  let environment = try makeEnvironment(populate: false)
  environment.settings.setProvider(.claude, enabled: true)
  environment.state.update(.claude) {
    $0.snapshot = sampleSnapshot(.claude)
    $0.availability = .authenticationRequired
  }
  environment.refreshUsagePresentation()
  let card = try #require(environment.cards.first { $0.provider == .claude })
  var signIns: [ProviderID] = []
  var opened: [ProviderID?] = []
  environment.actions.signInProvider = { signIns.append($0) }
  environment.actions.showProviders = { opened.append($0) }
  let view = ProviderCardView(
    card: card, environment: environment, onRefreshProvider: { _ in Issue.record("Retried expired credentials") })
  let buttons = coverageGateButtons(in: view.body, of: NativeIconButton.self)

  try #require(coverageGateButtons(in: view.body, of: NativeActionButton<Label<Text, Image>>.self).first).action()
  try #require(buttons.first { $0.accessibilityLabel == "Set up Claude" }).action()

  #expect(signIns == [.claude])
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
  [root] + root.subviews.flatMap { coverageGateViews(in: $0) }
}

@MainActor
private func coverageGateButtons<Value>(in value: Any, of type: Value.Type, depth: Int = 0) -> [Value] {
  if let button = value as? Value { return [button] }
  guard depth < 48 else { return [] }
  return Mirror(reflecting: value).children.flatMap {
    coverageGateButtons(in: $0.value, of: type, depth: depth + 1)
  }
}
