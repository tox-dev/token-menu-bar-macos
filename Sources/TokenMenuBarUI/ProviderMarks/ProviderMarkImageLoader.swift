import AppKit
import ImageIO
import TokenMenuBarCore

@MainActor
public final class ProviderMarkImageLoader {
  public static let shared = ProviderMarkImageLoader()

  private struct Key: Hashable {
    let provider: ProviderID
    let appearance: ProviderMarkAppearance
  }

  private var images: [Key: NSImage] = [:]
  private var unavailable: Set<Key> = []
  private let resourceURL: (String) -> URL?

  init(resourceURL: @escaping (String) -> URL? = ProviderMarkCatalog.resourceURL(named:)) {
    self.resourceURL = resourceURL
  }

  public func image(for provider: ProviderID, appearance: ProviderMarkAppearance) -> NSImage? {
    let key = Key(provider: provider, appearance: appearance)
    if let image = images[key] { return image }
    if unavailable.contains(key) { return nil }
    let descriptor = ProviderMarkCatalog.descriptor(for: provider, appearance: appearance)
    guard
      let url = resourceURL(descriptor.resourceName),
      let image = loadImage(at: url)
    else {
      unavailable.insert(key)
      return nil
    }
    image.isTemplate = false
    image.cacheMode = .always
    images[key] = image
    return image
  }

  private func loadImage(at url: URL) -> NSImage? {
    guard url.pathExtension == "png" else { return NSImage(contentsOf: url) }
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary)
    else { return nil }
    return NSImage(cgImage: image, size: .zero)
  }
}
