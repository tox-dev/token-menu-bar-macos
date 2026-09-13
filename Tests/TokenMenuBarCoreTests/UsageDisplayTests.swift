import Foundation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@Test(arguments: [(UsageDisplay.used, "36.4%", "used"), (.remaining, "63.6%", "left")])
func usageDisplayFormatsThePercentItNames(display: UsageDisplay, text: String, suffix: String) {
  #expect(Format.percent(used: 36.4, display: display, decimals: 1) == text)
  #expect(display.suffix == suffix)
}

private let session = QuotaWindow(
  id: "session", label: "Current session", group: .session, usedPercent: 36.4,
  resetsAt: fixedNow.addingTimeInterval(4 * 3600 + 24 * 60), duration: 18000)

private func snapshots() -> [ProviderID: ProviderSnapshot] {
  [.claude: ProviderSnapshot(provider: .claude, windows: [session], fetchedAt: fixedNow)]
}

private func input(format: StatusFormat, display: UsageDisplay) -> StatusItemInput {
  StatusItemInput(
    snapshots: snapshots(), availability: [.claude: .current],
    selectedKeys: [WindowKey(provider: .claude, windowID: "session")], format: format, customTemplate: "",
    decimals: 0, hideZeroCells: true, order: .provider, labels: [:], now: fixedNow, display: display)
}

@Test func templatePercentTokensFollowTheDisplayButKeepTheUsedColour() {
  let context = StatusCellContext(
    provider: .claude, window: session, cellLabel: "CC", shortLabel: "CC 5h", decimals: 0, planName: nil,
    credits: nil, now: fixedNow, display: .remaining)
  let lines = StatusTemplate.render("{pct} {pct0} {pct1} {pct2} {remaining}", context: context)
  #expect(StatusTemplate.plainText(lines) == "64% 64% 63.6% 63.60% 64%")
  #expect(lines[0].allSatisfy { $0.kind == .usage(36.4) || $0.kind == .label })
  #expect(lines[0].contains { $0.kind == .usage(36.4) })
}

@Test(arguments: [
  (UsageDisplay.used, "36%", "Claude Current session: 36%, resets 4 hr 24 min", "Current session: 36%"),
  (.remaining, "64%", "Claude Current session: 64% left, resets 4 hr 24 min", "Current session: 64% left"),
])
func builderRendersCellsAndTooltipsInTheChosenDisplay(
  display: UsageDisplay, percent: String, tooltip: String, barTooltip: String
) {
  let stacked = StatusItemBuilder.build(input(format: .stacked, display: display))
  #expect(stacked.cells[0].lines.map { StatusTemplate.plainText([$0]) } == ["CC 5h", percent])
  #expect(stacked.cells[0].tooltip == tooltip)
  #expect(stacked.cells[0].percent == 36.4)
  let bars = StatusItemBuilder.build(input(format: .miniBars, display: display))
  #expect(bars.cells[0].tooltip == barTooltip)
  #expect(bars.cells[0].bars.map(\.percent) == [36.4])
}

@Test func builderCarriesTheDisplayAcrossAdaptiveTiers() {
  let remaining = input(format: .stacked, display: .remaining)
  #expect(remaining.with(tier: .stacked).display == .remaining)
  for candidate in StatusItemBuilder.candidates(remaining) where !candidate.cells.isEmpty {
    #expect(candidate.cells[0].tooltip.contains("64% left"))
  }
}

@Test(arguments: [(UsageDisplay.used, "36%", "36% used"), (.remaining, "64%", "64% left")])
func windowRowsReadInTheChosenDisplay(display: UsageDisplay, percent: String, prefix: String) {
  let state = ProviderState(snapshot: snapshots()[.claude], availability: .current)
  let card = UsagePresenter.card(
    provider: .claude, state: state, samples: [:], options: UsageDisplayOptions(display: display), now: fixedNow)
  #expect(card.rows[0].percentText == percent)
  #expect(card.rows[0].accessibilityValue(at: fixedNow).hasPrefix(prefix))
  #expect(card.rows[0].color == UsageColor.color(pace: card.rows[0].pace.status, percent: 36.4))
}

@Test func presentationAndCardsPassTheDisplayThrough() {
  let state: [ProviderID: ProviderState] = [
    .claude: ProviderState(snapshot: snapshots()[.claude], availability: .current)
  ]
  let options = UsageDisplayOptions(display: .remaining)
  #expect(
    UsagePresenter.cards(state: state, enabled: [.claude], samples: [:], options: options, now: fixedNow)[0]
      .rows[0].percentText == "64%")
  let presentation = UsagePresenter.presentation(
    state: state, enabled: [.claude], selected: [WindowKey(provider: .claude, windowID: "session")], samples: [:],
    analytics: [:], lastRefresh: nil, iconTone: .normal, isRefreshing: false, options: options, now: fixedNow)
  #expect(presentation.cards[0].rows[0].percentText == "64%")
}

@Test func widgetSnapshotCarriesTheDisplayAndTreatsItAsContent() throws {
  let keys = [WindowKey(provider: .claude, windowID: "session")]
  let remaining = WidgetSnapshot.build(
    snapshots: snapshots(), availability: [:], selectedKeys: keys, display: .remaining, now: fixedNow)
  let used = WidgetSnapshot.build(snapshots: snapshots(), availability: [:], selectedKeys: keys, now: fixedNow)
  #expect(remaining.display == .remaining)
  #expect(remaining.rows[0].percentText(display: remaining.display) == "64%")
  #expect(used.rows[0].percentText(display: used.display) == "36%")
  #expect(!remaining.hasSameContent(as: used))
  #expect(remaining.shouldPublish(after: used))
  let store = WidgetSnapshotStore(url: temporaryDirectory().appendingPathComponent("widget.json"))
  try store.write(remaining)
  #expect(store.read()?.display == .remaining)
}

@Test func widgetSnapshotWrittenBeforeTheDisplayExistedDecodesAsUsed() throws {
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .secondsSince1970
  let legacy = try decoder.decode(
    WidgetSnapshot.self, from: Data(#"{"rows":[],"attention":true,"updatedAt":1788030000}"#.utf8))
  #expect(legacy.display == .used)
  #expect(legacy.attention)
  #expect(legacy.updatedAt == fixedNow)
}
