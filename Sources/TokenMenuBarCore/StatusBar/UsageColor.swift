import Foundation

public struct HSBColor: Hashable, Sendable {
  public let hue: Double
  public let saturation: Double
  public let brightness: Double

  public init(hue: Double, saturation: Double, brightness: Double) {
    self.hue = hue
    self.saturation = saturation
    self.brightness = brightness
  }
}

public enum UsageColor {
  public static let greenHue = 0.36
  public static let redHue = 0.0
  public static let saturation = 0.68
  public static let brightness = 0.82

  public static func color(percent: Double) -> HSBColor {
    let fraction = min(max(percent, 0), 100) / 100
    let eased = fraction * fraction * (3 - 2 * fraction)
    return HSBColor(hue: greenHue - (greenHue - redHue) * eased, saturation: saturation, brightness: brightness)
  }

  public static func color(pace: PaceStatus, percent: Double) -> HSBColor {
    switch pace {
    case .ahead: HSBColor(hue: 0.08, saturation: saturation, brightness: brightness)
    case .exhausted: HSBColor(hue: redHue, saturation: saturation, brightness: brightness)
    default: color(percent: percent)
    }
  }
}
