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

  func mixed(with other: HSBColor, fraction: Double) -> HSBColor {
    if fraction <= 0 { return self }
    if fraction >= 1 { return other }
    return HSBColor(
      hue: hue + (other.hue - hue) * fraction,
      saturation: saturation + (other.saturation - saturation) * fraction,
      brightness: brightness + (other.brightness - brightness) * fraction)
  }
}

public enum UsageColor {
  public static let green = HSBColor(hue: 0.38, saturation: 0.72, brightness: 0.52)
  public static let orange = HSBColor(hue: 0.08, saturation: 0.9, brightness: 0.86)
  public static let red = HSBColor(hue: 0.0, saturation: 0.85, brightness: 0.8)
  public static let orangeAt = 0.6

  public static func color(percent: Double) -> HSBColor {
    let fraction = min(max(percent, 0), 100) / 100
    return fraction < orangeAt
      ? green.mixed(with: orange, fraction: pow(fraction / orangeAt, 2))
      : orange.mixed(with: red, fraction: (fraction - orangeAt) / (1 - orangeAt))
  }

  public static func color(pace: PaceStatus, percent: Double) -> HSBColor {
    switch pace {
    case .ahead: orange
    case .exhausted: red
    default: color(percent: percent)
    }
  }
}
