import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func templateParserHandlesEscapesAndNewlines() {
  #expect(StatusTemplate.parse("a{{b}}c\\nd\ne") == [.text("a{b}c"), .newline, .text("d"), .newline, .text("e")])
  #expect(StatusTemplate.parse("{pct}") == [.placeholder("pct")])
  #expect(StatusTemplate.parse("{unclosed") == [.text("{unclosed")])
  #expect(StatusTemplate.parse("x{") == [.text("x{")])
  #expect(StatusTemplate.parse("}x") == [.text("}x")])
  #expect(StatusTemplate.parse("a}") == [.text("a}")])
  #expect(StatusTemplate.parse("\\t\\") == [.text("t")])
  #expect(StatusTemplate.parse("") == [])
}

@Test func templateRendersEveryToken() {
  let template =
    "{cell} {provider} {providerName} {window} {label}\n"
    + "{pct} {pct0} {pct1} {pct2} {remaining} {reset} {resetClock} {plan} {credits} {unknown}"
  let lines = StatusTemplate.render(template, context: context(decimals: 1))
  #expect(lines.count == 2)
  #expect(StatusTemplate.plainText([lines[0]]) == "CC·5h CC Claude 5h CC 5h")
  let second = StatusTemplate.plainText([lines[1]])
  #expect(second.hasPrefix("36.4% 36% 36.4% 36.40% 63.6% 4h24m "))
  #expect(second.hasSuffix(" Max 20x $5.00 "))
  #expect(lines[1][0].kind == .usage(36.4))
  #expect(lines[1].contains { $0.kind == .number })
  #expect(StatusTemplate.render("{plan}{credits}", context: context(plan: nil, credits: nil)).isEmpty)
  #expect(StatusTemplate.render("\n\n", context: context()).isEmpty)
}

private func context(
  _ window: QuotaWindow = session, decimals: Int = 0, plan: String? = "Max 20x", credits: String? = "$5.00"
) -> StatusCellContext {
  StatusCellContext(
    provider: .claude, window: window, cellLabel: "CC·5h", shortLabel: "CC 5h", decimals: decimals, planName: plan,
    credits: credits,
    now: fixedNow)
}

@Test func templateDetectsCountdownUsage() {
  #expect(StatusTemplate.referencesCountdown("{reset}"))
  #expect(!StatusTemplate.referencesCountdown("{resetClock}"))
  #expect(StatusFormat.stacked.template == "{label}\n{pct}")
  #expect(StatusFormat.inline.template == "{label}:{pct}")
  #expect(StatusFormat.custom.template == nil)
  #expect(StatusTemplate.tokens.count == 13)
}

@Test(
  arguments: [
    (session, "5h"),
    (QuotaWindow(id: "weekly", label: "Weekly", group: .weekly, usedPercent: 0, resetsAt: nil), "7d"),
    (QuotaWindow(id: "monthly", label: "Monthly", group: .monthly, usedPercent: 0, resetsAt: nil), "1mo"),
    (fable, "FAB"),
    (QuotaWindow(id: "code_review:weekly", label: "x", group: .weekly, usedPercent: 0, resetsAt: nil), "WEE"),
    (
      QuotaWindow(id: "tangelo", label: "x", group: .other, usedPercent: 0, resetsAt: nil, scope: "GPT-5.3 Spark"),
      "GPT"
    ),
  ])
func windowTagsAbbreviate(window: QuotaWindow, tag: String) {
  #expect(StatusTemplate.windowTag(window) == tag)
}

private let session = QuotaWindow(
  id: "session", label: "Current session", group: .session, usedPercent: 36.4,
  resetsAt: fixedNow.addingTimeInterval(4 * 3600 + 24 * 60), duration: 18000)
private let fable = QuotaWindow(
  id: "weekly:fable", label: "Fable", group: .weekly, usedPercent: 61, resetsAt: fixedNow.addingTimeInterval(3 * 86400),
  duration: 604_800, scope: "Fable")

@Test func defaultSelectionPrefersSessionAndWeeklyWindows() {
  let keys = StatusItemBuilder.defaultSelection(input().snapshots)
  #expect(keys.map(\.storageKey) == ["claude:session", "claude:weekly:fable", "codex:weekly"])
  let odd: [ProviderID: ProviderSnapshot] = [
    .codex: ProviderSnapshot(
      provider: .codex,
      windows: [
        QuotaWindow(id: "a", label: "A", group: .other, usedPercent: 1, resetsAt: nil),
        QuotaWindow(id: "b", label: "B", group: .other, usedPercent: 1, resetsAt: nil),
        QuotaWindow(id: "c", label: "C", group: .other, usedPercent: 1, resetsAt: nil),
      ], fetchedAt: fixedNow)
  ]
  #expect(StatusItemBuilder.defaultSelection(odd).map(\.windowID) == ["a", "b"])
}

