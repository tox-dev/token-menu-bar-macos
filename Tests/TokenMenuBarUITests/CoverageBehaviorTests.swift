import AppKit
import SwiftUI
import Testing

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

@Test @MainActor func statusPreviewButtonsSelectTheirModel() async throws {
  let model = statusModel()
  let cell = try #require(model.cells.first)
  let key = try #require(WindowKey(storageKey: cell.id))
  var highlighted: WindowKey?
  var selected: WindowKey?
  let preview = StatusPreview(
    model: model,
    highlightedKey: Binding(get: { highlighted }, set: { highlighted = $0 }),
    select: { selected = $0 })
  let hosting = host(preview, width: 520, height: 60)

  #expect(pressAccessibilityElement(label: cell.tooltip, in: hosting))
  await Task.yield()
  #expect(highlighted == key)
  #expect(selected == key)
}

@Test @MainActor func statusPreviewRendersCellsWithoutWindowKeys() {
  let cell = StatusCell(
    id: ProviderID.claude.rawValue, provider: .claude,
    lines: [[StatusRun(text: "CC", kind: .label)]], percent: 36, tooltip: "Claude usage")
  let model = StatusItemModel(cells: [cell], iconTone: .normal, showsIcon: false, countdownActive: false)
  #expect(inkFraction(StatusPreview(model: model), width: 180, height: 48) > 0)
}

@Test @MainActor func statusPreviewWrapsCellsAtNarrowWidths() {
  let model = statusModel()
  let wide = fittingSize(StatusPreview(model: model), width: 700)
  let narrow = fittingSize(StatusPreview(model: model), width: 180)

  #expect(narrow.width <= 180)
  #expect(narrow.height > wide.height)
}

@Test @MainActor func providerChipConstrainsLongValues() {
  let text = String(repeating: "long-provider-identity-", count: 8)
  var copied: String?
  let chip = UsageIdentityChip(
    chip: Chip(text: text), provider: .claude,
    onCopy: { copied = $0 })
  let size = fittingSize(chip, width: 260)

  #expect(size.width <= 260)
  #expect(chip.primaryHelp.title == text)
  chip.primaryAction()
  #expect(copied == text)
}

