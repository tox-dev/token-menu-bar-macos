import Foundation
import Testing

@testable import TokenMenuBarCore

private let key = WindowKey(provider: .claude, windowID: "session")
private let other = WindowKey(provider: .codex, windowID: "weekly")
private let utc = TimeZone(identifier: "UTC")!

private func sample(_ minutes: Double, _ value: Double, resets: Double? = 300, key: WindowKey = key) -> UsageSample {
  UsageSample(
    timestamp: fixedNow.addingTimeInterval(minutes * 60), key: key, usedPercent: value,
    resetsAt: resets.map { fixedNow.addingTimeInterval($0 * 60) })
}

private func raw(_ minutes: Double, _ value: Double, resets: Double? = nil) -> ChartPipeline.Raw {
  ChartPipeline.Raw(
    date: fixedNow.addingTimeInterval(minutes * 60), value: value,
    resetsAt: resets.map { fixedNow.addingTimeInterval($0 * 60) })
}

@Test func bucketKeepsLatestSamplePerBucket() {
  let samples = [sample(0.2, 1), sample(0.8, 2), sample(1.5, 3), sample(0.5, 9, key: other)]
  let buckets = ChartPipeline.bucket(samples, rollup: .minute, timeZone: utc)
  #expect(buckets.map(\.value) == [2, 3])
  let hourly = ChartPipeline.bucket(samples, rollup: .hour, timeZone: utc)
  #expect(hourly.map(\.value) == [3])
  let reversed = ChartPipeline.bucket([sample(0.8, 2), sample(0.2, 1)], rollup: .minute, timeZone: utc)
  #expect(reversed.map(\.value) == [2])
}

@Test func insertResetZerosAddsCliffAtResetBoundary() {
  let points = [raw(0, 80, resets: 10), raw(20, 5, resets: 310)]
  let result = ChartPipeline.insertResetZeros(points)
  #expect(result.map(\.value) == [80, 0, 5])
  #expect(result[1].date == fixedNow.addingTimeInterval(600))
  let dropOnly = ChartPipeline.insertResetZeros([raw(0, 80, resets: 10), raw(5, 5, resets: 310)])
  #expect(dropOnly.map(\.value) == [80, 0, 5])
  #expect(dropOnly[1].date == fixedNow.addingTimeInterval(299))
  let noReset = ChartPipeline.insertResetZeros([raw(0, 80), raw(5, 5)])
  #expect(noReset.map(\.value) == [80, 5])
  #expect(ChartPipeline.insertResetZeros([raw(0, 1)]).count == 1)
  let rising = ChartPipeline.insertResetZeros([raw(0, 5, resets: 10), raw(5, 80, resets: 310)])
  #expect(rising.map(\.value) == [5, 80])
}

@Test func clipCarriesLastValueIntoDomain() {
  let points = [raw(-10, 30), raw(5, 40), raw(20, 50)]
  let clipped = ChartPipeline.clip(points, start: fixedNow, end: fixedNow.addingTimeInterval(600))
  #expect(clipped.map(\.value) == [30, 40])
  #expect(clipped[0].date == fixedNow)
  let exact = ChartPipeline.clip([raw(0, 1), raw(1, 2)], start: fixedNow, end: fixedNow.addingTimeInterval(600))
  #expect(exact.map(\.value) == [1, 2])
  #expect(ChartPipeline.clip([raw(5, 1)], start: fixedNow, end: fixedNow.addingTimeInterval(600)).count == 1)
}

@Test func changePointsKeepsRunEndsAndResets() {
  let points = [raw(0, 1), raw(1, 1), raw(2, 1), raw(3, 2), raw(4, 0), raw(5, 0), raw(6, 3)]
  let kept = ChartPipeline.changePoints(points)
  #expect(kept.map(\.value) == [1, 1, 2, 0, 0, 3])
  #expect(kept.map { $0.date.timeIntervalSince(fixedNow) / 60 } == [0, 2, 3, 4, 5, 6])
  #expect(ChartPipeline.changePoints([raw(0, 1), raw(1, 1)]).count == 2)
}

@Test func extendToNowPinsLatestValue() {
  let extended = ChartPipeline.extendToNow([raw(0, 4)], end: fixedNow.addingTimeInterval(120))
  #expect(extended.map(\.value) == [4, 4])
  #expect(extended[1].date == fixedNow.addingTimeInterval(120))
  #expect(ChartPipeline.extendToNow([], end: fixedNow).isEmpty)
  #expect(ChartPipeline.extendToNow([raw(5, 4)], end: fixedNow).count == 1)
}

