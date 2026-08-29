import Charts
import SwiftUI
import TokenMenuBarCore

public struct HistoryTab: View {
  @Bindable var environment: UIEnvironment

  public init(environment: UIEnvironment) {
    self.environment = environment
  }

  private var presenter: HistoryPresenter { environment.historyPresenter }
  private var settings: TokenMenuBarCore.Settings { environment.settings }

  public var body: some View {
    ScrollingTab {
      VStack(alignment: .leading, spacing: 10) {
        controls
        HStack(alignment: .top, spacing: 12) {
          chart.frame(minWidth: 660, minHeight: 380)
          HistoryInspector(environment: environment).frame(width: 220)
        }
        if settings.historyRange == .custom {
          customRange
        }
        ForEach(environment.state.orderedProviders, id: \.self) { provider in
          if let sections = presenter.analytics[provider] {
            AnalyticsSectionsView(provider: provider, sections: sections, environment: environment)
          }
        }
      }
      .frame(minWidth: 980, alignment: .leading)
    }
    .task { presenter.reload() }
  }

  private var controls: some View {
    HStack(spacing: 10) {
      Picker("Range", selection: Binding(get: { settings.historyRange }, set: { presenter.setRange($0) })) {
        ForEach(HistoryRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      Picker("Rollup", selection: Binding(get: { settings.historyRollup }, set: { presenter.setRollup($0) })) {
        ForEach(Rollup.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      Toggle("Stacked", isOn: Binding(get: { settings.historyStacked }, set: { presenter.setStacked($0) }))
        .toggleStyle(.checkbox)
    }
  }

  private var customRange: some View {
    HStack {
      Button(action: pageBack) { Image(systemName: "chevron.left") }.disabled(!presenter.canPageBack)
      DatePicker(
        "From", selection: Binding(get: { presenter.customStart }, set: { presenter.setCustomStart($0) }),
        displayedComponents: components)
      DatePicker(
        "To", selection: Binding(get: { presenter.customEnd }, set: { presenter.setCustomEnd($0) }),
        displayedComponents: components
      )
      .disabled(presenter.followNow)
      Toggle("Now", isOn: Binding(get: { presenter.followNow }, set: { presenter.setFollowNow($0) })).toggleStyle(
        .checkbox)
      Button(action: pageForward) { Image(systemName: "chevron.right") }.disabled(!presenter.canPageForward)
    }
    .font(.caption)
  }

  public func pageBack() {
    presenter.page(forward: false, now: environment.now)
  }

  public func pageForward() {
    presenter.page(forward: true, now: environment.now)
  }

  private var components: DatePickerComponents {
    settings.historyRollup == .day ? [.date] : [.date, .hourAndMinute]
  }

  @ViewBuilder private var chart: some View {
    switch presenter.state {
    case .loading:
      ProgressView("Loading history…").frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let error):
      ContentUnavailableView("History unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
    case .loaded(let data, let refreshing, _):
      ZStack(alignment: .topTrailing) {
        if data.isEmpty {
          EmptyHistoryView()
        } else {
          UsageChart(data: data, presenter: presenter, stacked: settings.historyStacked, timeZone: presenter.timeZone)
        }
        if refreshing {
          UpdatingBadge()
        }
      }
    }
  }
}

public struct EmptyHistoryView: View {
  public init() {}

  public var body: some View {
    ContentUnavailableView(
      "No samples yet", systemImage: "chart.xyaxis.line",
      description: Text("Usage is recorded every few minutes while the app runs."))
  }
}

public struct UpdatingBadge: View {
  public init() {}

  public var body: some View {
    Text("Updating").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(
      .thinMaterial, in: Capsule())
  }
}

public struct UsageChart: View {
  public let data: HistoryRenderData
  public let presenter: HistoryPresenter
  public let stacked: Bool
  public let timeZone: TimeZone

  public static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]

  public init(data: HistoryRenderData, presenter: HistoryPresenter, stacked: Bool, timeZone: TimeZone) {
    self.data = data
    self.presenter = presenter
    self.stacked = stacked
    self.timeZone = timeZone
  }

  public static func color(index: Int) -> Color {
    palette[index % palette.count]
  }

  public var body: some View {
    Chart {
      ForEach(Array(data.series.enumerated()), id: \.element.id) { index, series in
        ForEach(series.points, id: \.self) { point in
          if stacked {
            AreaMark(
              x: .value("Time", point.date), yStart: .value("Base", point.stackBase),
              yEnd: .value("Used", point.stackTop),
              series: .value("Window", series.label)
            )
            .foregroundStyle(by: .value("Window", series.label))
            .interpolationMethod(.linear)
            .opacity(opacity(series.key))
          } else {
            LineMark(
              x: .value("Time", point.date), y: .value("Used", point.value), series: .value("Window", series.label)
            )
            .foregroundStyle(by: .value("Window", series.label))
            .interpolationMethod(.monotone)
            .opacity(opacity(series.key))
          }
        }
        if let selected = presenter.selectedDate, let point = series.value(at: selected) {
          PointMark(x: .value("Time", point.date), y: .value("Used", stacked ? point.stackTop : point.value))
            .foregroundStyle(by: .value("Window", series.label))
            .symbolSize(60)
        }
      }
      if let selected = presenter.selectedDate {
        RuleMark(x: .value("Selected", selected)).foregroundStyle(.secondary).lineStyle(
          StrokeStyle(lineWidth: 1, dash: [3, 3]))
      }
    }
    .chartForegroundStyleScale(domain: data.series.map(\.label), range: data.series.indices.map(Self.color(index:)))
    .chartXScale(domain: data.domain)
    .chartYScale(domain: 0...data.yMax)
    .chartYAxis {
      AxisMarks(values: .automatic(desiredCount: 5)) { value in
        AxisGridLine()
        AxisValueLabel { Text(Self.percentLabel(value)) }
      }
    }
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 4)) { _ in
        AxisGridLine()
        AxisValueLabel(format: Self.axisFormat(for: data.domain), centered: false)
      }
    }
    .chartLegend(.hidden)
    .chartOverlay { proxy in ChartOverlay(chart: self, proxy: proxy) }
    .environment(\.timeZone, timeZone)
  }

