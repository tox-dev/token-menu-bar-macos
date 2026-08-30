import Foundation

public struct BrandColor: Hashable, Sendable {
  public let red: Double
  public let green: Double
  public let blue: Double

  public init(red: Double, green: Double, blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  public init(_ hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
  }

  public var hex: String {
    let channels = [red, green, blue].map { Int((min(max($0, 0), 1) * 255).rounded()) }
    return "#" + channels.map { String(format: "%02X", $0) }.joined()
  }

  public func mixed(with other: BrandColor, fraction: Double) -> BrandColor {
    let amount = min(max(fraction, 0), 1)
    return BrandColor(
      red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
      blue: blue + (other.blue - blue) * amount)
  }
}

/// Palette shared by the app icon, the menu bar rendering and the website, so both stay in step.
public enum Brand {
  public static let name = "Token Menu Bar"
  public static let tagline = "Your AI coding plan limits, one glance away"

  public static let gradientStart = BrandColor(0x4C_3BE0)
  public static let gradientEnd = BrandColor(0x9A_6BFF)
  public static let iris = BrandColor(0x5A_46E8)
  public static let irisDark = BrandColor(0xA7_8BFA)
  public static let pageLight = BrandColor(0xFA_FAFC)
  public static let pageDark = BrandColor(0x0F_1117)
  public static let cardLight = BrandColor(0xFF_FFFF)
  public static let cardDark = BrandColor(0x17_1A22)

  /// The card the website draws a screenshot on, so an exported shot sits flush with the page around it.
  public static func card(dark: Bool) -> BrandColor {
    dark ? cardDark : cardLight
  }

  public static func gradient(at fraction: Double) -> BrandColor {
    gradientStart.mixed(with: gradientEnd, fraction: fraction)
  }

  /// The usage scale owns the semantic colors rather than the brand, so a full gauge reads as red.
  public static var usageStops: [(name: String, color: BrandColor)] {
    [("green", usage(0)), ("orange", usage(UsageColor.orangeAt * 100)), ("red", usage(100))]
  }

  static func usage(_ percent: Double) -> BrandColor {
    rgb(UsageColor.color(percent: percent))
  }

  static func rgb(_ hsb: HSBColor) -> BrandColor {
    let chroma = hsb.brightness * hsb.saturation
    let sector = hsb.hue * 6
    let secondary = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
    let base = hsb.brightness - chroma
    let rgb: (Double, Double, Double) =
      switch sector {
      case ..<1: (chroma, secondary, 0)
      case ..<2: (secondary, chroma, 0)
      case ..<3: (0, chroma, secondary)
      case ..<4: (0, secondary, chroma)
      case ..<5: (secondary, 0, chroma)
      default: (chroma, 0, secondary)
      }
    return BrandColor(red: rgb.0 + base, green: rgb.1 + base, blue: rgb.2 + base)
  }
}
