import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore
import Vision

@testable import TokenMenuBarUI

@Test(arguments: [StatusFormat.stacked, .custom]) @MainActor
func settingsTemplateControlsAppearOnlyForCustomFormat(format: StatusFormat) async throws {
  let environment = try makeEnvironment()
  environment.settings.statusFormat = format
  let text = try await renderedText(environment, named: "template-\(format.rawValue)")

  #expect(text.contains("Template") == (format == .custom), "Rendered text: \(text)")
}

@Test(arguments: [false, true]) @MainActor
func settingsDemoNoticeMatchesTheActiveDataMode(isDemo: Bool) async throws {
  let environment = try makeEnvironment()
  environment.isDemo = isDemo
  let text = try await renderedText(environment, named: "demo-\(isDemo)")

  #expect(text.contains("Demo data is on") == isDemo, "Rendered text: \(text)")
}

@Test(arguments: [false, true]) @MainActor
func settingsSetupGuidanceMatchesProviderDiscovery(hasProviders: Bool) async throws {
  let text = try await renderedText(makeEnvironment(populate: hasProviders), named: "providers-\(hasProviders)")
  #expect(
    text.contains("Select Show all providers to set up a provider on this Mac.") == !hasProviders,
    "Rendered text: \(text)")
}

@MainActor
private func renderedText(_ environment: UIEnvironment, named name: String) async throws -> String {
  let hosting = host(
    SettingsTab(environment: environment, mountsIncrementally: false)
      .environment(\.colorScheme, .light)
      .environment(\.displayScale, 2)
      .background(Color.white), width: 880, height: 1200)
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
  if let path = ProcessInfo.processInfo.environment["TOKEN_MENU_BAR_RENDER_ARTIFACTS"] {
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
  }
  return try await Task.detached { try recognizedText(png) }.value
}

private func recognizedText(_ png: Data) throws -> String {
  try autoreleasepool {
    let request = VNRecognizeTextRequest()
    request.revision = VNRecognizeTextRequestRevision3
    request.recognitionLevel = .fast
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = true
    // Hosted VMs must not require GPU or Neural Engine support for text assertions.
    do {
      for (stage, devices) in try request.supportedComputeStageDevices {
        let cpu = try #require(devices.first { if case .cpu = $0 { true } else { false } })
        request.setComputeDevice(cpu, for: stage)
      }
    } catch {
      throw OCRFailure.computeDevices(error)
    }
    do {
      try VNImageRequestHandler(data: png, options: [:]).perform([request])
    } catch {
      throw OCRFailure.recognition(error)
    }
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
  }
}

private enum OCRFailure: Error {
  case computeDevices(any Error)
  case recognition(any Error)
}
