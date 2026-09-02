import Accessibility
import Charts
import SwiftUI
import TokenMenuBarCore

public struct UsageChart: View {
  struct BarPattern: Hashable {
    let direction: Int
    let bands: Int
    let fadedStep: Int
    let solid: Bool
  }

  public let data: HistoryChartModel
  public let presenter: HistoryPresenter
  public let stacked: Bool
  public let timeZone: TimeZone

  public static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]

  public init(data: HistoryChartModel, presenter: HistoryPresenter, stacked: Bool, timeZone: TimeZone) {
    self.data = data
    self.presenter = presenter
    self.stacked = stacked
    self.timeZone = timeZone
  }

  public static func color(index: Int) -> Color {
    palette[index % palette.count]
  }

  public var body: some View {
    HistoryBaseChart(data: data, stacked: stacked)
      .equatable()
      .chartXScale(domain: data.domain)
      .chartYScale(domain: 0...data.yMax)
      .chartYAxis {
        AxisMarks(values: .automatic(desiredCount: 5)) { value in
          AxisGridLine()
          AxisValueLabel { Text(axisLabel(value)) }
        }
      }
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
          AxisGridLine()
          AxisValueLabel(format: Self.axisFormat(for: data.domain))
        }
      }
      .chartLegend(.hidden)
      .chartOverlay { proxy in ChartOverlay(chart: self, proxy: proxy) }
      .environment(\.timeZone, timeZone)
      .focusable()
      .onKeyPress(.leftArrow) {
        presenter.moveSelection(-1)
        return .handled
      }
      .onKeyPress(.rightArrow) {
        presenter.moveSelection(1)
        return .handled
      }
      .onKeyPress(.escape) {
        presenter.select(x: nil)
        return .handled
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("history-chart")
      .accessibilityLabel("\(data.metric.title) history")
      .accessibilityValue(data.summaryText)
      .accessibilityChartDescriptor(HistoryChartAccessibility(data: data, timeZone: timeZone))
      .richHelp(
        TooltipContent(
          title: "History chart",
          body:
            "Move the pointer to inspect a date. Use Left and Right to move between visible dates, "
            + "and Escape to clear the selection."
        ))
  }

  static func stroke(variant: Int) -> StrokeStyle {
    guard variant > 0 else { return StrokeStyle(lineWidth: 2) }
    let patterns: [[CGFloat]] = [[7, 3], [2, 3], [8, 2, 2, 2], [4, 2, 1, 2], [10, 3, 2, 3]]
    return StrokeStyle(
      lineWidth: 1.75 + CGFloat((variant / patterns.count) % 3) * 0.25,
      dash: patterns[variant % patterns.count], dashPhase: CGFloat((variant / (patterns.count * 3)) % 7))
  }

  static func barStyle(_ slot: HistoryStyleSlot) -> AnyShapeStyle {
    let color = color(index: slot.hueIndex)
    let pattern = barPattern(variant: slot.variant)
    guard !pattern.solid else { return AnyShapeStyle(color) }
    let directions: [(UnitPoint, UnitPoint)] = [
      (.leading, .trailing), (.top, .bottom), (.topLeading, .bottomTrailing), (.bottomLeading, .topTrailing),
    ]
    let direction = directions[pattern.direction]
    let faded = 0.3 + Double(pattern.fadedStep) * 0.1
    let colors = (0..<pattern.bands).flatMap { _ in [color, color.opacity(faded)] }
    return AnyShapeStyle(
      LinearGradient(colors: colors, startPoint: direction.0, endPoint: direction.1))
  }

  static func barPattern(variant: Int) -> BarPattern {
    BarPattern(
      direction: variant % 4, bands: 2 + (variant / 4) % 4, fadedStep: (variant / 16) % 4,
      solid: variant == 0)
  }

  static func symbol(for variant: Int) -> BasicChartSymbolShape {
    switch variant % 3 {
    case 1: .square
    case 2: .diamond
    default: .circle
    }
  }

  static func symbolPoints(_ points: [SeriesPoint], limit: Int = 16) -> [SeriesPoint] {
    guard points.count > limit, limit > 1 else { return points }
    let last = Double(points.count - 1)
    return (0..<limit).map { points[Int((Double($0) * last / Double(limit - 1)).rounded())] }
  }

  static func markLabel(_ label: String, at date: Date, timeZone: TimeZone) -> String {
    var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
    style.timeZone = timeZone
    return "\(label), \(date.formatted(style))"
  }

  static func axisFormat(for domain: ClosedRange<Date>) -> Date.FormatStyle {
    domain.upperBound.timeIntervalSince(domain.lowerBound) > 2 * 86400
      ? .dateTime.month(.defaultDigits).day() : .dateTime.hour().minute()
  }

  func selectionPoints(at date: Date) -> [HistorySelection] {
    data.visibleSeries.compactMap { series in
      series.value(at: date, metric: data.metric).map { HistorySelection(series: series, point: $0) }
    }
  }

  public func hover(_ phase: HoverPhase, in plot: CGRect) {
    switch phase {
    case .active(let location): pick(location, in: plot)
    case .ended: presenter.select(x: nil)
    }
  }

  public func pick(_ location: CGPoint, in plot: CGRect) {
    guard plot.width > 0, plot.contains(location) else {
      presenter.select(x: nil)
      return
    }
    let fraction = (location.x - plot.minX) / plot.width
    let interval = data.domain.upperBound.timeIntervalSince(data.domain.lowerBound)
    presenter.select(x: data.domain.lowerBound.addingTimeInterval(interval * fraction))
  }

  private func axisLabel(_ value: AxisValue) -> String {
    guard let number = value.as(Double.self) else { return "" }
    return formatted(number)
  }

  private func formatted(_ value: Double) -> String {
    Self.formatted(value, unit: data.metric.unit)
  }

  static func formatted(_ value: Double, unit: HistoryUnit) -> String {
    switch unit {
    case .percentage: Format.percent(value)
    case .usd: "$\(value.formatted(.number.precision(.fractionLength(2))))"
    case .tokens, .credits, .count: Format.compactNumber(value)
    }
  }
}

