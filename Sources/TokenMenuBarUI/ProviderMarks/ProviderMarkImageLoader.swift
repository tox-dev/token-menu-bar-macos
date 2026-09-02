import AppKit
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

  private init() {}

  public func image(for provider: ProviderID, appearance: ProviderMarkAppearance) -> NSImage? {
    let key = Key(provider: provider, appearance: appearance)
    if let image = images[key] { return image }
    if unavailable.contains(key) { return nil }
    let descriptor = ProviderMarkCatalog.descriptor(for: provider, appearance: appearance)
    guard
      let resourceName = descriptor.resourceName,
      let url = ProviderMarkCatalog.resourceURL(named: resourceName),
      let image = NSImage(contentsOf: url)
    else {
      unavailable.insert(key)
      return nil
    }
    image.isTemplate = false
    image.cacheMode = .always
    images[key] = image
    return image
  }
}
