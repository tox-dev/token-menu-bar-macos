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

public enum UsageContrast: Sendable, Hashable {
  case standard
  case increased

  public init(increased: Bool) {
    self = increased ? .increased : .standard
  }
}

public struct UsageLadder: Hashable, Sendable {
  public let green: HSBColor
  public let orange: HSBColor
  public let red: HSBColor

  public static let standard = UsageLadder(
    green: HSBColor(hue: 0.38, saturation: 0.72, brightness: 0.52),
    orange: HSBColor(hue: 0.08, saturation: 0.9, brightness: 0.86),
    red: HSBColor(hue: 0.0, saturation: 0.85, brightness: 0.8))
  public static let increased = UsageLadder(
    green: HSBColor(hue: 0.38, saturation: 0.95, brightness: 0.4),
    orange: HSBColor(hue: 0.08, saturation: 1, brightness: 0.74),
    red: HSBColor(hue: 0.0, saturation: 1, brightness: 0.6))

  public static func ladder(for contrast: UsageContrast) -> UsageLadder {
    switch contrast {
    case .standard: standard
    case .increased: increased
    }
  }
}

public enum UsageColor {
  public static let green = UsageLadder.standard.green
  public static let orange = UsageLadder.standard.orange
  public static let red = UsageLadder.standard.red
  public static let orangeAt = 0.6

  public static func color(percent: Double, contrast: UsageContrast = .standard) -> HSBColor {
    let ladder = UsageLadder.ladder(for: contrast)
    let fraction = min(max(percent, 0), 100) / 100
    return fraction < orangeAt
      ? ladder.green.mixed(with: ladder.orange, fraction: pow(fraction / orangeAt, 2))
      : ladder.orange.mixed(with: ladder.red, fraction: (fraction - orangeAt) / (1 - orangeAt))
  }

  public static func color(pace: PaceStatus, percent: Double, contrast: UsageContrast = .standard) -> HSBColor {
    switch pace {
    case .ahead: UsageLadder.ladder(for: contrast).orange
    case .exhausted: UsageLadder.ladder(for: contrast).red
    default: color(percent: percent, contrast: contrast)
    }
  }
}
