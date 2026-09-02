import Foundation
import TokenMenuBarCore

public enum ProviderMarkAppearance: String, CaseIterable, Sendable {
  case light
  case dark
}

public struct ProviderMarkDescriptor: Equatable, Sendable {
  public let provider: ProviderID
  public let appearance: ProviderMarkAppearance
  public let resourceName: String?
  public let fallbackText: String
  public let backgroundColor: BrandColor
  public let foregroundColor: BrandColor

  public var accessibilityLabel: String { provider.displayName }
}

public enum ProviderMarkCatalog {
  public static func descriptor(
    for provider: ProviderID, appearance: ProviderMarkAppearance
  ) -> ProviderMarkDescriptor {
    ProviderMarkDescriptor(
      provider: provider,
      appearance: appearance,
      resourceName: resourceName(for: provider, appearance: appearance),
      fallbackText: provider.shortLabel,
      backgroundColor: backgroundColor(for: provider, appearance: appearance),
      foregroundColor: foregroundColor(for: provider, appearance: appearance))
  }

  public static var metadataURL: URL? {
    resourceURL(named: "provider-marks.json")
  }

  static func resourceURL(named resourceName: String) -> URL? {
    let resource = resourceName as NSString
    let name = resource.deletingPathExtension
    let fileExtension = resource.pathExtension
    return resourceBundle.url(forResource: name, withExtension: fileExtension, subdirectory: "ProviderMarks")
      ?? resourceBundle.url(forResource: name, withExtension: fileExtension)
  }

  private static let resourceBundle: Bundle = {
    if let url = Bundle.main.url(forResource: "TokenMenuBar_TokenMenuBarUI", withExtension: "bundle"),
      let bundle = Bundle(url: url)
    {
      return bundle
    }
    return Bundle.module
  }()

  private static func resourceName(
    for provider: ProviderID, appearance: ProviderMarkAppearance
  ) -> String? {
    switch (provider, appearance) {
    case (.codex, _): "OpenAI-white-monoblossom.svg"
    case (.cursor, _): "CUBE_2D_DARK.svg"
    case (.claude, _): "Claude.svg"
    case (.gemini, _): "GoogleGemini.svg"
    case (.copilot, _): "GitHubCopilot.svg"
    }
  }

  private static func backgroundColor(
    for provider: ProviderID, appearance: ProviderMarkAppearance
  ) -> BrandColor {
    switch (provider, appearance) {
    case (.claude, .light): BrandColor(0xD9_7757)
    case (.claude, .dark): BrandColor(0xB8_5F43)
    case (.codex, .light): BrandColor(0x10_A37F)
    case (.codex, .dark): BrandColor(0x0C_8064)
    case (.gemini, .light): BrandColor(0x76_51B5)
    case (.gemini, .dark): BrandColor(0x5D_3D91)
    case (.cursor, .light): BrandColor(0x67_78C4)
    case (.cursor, .dark): BrandColor(0x43_4D8E)
    case (.copilot, .light): BrandColor(0x6E_40C9)
    case (.copilot, .dark): BrandColor(0x54_30A0)
    }
  }

  private static func foregroundColor(
    for provider: ProviderID, appearance: ProviderMarkAppearance
  ) -> BrandColor {
    switch (provider, appearance) {
    case (.claude, .light): BrandColor(0x7A_2F1E)
    case (.claude, .dark): BrandColor(0xFF_E7DF)
    case (.codex, .light): BrandColor(0x00_0000)
    case (.codex, .dark): BrandColor(0xFF_FFFF)
    case (.gemini, .light): BrandColor(0x17_4EA6)
    case (.gemini, .dark): BrandColor(0xDC_E8FF)
    case (.cursor, .light): BrandColor(0x26_251E)
    case (.cursor, .dark): BrandColor(0xED_ECEC)
    case (.copilot, .light): BrandColor(0x3C_2D91)
    case (.copilot, .dark): BrandColor(0xEC_E9FF)
    }
  }
}
