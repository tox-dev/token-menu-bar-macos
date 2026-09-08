import AppKit
import Foundation
import SwiftUI
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore
@testable import TokenMenuBarUI

private let costAnalytics = ProviderAnalytics(
  provider: .claude,
  points: [AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .costUSD, series: "claude-opus-5", value: 3)],
  fetchedAt: fixedNow)

@Test @MainActor func spendTilesRenderTheThreeTotals() {
  let summary = SpendSummary(
    today: 4.5, yesterday: 2, lastWindow: 7,
    topModels: [SpendModelShare(provider: .claude, model: "claude-opus-5", cost: 7)], providers: [.claude])
  #expect(inkFraction(SpendSummaryTiles(summary: summary), width: 520, height: 80) > 0)
}

@Test @MainActor func usageTabLoadsSpendWhileVisibleAndFollowsHistoryChanges() async throws {
  let environment = try makeEnvironment()
  environment.settings.lastTab = .usage
  environment.state.popoverVisible = true
  let model = SpendSummaryModel()
  let hostingFixture = NativeHosting(UsageTab(environment: environment, spend: model))
  defer { hostingFixture.close() }
  let hosting = hostingFixture.view
  await waitUntil { model.summary != nil }
  #expect(model.summary == .empty)

  try await environment.history.record(costAnalytics)
  environment.state.markHistoryChanged()
  await waitUntil { model.summary?.hasData == true }
  #expect(model.summary?.today == 3)
  #expect(model.summary?.providers == [.claude])
  hosting.layoutSubtreeIfNeeded()
}

@Test @MainActor func usageTabLeavesSpendAloneWhileHidden() async throws {
  let environment = try makeEnvironment()
  environment.settings.lastTab = .history
  let model = SpendSummaryModel()
  let hostingFixture = NativeHosting(UsageTab(environment: environment, spend: model))
  defer { hostingFixture.close() }
  let hosting = hostingFixture.view
  for _ in 0..<5 { await mainActorTurn() }
  #expect(model.summary == nil)
  hosting.layoutSubtreeIfNeeded()
}

@Test @MainActor func spendModelReportsUnavailableWhenTheStoreFails() async throws {
  let history = try UsageHistoryStore(url: nil)
  try await history.breakDatabase()
  let model = SpendSummaryModel()
  await model.load(history: history, providers: [.claude], now: fixedNow, timeZone: .current)
  #expect(model.summary == nil)
  #expect(model.error != nil)
}

@Test func firstRunCardDescribesTheDetectedProviders() {
  #expect(FirstRunCard(detected: [.claude, .codex]).title == "Detected: Claude, Codex")
  #expect(FirstRunCard(detected: [.claude]).description == "Review the providers to choose what the menu bar shows.")
  #expect(FirstRunCard(detected: []).title == "No providers detected yet")
  #expect(FirstRunCard(detected: []).description.hasPrefix("Sign in to a supported CLI"))
}

@Test @MainActor func firstRunCardButtonsNavigateAndDismissForGood() throws {
  let defaults = testDefaults()
  let settings = TokenMenuBarCore.Settings(defaults: defaults)
  let environment = try makeEnvironment(settings: settings)
  let shown = ShownProviders()
  environment.actions = UIActions(showProviders: { shown.requests.append($0) })
  environment.firstRunCard = FirstRunCard(detected: [.claude])
  #expect(inkFraction(UsageTab(environment: environment)) > 0)
  let view = FirstRunCardView(environment: environment, card: FirstRunCard(detected: [.claude]))
  #expect(inkFraction(view, width: 520, height: 140) > 0)

  view.review()
  #expect(shown.requests == [nil])
  #expect(environment.firstRunCard != nil)

  view.dismiss()
  #expect(environment.firstRunCard == nil)
  #expect(settings.firstRunCardDismissed)
  #expect(TokenMenuBarCore.Settings(defaults: defaults).firstRunCardDismissed)
}

@MainActor
private final class ShownProviders {
  var requests: [ProviderID?] = []
}

private struct DetectedProvider: UsageProvider {
  let id: ProviderID
  let pollingPolicy = PollingPolicy(minimumInterval: 0, activeInterval: 0, defaultInterval: 0)

  var credentialDescription: String { "detected \(id.rawValue)" }

  func credentialState(now: Date) -> CredentialState { .valid(expiresAt: nil) }

  func credentialHealth(now: Date) async -> ProviderCredentialHealth {
    .valid(
      source: CredentialSource(id: "test-\(id.rawValue)", provider: id, title: "Test", detail: "test"), expiresAt: nil)
  }

  func fetch(now: Date, options: FetchOptions) async -> ProviderFetchResult {
    ProviderFetchResult(outcome: .success(sampleSnapshot(id)))
  }
}

