import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@testable import TokenMenuBarUI

@Test(arguments: [StatusFormat.stacked, .custom]) @MainActor
func settingsTemplateControlsAppearOnlyForCustomFormat(format: StatusFormat) async throws {
  let environment = try makeEnvironment()
  environment.settings.statusFormat = format
  try await captureSettings(
    environment, named: "template-\(format.rawValue)",
    expectation: RenderedText(
      contains: ["Format"] + (format == .custom ? ["Template"] : []),
      excludes: format == .custom ? [] : ["Template"]))
}

@Test(arguments: [false, true]) @MainActor
func settingsDemoHasOneControlInEitherDataMode(isDemo: Bool) async throws {
  let environment = try makeEnvironment()
  environment.isDemo = isDemo
  try await captureSettings(
    environment, named: "demo-\(isDemo)",
    expectation: RenderedText(
      contains: ["Version", "Demo data"], excludes: ["Demo data is on", "Turn Off Demo Data"]))
}

@Test(arguments: [false, true]) @MainActor
func settingsSetupGuidanceMatchesProviderDiscovery(hasProviders: Bool) async throws {
  let guidance = "Select Show all providers to set up a provider on this Mac."
  try await captureSettings(
    makeEnvironment(populate: hasProviders), named: "providers-\(hasProviders)",
    expectation: RenderedText(
      contains: ["Show all providers"] + (hasProviders ? [] : [guidance]),
      excludes: hasProviders ? [guidance] : []))
}

@Test(arguments: [false, true]) @MainActor
func settingsCollectionControlsRenderTheirValuesOnlyWhenExpanded(expanded: Bool) async throws {
  let environment = try makeEnvironment()
  environment.settings.analyticsRefreshMinutes = 25
  environment.settings.paceWorkdays = 4
  environment.disclosures.setExpanded(expanded, for: "settings.collection")
  let controls = ["Every 25 min", "Expect usage on 4 days a week", "Write usage.json"]
  try await captureSettings(
    environment, named: "collection-\(expanded)",
    expectation: RenderedText(
      contains: ["Collection and integrations"] + (expanded ? controls : []),
      excludes: expanded ? [] : controls), height: 2_000)
}

@Test(arguments: [ProviderID.claude, .codex], [false, true]) @MainActor
func providerCostsKeepAttributionVisibleAndExposeAllModels(provider: ProviderID, expanded: Bool) async throws {
  let rows = ["ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO", "FOXTROT", "GOLF"].enumerated().map { index, model in
    HistoryAnalyticsRow(
      provider: provider,
      point: AnalyticsPoint(day: DayStamp.string(fixedNow), metric: .costUSD, series: model, value: Double(index)))
  }
  let disclosures = DisclosureState()
  disclosures.setExpanded(expanded, for: "usage.\(provider.rawValue).cost")
  try await capture(
    host(
      ProviderCostSummary(
        summary: SpendSummaryPresenter.summary(rows: rows, now: fixedNow, timeZone: .current),
        provider: provider, disclosures: disclosures
      )
      .environment(\.colorScheme, .light).padding(12).background(Color.white), width: 700, height: 500),
    named: "cost-\(provider.rawValue)-\(expanded)",
    expectation: RenderedText(
      contains: [provider.displayName, "API-equivalent estimates", "Model cost estimates"]
        + (expanded ? ["ALPHA", "GOLF", "not your subscription bill"] : []),
      excludes: expanded ? [] : ["ALPHA", "GOLF"]))
}

@MainActor
private func captureSettings(
  _ environment: UIEnvironment, named name: String, expectation: RenderedText, height: CGFloat = 1_200
) async throws {
  let hosting = host(
    SettingsTab(environment: environment, mountsIncrementally: false)
      .environment(\.colorScheme, .light)
      .environment(\.displayScale, 2)
      .background(Color.white), width: 880, height: height)
  try await capture(hosting, named: name, expectation: expectation)
}

@Test(arguments: [
  ("present", RenderedText(contains: ["ALPHA BRAVO"])),
  ("missing", RenderedText(contains: ["ALPHA BRAVO CHARLIE"], matches: false)),
  ("excluded", RenderedText(excludes: ["CHARLIE"])),
  ("unexpected", RenderedText(excludes: ["BRAVO"], matches: false)),
  ("suffix", RenderedText(suffix: "BRAVO", layout: .paragraph)),
  ("wrong-suffix", RenderedText(suffix: "ALPHA", matches: false, layout: .paragraph)),
]) @MainActor
func renderedTextVerifierDistinguishesMissingAndClippedWords(name: String, expectation: RenderedText) async throws {
  try await capture(
    host(
      Text("ALPHA BRAVO").font(.system(size: 30)).foregroundStyle(.black)
        .frame(width: 400, height: 80).background(.white), width: 400, height: 80),
    named: "verifier-\(name)", expectation: expectation)
}

@MainActor
private func capture(_ hosting: NSView, named name: String, expectation: RenderedText) async throws {
  hosting.appearance = NSAppearance(named: .aqua)
  await mainActorTurn()
  hosting.layoutSubtreeIfNeeded()
  let bitmap = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(hosting.bounds.width * 2), pixelsHigh: Int(hosting.bounds.height * 2),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0))
  bitmap.size = hosting.bounds.size
  hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
  let png = try #require(bitmap.representation(using: .png, properties: [:]))
  let directory = URL(
    fileURLWithPath: try #require(ProcessInfo.processInfo.environment["TOKEN_MENU_BAR_RENDER_ARTIFACTS"]),
    isDirectory: true)
  try expectation.capture(png, at: directory.appendingPathComponent("\(name).png"))
}
