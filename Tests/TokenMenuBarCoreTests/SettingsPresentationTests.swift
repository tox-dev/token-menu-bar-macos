import Foundation
import Testing
import TokenMenuBarCore

private let presentationNow = Date(timeIntervalSince1970: 1_788_030_000)

private func presentationSnapshot(_ provider: ProviderID, windows: [QuotaWindow]) -> ProviderSnapshot {
  ProviderSnapshot(provider: provider, windows: windows, fetchedAt: presentationNow)
}

private func presentationWindow(_ id: String, percent: Double, group: WindowGroup = .other) -> QuotaWindow {
  QuotaWindow(id: id, label: Format.humanize(id), group: group, usedPercent: percent, resetsAt: nil)
}

@Test func settingsSectionTitlesAreStable() {
  #expect(
    SettingsSection.allCases.map(\.title) == ["About", "Menu bar", "Providers", "Data", "Notifications", "Log"])
}

@Test func providerGroupReportsNoneSomeAndAllSelection() {
  #expect(SettingsProviderGroup(provider: .codex, rows: [], selectedCount: 0, totalCount: 2).selection == .none)
  #expect(SettingsProviderGroup(provider: .codex, rows: [], selectedCount: 1, totalCount: 2).selection == .some)
  #expect(SettingsProviderGroup(provider: .codex, rows: [], selectedCount: 2, totalCount: 2).selection == .all)
}

@Test func shortLabelPolicyCapsGraphemesAndRemovesDefaults() {
  #expect(ShortLabelPolicy.draft("A👨‍👩‍👧‍👦BCDEF") == "A👨‍👩‍👧‍👦BCDE")
  #expect(ShortLabelPolicy.override("  ", default: "CX") == nil)
  #expect(ShortLabelPolicy.override("CX", default: "CX") == nil)
  #expect(ShortLabelPolicy.override("SPARKLES", default: "CX") == "SPARKL")
}

@Test func shortLabelPolicyDerivesUniqueLabelsForSamePrefixModels() {
  let alpha = QuotaWindow(
    id: "additional:spark-alpha", label: "Spark Alpha", group: .other, usedPercent: 20, resetsAt: nil)
  let beta = QuotaWindow(
    id: "additional:spark-beta", label: "Spark Beta", group: .other, usedPercent: 30, resetsAt: nil)
  let alphaKey = WindowKey(.codex, alpha)
  let betaKey = WindowKey(.codex, beta)
  let labels = ShortLabelPolicy.derivedLabels(windows: [betaKey: beta, alphaKey: alpha])
  #expect(labels[alphaKey] == "SPK")
  #expect(labels[betaKey] == "SPK2")
  #expect(labels.values.allSatisfy { $0.count <= ShortLabelPolicy.limit })
  #expect(Set(labels.values).count == 2)
  #expect(labels == ShortLabelPolicy.derivedLabels(windows: [alphaKey: alpha, betaKey: beta]))
}

@Test func shortLabelPolicyRejectsUnicodeCaseAndWhitespaceEquivalentOverrides() {
  let claude = presentationWindow("session", percent: 20)
  let codex = presentationWindow("weekly", percent: 30)
  let claudeKey = WindowKey(.claude, claude)
  let codexKey = WindowKey(.codex, codex)
  let windows = [claudeKey: claude, codexKey: codex]
  let overrides = [claudeKey: "É X"]
  #expect(
    ShortLabelPolicy.conflictingKey(
      "\u{00A0}e\u{301}\tX ", for: codexKey, windows: windows, overrides: overrides) == claudeKey)
}

@Test func shortLabelPolicyKeepsPersistedLabelWhenDraftConflicts() {
  let claude = presentationWindow("session", percent: 20)
  let codex = presentationWindow("weekly", percent: 30)
  let claudeKey = WindowKey(.claude, claude)
  let codexKey = WindowKey(.codex, codex)
  let labels = ShortLabelPolicy.validOverrides(
    windows: [claudeKey: claude, codexKey: codex], persisted: [codexKey: "PAIR"], drafts: [claudeKey: " pair "])
  #expect(labels[claudeKey] == nil)
  #expect(labels[codexKey] == "PAIR")
}

@Test func settingsPresentationRejectsLegacyDuplicateShortLabelOverrides() {
  let claude = presentationWindow("session", percent: 20)
  let codex = presentationWindow("weekly", percent: 30)
  let claudeKey = WindowKey(.claude, claude)
  let codexKey = WindowKey(.codex, codex)
  let groups = SettingsModelPresentation.groups(
    snapshots: [
      .claude: presentationSnapshot(.claude, windows: [claude]),
      .codex: presentationSnapshot(.codex, windows: [codex]),
    ],
    selected: [claudeKey, codexKey], labels: [claudeKey: "SAME", codexKey: " same "],
    providerOrder: [.claude, .codex], modelOrder: [claudeKey, codexKey], query: "", hideUnused: false,
    now: presentationNow)
  let rows = groups.flatMap(\.rows)
  #expect(Set(rows.map { $0.label.lowercased() }).count == 2)
  #expect(rows.count(where: \.isLabelOverridden) == 1)
}

