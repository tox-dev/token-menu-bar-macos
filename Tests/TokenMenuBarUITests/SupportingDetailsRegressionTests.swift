import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@testable import TokenMenuBarUI

@Test(arguments: ["startup", "support", "display", "collection", "storage"]) @MainActor
func settingsDisclosuresMountAndReleaseTheirSecondaryControls(group: String) async throws {
  let environment = try makeEnvironment()
  environment.launchAtLoginStatus = .enabled
  let hosting = host(
    SettingsTab(environment: environment, mountsIncrementally: false).transaction { $0.disablesAnimations = true },
    width: 880, height: 3000)
  await mainActorTurn()
  hosting.layoutSubtreeIfNeeded()
  let collapsed = hosting.fittingSize.height
  environment.disclosures.setExpanded(true, for: "settings.\(group)")
  await mainActorTurn()
  hosting.layoutSubtreeIfNeeded()
  #expect(hosting.fittingSize.height > collapsed + 10)
  environment.disclosures.setExpanded(false, for: "settings.\(group)")
  await waitUntil {
    hosting.layoutSubtreeIfNeeded()
    return abs(hosting.fittingSize.height - collapsed) < 1
  }
  #expect(abs(hosting.fittingSize.height - collapsed) < 1)
}

@Test @MainActor func collapsedSupportingDetailsDoNotConstructTheirContent() async {
  let state = DisclosureState()
  var builds = 0
  func content() -> Text {
    builds += 1
    return Text("Synthetic supporting detail")
  }
  let hosting = host(SupportingDetails("Details", id: "lazy", state: state, content: content), width: 880, height: 400)
  #expect(builds == 0)
  state.setExpanded(true, for: "lazy")
  await mainActorTurn()
  hosting.layoutSubtreeIfNeeded()
  #expect(builds > 0)
}

@Test @MainActor func historyStackingSettingSurvivesRenderingAdditiveSeries() async throws {
  let environment = try makeEnvironment()
  try await environment.history.record(
    ProviderAnalytics(
      provider: .codex,
      points: ["first", "second"].map {
        AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .modelCredits, series: $0, value: 3)
      }, fetchedAt: fixedNow))
  environment.settings.lastTab = .history
  environment.state.popoverVisible = true
  environment.historyPresenter.setMetric(.analytics(.modelCredits))
  environment.historyPresenter.ensureLoaded()
  await environment.historyPresenter.waitForLoad()
  #expect(environment.historyPresenter.canStack)
  let tab = HistoryTab(environment: environment)
  environment.disclosures.setExpanded(true, for: "history.data")
  tab.stackedBinding.wrappedValue = true
  let hosting = host(tab, width: 880, height: 900)
  #expect(hosting.fittingSize.height > 500)
  #expect(environment.settings.historyStacked)
}

@Test @MainActor func disclosureBindingChangesOnlyItsOwnExpansionState() throws {
  let state = DisclosureState()
  state.setExpanded(true, for: "other")
  let view = SupportingDetails("Details", id: "details", state: state) { Text("Details") }
  let binding: Binding<Bool> = try #require(boundValue(in: view.body))
  binding.wrappedValue = true
  #expect(binding.wrappedValue && state.expanded == ["details", "other"])
  binding.wrappedValue = false
  #expect(!binding.wrappedValue && state.expanded == ["other"])
}

private func boundValue<Value>(in value: Any, depth: Int = 0) -> Binding<Value>? {
  if let binding = value as? Binding<Value> { return binding }
  guard depth < 48 else { return nil }
  return Mirror(reflecting: value).children.lazy.compactMap { boundValue(in: $0.value, depth: depth + 1) }.first
}

@Test(arguments: [true, false]) @MainActor
func demoToggleRequestsTheSelectedDataMode(enabled: Bool) throws {
  let environment = try makeEnvironment()
  environment.isDemo = !enabled
  var requested: Bool?
  environment.actions.setDemoMode = { requested = $0 }
  let binding = SettingsTab(environment: environment).demoModeBinding
  #expect(binding.wrappedValue == !enabled)
  binding.wrappedValue = enabled
  #expect(requested == enabled)
}

@Test @MainActor func historyDataDetailsExpandBeforeTheInitialQueryCompletes() throws {
  let environment = try makeEnvironment(populate: false)
  let collapsed = host(HistoryTab(environment: environment), width: 880, height: 900).fittingSize.height
  environment.disclosures.setExpanded(true, for: "history.data")
  let hosting = host(HistoryTab(environment: environment), width: 880, height: 900)
  #expect(environment.historyPresenter.state.data == nil && hosting.fittingSize.height > collapsed + 10)
}

@Test @MainActor func historyPrivacyChangesRedrawMountedProjectLabels() async throws {
  let environment = try makeEnvironment()
  let project = "/fixture/client/repository"
  try await environment.history.record(
    ProviderAnalytics(
      provider: .claude,
      points: [AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .projectCost, series: project, value: 3)],
      fetchedAt: fixedNow))
  environment.settings.lastTab = .history
  environment.state.popoverVisible = true
  environment.historyPresenter.setMetric(.analytics(.projectCost))
  environment.historyPresenter.ensureLoaded()
  await environment.historyPresenter.waitForLoad()
  let hosting = host(HistoryTab(environment: environment), width: 880, height: 900)
  await mainActorTurn()
  #expect(environment.historyPresenter.state.data?.series.map(\.label) == ["repository"])
  environment.settings.hidePersonalInformation = true
  await waitUntil {
    hosting.layoutSubtreeIfNeeded()
    return environment.historyPresenter.state.data?.series.first?.label == ProjectIdentity.anonymous(project)
  }
  #expect(environment.historyPresenter.state.data?.series.map(\.label) == [ProjectIdentity.anonymous(project)])
}

