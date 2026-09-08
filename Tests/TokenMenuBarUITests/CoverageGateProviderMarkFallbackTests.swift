import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@testable import TokenMenuBarUI

@Test @MainActor func providerMarkUsesItsTextFallbackWhenTheAssetIsMissing() throws {
  let missing = ProviderMarkImageLoader(resourceURL: { _ in nil })
  let fallback = try rendered(ProviderMarkView(.claude, imageLoader: missing))
  let image = try rendered(ProviderMarkView(.claude, imageLoader: .shared))

  #expect(missing.image(for: .claude, appearance: .light) == nil)
  #expect(!fallback.isEmpty)
  #expect(fallback != image)
}

@MainActor
private func rendered(_ view: ProviderMarkView) throws -> Data {
  let hosting = host(view, width: ProviderMarkView.defaultSize.width, height: ProviderMarkView.defaultSize.height)
  let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
  hosting.cacheDisplay(in: hosting.bounds, to: rep)
  return try #require(rep.tiffRepresentation)
}