@Test func settingsPresentationGroupsFiltersAndKeepsDerivedLabels() throws {
  let opus = presentationWindow("opus-5", percent: 30)
  let weekly = presentationWindow("weekly", percent: 0, group: .weekly)
  let codex = presentationWindow("gpt-5.5", percent: 80)
  let opusKey = WindowKey(.claude, opus)
  let codexKey = WindowKey(.codex, codex)
  let groups = SettingsModelPresentation.groups(
    snapshots: [
      .claude: presentationSnapshot(.claude, windows: [opus, weekly]),
      .codex: presentationSnapshot(.codex, windows: [codex]),
    ],
    selected: [codexKey, opusKey], labels: [codexKey: "GPT"], providerOrder: [.codex, .claude],
    modelOrder: [codexKey, opusKey, WindowKey(.claude, weekly)], query: "gpt", hideUnused: true,
    now: presentationNow)
  let group = try #require(groups.first)
  let row = try #require(group.rows.first)
  #expect(groups.map(\.provider) == [.codex])
  #expect(row.key == codexKey)
  #expect(row.label == "GPT")
  #expect(row.isLabelOverridden)
  #expect(row.recency == "today")
  #expect(row.detail == "gpt-5.5")
}

@Test func settingsPresentationDerivesLastUseFromIncreasesAndResets() {
  let key = WindowKey(provider: .codex, windowID: "weekly")
  let reset = presentationNow.addingTimeInterval(3600)
  let samples = [
    UsageSample(timestamp: presentationNow.addingTimeInterval(-400), key: key, usedPercent: 0, resetsAt: nil),
    UsageSample(timestamp: presentationNow.addingTimeInterval(-300), key: key, usedPercent: 10, resetsAt: nil),
    UsageSample(timestamp: presentationNow.addingTimeInterval(-200), key: key, usedPercent: 10, resetsAt: nil),
    UsageSample(timestamp: presentationNow.addingTimeInterval(-100), key: key, usedPercent: 1, resetsAt: reset),
  ]
  #expect(SettingsModelPresentation.lastUsageDates(samples)[key] == presentationNow.addingTimeInterval(-100))
}

@Test func settingsPresentationDoesNotTreatAnUnchangedPollAsUse() {
  let key = WindowKey(provider: .claude, windowID: "weekly")
  let firstUse = presentationNow.addingTimeInterval(-300)
  let samples = [
    UsageSample(timestamp: firstUse, key: key, usedPercent: 10, resetsAt: nil),
    UsageSample(timestamp: presentationNow, key: key, usedPercent: 10, resetsAt: nil),
  ]
  #expect(SettingsModelPresentation.lastUsageDates(samples)[key] == firstUse)
}

@Test func settingsPresentationRevealsAFilteredUnusedModel() throws {
  let window = presentationWindow("gpt-5.5", percent: 0)
  let key = WindowKey(.codex, window)
  let groups = SettingsModelPresentation.groups(
    snapshots: [.codex: presentationSnapshot(.codex, windows: [window])], selected: [key], labels: [:],
    providerOrder: [], modelOrder: [], query: "no match", hideUnused: true, revealedKey: key,
    now: presentationNow)
  #expect(try #require(groups.first?.rows.first).key == key)
}

@Test func settingsPresentationKeepsModelsUsedEarlierInTheRange() throws {
  let window = presentationWindow("gpt-5.5", percent: 0)
  let key = WindowKey(.codex, window)
  let groups = SettingsModelPresentation.groups(
    snapshots: [.codex: presentationSnapshot(.codex, windows: [window])], selected: [key], labels: [:],
    providerOrder: [], modelOrder: [], query: "", hideUnused: true,
    lastUsedAt: [key: presentationNow.addingTimeInterval(-86400)], now: presentationNow)
  #expect(try #require(groups.first?.rows.first).key == key)
}

@Test func settingsPresentationHidesModelsUnusedThroughoutTheRange() {
  let window = presentationWindow("gpt-5.5", percent: 0)
  let key = WindowKey(.codex, window)
  let groups = SettingsModelPresentation.groups(
    snapshots: [.codex: presentationSnapshot(.codex, windows: [window])], selected: [key], labels: [:],
    providerOrder: [], modelOrder: [], query: "", hideUnused: true, now: presentationNow)
  #expect(groups.isEmpty)
}

