import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
import TokenMenuBarCore

@testable import TokenMenuBarUI

@Test func providerMarkCatalogLoadsAssetsFromExecutableResourceBundle() throws {
  let metadataURL = try #require(ProviderMarkCatalog.metadataURL)
  let executable = try #require(resolveExecutable(named: "TokenMenuBar", near: metadataURL))
  let output = FileManager.default.temporaryDirectory
    .appendingPathComponent("provider-mark-bundle-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: output) }
  let process = Process()
  process.executableURL = executable
  process.arguments = ["--export-popover", output.path]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice

  try process.run()
  process.waitUntilExit()

  #expect(process.terminationStatus == 0)
  #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("popover-usage-light.png").path))
}

private func resolveExecutable(named name: String, near resource: URL) -> URL? {
  var directory = resource.deletingLastPathComponent()
  for _ in 0..<12 {
    let candidate = directory.appendingPathComponent(name)
    if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    directory.deleteLastPathComponent()
  }
  return nil
}

@Test(arguments: ProviderID.allCases, ProviderMarkAppearance.allCases)
@MainActor func providerMarkLoaderLoadsDistributedAssets(
  provider: ProviderID, appearance: ProviderMarkAppearance
) throws {
  let image = try #require(ProviderMarkImageLoader.shared.image(for: provider, appearance: appearance))
  #expect(image.size.width > 0)
  #expect(image.size.height > 0)
}

@Test(arguments: ProviderID.allCases, ProviderMarkAppearance.allCases)
@MainActor func providerMarkLoaderPreservesOriginalRendering(
  provider: ProviderID, appearance: ProviderMarkAppearance
) throws {
  let image = try #require(ProviderMarkImageLoader.shared.image(for: provider, appearance: appearance))
  #expect(!image.isTemplate)
}

@Test(arguments: ProviderID.allCases, ProviderMarkAppearance.allCases)
@MainActor func providerMarkLoaderCachesByProviderAndAppearance(
  provider: ProviderID, appearance: ProviderMarkAppearance
) throws {
  let first = try #require(ProviderMarkImageLoader.shared.image(for: provider, appearance: appearance))
  let second = try #require(ProviderMarkImageLoader.shared.image(for: provider, appearance: appearance))
  #expect(first === second)
}

@Test(arguments: ProviderID.allCases)
func providerMarkBadgesAdaptTheirPaletteToAppearance(provider: ProviderID) {
  let light = ProviderMarkCatalog.descriptor(for: provider, appearance: .light)
  let dark = ProviderMarkCatalog.descriptor(for: provider, appearance: .dark)
  #expect(light.backgroundColor != dark.backgroundColor)
  #expect(light.foregroundColor != dark.foregroundColor)
}

@Test func providerMarkBadgesUseProviderSpecificColors() {
  let colors = ProviderID.allCases.map {
    ProviderMarkCatalog.descriptor(for: $0, appearance: .light).backgroundColor
  }
  #expect(Set(colors).count == ProviderID.allCases.count)
}

@Test(arguments: ProviderID.allCases, ProviderMarkAppearance.allCases)
func providerMarkDescriptorsExposeReadableAccessibilityLabels(
  provider: ProviderID, appearance: ProviderMarkAppearance
) {
  let descriptor = ProviderMarkCatalog.descriptor(for: provider, appearance: appearance)
  #expect(descriptor.accessibilityLabel == provider.displayName)
  #expect(!descriptor.fallbackText.isEmpty)
}

@Test(arguments: ProviderID.allCases, [ColorScheme.light, .dark])
@MainActor func providerMarkViewKeepsOneSlotSize(provider: ProviderID, colorScheme: ColorScheme) {
  let view = ProviderMarkView(provider).environment(\.colorScheme, colorScheme)
  let hosting = NSHostingView(rootView: view)
  #expect(hosting.fittingSize == ProviderMarkView.defaultSize)
}

@Test func providerMarkMetadataCoversEveryProvider() throws {
  let metadata = try providerMarkMetadata()
  let providers = Set(metadata.assets.map(\.provider) + metadata.fallbacks.map(\.provider))
  #expect(providers == Set(ProviderID.allCases.map(\.rawValue)))
}

@Test func providerMarkMetadataRecordsApprovalAndSources() throws {
  let metadata = try providerMarkMetadata()
  #expect(metadata.retrieved == "2026-09-01")
  for record in metadata.assets + metadata.fallbacks {
    #expect(!record.approvalState.isEmpty)
    #expect(record.sourcePage.scheme == "https")
    #expect(record.terms.scheme == "https")
  }
}

@Test func providerMarkAssetArchivesHaveProvenance() throws {
  for asset in try providerMarkMetadata().assets {
    #expect(asset.sourceArchive?.scheme == "https")
    #expect(asset.sourceArchiveSHA256?.count == 64)
  }
}

@Test func providerMarkCatalogMatchesRecordedVariants() throws {
  for asset in try providerMarkMetadata().assets {
    let provider = try #require(ProviderID(rawValue: asset.provider))
    for variant in asset.variants {
      let appearance = try #require(ProviderMarkAppearance(rawValue: variant.appearance))
      #expect(ProviderMarkCatalog.descriptor(for: provider, appearance: appearance).resourceName == variant.resource)
    }
  }
}

@Test func providerMarkFilesMatchRecordedHashes() throws {
  for asset in try providerMarkMetadata().assets {
    for variant in asset.variants {
      let url = try #require(ProviderMarkCatalog.resourceURL(named: variant.resource))
      let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
      #expect(digest == variant.sha256)
    }
  }
}

private struct ProviderMarkMetadata: Decodable {
  let retrieved: String
  let assets: [ProviderMarkRecord]
  let fallbacks: [ProviderMarkRecord]
}

private struct ProviderMarkRecord: Decodable {
  let provider: String
  let approvalState: String
  let sourcePage: URL
  let terms: URL
  let sourceArchive: URL?
  let sourceArchiveSHA256: String?
  let variants: [ProviderMarkVariant]

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    provider = try values.decode(String.self, forKey: .provider)
    approvalState = try values.decode(String.self, forKey: .approvalState)
    sourcePage = try values.decode(URL.self, forKey: .sourcePage)
    terms = try values.decode(URL.self, forKey: .terms)
    sourceArchive = try values.decodeIfPresent(URL.self, forKey: .sourceArchive)
    sourceArchiveSHA256 = try values.decodeIfPresent(String.self, forKey: .sourceArchiveSHA256)
    variants = try values.decodeIfPresent([ProviderMarkVariant].self, forKey: .variants) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case approvalState
    case sourcePage
    case terms
    case sourceArchive
    case sourceArchiveSHA256
    case variants
  }
}

private struct ProviderMarkVariant: Decodable {
  let appearance: String
  let resource: String
  let sha256: String
}

private func providerMarkMetadata() throws -> ProviderMarkMetadata {
  let url = try #require(ProviderMarkCatalog.metadataURL)
  return try JSONDecoder().decode(ProviderMarkMetadata.self, from: Data(contentsOf: url))
}
