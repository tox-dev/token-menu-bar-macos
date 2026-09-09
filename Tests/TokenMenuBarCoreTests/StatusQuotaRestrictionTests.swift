import Foundation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@Test(arguments: [ProviderID.claude, .codex], [UsageDisplay.used, .remaining])
func hiddenWeeklyLimitOverridesAvailableSession(provider: ProviderID, display: UsageDisplay) {
  let model = StatusItemBuilder.build(restrictedInput(provider: provider, display: display))
  #expect(StatusTemplate.plainText(model.cells[0].lines).hasSuffix("\nLimit"))
  #expect(model.cells[0].percent == 100)
  #expect(model.cells[0].lines[1] == [StatusRun(text: "Limit", kind: .usage(100))])
  #expect(model.cells[0].tooltip.contains(display == .used ? "Current session: 36%" : "Current session: 64% left"))
  #expect(model.cells[0].tooltip.contains("Included quota limited by All models (100% used; resets 2d 0h)."))
}

@Test(arguments: [
  (StatusFormat.inline, "CC 5h:Limit"),
  (.percentCountdown, "CC 5h Limit · 2d0h"),
  (.countdownWhenExhausted, "CC 5h\n2d0h"),
  (.custom, "CC 5h Limit"),
])
func restrictedStatusFormatsUseTheBlockingQuota(format: StatusFormat, expected: String) {
  #expect(StatusTemplate.plainText(StatusItemBuilder.build(restrictedInput(format: format)).cells[0].lines) == expected)
}

@Test(arguments: ["{pct0}", "{pct1}", "{pct2}", "{remaining}", ""])
func customFormatsCannotHideAQuotaRestriction(template: String) {
  let model = StatusItemBuilder.build(restrictedInput(format: .custom, template: template))
  #expect(StatusTemplate.plainText(model.cells[0].lines).trimmingCharacters(in: .whitespaces) == "Limit")
}

@Test func restrictedMiniBarsPreserveTheRawReadingInAccessibilityText() {
  let cell = StatusItemBuilder.build(restrictedInput(format: .miniBars)).cells[0]
  #expect(cell.bars == [StatusBar(label: "CC 5h", percent: 100)])
  #expect(cell.tooltip == "Current session: 36%\nIncluded quota limited by All models (100% used; resets 2d 0h).")
}

@Test func anUnusedSessionIsStillVisibleWhenWeeklyQuotaIsExhausted() {
  let model = StatusItemBuilder.build(restrictedInput(sessionPercent: 0))
  #expect(model.cells.count == 1)
  #expect(model.cells[0].percent == 100)
}

@Test(arguments: [StatusTier.configured, .stacked, .worstPerProvider, .miniBars, .iconOnly])
func quotaRestrictionSurvivesWidthAdaptation(tier: StatusTier) {
  #expect(StatusItemBuilder.build(restrictedInput().with(tier: tier)).iconTone == .attention)
}

@Test func iconOnlyStatusNamesTheBlockingQuota() {
  let model = StatusItemBuilder.build(restrictedInput().with(tier: .iconOnly))
  #expect(model.accessibilitySummary == "Claude: Included quota limited by All models (100% used; resets 2d 0h).")
}

@Test(arguments: [StatusTier.configured, .miniBars, .iconOnly])
func quotaRestrictionRemainsInTheTooltip(tier: StatusTier) {
  #expect(
    StatusItemBuilder.build(restrictedInput().with(tier: tier)).tooltip
      .contains("Included quota limited by All models (100% used; resets 2d 0h)."))
}

@Test func iconOnlyStatusWarnsWhenTheSelectedQuotaItselfIsExhausted() {
  let model = StatusItemBuilder.build(restrictedInput(sessionPercent: 100, weeklyPercent: 40).with(tier: .iconOnly))
  #expect(model.iconTone == .attention)
  #expect(model.accessibilitySummary == "Claude: Current session limit reached; resets 2 hr 0 min.")
}

@Test func inactiveSelectedQuotaDoesNotInheritARestriction() {
  let model = StatusItemBuilder.build(restrictedInput(sessionActive: false))
  #expect(model.cells[0].percent == 36)
}

@Test func unknownCodexQuotaDoesNotInheritTheAccountWeeklyLimit() {
  let model = StatusItemBuilder.build(restrictedInput(provider: .codex, sessionGroup: .other))
  #expect(model.cells[0].percent == 36)
}

@Test(arguments: [
  ("not exhausted", 99.0, 172_800.0, true),
  ("already reset", 100.0, -1.0, true),
  ("reset now", 100.0, 0.0, true),
  ("inactive", 100.0, 172_800.0, false),
])
func nonbindingWeeklyQuotaDoesNotBlockTheSession(
  reason: String, percent: Double, resetOffset: Double, active: Bool
) {
  let model = StatusItemBuilder.build(
    restrictedInput(weeklyPercent: percent, weeklyReset: fixedNow.addingTimeInterval(resetOffset), weeklyActive: active)
  )
  #expect(StatusTemplate.plainText(model.cells[0].lines) == "CC 5h\n36%", Comment(rawValue: reason))
}