@Test func settingsPresentationNamesRateLimitWindows() throws {
  let weekly = presentationWindow("weekly", percent: 40, group: .weekly)
  let key = WindowKey(.claude, weekly)
  let groups = SettingsModelPresentation.groups(
    snapshots: [.claude: presentationSnapshot(.claude, windows: [weekly])], selected: [key], labels: [:],
    providerOrder: [], modelOrder: [], query: "", hideUnused: false, now: presentationNow)
  let row = try #require(groups.first?.rows.first)
  #expect(row.detail == "window · 7d")
  #expect(row.label == row.defaultLabel)
  #expect(!row.isLabelOverridden)
}

@Test func settingsPresentationReplacesEmptyStoredLabelsWithDerivedLabels() throws {
  let window = presentationWindow("gpt-5.5", percent: 40)
  let key = WindowKey(.codex, window)
  let groups = SettingsModelPresentation.groups(
    snapshots: [.codex: presentationSnapshot(.codex, windows: [window])], selected: [key], labels: [key: ""],
    providerOrder: [], modelOrder: [], query: "", hideUnused: false, now: presentationNow)
  let row = try #require(groups.first?.rows.first)
  #expect(row.label == row.defaultLabel)
  #expect(!row.isLabelOverridden)
}

@Test func settingsPresentationNamesOldAndBuiltInWindows() throws {
  let old = presentationNow.addingTimeInterval(-86400)
  let windows = [
    presentationWindow("session", percent: 10, group: .session),
    presentationWindow("monthly", percent: 20, group: .monthly),
  ]
  let keys = windows.map { WindowKey(.claude, $0) }
  let groups = SettingsModelPresentation.groups(
    snapshots: [.claude: ProviderSnapshot(provider: .claude, windows: windows, fetchedAt: old)],
    selected: keys, labels: [:], providerOrder: [], modelOrder: [], query: "",
    hideUnused: false, lastUsedAt: Dictionary(uniqueKeysWithValues: keys.map { ($0, old) }), now: presentationNow)
  #expect(groups.first?.rows.map(\.detail) == ["window · 5h", "window · 1mo"])
  #expect(groups.first?.rows.allSatisfy { $0.recency.hasPrefix("last ") } == true)
}

@Test func settingsProviderPresentationIncludesIdentitySuccessAndRetry() {
  let retry = presentationNow.addingTimeInterval(600)
  let snapshot = ProviderSnapshot(
    provider: .codex,
    identity: ProviderIdentity(planName: "Team", email: "dev@example.com", organization: "Acme"),
    windows: [], fetchedAt: presentationNow)
  let presentation = SettingsProviderPresentation(
    state: ProviderState(
      snapshot: snapshot, availability: .rateLimited, lastSuccess: presentationNow.addingTimeInterval(-120),
      serviceHealth: .rateLimited(retryAt: retry, detail: "Slow down")),
    now: presentationNow)
  #expect(presentation.identity == "dev@example.com · Acme · Team")
  #expect(presentation.lastSuccess == "Last success 2 min ago")
  #expect(presentation.service.contains("Slow down"))
  #expect(presentation.service.contains(retry.formatted(date: .abbreviated, time: .shortened)))
}

@Test func settingsOrderDraftUsesProviderMajorMoves() {
  let claudeA = WindowKey(provider: .claude, windowID: "a")
  let claudeB = WindowKey(provider: .claude, windowID: "b")
  let codexA = WindowKey(provider: .codex, windowID: "a")
  var draft = SettingsOrderDraft(
    providers: [.claude, .codex], models: [claudeA, claudeB, codexA],
    available: [claudeA, claudeB, codexA])
  draft.moveProvider(.codex, before: .claude)
  draft.moveModel(claudeB, by: -1)
  #expect(draft.providers == [.codex, .claude])
  #expect(draft.models == [claudeB, claudeA, codexA])
  #expect(draft.orderedSelection([claudeA, codexA, claudeB]) == [codexA, claudeB, claudeA])
  draft.moveModel(claudeA, before: codexA)
  #expect(draft.models == [claudeB, claudeA, codexA])
  draft.moveProvider(.codex, by: 1)
  #expect(draft.providers == [.claude, .codex])
  draft.moveModel(claudeA, by: 1)
  #expect(draft.models == [claudeB, claudeA, codexA])
}

@Test func settingsOrderDraftMovesAModelBeforeAnotherModelFromItsProvider() {
  let first = WindowKey(provider: .claude, windowID: "first")
  let second = WindowKey(provider: .claude, windowID: "second")
  var draft = SettingsOrderDraft(providers: [.claude], models: [first, second], available: [first, second])
  draft.moveModel(second, before: first)
  #expect(draft.models == [second, first])
}