private func input(
  format: StatusFormat = .stacked, selected: [WindowKey]? = nil, hideZero: Bool = true, order: WindowOrder = .provider,
  availability: [ProviderID: QuotaAvailability] = [.claude: .current, .codex: .current],
  labels: [WindowKey: String] = [:]
) -> StatusItemInput {
  let claude = ProviderSnapshot(
    provider: .claude, identity: ProviderIdentity(planName: "Max"), windows: [session, fable], fetchedAt: fixedNow)
  let codex = ProviderSnapshot(
    provider: .codex,
    windows: [
      QuotaWindow(id: "weekly", label: "Weekly", group: .weekly, usedPercent: 62, resetsAt: nil),
      QuotaWindow(
        id: "additional:spark:session", label: "Spark 5h", group: .session, usedPercent: 0, resetsAt: nil,
        scope: "Spark"),
    ],
    credits: CreditBalance(balance: 0),
    fetchedAt: fixedNow
  )
  let snapshots: [ProviderID: ProviderSnapshot] = [.claude: claude, .codex: codex]
  return StatusItemInput(
    snapshots: snapshots,
    availability: availability,
    selectedKeys: selected ?? StatusItemBuilder.defaultSelection(snapshots),
    format: format,
    customTemplate: "{label}={pct} {reset}",
    decimals: 0,
    hideZeroCells: hideZero,
    order: order,
    labels: labels,
    now: fixedNow
  )
}

@Test func builderRendersStackedCells() {
  let model = StatusItemBuilder.build(input())
  #expect(model.cells.map(\.id) == ["claude:session", "claude:weekly:fable", "codex:weekly"])
  #expect(model.cells[0].lines.map { StatusTemplate.plainText([$0]) } == ["CC 5h", "36%"])
  #expect(model.cells[1].lines.map { StatusTemplate.plainText([$0]) } == ["FAB", "61%"])
  #expect(model.cells[2].lines.map { StatusTemplate.plainText([$0]) } == ["CX 7d", "62%"])
  #expect(model.cells[0].tooltip == "Claude Current session: 36%, resets 4 hr 24 min")
  #expect(!model.cells[0].isMiniBar)
  #expect(model.iconTone == .normal)
  #expect(!model.showsIcon)
  #expect(!model.countdownActive)
}

@Test func builderHonoursHideZeroOrderAndCustomTemplate() {
  let all = input(
    format: .custom,
    selected: [
      WindowKey(provider: .codex, windowID: "additional:spark:session"),
      WindowKey(provider: .claude, windowID: "session"),
    ], hideZero: false, order: .percent, labels: [WindowKey(provider: .claude, windowID: "session"): "S"])
  let model = StatusItemBuilder.build(all)
  #expect(model.cells.map(\.id) == ["claude:session", "codex:additional:spark:session"])
  #expect(StatusTemplate.plainText(model.cells[0].lines) == "S=36% 4h24m")
  #expect(StatusTemplate.plainText(model.cells[1].lines) == "SPK=0% --")
  #expect(model.countdownActive)
  let hidden = StatusItemBuilder.build(
    input(format: .custom, selected: [WindowKey(provider: .codex, windowID: "additional:spark:session")]))
  #expect(hidden.cells.isEmpty)
  #expect(hidden.showsIcon)
  #expect(!hidden.countdownActive)
  #expect(StatusItemBuilder.build(input(selected: [WindowKey(provider: .claude, windowID: "nope")])).cells.isEmpty)
}

@Test func builderDerivesShortLabelsFromProviderAndWindow() {
  let window = QuotaWindow(
    id: "additional:spark:session", label: "Spark", group: .session, usedPercent: 0, resetsAt: nil)
  #expect(StatusItemBuilder.defaultShortLabel(provider: .codex, window: window) == "SPK")
  let generic = QuotaWindow(
    id: "additional:codex:model", label: "Codex Model", group: .other, usedPercent: 0, resetsAt: nil,
    scope: "Codex Model")
  #expect(StatusItemBuilder.defaultShortLabel(provider: .codex, window: generic) == "COD")
}

@Test func builderRejectsLegacyDuplicateShortLabels() {
  let claude = WindowKey(provider: .claude, windowID: "session")
  let codex = WindowKey(provider: .codex, windowID: "weekly")
  let model = StatusItemBuilder.build(
    input(
      format: .custom, selected: [codex, claude], hideZero: false,
      labels: [claude: "SAME", codex: " same "]))
  #expect(
    model.cells.map { StatusTemplate.plainText($0.lines).split(separator: "=").first.map(String.init) } == [
      "CX 7d", "SAME",
    ])
}

@Test func builderRendersMiniBarsPerProvider() {
  let model = StatusItemBuilder.build(input(format: .miniBars, order: .percent))
  #expect(model.cells.map(\.id) == ["codex", "claude"])
  #expect(model.cells[1].bars == [StatusBar(label: "FAB", percent: 61), StatusBar(label: "CC 5h", percent: 36.4)])
  #expect(model.cells[1].isMiniBar)
  #expect(model.cells[1].percent == 61)
  #expect(model.cells[0].tooltip == "Weekly: 62%")
  #expect(StatusItemBuilder.build(input(format: .miniBars)).cells.map(\.id) == ["claude", "codex"])
}

@Test func builderIconToneFollowsAvailability() {
  #expect(
    StatusItemBuilder.build(input(availability: [.claude: .authenticationRequired, .codex: .networkUnavailable]))
      .iconTone == .attention)
  let offline = StatusItemBuilder.build(input(availability: [.claude: .networkUnavailable]))
  #expect(offline.iconTone == .offline)
  #expect(!offline.showsIcon)
  #expect(StatusItemModel.empty.showsIcon)
  #expect(StatusItemBuilder.orderedProviders([]).isEmpty)
}
