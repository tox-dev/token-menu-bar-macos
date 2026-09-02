import AppKit
import Foundation
import Testing

@testable import TokenMenuBarUI

@Test func coverageGatePopoverExportUsesTextWhenAProviderMarkAssetIsMissing() throws {
  let metadata = try #require(ProviderMarkCatalog.metadataURL)
  let executable = try #require(providerMarkGateExecutable(near: metadata))
  let asset = try #require(ProviderMarkCatalog.resourceURL(named: "Claude.svg"))
  let baselineDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "provider-mark-baseline-\(UUID().uuidString)")
  let fallbackDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "provider-mark-fallback-\(UUID().uuidString)")
  let backupDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "provider-mark-backup-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
  let backup = backupDirectory.appendingPathComponent(asset.lastPathComponent)
  defer {
    try? FileManager.default.removeItem(at: baselineDirectory)
    try? FileManager.default.removeItem(at: fallbackDirectory)
    try? FileManager.default.removeItem(at: backupDirectory)
  }

  try providerMarkGateExport(executable: executable, output: baselineDirectory)
  try FileManager.default.moveItem(at: asset, to: backup)
  defer {
    if FileManager.default.fileExists(atPath: backup.path) {
      try? FileManager.default.moveItem(at: backup, to: asset)
    }
  }
  try providerMarkGateExport(executable: executable, output: fallbackDirectory)

  let baseline = try Data(contentsOf: baselineDirectory.appendingPathComponent("popover-usage-light.png"))
  let fallback = try Data(contentsOf: fallbackDirectory.appendingPathComponent("popover-usage-light.png"))
  let image = try #require(NSImage(data: fallback))
  #expect(image.size.width > 0)
  #expect(image.size.height > 0)
  #expect(fallback != baseline)
}

private func providerMarkGateExport(executable: URL, output: URL) throws {
  let process = Process()
  process.executableURL = executable
  process.arguments = ["--export-popover", output.path]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0)
}

private func providerMarkGateExecutable(near resource: URL) -> URL? {
  var directory = resource.deletingLastPathComponent()
  for _ in 0..<12 {
    let candidate = directory.appendingPathComponent("TokenMenuBar")
    if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    directory.deleteLastPathComponent()
  }
  return nil
}
