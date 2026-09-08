import Foundation
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@Test(arguments: [("first", 3.0), ("second", 7.0)])
func accountSwitchRestoresSeparateAnalytics(account: String, expected: Double) async throws {
  let history = try UsageHistoryStore(url: nil)
  for (identity, value) in [("first", 3.0), ("second", 7.0)] {
    try await history.record(
      ProviderAnalytics(
        provider: .codex,
        points: [AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .credits, series: identity, value: value)],
        fetchedAt: fixedNow, accountFingerprint: identity))
  }
  try await history.record(
    ProviderAnalytics(provider: .codex, points: [], fetchedAt: fixedNow, accountFingerprint: account))
  #expect(
    try await history.analytics(provider: .codex, from: DayStamp.string(fixedNow), to: DayStamp.string(fixedNow)).map(
      \.value) == [expected])
}

@Test(arguments: [true, false])
func projectExportAppliesPrivacyToFullAndSelectedHistory(full: Bool) async throws {
  let history = try UsageHistoryStore(url: nil)
  let project = "/private/client/repository"
  try await history.record(
    ProviderAnalytics(
      provider: .claude,
      points: [
        AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .projectCost, series: project, value: 3)
      ], fetchedAt: fixedNow))
  let url = temporaryDirectory().appendingPathComponent("history.csv")
  if full {
    try await history.exportCSV(to: url, hidePersonalInformation: true)
  } else {
    try await history.exportCSV(
      to: url, metric: .analytics(.projectCost), from: fixedNow, to: fixedNow, hidePersonalInformation: true)
  }
  let exported = try String(contentsOf: url, encoding: .utf8)
  #expect(exported.contains(ProjectIdentity.anonymous(project)) && !exported.contains(project))
}

@Test @MainActor func disclosureChangesNeverCloseOtherGroups() {
  let state = DisclosureState()
  state.setExpanded(true, for: "one")
  state.setExpanded(true, for: "two")
  state.setExpanded(false, for: "one")
  #expect(state.expanded == ["two"])
}

@Test(arguments: [true, false]) @MainActor
func disclosureHeadingTogglesOnlyItsOwnGroup(initiallyExpanded: Bool) {
  let state = DisclosureState()
  state.setExpanded(true, for: "other")
  state.setExpanded(initiallyExpanded, for: "details")
  state.toggleAction(for: "details")()
  #expect(state.expanded == (initiallyExpanded ? ["other"] : ["details", "other"]))
}

@Test func projectLabelsDisambiguateMatchingBasenames() {
  #expect(
    ProjectIdentity.labels(["/a/repo", "/b/repo", "/a/other"], private: false) == [
      "/a/repo": "a/repo", "/b/repo": "b/repo", "/a/other": "other",
    ])
}

@Test func privateProjectLabelsHideEveryDirectoryComponent() {
  let projects = ["/private/client/repo", "/private/other/repo"]
  #expect(
    ProjectIdentity.labels(projects, private: true)
      == Dictionary(uniqueKeysWithValues: projects.map { ($0, ProjectIdentity.anonymous($0)) }))
}

@Test func projectLabelsRetainDistinctRootsAndLongSharedSuffixes() {
  let identities = ["/a/one/repo", "/b/one/repo", "/repo", "repo", "/"]
  let labels = ProjectIdentity.labels(identities, private: false)
  #expect(Set(labels.values).count == identities.count)
  #expect(labels["/a/one/repo"] == "a/one/repo")
  #expect(labels["/repo"] == "/repo")
}

@Test @MainActor func hiddenHistoryRevisionsKeepTheLastRenderUntilReactivation() async throws {
  let history = try UsageHistoryStore(url: nil)
  let presenter = HistoryPresenter(
    history: history, settings: Settings(defaults: testDefaults()), clock: testClock,
    initialMetric: .analytics(.turns))
  presenter.ensureLoaded()
  await presenter.waitForLoad()
  presenter.setActive(false)
  try await history.record(
    ProviderAnalytics(
      provider: .codex,
      points: [
        AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .turns, series: "model", value: 5)
      ], fetchedAt: fixedNow))
  presenter.reload()
  presenter.reload()
  await presenter.waitForLoad()
  #expect(presenter.state.data?.isEmpty == true)
  presenter.setActive(true)
  await presenter.waitForLoad()
  #expect(presenter.state.data?.series.flatMap(\.points).map(\.value) == [5])
}