struct HistorySelection: Identifiable {
  let series: HistorySeries
  let point: SeriesPoint

  var id: HistorySeriesID { series.id }
}

private struct HistoryBaseChart: View, Equatable {
  let data: HistoryChartModel
  let stacked: Bool

  var body: some View {
    Chart {
      ForEach(data.visibleSeries) { series in
        switch data.metric.markKind {
        case .stepLine, .line:
          line(series)
        case .bars:
          bars(series)
        }
      }
    }
  }

  @ChartContentBuilder
  private func line(_ series: HistorySeries) -> some ChartContent {
    let color = UsageChart.color(index: series.style.hueIndex)
    let stroke = UsageChart.stroke(variant: series.style.variant)
    ForEach(series.points, id: \.self) { point in
      LineMark(
        x: .value("Time", point.date), y: .value("Value", point.value),
        series: .value("Series", series.id.storageKey)
      )
      .foregroundStyle(color)
      .lineStyle(stroke)
      .interpolationMethod(data.metric.markKind == .stepLine ? .stepEnd : .linear)
      .accessibilityHidden(true)
      if point.isReset {
        PointMark(x: .value("Reset", point.date), y: .value("Value", point.value))
          .foregroundStyle(color)
          .symbol(.diamond)
          .symbolSize(28)
          .accessibilityHidden(true)
      }
    }
    ForEach(UsageChart.symbolPoints(series.points), id: \.self) { point in
      PointMark(x: .value("Time", point.date), y: .value("Value", point.value))
        .foregroundStyle(color)
        .symbol(UsageChart.symbol(for: series.style.variant))
        .symbolSize(18)
        .accessibilityHidden(true)
    }
  }

  @ChartContentBuilder
  private func bars(_ series: HistorySeries) -> some ChartContent {
    let style = UsageChart.barStyle(series.style)
    ForEach(series.points, id: \.self) { point in
      if stacked {
        BarMark(
          x: .value("Day", point.date, unit: .day), y: .value("Value", point.value), stacking: .standard
        )
        .foregroundStyle(style)
        .accessibilityHidden(true)
      } else {
        BarMark(
          x: .value("Day", point.date, unit: .day), y: .value("Value", point.value), stacking: .unstacked
        )
        .foregroundStyle(style)
        .position(by: .value("Series", series.id.storageKey))
        .accessibilityHidden(true)
      }
    }
  }
}

private struct HistoryChartAccessibility: AXChartDescriptorRepresentable {
  let data: HistoryChartModel
  let timeZone: TimeZone

  func makeChartDescriptor() -> AXChartDescriptor {
    let xAxis = AXNumericDataAxisDescriptor(
      title: "Time",
      range: data.domain.lowerBound
        .timeIntervalSinceReferenceDate...data.domain.upperBound.timeIntervalSinceReferenceDate,
      gridlinePositions: []
    ) { value in
      var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
      style.timeZone = timeZone
      return Date(timeIntervalSinceReferenceDate: value).formatted(style)
    }
    let yAxis = AXNumericDataAxisDescriptor(title: data.metric.title, range: 0...data.yMax, gridlinePositions: []) {
      value in
      switch data.metric.unit {
      case .percentage: Format.percent(value)
      case .usd: "$\(value.formatted(.number.precision(.fractionLength(2))))"
      case .tokens, .credits, .count: Format.compactNumber(value)
      }
    }
    let series = data.visibleSeries.flatMap { series -> [AXDataSeriesDescriptor] in
      if data.metric.markKind == .bars {
        return [
          AXDataSeriesDescriptor(
            name: series.label, isContinuous: false,
            dataPoints: series.points.map { point in
              AXDataPoint(
                x: point.date.timeIntervalSinceReferenceDate, y: point.value,
                label: resetLabel(point))
            })
        ]
      }
      return [
        AXDataSeriesDescriptor(
          name: series.label, isContinuous: true,
          dataPoints: series.points.map { point in
            AXDataPoint(
              x: point.date.timeIntervalSinceReferenceDate, y: point.value,
              label: resetLabel(point))
          })
      ]
    }
    return AXChartDescriptor(
      title: "\(data.metric.title) history", summary: data.summaryText, xAxis: xAxis, yAxis: yAxis, series: series)
  }

  private func resetLabel(_ point: SeriesPoint) -> String? {
    guard point.isReset else { return nil }
    guard let date = point.resetsAt else { return "Reset" }
    var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
    style.timeZone = timeZone
    return "Reset at \(date.formatted(style))"
  }
}
