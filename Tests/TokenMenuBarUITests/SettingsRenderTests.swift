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
func settingsDemoNoticeMatchesTheActiveDataMode(isDemo: Bool) async throws {
  let environment = try makeEnvironment()
  environment.isDemo = isDemo
  try await captureSettings(
    environment, named: "demo-\(isDemo)",
    expectation: RenderedText(
      contains: ["Version"] + (isDemo ? ["Demo data is on"] : []),
      excludes: isDemo ? [] : ["Demo data is on"]))
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

@MainActor
private func captureSettings(_ environment: UIEnvironment, named name: String, expectation: RenderedText) async throws {
  let hosting = host(
    SettingsTab(environment: environment, mountsIncrementally: false)
      .environment(\.colorScheme, .light)
      .environment(\.displayScale, 2)
      .background(Color.white), width: 880, height: 1200)
  try await capture(hosting, named: name, expectation: expectation)
}

@Test(arguments: [
  ("present", RenderedText(contains: ["ALPHA BRAVO"])),
  ("missing", RenderedText(contains: ["ALPHA BRAVO CHARLIE"], matches: false)),
  ("excluded", RenderedText(excludes: ["CHARLIE"])),
  ("unexpected", RenderedText(excludes: ["BRAVO"], matches: false)),
  ("suffix", RenderedText(suffix: "BRAVO")),
  ("wrong-suffix", RenderedText(suffix: "ALPHA", matches: false)),
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