  static func axisFormat(for domain: ClosedRange<Date>) -> Date.FormatStyle {
    domain.upperBound.timeIntervalSince(domain.lowerBound) > 2 * 86400
      ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute()
  }

  static func percentLabel(_ value: AxisValue) -> String {
    value.as(Double.self).map { Format.percent($0) } ?? ""
  }

  func opacity(_ key: WindowKey) -> Double {
    guard let hovered = presenter.hoveredKey else { return 1 }
    return hovered == key ? 1 : 0.18
  }

  public func hover(_ phase: HoverPhase, in plot: CGRect, dateAt: (CGFloat) -> Date?) {
    switch phase {
    case .active(let location): pick(location, in: plot, dateAt: dateAt)
    case .ended: presenter.select(x: nil)
    }
  }

  public func pick(_ location: CGPoint, in plot: CGRect, dateAt: (CGFloat) -> Date?) {
    presenter.select(x: dateAt(location.x - plot.minX))
  }
}

struct ChartOverlay: View {
  let chart: UsageChart
  let proxy: ChartProxy

  var body: some View {
    GeometryReader { geometry in
      let plot = geometry[proxy.plotFrame!]
      let drag = DragGesture(minimumDistance: 0)
      Rectangle().fill(Color.clear).contentShape(Rectangle())
        .gesture(drag.onChanged { chart.pick($0.location, in: plot) { proxy.value(atX: $0, as: Date.self) } })
        .onContinuousHover { chart.hover($0, in: plot) { proxy.value(atX: $0, as: Date.self) } }
    }
  }
}

public struct HistoryInspector: View {
  @Bindable var environment: UIEnvironment

  public init(environment: UIEnvironment) {
    self.environment = environment
  }

  private var presenter: HistoryPresenter { environment.historyPresenter }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle("UTC", isOn: Binding(get: { environment.settings.historyUseUTC }, set: { presenter.setUseUTC($0) }))
        .toggleStyle(.checkbox)
        .font(.caption)
      Text(presenter.selectedDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Latest values")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      if let data = presenter.state.data {
        ForEach(Array(data.series.enumerated()), id: \.element.id) { index, series in
          legendRow(series, index: index)
        }
      }
      ForEach(presenter.availableWindows.filter { !presenter.isVisible($0.key) }) { summary in
        Button(action: { presenter.toggleVisibility(summary.key) }, label: { hiddenRow(summary) })
          .buttonStyle(.plain)
          .font(.caption)
      }
      Text("Click a row to hide it, double-click to isolate it, hover to highlight.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.top, 4)
    }
  }

  func hiddenRow(_ summary: WindowSummary) -> some View {
    HStack {
      Circle().fill(Color.secondary.opacity(0.3)).frame(width: 8, height: 8)
      Text("\(summary.key.provider.displayName) \(summary.label)").strikethrough().foregroundStyle(.secondary)
      Spacer()
    }
  }

  func legendRow(_ series: HistorySeries, index: Int) -> some View {
    HStack {
      Circle().fill(UsageChart.color(index: index)).frame(width: 8, height: 8)
      Text(series.label).lineLimit(1)
      Spacer()
      Text(presenter.value(for: series)).monospacedDigit()
    }
    .font(.caption)
    .contentShape(Rectangle())
    .opacity(presenter.hoveredKey.map { $0 == series.key ? 1 : 0.35 } ?? 1)
    .onHover { presenter.hoveredKey = $0 ? series.key : nil }
    .onTapGesture(count: 2) { presenter.isolate(series.key) }
    .onTapGesture(count: 1) { presenter.toggleVisibility(series.key) }
  }
}

public struct AnalyticsSectionsView: View {
  public let provider: ProviderID
  public let sections: [AnalyticsSection]
  @Bindable var environment: UIEnvironment

  public init(provider: ProviderID, sections: [AnalyticsSection], environment: UIEnvironment) {
    self.provider = provider
    self.sections = sections
    self.environment = environment
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("\(provider.displayName) analytics").font(.headline)
        Spacer()
        Picker(
          "Metric",
          selection: Binding(
            get: { environment.settings.historyAnalyticsMetric },
            set: { environment.settings.historyAnalyticsMetric = $0 })
        ) {
          ForEach(sections) { Text($0.metric.title).tag($0.metric) }
        }
        .labelsHidden()
        .frame(maxWidth: 200)
      }
      if let section = sections.first(where: { $0.metric == environment.settings.historyAnalyticsMetric })
        ?? sections.first
      {
        HStack(alignment: .firstTextBaseline) {
          Text(section.totalText).font(.title2.monospacedDigit().weight(.semibold))
          Text(section.metric == .surfaceUsagePercent ? "average daily usage" : "total \(section.metric.unit)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Chart(section.bars) { bar in
          BarMark(x: .value("Day", bar.date, unit: .day), y: .value(section.metric.unit, bar.value))
            .foregroundStyle(by: .value("Series", bar.series))
        }
        .chartForegroundStyleScale(domain: section.series, range: section.series.indices.map(UsageChart.color(index:)))
        .chartXAxis {
          AxisMarks(values: .stride(by: .day, count: 7)) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
          }
        }
        .frame(height: 170)
      }
    }
    .padding(12)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
  }
}
