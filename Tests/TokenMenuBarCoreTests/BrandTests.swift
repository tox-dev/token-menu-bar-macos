import Foundation
import Testing

@testable import TokenMenuBarCore

@Test func brandColorsRoundTripThroughHex() {
  #expect(Brand.gradientStart.hex == "#4C3BE0")
  #expect(Brand.gradientEnd.hex == "#9A6BFF")
  #expect(Brand.iris.hex == "#5A46E8")
  #expect(Brand.irisDark.hex == "#A78BFA")
  #expect(Brand.pageDark.hex == "#0F1117")
  #expect(Brand.pageLight.hex == "#FAFAFC")
  #expect(Brand.card(dark: true).hex == "#171A22")
  #expect(Brand.card(dark: false).hex == "#FFFFFF")
  #expect(BrandColor(red: -1, green: 2, blue: 0.5).hex == "#00FF80")
  #expect(BrandColor(0xFFFFFF) == BrandColor(red: 1, green: 1, blue: 1))
}

@Test func brandGradientInterpolatesBetweenStops() {
  #expect(Brand.gradient(at: 0) == Brand.gradientStart)
  #expect(Brand.gradient(at: 1) == Brand.gradientEnd)
  #expect(Brand.gradient(at: 2) == Brand.gradientEnd)
  let middle = Brand.gradient(at: 0.5)
  #expect(middle.red > Brand.gradientStart.red && middle.red < Brand.gradientEnd.red)
  #expect(middle.blue > Brand.gradientStart.blue)
  #expect(Brand.name == "Token Menu Bar")
  #expect(!Brand.tagline.isEmpty)
}

@Test func usageStopsConvertTheSemanticScaleToHex() {
  let stops = Brand.usageStops
  #expect(stops.map(\.name) == ["green", "orange", "red"])
  #expect(stops[0].color.green > stops[0].color.red)
  #expect(stops[1].color.red > stops[1].color.green && stops[1].color.green > stops[1].color.blue)
  #expect(stops[2].color.red > stops[2].color.green)
  #expect(stops.allSatisfy { $0.color.hex.count == 7 })
  #expect(Brand.usage(0).hex == stops[0].color.hex)
}

@Test(arguments: [0.0, 0.1, 0.25, 0.4, 0.55, 0.7, 0.85, 1.0])
func usageConversionCoversEveryHueSector(hueFraction: Double) {
  let color = Brand.usage(hueFraction * 100)
  #expect((0...1).contains(color.red) && (0...1).contains(color.green) && (0...1).contains(color.blue))
  #expect(Brand.rgb(HSBColor(hue: hueFraction, saturation: 0.8, brightness: 0.8)).hex.count == 7)
}