@Test @MainActor func providerCardDefaultRefreshActionIsSafe() throws {
  let environment = try makeEnvironment()
  let card = ProviderCardView(card: try #require(environment.cards.first), environment: environment)
  card.refresh()
}

@MainActor private func fittingSize<Content: View>(_ view: Content, width: CGFloat) -> CGSize {
  let hosting = NSHostingView(
    rootView: view.frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
  hosting.layoutSubtreeIfNeeded()
  return hosting.fittingSize
}

@Test @MainActor func settingsFocusesARequestedProvider() async throws {
  let environment = try makeEnvironment()
  let request = ProviderSettingsFocusRequest(provider: .codex)
  environment.providerFocusRequest = request
  let hosting = host(
    SettingsTab(environment: environment, providerFocusRequest: request), width: 720, height: 1_000)
  #expect(hosting.fittingSize.width > 0)
  await waitUntil { environment.providerFocusRequest == nil }
  #expect(environment.providerFocusRequest == nil)
}

@Test @MainActor func settingsHostedConstructionAndLayoutStaysUnderTwoHundredMilliseconds() throws {
  let environment = try makeEnvironment()
  _ = NSHostingView(rootView: Color.clear)
  let start = ContinuousClock.now
  let hosting = NSHostingView(rootView: SettingsTab(environment: environment))
  hosting.frame = NSRect(x: 0, y: 0, width: 880, height: 800)
  hosting.layoutSubtreeIfNeeded()
  let elapsed = start.duration(to: .now)
  #expect(hosting.fittingSize.width > 0)
  #expect(elapsed < .milliseconds(200))
}

@Test @MainActor func settingsDeferredSectionsBecomeAccessible() async throws {
  let environment = try makeEnvironment()
  var contentReady = false
  let hosting = host(
    SettingsTab(environment: environment)
      .onPreferenceChange(SettingsContentReadyKey.self) { contentReady = $0 },
    width: 880, height: 1_600)

  await waitUntil { contentReady }

  #expect(contentReady)
  #expect(hosting.fittingSize.height > 0)
}

@Test @MainActor func settingsProviderVisibilityFollowsDiscoveryAndShowAll() throws {
  let environment = try makeEnvironment(populate: false)
  let tab = SettingsTab(environment: environment)
  #expect(tab.visibleProviders.isEmpty)

  environment.settings.showAllProviders = true
  #expect(tab.visibleProviders == ProviderID.allCases)

  environment.settings.showAllProviders = false
  tab.setProvider(.gemini, enabled: false)
  #expect(tab.visibleProviders.isEmpty)
  #expect(environment.settings.providerOverride(for: .gemini) == false)

  environment.state.update(.gemini) {
    $0.credentialHealth = .valid(source: ProviderID.gemini.setup.credentialSources[0], expiresAt: nil)
  }
  #expect(tab.visibleProviders == [.gemini])
}

@Test @MainActor func usageWindowRowsExposeLongLabelsAndPaceAtNarrowWidth() {
  let label = "Extremely Long Localized Model Window Name That Must Remain Readable"
  let projection = fixedNow.addingTimeInterval(2 * 86400)
  let window = QuotaWindow(
    id: "long-model-identifier-that-must-remain-readable", label: label, group: .weekly, usedPercent: 67,
    resetsAt: fixedNow.addingTimeInterval(4 * 86400), duration: 7 * 86400)
  let row = WindowRow(
    key: WindowKey(.claude, window), window: window,
    pace: PaceEstimate(status: .ahead, expectedPercent: 42, ratio: 1.6, projectedExhaustion: projection),
    countdown: "4d", resetClock: "Friday at 10:00 AM")
  let view = WindowRowView(row: row, now: fixedNow)
  #expect(inkFraction(view, width: 320, height: 180) > 0)

  #expect(view.accessibilityLabelText.contains(label))
  #expect(view.accessibilityValue.contains("Ahead of pace"))
  #expect(view.accessibilityValue.contains("expected 42%"))
  #expect(view.accessibilityValue.contains("1.6×"))
}

@Test @MainActor func everyPaceStateRemainsVisibleAtNarrowWidth() {
  let cases: [(PaceStatus, Double?, Double?, String)] = [
    (.unknown, nil, nil, "Learning pace"),
    (.onTrack, 42, 1, "On pace"),
    (.ahead, 42, 1.6, "Ahead of pace"),
    (.behind, 42, 0.6, "Under pace"),
    (.exhausted, nil, nil, "Limit reached"),
  ]
  for (status, expected, ratio, text) in cases {
    let window = QuotaWindow(
      id: status.rawValue, label: "Long (status.rawValue) model window", group: .weekly,
      usedPercent: status == .exhausted ? 100 : 48,
      resetsAt: fixedNow.addingTimeInterval(4 * 86400), duration: 7 * 86400)
    let row = WindowRow(
      key: WindowKey(.claude, window), window: window,
      pace: PaceEstimate(status: status, expectedPercent: expected, ratio: ratio, projectedExhaustion: nil),
      countdown: "4d", resetClock: "Friday at 10:00 AM")
    let view = WindowRowView(row: row, now: fixedNow)
    #expect(inkFraction(view, width: 320, height: 150) > 0)
    #expect(view.accessibilityValue.contains(text))
  }
}

@MainActor
private func pressAccessibilityElement(label: String, in root: NSView) -> Bool {
  pressAccessibilityElement(label: label, in: root as Any, depth: 0)
}

@MainActor
private func pressAccessibilityElement(label: String, in value: Any, depth: Int) -> Bool {
  guard depth < 30 else { return false }
  if let view = value as? NSView {
    if view.accessibilityLabel() == label, view.accessibilityPerformPress() { return true }
    if (view.accessibilityChildren() ?? []).contains(where: {
      pressAccessibilityElement(label: label, in: $0, depth: depth + 1)
    }) {
      return true
    }
    return view.subviews.contains {
      pressAccessibilityElement(label: label, in: $0, depth: depth + 1)
    }
  }
  if let element = value as? NSAccessibilityElement {
    if element.accessibilityLabel() == label, element.accessibilityPerformPress() { return true }
    return (element.accessibilityChildren() ?? []).contains {
      pressAccessibilityElement(label: label, in: $0, depth: depth + 1)
    }
  }
  return false
}
