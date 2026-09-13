import Testing
import TokenMenuBarCore

@Test func increasedContrastLadderIsMoreSaturatedAndDarkerAtEveryStop() {
  let pairs = [
    (UsageLadder.standard.green, UsageLadder.increased.green),
    (UsageLadder.standard.orange, UsageLadder.increased.orange),
    (UsageLadder.standard.red, UsageLadder.increased.red),
  ]
  for (standard, increased) in pairs {
    #expect(increased.hue == standard.hue)
    #expect(increased.saturation > standard.saturation)
    #expect(increased.brightness < standard.brightness)
  }
}

@Test func increasedContrastColoursFollowTheSameLadderShape() {
  #expect(UsageColor.color(percent: 0, contrast: .increased) == UsageLadder.increased.green)
  #expect(UsageColor.color(percent: 60, contrast: .increased) == UsageLadder.increased.orange)
  #expect(UsageColor.color(percent: 100, contrast: .increased) == UsageLadder.increased.red)
  #expect(UsageColor.color(percent: 30, contrast: .increased) != UsageColor.color(percent: 30))
  #expect(UsageColor.color(pace: .ahead, percent: 10, contrast: .increased) == UsageLadder.increased.orange)
  #expect(UsageColor.color(pace: .exhausted, percent: 10, contrast: .increased) == UsageLadder.increased.red)
  #expect(UsageColor.color(pace: .onTrack, percent: 0, contrast: .increased) == UsageLadder.increased.green)
}

@Test(arguments: [(false, UsageContrast.standard), (true, .increased)])
func usageContrastMapsTheAccessibilityFlag(increased: Bool, expected: UsageContrast) {
  #expect(UsageContrast(increased: increased) == expected)
  #expect(UsageLadder.ladder(for: expected) == (increased ? UsageLadder.increased : UsageLadder.standard))
}