@Test func downsamplePreservesExtremes() {
  let points = (0..<1000).map { raw(Double($0), $0 == 500 ? 100 : $0 == 700 ? 0 : 50) }
  let reduced = ChartPipeline.downsample(points, limit: 100)
  #expect(reduced.count <= 100)
  #expect(reduced.first == points.first)
  #expect(reduced.last == points.last)
  #expect(reduced.contains { $0.value == 100 })
  #expect(reduced.contains { $0.value == 0 })
  #expect(zip(reduced, reduced.dropFirst()).allSatisfy { $0.date <= $1.date })
  #expect(ChartPipeline.downsample(points, limit: 2000).count == 1000)
  let descending = (0..<50).map { raw(Double($0), Double(50 - $0)) }
  #expect(ChartPipeline.downsample(descending, limit: 10).count <= 10)
}

@Test func stackAccumulatesBases() {
  let lower = HistorySeries(
    key: key, label: "a",
    points: [SeriesPoint(date: fixedNow, value: 10), SeriesPoint(date: fixedNow.addingTimeInterval(60), value: 20)])
  let upper = HistorySeries(
    key: other, label: "b", points: [SeriesPoint(date: fixedNow.addingTimeInterval(30), value: 5)])
  let stacked = ChartPipeline.stack([lower, upper])
  #expect(stacked[0].points.map(\.value) == [10, 10, 20])
  #expect(stacked[1].points.map(\.stackBase) == [10, 10, 20])
  #expect(stacked[1].points.map(\.value) == [0, 5, 5])
  #expect(stacked[1].points.last?.stackTop == 25)
}

@Test func renderProducesSeriesDomainAndYMax() {
  let samples = [sample(-30, 10), sample(0, 80, resets: 5), sample(20, 5, resets: 305), sample(0, 60, key: other)]
  let request = HistoryRequest(
    keys: [key, other], start: fixedNow.addingTimeInterval(-600), end: fixedNow.addingTimeInterval(3600),
    rollup: .minute, timeZone: utc)
  let data = ChartPipeline.render(
    samples: samples, request: request, labels: [key: "Session"], now: fixedNow.addingTimeInterval(1800))
  #expect(data.series.map(\.label) == ["Session", "weekly"])
  #expect(data.domain == request.start...fixedNow.addingTimeInterval(1800))
  #expect(data.yMax == 100)
  #expect(data.series[0].points.map(\.value) == [10, 80, 0, 5, 5])
  #expect(data.series[0].points.last?.date == fixedNow.addingTimeInterval(1800))
  #expect(!data.isEmpty)
  #expect(data.series[0].value(at: fixedNow.addingTimeInterval(10))?.value == 80)
  #expect(
    ChartPipeline.nearestDate(in: data, to: fixedNow.addingTimeInterval(1190)) == fixedNow.addingTimeInterval(1200))
  let stacked = ChartPipeline.render(
    samples: samples,
    request: HistoryRequest(
      keys: [key, other], start: request.start, end: request.end, rollup: .minute, stacked: true, timeZone: utc),
    labels: [:], now: fixedNow.addingTimeInterval(1800))
  #expect(stacked.yMax == 140)
  let empty = ChartPipeline.render(samples: [], request: request, labels: [:], now: fixedNow)
  #expect(empty.isEmpty)
  #expect(ChartPipeline.nearestDate(in: empty, to: fixedNow) == nil)
  let future = ChartPipeline.render(
    samples: [],
    request: HistoryRequest(
      keys: [key], start: fixedNow.addingTimeInterval(60), end: fixedNow.addingTimeInterval(120), rollup: .day),
    labels: [:], now: fixedNow)
  #expect(future.domain.lowerBound == future.domain.upperBound)
}

@Test func dailyBucketsGroupTopSeriesAndOther() {
  var points: [AnalyticsPoint] = []
  for index in 0..<10 {
    points.append(AnalyticsPoint(day: "2026-08-01", metric: .turns, series: "s\(index)", value: Double(index + 1)))
  }
  points.append(AnalyticsPoint(day: "2026-08-02", metric: .turns, series: "s9", value: 0))
  points.append(AnalyticsPoint(day: "2026-08-02", metric: .credits, series: "ignored", value: 5))
  let buckets = ChartPipeline.dailyBuckets(points, metric: .turns, topSeries: 3)
  #expect(buckets.map(\.series) == ["Other", "s7", "s8", "s9"])
  #expect(buckets.first { $0.series == "Other" }?.value == 28)
  #expect(buckets.allSatisfy { $0.day == "2026-08-01" })
  #expect(ChartPipeline.dailyBuckets([], metric: .turns).isEmpty)
}

@Test func historyEnumsExposeSpans() {
  #expect(HistoryRange.allCases.map(\.days) == [1, 7, 30, 60, nil])
  #expect(Rollup.allCases.map(\.seconds) == [60, 3600, 86400])
  #expect(HistorySeries(key: key, label: "x", points: []).value(at: fixedNow) == nil)
  #expect(HistorySeries(key: key, label: "x", points: []).id == key)
  #expect(ChartPipeline.stepValue([], at: fixedNow) == 0)
}