@Test @MainActor func firstLaunchOpensTheUsageTabWithTheDetectedProviders() async throws {
  let clock = ManualClock()
  var (dependencies, _) = try makeDependencies(
    providers: [
      DetectedProvider(id: .claude),
      ScriptedProvider(id: .codex, result: ProviderFetchResult(outcome: .notAuthenticated("no token"))),
    ], clock: clock.clock)
  dependencies.openPopoverOnLaunch = false
  dependencies.settings.lastTab = .history
  let controller = AppController(dependencies: dependencies)
  controller.start()
  let anchor = detachedStatusWindow(holding: try #require(controller.statusItem?.item.button))
  controller.statusItem?.visibleItemFrame = { _ in anchor.frame }
  defer {
    controller.stop()
    anchor.close()
  }
  #expect(controller.popover?.isShown == false)

  await waitUntil { controller.environment.firstRunCard != nil }
  #expect(controller.environment.firstRunCard == FirstRunCard(detected: [.claude]))
  #expect(dependencies.settings.lastTab == .usage)
  #expect(dependencies.settings.lastLaunchedVersion == testAppInfo.version)
  #expect(dependencies.log.text.contains("first run: opening the usage tab"))
  await clock.advance(by: AppController.attachmentPollInterval) { controller.popover?.isShown == true }
  #expect(controller.popover?.isShown == true)
  #expect(clock.sleeps.contains(AppController.attachmentPollInterval))
}

@Test @MainActor func firstLaunchListsGeneratedProvidersAfterDiscovery() async throws {
  let (dependencies, _) = try makeDependencies(providers: ProviderID.allCases.map { DemoProvider(id: $0) })
  let controller = AppController(dependencies: dependencies)
  controller.start()
  defer { controller.stop() }

  await waitUntil { controller.environment.firstRunCard != nil }

  #expect(controller.environment.firstRunCard?.detected == ProviderID.allCases.sorted())
}

enum FirstRunSkip: CaseIterable {
  case launchedBefore
  case providerConfigured
  case dismissed

  @MainActor func apply(to settings: TokenMenuBarCore.Settings) {
    switch self {
    case .launchedBefore: settings.lastLaunchedVersion = "1.0.0"
    case .providerConfigured: settings.setProvider(.claude, enabled: true)
    case .dismissed: settings.firstRunCardDismissed = true
    }
  }
}

@Test(arguments: FirstRunSkip.allCases)
@MainActor func laterLaunchesKeepTheFirstRunCardHidden(skip: FirstRunSkip) async throws {
  let clock = ManualClock()
  let (dependencies, _) = try makeDependencies(providers: [DetectedProvider(id: .claude)], clock: clock.clock)
  skip.apply(to: dependencies.settings)
  let controller = AppController(dependencies: dependencies)
  controller.start()
  controller.statusItem?.visibleItemFrame = { _ in CGRect(x: 10, y: 10, width: 36, height: 24) }
  defer { controller.stop() }

  await waitUntil { dependencies.state.state(for: .claude).credentialHealth.isUsable }
  for _ in 0..<5 {
    clock.advance(by: AppController.attachmentPollInterval)
    await mainActorTurn()
  }
  #expect(controller.environment.firstRunCard == nil)
  #expect(controller.popover?.isShown == false)
  #expect(!dependencies.log.text.contains("first run"))
}

@Test @MainActor func appControllerWritesUsageJSONNextToTheSnapshotCache() async throws {
  let support = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-usage-\(UUID().uuidString)")
  let provider = ScriptedProvider(id: .claude, result: ProviderFetchResult(outcome: .success(sampleSnapshot(.claude))))
  let (dependencies, _) = try makeDependencies(
    providers: [provider], snapshotCache: SnapshotCache(url: support.appendingPathComponent("snapshots.json")))
  dependencies.settings.setProvider(.claude, enabled: true)
  dependencies.settings.writeUsageFile = true
  let controller = AppController(dependencies: dependencies)
  defer { controller.stop() }

  await controller.coordinator.refresh(RefreshRequest(reason: .userInitiated, usage: .force))
  await controller.flushPersistence()

  let output = try await ExportRunner.run(.usageJSON, supportDirectory: support)
  let written = try Data(contentsOf: support.appendingPathComponent("usage.json"))
  #expect(output == String(decoding: written, as: UTF8.self))
  try FileManager.default.removeItem(at: support)
}

@Test @MainActor func exportRunnerPrintsUsageJSONFromTheSupportDirectory() async throws {
  let support = FileManager.default.temporaryDirectory.appendingPathComponent("tmb-usage-\(UUID().uuidString)")
  await #expect(throws: UsageExportCommand.NoCachedUsage.self) {
    try await ExportRunner.run(.usageJSON, supportDirectory: support)
  }
  try SnapshotCache(url: support.appendingPathComponent("snapshots.json")).store([.claude: sampleSnapshot(.claude)])

  let output = try await ExportRunner.run(.usageJSON, supportDirectory: support)
  #expect(output.contains(#""id" : "claude""#))
  #expect(output.contains(#""plan" : "Max 20x""#))
  #expect(output.contains(#""id" : "weekly:fable""#))

  let files = try await ExportRunner.run(.files(.menuBar, directory: support))
  #expect(files == "wrote 2 files to \(support.path)")
  try FileManager.default.removeItem(at: support)
}