@Test @MainActor func settingsConnectionDetailsRetainGrantedResourceAccess() async throws {
  let environment = try makeEnvironment()
  environment.isSandboxed = true
  environment.state.applySetupStates([
    .codex: ProviderSetupState(
      enabled: true, credential: .valid(source: ProviderID.codex.credentialSource("codex.file"), expiresAt: nil),
      resources: [ResourceAccessState(resource: ProviderID.codex.sandboxResources[0], health: .granted)])
  ])
  environment.disclosures.setExpanded(true, for: "connection.codex")
  environment.credentialDescriptions[.codex] = "/fixture/codex/auth.json"
  let hosting = host(SettingsTab(environment: environment, mountsIncrementally: false), width: 880, height: 3000)
  #expect(hosting.fittingSize.height > 500)
  #expect(environment.state.state(for: .codex).resourceAccess.first?.health == .granted)
}

@Test @MainActor func usageDisplaysCostHistoryReadFailures() async throws {
  let environment = try makeEnvironment()
  try await environment.history.breakDatabase()
  await environment.spendSummary.load(
    history: environment.history, providers: [.claude], now: fixedNow, timeZone: .current)
  let hosting = host(UsageTab(environment: environment), width: 880, height: 2000)
  #expect(hosting.fittingSize.height > 100)
  #expect(environment.spendSummary.error == "Cost history could not be loaded.")
}

@Test(arguments: ["account", "resets", "provider", "credit", "creditEstimates", "local"]) @MainActor
func providerDisclosuresMountTheirSupportingContent(group: String) async throws {
  let environment = try makeEnvironment(populate: false)
  let detail = ProviderDetail(
    id: "origin", title: "Allowance origin", value: "Organization", explanation: "Reported by the provider")
  let snapshot = ProviderSnapshot(
    provider: .codex, identity: ProviderIdentity(planName: "Pro", email: "fixture@example.com"),
    windows: sampleSnapshot(.codex).windows,
    credits: CreditBalance(balance: 0, approxLocalMessages: 0...0),
    spend: SpendControl(enabled: false, balance: Money(amountMinor: 0, currency: "USD")),
    resetCredits: ResetCredits(available: 0, applicable: 0, details: [detail]),
    localUsage: sampleSnapshot(.codex).localUsage, fetchedAt: fixedNow, details: [detail])
  let card = try #require(
    UsagePresenter.cards(
      state: [.codex: ProviderState(snapshot: snapshot, availability: .current)], enabled: [.codex], samples: [:],
      now: fixedNow
    ).first)
  let hosting = host(
    ProviderCardView(card: card, environment: environment, onRefreshProvider: { _ in })
      .transaction { $0.disablesAnimations = true }, width: 880, height: 2000)
  await mainActorTurn()
  hosting.layoutSubtreeIfNeeded()
  let collapsed = hosting.fittingSize.height
  environment.disclosures.setExpanded(true, for: "usage.codex.\(group)")
  await mainActorTurn()
  hosting.layoutSubtreeIfNeeded()
  #expect(hosting.fittingSize.height > collapsed + 10)
  environment.disclosures.setExpanded(false, for: "usage.codex.\(group)")
  await waitUntil {
    hosting.layoutSubtreeIfNeeded()
    return abs(hosting.fittingSize.height - collapsed) < 1
  }
  #expect(abs(hosting.fittingSize.height - collapsed) < 1)
}

@Test @MainActor func expandedLogReceivesNewEntriesWithoutRemounting() async throws {
  let environment = try makeEnvironment(populate: false)
  environment.disclosures.setExpanded(true, for: "settings.log")
  let hosting = host(LogSection(environment: environment), width: 880, height: 300)
  await mainActorTurn()
  environment.log.log("Disclosure subscription fixture")
  await waitUntil { accessibleText(hosting).contains("Disclosure subscription fixture") }
  #expect(accessibleText(hosting).contains("Disclosure subscription fixture"))
}

@Test(arguments: [false, true]) @MainActor
func statusPreviewNamesBothItsModelListAndIcon(showsIcon: Bool) {
  let model = showsIcon ? StatusItemModel.empty : statusModel()
  let hosting = host(StatusPreview(model: model, highlightedKey: .constant(nil), select: { _ in }))

  #expect(accessibleText(hosting).contains("Menu bar preview"))
}

@MainActor
private func accessibleText(_ value: Any, depth: Int = 0) -> String {
  guard depth < 30 else { return "" }
  if let view = value as? NSView {
    return
      ([view.accessibilityLabel() ?? "", String(describing: view.accessibilityValue() ?? "")]
      + (view.accessibilityChildren() ?? []).map { accessibleText($0, depth: depth + 1) }
      + view.subviews.map { accessibleText($0, depth: depth + 1) }).joined(separator: "\n")
  }
  guard let element = value as? any NSAccessibilityProtocol else { return "" }
  return
    ([element.accessibilityLabel() ?? "", String(describing: element.accessibilityValue() ?? "")]
    + (element.accessibilityChildren() ?? []).map { accessibleText($0, depth: depth + 1) }).joined(separator: "\n")
}