@Test func scopedClaudeQuotaDoesNotBlockOtherModels() {
  let model = StatusItemBuilder.build(restrictedInput(weeklyID: "weekly:fable", weeklyScope: "Fable"))
  #expect(StatusTemplate.plainText(model.cells[0].lines) == "CC 5h\n36%")
}

@Test func accountWeeklyQuotaBlocksASelectedClaudeModel() {
  let model = StatusItemBuilder.build(
    restrictedInput(sessionID: "weekly:fable", sessionScope: "Fable", sessionGroup: .weekly))
  #expect(StatusTemplate.plainText(model.cells[0].lines) == "FAB\nLimit")
}

@Test(arguments: ["code_review:", "additional:spark:"])
func codexQuotaRestrictionsStayInsideTheirFamily(prefix: String) {
  let model = StatusItemBuilder.build(restrictedInput(provider: .codex, weeklyID: prefix + "weekly"))
  #expect(StatusTemplate.plainText(model.cells[0].lines) == "CX 5h\n36%")
}

@Test(arguments: ["code_review:", "additional:spark:"])
func codexScopedWeeklyQuotaBlocksItsMatchingSession(prefix: String) {
  let model = StatusItemBuilder.build(
    restrictedInput(provider: .codex, sessionID: prefix + "session", weeklyID: prefix + "weekly"))
  #expect(StatusTemplate.plainText(model.cells[0].lines).hasSuffix("\nLimit"))
}

@Test(arguments: [ProviderID.gemini, .antigravity, .cursor, .copilot])
func unrelatedProvidersDoNotInheritClaudeQuotaRules(provider: ProviderID) {
  #expect(StatusItemBuilder.build(restrictedInput(provider: provider)).cells[0].percent == 36)
}

@Test func unknownBlockingResetDoesNotPromiseTheSessionReset() {
  let model = StatusItemBuilder.build(restrictedInput(format: .percentCountdown, weeklyReset: nil))
  #expect(StatusTemplate.plainText(model.cells[0].lines) == "CC 5h Limit · --")
}

@Test func restrictedCountdownWithUnknownResetShowsLimit() {
  let model = StatusItemBuilder.build(restrictedInput(format: .countdownWhenExhausted, weeklyReset: nil))
  #expect(StatusTemplate.plainText(model.cells[0].lines) == "CC 5h\nLimit")
}

@Test(arguments: [StatusFormat.percentCountdown, .countdownWhenExhausted])
func restrictedUnknownResetDoesNotStartAnIdleTicker(format: StatusFormat) {
  #expect(!StatusItemBuilder.build(restrictedInput(format: format, weeklyReset: nil)).countdownActive)
}

@Test func restrictedKnownResetStartsTheCountdownTicker() {
  #expect(StatusItemBuilder.build(restrictedInput(format: .countdownWhenExhausted)).countdownActive)
}

@Test func multipleExhaustedQuotasUseTheLastReset() {
  let model = StatusItemBuilder.build(
    restrictedInput(format: .countdownWhenExhausted, sessionPercent: 100, weeklyReset: fixedNow.addingTimeInterval(60)))
  #expect(StatusTemplate.plainText(model.cells[0].lines) == "CC 5h\n2h00m")
}

@Test func statusRestrictionDoesNotAlterStoredUsage() {
  let input = restrictedInput()
  let model = StatusItemBuilder.build(input)
  #expect([model.cells[0].percent, input.snapshots[.claude]!.window("session")!.usedPercent] == [100, 36])
}

private func restrictedInput(
  provider: ProviderID = .claude, display: UsageDisplay = .used, format: StatusFormat = .stacked,
  template: String = "{label}", sessionID: String = "session", sessionScope: String? = nil,
  sessionGroup: WindowGroup = .session, sessionActive: Bool = true,
  sessionPercent: Double = 36, weeklyID: String = "weekly", weeklyScope: String? = nil,
  weeklyPercent: Double = 100, weeklyReset: Date? = fixedNow.addingTimeInterval(172_800), weeklyActive: Bool = true
) -> StatusItemInput {
  StatusItemInput(
    snapshots: [
      provider: ProviderSnapshot(
        provider: provider,
        windows: [
          QuotaWindow(
            id: sessionID, label: "Current session", group: sessionGroup, usedPercent: sessionPercent,
            resetsAt: fixedNow.addingTimeInterval(7200), duration: 18000, isActive: sessionActive, scope: sessionScope),
          QuotaWindow(
            id: weeklyID, label: "All models", group: .weekly, usedPercent: weeklyPercent, resetsAt: weeklyReset,
            duration: 604_800, isActive: weeklyActive, scope: weeklyScope),
        ], fetchedAt: fixedNow)
    ], availability: [provider: .current], selectedKeys: [WindowKey(provider: provider, windowID: sessionID)],
    format: format, customTemplate: template, decimals: 0, hideZeroCells: true, order: .provider,
    labels: [:], now: fixedNow, display: display)
}
