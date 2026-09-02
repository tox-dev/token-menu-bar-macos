import Foundation
import Testing

@testable import TokenMenuBarCore

private let paceNow = Date(timeIntervalSince1970: 1_788_030_000)

@Test func unknownPaceExplainsThatItIsStillLearning() {
  let pace = PaceEstimate(status: .unknown, expectedPercent: nil, ratio: nil, projectedExhaustion: nil)
  #expect(pace.comparison(now: paceNow) == "Learning pace")
}

@Test func earlyPaceShowsExpectedUsageAndProjectionWhenKnown() {
  let pace = PaceEstimate(
    status: .unknown, expectedPercent: 3, ratio: nil,
    projectedExhaustion: paceNow.addingTimeInterval(2 * 86400))
  let comparison = pace.comparison(now: paceNow)
  #expect(comparison.contains("Learning pace"))
  #expect(comparison.contains("expected 3%"))
  #expect(comparison.contains("hits 100% in 2d"))
}

@Test func onTrackPaceShowsRatioAndThatItLastsToReset() {
  let pace = PaceEstimate(status: .onTrack, expectedPercent: 42, ratio: 1, projectedExhaustion: nil)
  let comparison = pace.comparison(now: paceNow)
  #expect(comparison.contains("On pace"))
  #expect(comparison.contains("expected 42%"))
  #expect(comparison.contains("1.0×"))
  #expect(comparison.hasSuffix("lasts to reset"))
}

@Test func aheadPaceShowsRatioAndProjectedExhaustion() {
  let pace = PaceEstimate(
    status: .ahead, expectedPercent: 42, ratio: 1.6,
    projectedExhaustion: paceNow.addingTimeInterval(2 * 86400))
  let comparison = pace.comparison(now: paceNow)
  #expect(comparison.contains("Ahead of pace"))
  #expect(comparison.contains("expected 42%"))
  #expect(comparison.contains("1.6×"))
  #expect(comparison.contains("hits 100% in 2d"))
}

@Test func underPaceShowsRatioAndThatItLastsToReset() {
  let pace = PaceEstimate(status: .behind, expectedPercent: 42, ratio: 0.6, projectedExhaustion: nil)
  let comparison = pace.comparison(now: paceNow)
  #expect(comparison.contains("Under pace"))
  #expect(comparison.contains("0.6×"))
  #expect(comparison.hasSuffix("lasts to reset"))
}

@Test func exhaustedPaceStatesThatTheLimitWasReached() {
  let pace = PaceEstimate(status: .exhausted, expectedPercent: nil, ratio: nil, projectedExhaustion: paceNow)
  #expect(pace.comparison(now: paceNow) == "Limit reached")
}
