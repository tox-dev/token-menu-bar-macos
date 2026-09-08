import AppKit
import SwiftUI
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func iconOnlyStatusKeepsItsQuotaWarningAccessible() {
  let model = StatusItemModel(
    cells: [], iconTone: .attention, showsIcon: true, countdownActive: false,
    accessibilitySummary: "Claude: Included quota limited by All models (100% used; resets 2d).")
  #expect(
    StatusItemRenderer.accessibilityDescription(for: model)
      == "Token Menu Bar, Claude: Included quota limited by All models (100% used; resets 2d).")
}

@Test @MainActor func settingsTabBindsTheDisplayPaceAndPrivacyControls() throws {
  let environment = try makeEnvironment()
  let tab = SettingsTab(environment: environment, mountsIncrementally: false)
  var changes = 0
  environment.actions.settingsChanged = { changes += 1 }

  tab.menuBarSetting(\.usageDisplay).wrappedValue = .remaining
  tab.menuBarSetting(\.hidePersonalInformation).wrappedValue = true
  tab.setting(\.paceWorkdays).wrappedValue = 5
  tab.setting(\.notifications.notifyOnPace).wrappedValue = false
  tab.setThreshold(50, on: true)

  #expect(environment.settings.usageDisplay == .remaining)
  #expect(environment.settings.hidePersonalInformation)
  #expect(environment.settings.paceWorkdays == 5)
  #expect(!environment.settings.notifications.notifyOnPace)
  #expect(environment.settings.notifications.thresholds.contains(50))
  #expect(changes == 2)
  let hosting = host(tab, width: 880, height: 3_000)
  #expect(hosting.frame.width == 880)
}

@Test @MainActor func settingsPreviewFollowsTheUsageDisplay() throws {
  let environment = try makeEnvironment()
  let tab = SettingsTab(environment: environment, mountsIncrementally: false)
  let used = tab.previewModel.cells.map { StatusTemplate.plainText($0.lines) }
  environment.settings.usageDisplay = .remaining
  let remaining = tab.previewModel.cells.map { StatusTemplate.plainText($0.lines) }

  #expect(used.contains { $0.hasSuffix("36%") })
  #expect(remaining.contains { $0.hasSuffix("64%") })
  #expect(tab.previewModel.cells[0].tooltip.contains("64% left"))
  let hosting = host(
    StatusPreview(model: tab.previewModel, highlightedKey: .constant(nil), select: { _ in }), width: 600,
    height: 60)
  #expect(hosting.frame.height == 60)
  let buttons = previewButtons(in: hosting)
  #expect(buttons.count == tab.previewModel.cells.count)
  let frames = buttons.map { hosting.convert($0.bounds, from: $0) }
  #expect(frames.allSatisfy { !$0.isEmpty && hosting.bounds.contains($0) }, "Preview frames: \(frames)")
  #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.maxX <= $1.minX }, "Preview frames: \(frames)")
  #expect(StatusItemRenderer.accessibilityDescription(for: tab.previewModel).contains("64% left"))
}

@MainActor
private func previewButtons(in root: NSView) -> [NSButton] {
  root.subviews.flatMap { view in
    (view as? NSButton).map { [$0] } ?? previewButtons(in: view)
  }
}

@Test @MainActor func settingsPreviewIdentifiersSurviveDisplayChanges() throws {
  let environment = try makeEnvironment()
  let tab = SettingsTab(environment: environment, mountsIncrementally: false)
  let hosting = host(
    StatusPreview(model: tab.previewModel, highlightedKey: .constant(nil), select: { _ in }), width: 600, height: 60)
  let identifiers = previewButtons(in: hosting).map { $0.accessibilityIdentifier() }
  let labels = previewButtons(in: hosting).map { $0.accessibilityLabel() }
  #expect(identifiers == tab.previewModel.cells.map { "status-preview-\($0.id)" })

  environment.settings.usageDisplay = .remaining
  hosting.rootView = StatusPreview(model: tab.previewModel, highlightedKey: .constant(nil), select: { _ in })
  hosting.layoutSubtreeIfNeeded()
  hosting.displayIfNeeded()

  #expect(previewButtons(in: hosting).map { $0.accessibilityIdentifier() } == identifiers)
  #expect(previewButtons(in: hosting).map { $0.accessibilityLabel() } != labels)
}

