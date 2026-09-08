import Foundation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@Test func countdownPresetsHaveTemplatesAndShortPickerLabels() {
  #expect(StatusFormat.percentCountdown.template == "{label} {pct} · {reset}")
  #expect(StatusFormat.countdownWhenExhausted.template == "{label}\n{pctOrReset}")
  #expect(StatusFormat.percentCountdown.pickerLabel == "Countdown")
  #expect(StatusFormat.countdownWhenExhausted.pickerLabel == "Countdown at 100%")
  #expect(StatusFormat.stacked.pickerLabel == "Stacked")
  #expect(StatusFormat.allCases.last == .custom)
  #expect(StatusTemplate.tokens.contains { $0.token == "{pctOrReset}" })
}

private func window(_ used: Double) -> QuotaWindow {
  QuotaWindow(
    id: "session", label: "Current session", group: .session, usedPercent: used,
    resetsAt: fixedNow.addingTimeInterval(4 * 3600 + 24 * 60), duration: 18000)
}

private func context(_ used: Double) -> StatusCellContext {
  StatusCellContext(
    provider: .claude, window: window(used), cellLabel: "CC", shortLabel: "CC 5h", decimals: 1, planName: nil,
    credits: nil, now: fixedNow)
}

@Test(arguments: [(36.4, "36.4%"), (100, "4h24m")])
func pctOrResetSwitchesToTheCountdownOnceExhausted(used: Double, text: String) {
  let lines = StatusTemplate.render("{pctOrReset}", context: context(used))
  #expect(StatusTemplate.plainText(lines) == text)
  #expect(lines[0][0].kind == .usage(used))
}

@Test func compiledTemplateTellsTheTwoCountdownTokensApart() {
  let conditional = StatusTemplate.compile("{pctOrReset}")
  #expect(conditional.referencesExhaustedCountdown)
  #expect(!conditional.referencesCountdown)
  let live = StatusTemplate.compile("{reset}")
  #expect(live.referencesCountdown)
  #expect(!live.referencesExhaustedCountdown)
}

private func input(format: StatusFormat, used: Double) -> StatusItemInput {
  StatusItemInput(
    snapshots: [.claude: ProviderSnapshot(provider: .claude, windows: [window(used)], fetchedAt: fixedNow)],
    availability: [.claude: .current], selectedKeys: [WindowKey(provider: .claude, windowID: "session")],
    format: format, customTemplate: "", decimals: 0, hideZeroCells: true, order: .provider, labels: [:],
    now: fixedNow)
}

@Test(arguments: [
  (StatusFormat.percentCountdown, 36.4, true, ["CC 5h 36% · 4h24m"]),
  (.percentCountdown, 100, true, ["CC 5h 100% · 4h24m"]),
  (.countdownWhenExhausted, 36.4, false, ["CC 5h", "36%"]),
  (.countdownWhenExhausted, 100, true, ["CC 5h", "4h24m"]),
])
func builderRunsTheCountdownOnlyWhenAPresetShowsOne(
  format: StatusFormat, used: Double, countdown: Bool, lines: [String]
) {
  let model = StatusItemBuilder.build(input(format: format, used: used))
  #expect(model.countdownActive == countdown)
  #expect(model.cells[0].lines.map { StatusTemplate.plainText([$0]) } == lines)
}