@Test @MainActor func formatPickerListsTheCountdownPresets() throws {
  let environment = try makeEnvironment()
  environment.disclosures.setExpanded(true, for: "settings.display")
  let hosting = host(SettingsTab(environment: environment, mountsIncrementally: false), width: 880, height: 3_000)
  let controls = segmentedControls(in: hosting)
  let labels = controls.map { control in (0..<control.segmentCount).compactMap { control.label(forSegment: $0) } }

  #expect(labels.contains(StatusFormat.allCases.map(\.pickerLabel)))
  #expect(labels.contains(["Used", "Left"]))
}

@MainActor
private func segmentedControls(in root: NSView) -> [NSSegmentedControl] {
  var found: [NSSegmentedControl] = []
  var pending = [root]
  while let view = pending.popLast() {
    if let control = view as? NSSegmentedControl { found.append(control) }
    pending.append(contentsOf: view.subviews)
  }
  return found
}

@Test @MainActor func windowRowsRenderTheRemainingShare() throws {
  let card = UsagePresenter.card(
    provider: .claude, state: ProviderState(snapshot: sampleSnapshot(.claude), availability: .current), samples: [:],
    options: UsageDisplayOptions(display: .remaining), now: fixedNow)
  let row = try #require(card.rows.first)
  let view = WindowRowView(row: row, now: fixedNow)

  #expect(row.percentText == "64%")
  #expect(view.accessibilityValue.hasPrefix("64% left"))
  #expect(inkFraction(view, width: 820, height: 50) > 0)
}

@Test @MainActor func usagePresentationRefreshesWhenTheDisplaySettingsChange() async throws {
  let environment = try makeEnvironment()
  environment.state.popoverVisible = true
  environment.settings.lastTab = .usage
  let before = try #require(environment.usagePresentation.cards.first?.rows.first)
  #expect(before.percentText == "36%")
  #expect(environment.usagePresentation.cards[0].chips.map(\.text).contains("user@example.com"))

  environment.settings.usageDisplay = .remaining
  environment.settings.hidePersonalInformation = true
  await waitUntil { environment.usagePresentation.cards.first?.rows.first?.percentText == "64%" }

  #expect(environment.usagePresentation.cards[0].rows[0].percentText == "64%")
  #expect(environment.usagePresentation.cards[0].chips.map(\.text).contains("account"))
  #expect(!environment.usagePresentation.cards[0].chips.map(\.text).contains("user@example.com"))
}

@Test @MainActor func providerRowsMaskTheAccountWhenAsked() throws {
  let environment = try makeEnvironment()
  environment.settings.hidePersonalInformation = true
  let hosting = host(SettingsTab(environment: environment, mountsIncrementally: false), width: 880, height: 3_000)
  let presentation = SettingsProviderPresentation(
    state: environment.state.state(for: .claude), now: fixedNow,
    hidePersonalInformation: environment.settings.hidePersonalInformation)

  #expect(presentation.identity == "account · Max 20x")
  #expect(hosting.frame.width == 880)
}

@Test @MainActor func exhaustedPresetRendersTheCountdownInTheStatusItem() {
  let snapshots: [ProviderID: ProviderSnapshot] = [.claude: sampleSnapshot(.claude, percent: 100)]
  let model = StatusItemBuilder.build(
    StatusItemInput(
      snapshots: snapshots, availability: [.claude: .current],
      selectedKeys: [WindowKey(provider: .claude, windowID: "session")], format: .countdownWhenExhausted,
      customTemplate: "", decimals: 0, hideZeroCells: true, order: .provider, labels: [:], now: fixedNow))

  #expect(model.countdownActive)
  #expect(model.cells[0].lines.map { StatusTemplate.plainText([$0]) } == ["CC 5h", "4h00m"])
  let title = StatusItemRenderer.attributedTitle(for: model, height: 18, dark: false)
  #expect(title.length == 1)
}

@Test @MainActor func settingsTabBindsTheUsageFileToggle() throws {
  let environment = try makeEnvironment()
  let tab = SettingsTab(environment: environment, mountsIncrementally: false)

  tab.setting(\.writeUsageFile).wrappedValue = true

  #expect(environment.settings.writeUsageFile)
  #expect(host(tab).fittingSize.height > 0)
}
